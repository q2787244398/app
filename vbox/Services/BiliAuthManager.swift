//
//  BiliAuthManager.swift
//  vbox
//
//  B站扫码登录管理器 — 对接 Node 常驻系统的 /website/api/bili/login/* 路由
//
//  ★ 接口契约（来自 TVS 逆向数据包 login-methods / deep-login-bili-start.json）：
//
//    POST /website/api/bili/login/start        （无 body）
//      返回（扁平，无 data 包裹）：
//      {
//        "code": 0,
//        "taskId": "eb3aeee5-...",                 // 轮询用
//        "status": "waiting",
//        "msg": "请使用哔哩哔哩 App 扫码确认",
//        "qrUrl": "https://account.bilibili.com/h5/account-h5/auth/scan-web?...&qrcode_key=...",
//        "qrImage": "data:image/png;base64,iVBORw0..."  // 服务端已生成，直接用
//      }
//
//    POST /website/api/bili/login/poll         body = {"provider":"bili","taskId":"..."}
//      返回：{"code":0,"status":"waiting|scanned|success|expired|error","terminal":false,"msg":"..."}
//
//    POST /website/api/bili/login/cancel       body = {"provider":"bili","taskId":"..."}
//    PUT  /website/api/bili/cookie             body = {"cookie":"..."}
//    DELETE /website/api/bili/cookie
//
//  登录成功后 Node 侧已把 cookie 写入 db(/siteCookie/bili/cookie)；
//  iOS 调 NodeCredentialSyncService.shared.saveProfile() 拉回 Keychain。
//
//  ★ 不修改 CloudDriveAuthManager 现有方法；不影响其他网盘逻辑。
//

import Foundation
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - B站扫码状态

enum BiliQrLoginState: Equatable {
    case idle
    case loading          // 正在生成二维码
    case waitingScan      // status: waiting
    case scanned          // status: scanned
    case saving           // 已确认，正在回收 cookie
    case success          // 登录成功
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "准备生成二维码"
        case .loading: return "正在生成二维码..."
        case .waitingScan: return "请使用哔哩哔哩 App 扫码"
        case .scanned: return "已扫码，请在手机上确认"
        case .saving: return "已确认，正在回收登录态..."
        case .success: return "哔哩哔哩登录成功"
        case .error(let msg): return "错误: \(msg)"
        }
    }

    /// 是否处于轮询中（决定按钮显隐）
    var isPolling: Bool {
        switch self {
        case .waitingScan, .scanned, .saving: return true
        default: return false
        }
    }
}

// MARK: - B站认证管理器

final class BiliAuthManager: ObservableObject {

    static let shared = BiliAuthManager()

    @Published var qrLoginState: BiliQrLoginState = .idle
    @Published var qrCodeImage: UIImage?
    @Published var qrUrl: String?
    @Published var message: String = ""

    private(set) var taskId: String?

    private var isCancelled = false
    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    // 与 AliyunPgAuthManager 保持一致：空 init，不在单例构造期启动未持有的 Task。
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    // MARK: - Node.js baseURL

    private var nodeBaseURL: String {
        NodeRuntimeManager.shared.baseURL
    }

    // MARK: - 完整扫码登录流程

    @MainActor
    func startQrLogin() async {
        // 重置
        pollTask?.cancel()
        isCancelled = false
        qrLoginState = .loading
        qrCodeImage = nil
        qrUrl = nil
        message = ""
        taskId = nil

        do {
            let start = try await requestQrCode()
            taskId = start.taskId
            qrCodeImage = start.image
            qrUrl = start.qrUrl
            message = start.msg
            qrLoginState = .waitingScan

            try await pollLoginStatus(taskId: start.taskId)
        } catch {
            qrLoginState = .error(error.localizedDescription)
            print("[Bili] 扫码登录失败: \(error)")
        }
    }

    // MARK: - Step 1: 获取二维码

    private struct QrStart {
        let taskId: String
        let image: UIImage?
        let qrUrl: String
        let msg: String
    }

    private func requestQrCode() async throws -> QrStart {
        let url = URL(string: "\(nodeBaseURL)/website/api/bili/login/start")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiliAuthError.requestFailed("获取二维码失败（HTTP 异常）")
        }

        // 扁平结构：{code, taskId, status, msg, qrUrl, qrImage}
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let code = json["code"] as? Int ?? -1
        let msg = json["msg"] as? String ?? ""

        guard code == 0, let taskId = json["taskId"] as? String, !taskId.isEmpty else {
            throw BiliAuthError.requestFailed(msg.isEmpty ? "二维码数据格式异常" : msg)
        }

        let qrUrl = json["qrUrl"] as? String ?? ""
        var image: UIImage? = nil
        if let dataUrl = json["qrImage"] as? String {
            image = Self.decodeDataURL(dataUrl)
        }
        // 兜底：服务端未给图片时，用 qrUrl 自行生成
        if image == nil, !qrUrl.isEmpty {
            image = Self.makeQRCode(from: qrUrl)
        }

        return QrStart(
            taskId: taskId,
            image: image,
            qrUrl: qrUrl,
            msg: msg.isEmpty ? "请使用哔哩哔哩 App 扫码确认" : msg
        )
    }

    // MARK: - Step 2: 轮询扫码状态

    @MainActor
    private func pollLoginStatus(taskId: String) async throws {
        let url = URL(string: "\(nodeBaseURL)/website/api/bili/login/poll")!
        var consecutiveErrors = 0

        while !isCancelled && !Task.isCancelled {
            do {
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(
                    withJSONObject: ["provider": "bili", "taskId": taskId]
                )

                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw BiliAuthError.pollFailed("轮询失败（HTTP 异常）")
                }
                consecutiveErrors = 0

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let status = (json["status"] as? String ?? "").lowercased()
                let terminal = json["terminal"] as? Bool ?? false
                let msg = json["msg"] as? String ?? ""

                switch status {
                case "waiting":
                    // bundle 的 _Ce() 对「等待扫码」和「已扫码待确认」都返回 status:"waiting"，
                    // 已扫码状态只在 msg 里体现（"已扫码，请在 Bili App 确认"）。
                    let scanned = msg.contains("已扫码")
                    let text = msg
                    await MainActor.run {
                        self.qrLoginState = scanned ? .scanned : .waitingScan
                        if !text.isEmpty { self.message = text }
                    }
                case "scanned", "confirm", "confirmed":
                    await MainActor.run { self.qrLoginState = .scanned; if !msg.isEmpty { self.message = msg } }
                case "success":
                    await MainActor.run { self.qrLoginState = .saving }
                    // 对齐光鸭/蜗牛：cookie 已写入 Node db，拉回 Keychain
                    _ = await NodeCredentialSyncService.shared.saveProfile()
                    await MainActor.run {
                        self.message = msg.isEmpty ? "Cookie 已保存" : msg
                        self.qrLoginState = .success
                    }
                    return
                case "expired":
                    await MainActor.run { self.qrLoginState = .error(msg.isEmpty ? "二维码已过期，请重试" : msg) }
                    return
                case "error", "failed":
                    await MainActor.run { self.qrLoginState = .error(msg.isEmpty ? "扫码登录失败" : msg) }
                    return
                default:
                    if terminal {
                        await MainActor.run { self.qrLoginState = .error(msg.isEmpty ? "扫码登录已结束" : msg) }
                        return
                    }
                    // 未知状态：保持等待
                }
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 5 {
                    await MainActor.run { self.qrLoginState = .error("网络异常，已重试 \(consecutiveErrors) 次") }
                    return
                }
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 秒轮询
        }
    }

    // MARK: - 取消登录

    @MainActor
    func cancel() {
        isCancelled = true
        pollTask?.cancel()
        if let tid = taskId, !tid.isEmpty {
            let url = URL(string: "\(nodeBaseURL)/website/api/bili/login/cancel")
            var req = URLRequest(url: url ?? URL(string: nodeBaseURL)!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": "bili", "taskId": tid])
            session.dataTask(with: req).resume()
        }
        qrLoginState = .idle
    }

    /// 视图消失时静默清理轮询（不发 cancel 请求，避免误取消 Node 侧任务）
    @MainActor
    func stopPolling() {
        isCancelled = true
        pollTask?.cancel()
    }

    // MARK: - 检查登录状态（从 Keychain 读，与授权中心一致）

    @MainActor
    func checkLoginStatus() -> Bool {
        CloudDriveAuthManager.shared.isAuthorized(.bilibili)
    }
    // MARK: - 清除 Cookie（Node 侧 + Keychain 侧）

    @MainActor
    func clearCookie() async {
        do {
            let url = URL(string: "\(nodeBaseURL)/website/api/bili/cookie")!
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            _ = try await session.data(for: req)
            CloudDriveAuthManager.shared.removeCredential(for: .bilibili)
            qrLoginState = .idle
            print("[Bili] Cookie 已清除")
        } catch {
            print("[Bili] 清除 Cookie 失败: \(error)")
        }
    }

    // MARK: - 二维码工具

    /// 解析服务端返回的 "data:image/png;base64,xxxx"
    static func decodeDataURL(_ string: String) -> UIImage? {
        let base64: String
        if let comma = string.firstIndex(of: ",") {
            base64 = String(string[string.index(after: comma)...])
        } else {
            base64 = string
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    /// 本地生成二维码（兜底）
    static func makeQRCode(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue(string.utf8.count > 800 ? "L" : "M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 错误类型

enum BiliAuthError: Error, LocalizedError {
    case requestFailed(String)
    case pollFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): return msg
        case .pollFailed(let msg): return msg
        }
    }
}

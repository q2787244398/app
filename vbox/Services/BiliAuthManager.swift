//
//  BiliAuthManager.swift
//  vbox
//
//  B站扫码登录管理器 — 通过 Node.js 常驻系统的 /website/api/bili/login/* 路由
//  实现 B站扫码登录，cookie 自动写入 Node.js db (/siteCookie/bili/cookie)
//  登录成功后调 NodeCredentialSyncService.saveProfile() 拉回 Keychain
//  授权中心 nodeManagedAccountCard 显示登录状态
//
//  ★ 不修改 CloudDriveAuthManager 现有方法
//  ★ 不影响百度/夸克/UC/阿里 等网盘的任何逻辑
//  ★ 对齐光鸭/蜗牛的 Node 托管模式
//

import Foundation
import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - B站扫码状态

enum BiliQrLoginState: Equatable {
    case idle
    case loading
    case waitingScan
    case scanned
    case success
    case error(String)

    var displayText: String {
        switch self {
        case .idle: return "准备中"
        case .loading: return "正在生成二维码..."
        case .waitingScan: return "请使用 B站 App 扫码"
        case .scanned: return "已扫码，请在手机上确认"
        case .success: return "登录成功！"
        case .error(let msg): return "错误: \(msg)"
        }
    }
}

// MARK: - B站认证管理器

final class BiliAuthManager: ObservableObject {

    static let shared = BiliAuthManager()

    @Published var qrLoginState: BiliQrLoginState = .idle
    @Published var qrCodeImage: UIImage?
    @Published var qrCodeLink: String?

    private var isCancelled = false
    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        Task { await checkLoginStatus() }
    }

    // MARK: - Node.js baseURL

    private var nodeBaseURL: String {
        NodeRuntimeManager.shared.baseURL
    }

    // MARK: - 完整扫码登录流程

    func startQrLogin() async {
        await MainActor.run {
            qrLoginState = .loading
            qrCodeImage = nil
            qrCodeLink = nil
            isCancelled = false
        }

        do {
            // Step 1: 调 Node.js 获取二维码
            let loginData = try await requestQrCode()

            let qrUrl = loginData["url"] as? String ?? ""
            let qrcodeKey = loginData["qrcode_key"] as? String ?? ""

            let qrImage = generateQRImage(from: qrUrl)

            await MainActor.run {
                self.qrCodeLink = qrUrl
                self.qrCodeImage = qrImage
                self.qrLoginState = .waitingScan
            }

            // Step 2: 轮询扫码状态
            try await pollLoginStatus(qrcodeKey: qrcodeKey)

        } catch {
            await MainActor.run {
                self.qrLoginState = .error(error.localizedDescription)
            }
            print("[Bili] 扫码登录失败: \(error)")
        }
    }

    // MARK: - Step 1: 获取二维码

    private func requestQrCode() async throws -> [String: Any] {
        let url = URL(string: "\(nodeBaseURL)/website/api/bili/login/start")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiliAuthError.requestFailed("获取二维码失败")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let dataDict = json["data"] as? [String: Any] else {
            throw BiliAuthError.requestFailed("二维码数据格式异常")
        }
        return dataDict
    }

    // MARK: - Step 2: 轮询扫码

    private func pollLoginStatus(qrcodeKey: String) async throws {
        let url = URL(string: "\(nodeBaseURL)/website/api/bili/login/poll")!
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && !self.isCancelled {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body = ["taskId": qrcodeKey]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (data, response) = try await self.session.data(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continue
                    }
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    let code = json["code"] as? Int ?? -1

                    switch code {
                    case 86101:
                        await MainActor.run { self.qrLoginState = .waitingScan }
                    case 86090:
                        await MainActor.run { self.qrLoginState = .scanned }
                    case 0:
                        // 登录成功，拉回 Keychain（对齐光鸭/蜗牛）
                        _ = await NodeCredentialSyncService.shared.saveProfile()
                        await MainActor.run {
                            self.qrLoginState = .success
                        }
                        return
                    case 86038:
                        await MainActor.run {
                            self.qrLoginState = .error("二维码已过期，请重试")
                        }
                        return
                    default:
                        break
                    }
                } catch {
                    // 网络错误，继续重试
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        try await pollTask?.value
    }

    // MARK: - 取消登录

    func cancel() {
        isCancelled = true
        pollTask?.cancel()
        Task { @MainActor in
            qrLoginState = .idle
        }
    }

    // MARK: - 检查登录状态

    func checkLoginStatus() async {
        // 从 Keychain 读取，与授权中心一致
        await MainActor.run {
            _ = CloudDriveAuthManager.shared.isAuthorized(.bilibili)
        }
    }

    // MARK: - 清除 Cookie

    func clearCookie() async {
        do {
            let url = URL(string: "\(nodeBaseURL)/website/api/bili/cookie")!
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            _ = try await session.data(for: req)

            // 同时清除 Keychain 侧的凭证
            await MainActor.run {
                CloudDriveAuthManager.shared.removeCredential(for: .bilibili)
                self.qrLoginState = .idle
            }
            print("[Bili] Cookie 已清除")
        } catch {
            print("[Bili] 清除 Cookie 失败: \(error)")
        }
    }

    // MARK: - 二维码图片生成

    private func generateQRImage(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIQRCodeGenerator()
        filter.message = Data(string.utf8)
        filter.scale = 8.0
        guard let outputImage = filter.outputImage else { return nil }
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
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

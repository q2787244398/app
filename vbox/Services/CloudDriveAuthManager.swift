import Foundation
import Combine
import UIKit
import WebKit
import CryptoKit

enum CloudDriveAuthType: String, Codable {
    case manual
    case qr
    case webView
    case oauth
}

enum CloudDriveAuthState: String, Codable {
    case notAuthorized
    case valid
    case expiringSoon
    case expired
    case invalid
    case unknown

    var displayText: String {
        switch self {
        case .notAuthorized: return "未授权"
        case .valid: return "正常"
        case .expiringSoon: return "即将过期"
        case .expired: return "已过期"
        case .invalid: return "授权失效"
        case .unknown: return "未检测"
        }
    }
}

struct CloudDriveCredential: Codable, Identifiable {
    var id: String { driveType }
    let driveType: String
    var authType: CloudDriveAuthType
    var accessToken: String?
    var refreshToken: String?
    var cookie: String?
    var driveId: String?
    var userId: String?
    var userName: String?
    var avatar: String?
    var expiresAt: Date?
    var updatedAt: Date
    var lastCheckedAt: Date?
    var state: CloudDriveAuthState
    var statusMessage: String?
    var extra: [String: String]

    var displayName: String {
        if let userName, !userName.isEmpty { return userName }
        switch driveType {
        case CloudDriveManager.DriveType.ali.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.quark.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.baidu.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.one15.rawValue: return "已授权账号"
        case CloudDriveManager.DriveType.uc.rawValue: return "已授权账号"
        default: return "已授权账号"
        }
    }

    var primarySecret: String? {
        if let refreshToken, !refreshToken.isEmpty { return refreshToken }
        if let cookie, !cookie.isEmpty { return cookie }
        if let accessToken, !accessToken.isEmpty { return accessToken }
        return nil
    }
}

final class CloudDriveAuthManager: ObservableObject {
    static let shared = CloudDriveAuthManager()

    @Published private(set) var credentials: [String: CloudDriveCredential] = [:]

    private let defaults = UserDefaults.standard
    private let storageKey = "cloud_drive_credentials_v1"
    private let baiduVerifyCooldownKey = "baidu_verify_cooldowns_v1"
    private let session: URLSession
    private let ucSession: URLSession

    // MARK: - OpenList 阿里云盘配置
    private struct OpenListAliConfig {
        static let requestURL = "https://api.oplist.org/alicloud/requests"
        static let callbackURL = "https://api.oplist.org/alicloud/callback"
        static let renewURL = "https://api.oplist.org/alicloud/renewapi"
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        let ucConfig = URLSessionConfiguration.ephemeral
        ucConfig.timeoutIntervalForRequest = 30
        ucSession = URLSession(configuration: ucConfig)
        load()
        syncLegacyTokensIfNeeded()
    }

    // MARK: - 阿里云盘（OpenList 方案）

    /// 通过 OpenList APIPages 发起阿里云盘扫码授权
    /// 调用 api.oplist.org/alicloud/requests 获取 OAuth 授权 URL
    func aliOpenListCreateQr() async throws -> URL {
        var components = URLComponents(string: OpenListAliConfig.requestURL)!
        components.queryItems = [
            URLQueryItem(name: "driver", value: "alicloud"),
            URLQueryItem(name: "driver_txt", value: "alicloud_qr"),
            URLQueryItem(name: "server_use", value: "true"),
            URLQueryItem(name: "server_set", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[Ali OpenList] create QR HTTP \(httpStatus)")

        // 返回可能是重定向（302）到阿里 OAuth 页面，或者 JSON
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location) {
            print("[Ali OpenList] got redirect to: \(location.prefix(100))")
            return url
        }

        // 如果不是重定向，尝试解析 JSON 获取授权 URL
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authURL = json["url"] as? String ?? json["authorize_url"] as? String,
              let url = URL(string: authURL) else {
            // 尝试直接把返回的 data 当作 URL
            if let text = String(data: data, encoding: .utf8),
               text.hasPrefix("http"),
               let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
            throw AuthError.invalidResponse("阿里云盘 OpenList 获取授权链接失败 (HTTP \(httpStatus))")
        }
        return url
    }

    /// 通过 OpenList 回调接口处理授权码，换取 token
    func aliOpenListExchangeToken(authCode: String) async throws {
        var components = URLComponents(string: OpenListAliConfig.callbackURL)!
        components.queryItems = [
            URLQueryItem(name: "driver", value: "alicloud"),
            URLQueryItem(name: "code", value: authCode),
            URLQueryItem(name: "server_use", value: "true"),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 回调可能返回 302 重定向，URL 中包含 base64 编码的 token JSON
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let url = URL(string: location),
           let fragment = url.fragment {
            // 尝试从 URL fragment 解析 token
            let params = fragment.split(separator: "&").reduce(into: [String: String]()) { result, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    result[String(parts[0])] = String(parts[1])
                }
            }
            if let refreshToken = params["refresh_token"] ?? params["refreshToken"], !refreshToken.isEmpty {
                print("[Ali OpenList] got token from redirect fragment")
                saveAliCredential(refreshToken: refreshToken, accessToken: params["access_token"] ?? params["accessToken"])
                return
            }
            // 尝试 base64 解码
            if let decoded = Data(base64Encoded: fragment),
               let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] {
                if let refreshToken = json["refresh_token"] as? String ?? json["refreshToken"] as? String, !refreshToken.isEmpty {
                    print("[Ali OpenList] got token from base64 fragment")
                    saveAliCredential(refreshToken: refreshToken, accessToken: json["access_token"] as? String ?? json["accessToken"] as? String)
                    return
                }
            }
        }

        // 尝试解析 JSON 响应体
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let refreshToken = json["refresh_token"] as? String ?? json["refreshToken"] as? String, !refreshToken.isEmpty {
                print("[Ali OpenList] got token from JSON body")
                saveAliCredential(refreshToken: refreshToken, accessToken: json["access_token"] as? String ?? json["accessToken"] as? String)
                return
            }
            if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
                throw AuthError.remoteError(json["message"] as? String ?? "阿里云盘授权失败: \(code)")
            }
        }

        // 最后尝试检查 location query 参数
        if let httpResponse = response as? HTTPURLResponse,
           let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let urlComponents = URLComponents(string: location),
           let queryItems = urlComponents.queryItems {
            let params = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
            if let refreshToken = params["refresh_token"] ?? params["refreshToken"], !refreshToken.isEmpty {
                print("[Ali OpenList] got token from redirect query")
                saveAliCredential(refreshToken: refreshToken, accessToken: params["access_token"] ?? params["accessToken"])
                return
            }
        }

        throw AuthError.invalidResponse("阿里云盘 OpenList 换取 token 失败 (HTTP \(httpStatus))")
    }

    /// 保存阿里云盘凭证（支持 nickName 参数）
    func saveAliCredential(refreshToken: String, accessToken: String?, nickName: String = "阿里云盘用户") {
        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.ali.rawValue,
            authType: .qr,
            accessToken: accessToken,
            refreshToken: refreshToken,
            cookie: nil,
            driveId: nil,
            userId: nil,
            userName: nickName,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "阿里云盘扫码登录成功",
            extra: [:]
        )
        saveCredential(credential)
    }

    /// 保存阿里云盘凭证（去重）
    func saveAliCredentialIfNew(refreshToken: String, accessToken: String?) {
        // Check if we already have this token
        if let existing = credential(for: .ali),
           existing.refreshToken == refreshToken {
            return
        }
        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.ali.rawValue,
            authType: .qr,
            accessToken: accessToken,
            refreshToken: refreshToken,
            cookie: nil,
            driveId: nil,
            userId: nil,
            userName: "阿里云盘用户",
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "阿里云盘 OpenList 扫码登录成功",
            extra: [:]
        )
        saveCredential(credential)
    }

    /// 通过 OpenList 刷新阿里云盘 token
    /// OpenList renewapi 内部会调用阿里云盘官方 OAuth 接口（含 client_id/secret）进行刷新
    /// 成功返回 {"refresh_token":"...", "access_token":"..."} (HTTP 200)
    /// 失败返回 {"text":"<错误描述>"} (HTTP 500)
    func refreshAliAccessTokenIfNeeded() async throws -> CloudDriveCredential {
        guard var credential = credential(for: .ali),
              let refreshToken = credential.refreshToken,
              !refreshToken.isEmpty else {
            throw AuthError.notAuthorized("阿里云盘未授权")
        }

        // 优先使用阿里官方 API 刷新（auth.aliyundrive.com/v2/account/token）
        do {
            let result = try await refreshAliViaOfficialAPI(refreshToken: refreshToken)
            credential.accessToken = result.accessToken
            credential.refreshToken = result.refreshToken
            credential.state = .valid
            credential.statusMessage = "阿里 token 已刷新（官方 API）"
            credential.lastCheckedAt = Date()
            credential.updatedAt = Date()
            saveCredential(credential)
            print("[Ali Official] ✅ refresh 成功，access_token 长度=\(result.accessToken?.count ?? 0)")
            return credential
        } catch {
            print("[Ali Official] ⚠️ 官方 API 刷新失败: \(error.localizedDescription)")
        }

        // 兜底：尝试 OpenList 刷新（GET 方式）
        do {
            let result = try await refreshAliViaOpenList(refreshToken: refreshToken, usePost: false)
            credential.accessToken = result.accessToken
            credential.refreshToken = result.refreshToken
            credential.state = .valid
            credential.statusMessage = "阿里 token 已刷新"
            credential.lastCheckedAt = Date()
            credential.updatedAt = Date()
            saveCredential(credential)
            print("[Ali OpenList] ✅ refresh 成功，access_token 长度=\(result.accessToken?.count ?? 0)")
            return credential
        } catch {
            print("[Ali OpenList] ⚠️ GET 刷新失败: \(error.localizedDescription)")
        }

        // 兜底：尝试 OpenList 刷新（POST 方式）
        do {
            let result = try await refreshAliViaOpenList(refreshToken: refreshToken, usePost: true)
            credential.accessToken = result.accessToken
            credential.refreshToken = result.refreshToken
            credential.state = .valid
            credential.statusMessage = "阿里 token 已刷新"
            credential.lastCheckedAt = Date()
            credential.updatedAt = Date()
            saveCredential(credential)
            print("[Ali OpenList] ✅ POST refresh 成功")
            return credential
        } catch {
            print("[Ali OpenList] ⚠️ POST 刷新也失败: \(error.localizedDescription)")
        }

        // 兜底：尝试 PG extscreen 刷新（第四级 fallback，仅 PG 凭证触发）
        if credential.extra["pg_source"] != nil {
            do {
                let refreshed = try await AliyunPgAuthManager.shared.refreshViaExtscreen(credential: credential)
                print("[Ali PG] ✅ extscreen 第四级刷新成功")
                return refreshed
            } catch {
                print("[Ali PG] ⚠️ extscreen 刷新也失败: \(error.localizedDescription)")
            }
        }

        // 所有刷新方式均失败，标记凭证失效
        markInvalid(.ali, reason: "token 已过期，请重新授权")
        throw AuthError.remoteError("阿里云盘 token 已过期，请在网盘授权中心重新授权阿里云盘")
    }

    /// 使用阿里官方 API 刷新 Token
    private func refreshAliViaOfficialAPI(refreshToken: String) async throws -> (accessToken: String?, refreshToken: String) {
        var request = URLRequest(url: URL(string: "https://auth.aliyundrive.com/v2/account/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "client_id": "5f6b9c8e3f8a4b2c9e1d7a3f5b8c2e4d",
            "client_secret": "8c7e2a1f3d5b4c6e9a8f2d3c1b4e5a6f",
            "grant_type": "refresh_token"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.remoteError("阿里官方 API 刷新失败: 无效响应")
        }
        guard http.statusCode == 200 else {
            throw AuthError.remoteError("阿里官方 API 刷新失败: HTTP \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String else {
            throw AuthError.remoteError("阿里官方 API 刷新响应解析失败")
        }
        return (accessToken: accessToken, refreshToken: newRefreshToken)
    }

    /// OpenList 刷新阿里云盘 token 的具体实现
    private func refreshAliViaOpenList(refreshToken: String, usePost: Bool) async throws -> (accessToken: String?, refreshToken: String) {
        var components = URLComponents(string: OpenListAliConfig.renewURL)!
        let queryItems = [
            URLQueryItem(name: "driver_txt", value: "alicloud_qr"),
            URLQueryItem(name: "refresh_ui", value: refreshToken),
            URLQueryItem(name: "server_use", value: "true")
        ]

        var request: URLRequest
        if usePost {
            // POST 方式：参数放在 body 中
            var postComponents = URLComponents(string: OpenListAliConfig.renewURL)!
            request = URLRequest(url: postComponents.url!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let bodyParts = queryItems.map { item -> String in
                let value = item.value ?? ""
                let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(item.name)=\(encoded)"
            }
            let bodyString = bodyParts.joined(separator: "&")
            request.httpBody = bodyString.data(using: .utf8)
        } else {
            // GET 方式：参数放在 URL 中
            components.queryItems = queryItems
            request = URLRequest(url: components.url!)
        }
        request.setValue(aliUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
        print("[Ali OpenList] renewapi HTTP \(httpStatus), usePost=\(usePost), response: \(bodyPreview)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("阿里云盘刷新 token 返回无法解析 (HTTP \(httpStatus))")
        }

        // 检测 OpenList 错误格式：{"text":"<错误描述>"} 表示刷新失败
        if let errorText = json["text"] as? String {
            print("[Ali OpenList] ❌ renewapi 返回错误: \(errorText) (HTTP \(httpStatus))")
            if errorText.contains("invalid") || errorText.contains("expired") || errorText.contains("过期") {
                throw AuthError.remoteError("阿里云盘 refresh_token 已失效：\(errorText)")
            }
            throw AuthError.remoteError("阿里云盘 token 刷新失败：\(errorText)")
        }

        // HTTP 状态码检查：>= 400 视为错误
        if httpStatus >= 400 {
            let msg = json["message"] as? String ?? json["error"] as? String ?? "HTTP \(httpStatus)"
            throw AuthError.remoteError("阿里云盘 token 刷新失败：\(msg)")
        }

        // 解析成功的响应：{"refresh_token":"...", "access_token":"..."}
        let newRefreshToken = json["refresh_token"] as? String ?? json["refreshToken"] as? String ?? ""
        let newAccessToken = json["access_token"] as? String ?? json["accessToken"] as? String

        // 必须返回新的 refresh_token 才算成功（不再回退到旧 token，避免掩盖错误）
        guard !newRefreshToken.isEmpty else {
            throw AuthError.invalidResponse("阿里云盘刷新 token 未返回 refresh_token (HTTP \(httpStatus))")
        }

        return (accessToken: newAccessToken, refreshToken: newRefreshToken)
    }

    // MARK: - 天翼云盘 原生扫码

    struct Pan189QrLoginToken {
        let uuid: String
        let ticket: String
        let qrPayload: String
    }

    enum Pan189QrPollResult {
        case pending
        case scanned
        case success(loginUrl: String)
        case expired
        case failed(message: String)
    }

    private static let pan189UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    func pan189CreateQrToken() async throws -> Pan189QrLoginToken {
        // 使用独立干净 session，避免全局 session 残留 Cookie/头干扰
        let pan189Session = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15
            return c
        }())

        let url = URL(string: "https://cloud.189.cn/api/portal/getQRCodeInfo.action")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.pan189UserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://cloud.189.cn/", forHTTPHeaderField: "Referer")

        let (data, response) = try await pan189Session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox Pan189 CreateToken] HTTP \(httpStatus) raw: \(rawBody)")

        guard httpStatus == 200 else {
            throw AuthError.remoteError("天翼云盘获取二维码 HTTP 失败 (\(httpStatus))")
        }

        let json = try parseJSON(data)

        let resCode = json["resCode"] as? Int ?? -1
        guard resCode == 0 else {
            let msg = json["resMessage"] as? String ?? json["msg"] as? String ?? "未知错误"
            print("[VBox Pan189 CreateToken] resCode=\(resCode) msg=\(msg)")
            throw AuthError.remoteError("获取二维码失败: \(msg)")
        }

        guard let dataDict = json["data"] as? [String: Any],
              let uuid = dataDict["uuid"] as? String,
              let ticket = dataDict["ticket"] as? String else {
            throw AuthError.invalidResponse("天翼云盘未返回二维码 uuid/ticket")
        }

        let qrPayload = "https://cloud.189.cn/qrlogin?uuid=\(uuid)"
        print("[VBox Pan189 CreateToken] uuid=\(uuid) ticket=\(ticket)")
        return Pan189QrLoginToken(uuid: uuid, ticket: ticket, qrPayload: qrPayload)
    }

    func pan189PollQrStatus(token: Pan189QrLoginToken) async throws -> Pan189QrPollResult {
        var components = URLComponents(string: "https://cloud.189.cn/api/portal/queryQRCodeStatus.action")!
        components.queryItems = [
            URLQueryItem(name: "ticket", value: token.ticket),
            URLQueryItem(name: "uuid", value: token.uuid)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(Self.pan189UserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://cloud.189.cn/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox Pan189 Poll] HTTP \(httpStatus) raw: \(rawBody.prefix(300))")

        let resCode = json["resCode"] as? Int ?? -1
        guard resCode == 0 else {
            let msg = json["resMessage"] as? String ?? json["msg"] as? String ?? "查询异常"
            print("[VBox Pan189 Poll] resCode=\(resCode) msg=\(msg)")
            return .failed(message: msg)
        }

        guard let dataDict = json["data"] as? [String: Any],
              let status = dataDict["status"] as? Int else {
            return .pending
        }

        print("[VBox Pan189 Poll] status=\(status)")

        switch status {
        case 0:
            return .pending
        case 1:
            return .scanned
        case 2:
            guard let loginUrl = dataDict["loginUrl"] as? String else {
                return .failed(message: "登录成功但未返回 loginUrl")
            }
            return .success(loginUrl: loginUrl)
        case -1:
            return .expired
        default:
            return .pending
        }
    }

    func pan189ExchangeCookie(_ loginUrl: String) async throws {
        // 使用独立干净的 URLSession 来完成登录跳转，收集 Cookie
        let exchangeSession: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.httpShouldSetCookies = true
            return URLSession(configuration: config)
        }()

        guard let url = URL(string: loginUrl) else {
            throw AuthError.invalidResponse("loginUrl 无效")
        }
        var request = URLRequest(url: url)
        request.setValue(Self.pan189UserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://cloud.189.cn/", forHTTPHeaderField: "Referer")

        let (data, response) = try await exchangeSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox Pan189 Exchange] HTTP \(httpStatus): \(rawBody.prefix(200))")

        // 收集所有跳转过程中设置的 Cookie
        let allCookie = collectAllCookiesFromSession(exchangeSession, for: URL(string: "https://cloud.189.cn")!)

        let cookieLower = allCookie.lowercased()
        let hasLoginCookie = cookieLower.contains("ssotoken=") || cookieLower.contains("sso_token=") ||
                             cookieLower.contains("usersession=") || cookieLower.contains("ec_session=") ||
                             cookieLower.contains("CASTGC=") || cookieLower.contains("islogin=")

        print("[VBox Pan189 Exchange] cookie length: \(allCookie.count)")
        print("[VBox Pan189 Exchange] has login cookie: \(hasLoginCookie)")

        guard hasLoginCookie else {
            throw AuthError.invalidResponse("天翼云盘 Cookie 缺少登录态字段，登录可能无效")
        }

        // 保存凭证
        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.pan189.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: allCookie,
            driveId: nil,
            userId: nil,
            userName: nil,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: "扫码授权成功",
            extra: [:]
        )
        saveCredential(credential)
        print("[VBox Pan189 Exchange] ✅ 天翼云盘扫码登录成功，Cookie 已保存")
    }

    // MARK: - UC 原生扫码

    struct UCQrLoginToken {
        let token: String
        let clientId: String
        let pollClientId: String
        let requestId: String
        let qrPayload: String
    }

    enum UCQrPollResult {
        case pending
        case scanned
        case success(serviceTicket: String)
        case expired
        case failed(message: String)
    }

    // 对齐 iBox 实测：UC 扫码登录 web 端 client_id 为 381，请求为 POST + form body
    private static let ucWebClientId = "381"

    func ucCreateQrToken(clientId: String = ucWebClientId, pollClientId: String = ucWebClientId) async throws -> UCQrLoginToken {
        let ts = timestampMS()
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin")!
        components.queryItems = [
            URLQueryItem(name: "__dt", value: "2951"),
            URLQueryItem(name: "__t", value: ts)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://broccoli.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://broccoli.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = "client_id=\(clientId)&request_id=\(ts)&v=1.2".data(using: .utf8)

        let (data, response) = try await ucSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.remoteError("UC 获取扫码 token HTTP 失败")
        }
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox UC CreateToken] raw: \(rawBody)")
        let apiStatus = (json["status"] as? Int) ?? -1
        if apiStatus != 2000000 && apiStatus != -1 {
            let msg = json["message"] as? String ?? "未知错误"
            print("[VBox UC CreateToken] API status: \(apiStatus) message: \(msg)")
        }
        guard let token = extractString(json, keys: ["token", "qrcode_token"])
                ?? extractNestedString(json, path: ["data", "members", "token"])
                ?? extractNestedString(json, path: ["data", "token"])
                ?? extractNestedString(json, path: ["result", "token"]) else {
            throw AuthError.invalidResponse("UC 未返回二维码 token")
        }
        print("[VBox UC CreateToken] token: \(token) clientId: \(clientId) requestId: \(ts)")
        return UCQrLoginToken(token: token, clientId: clientId, pollClientId: pollClientId, requestId: ts, qrPayload: ucQRCodePayload(token: token, clientId: pollClientId))
    }

    func ucPollQrStatus(token: UCQrLoginToken) async throws -> UCQrPollResult {
        let ts = timestampMS()
        var components = URLComponents(string: "https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken")!
        components.queryItems = [
            URLQueryItem(name: "__dt", value: "10314"),
            URLQueryItem(name: "__t", value: ts)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://broccoli.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://broccoli.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue(ucUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = "client_id=\(token.pollClientId)&request_id=\(ts)&token=\(token.token)&v=1.2".data(using: .utf8)

        let (data, response) = try await ucSession.data(for: request)
        let json = try parseJSON(data)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Poll] HTTP \(httpStatus) raw: \(rawBody)")

        let ticket = extractNestedString(json, path: ["data", "members", "service_ticket"])
            ?? extractNestedString(json, path: ["data", "service_ticket"])
            ?? extractNestedString(json, path: ["result", "service_ticket"])
            ?? extractString(json, keys: ["service_ticket", "ticket"])
        if let ticket, !ticket.isEmpty {
            print("[VBox UC Poll] 获取到 service_ticket: \(ticket)")
            return .success(serviceTicket: ticket)
        }

        var status = json["status"] as? Int
            ?? json["code"] as? Int
            ?? json["status"] as? NSNumber as? Int
            ?? json["code"] as? NSNumber as? Int
            ?? extractNestedInt(json, path: ["data", "members", "status"])
            ?? extractNestedInt(json, path: ["data", "status"])
            ?? -1
        if status == -1 {
            if let s = json["status"] as? String ?? json["code"] as? String {
                status = Int(s) ?? -1
                if status == -1, s == "SUCCESS" || s.caseInsensitiveCompare("ok") == .orderedSame { status = 0 }
            }
        }
        print("[VBox UC Poll] parsed status: \(status)")

        // 已知状态码映射
        if [50004002, 50004003, 50004004, 50004005, 50004006, 50004007].contains(status) { return .expired }
        if status == 50004000 { return .scanned }
        // 50004001 = 等待扫码 / 50000000 = 服务器繁忙（token 尚未就绪，继续轮询）
        if status == 50004001 || status == 50000000 { return .pending }
        if status == 0 || status == 2000000 { return .pending }
        if status != -1 { print("[VBox UC Poll] unknown status: \(status), treating as pending") }
        return .pending
    }

    func ucExchangeServiceTicket(_ serviceTicket: String) async throws {
        // 使用独立干净的 URLSession（不携带 CAS 追踪 Cookie），匹配 iBox 行为
        // mobileinfo 是给 WebView 内嵌页面用的端点，需要 Android WebView UA
        let exchangeSession: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
        var components = URLComponents(string: "https://drive.uc.cn/account/mobileinfo")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "h5"),
            URLQueryItem(name: "__t", value: timestampMS()),
            URLQueryItem(name: "st", value: serviceTicket)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await exchangeSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Exchange] HTTP \(httpStatus): \(rawBody.prefix(300))")

        // 只从本次 exchange 响应中收集 Cookie（Set-Cookie 头 + JSON body）
        // 不需要 CAS 追踪 Cookie，mobileinfo 端点会直接返回 __pus 登录态 Cookie
        let headerCookie = collectCookies(from: (response as? HTTPURLResponse) ?? HTTPURLResponse(), storage: exchangeSession.configuration.httpCookieStorage, url: URL(string: "https://drive.uc.cn")!)

        let bodyJSON = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let bodyData = bodyJSON?["data"] as? [String: Any] ?? [:]
        var bodyCookies: [String] = []
        if let pus = bodyData["__pus"] as? String, !pus.isEmpty { bodyCookies.append("__pus=\(pus)") }
        if let kps = bodyData["kps"] as? String, !kps.isEmpty { bodyCookies.append("kps=\(kps)") }
        if let uid = bodyData["uid"] { bodyCookies.append("__uid=\(uid)") }

        let cookie = mergeCookieStrings([headerCookie] + (bodyCookies.isEmpty ? [] : [bodyCookies.joined(separator: "; ")]))
        print("[VBox UC Exchange] header cookie: \(headerCookie.isEmpty ? "none" : headerCookie.prefix(100))...")
        print("[VBox UC Exchange] merged cookie: \(cookie.isEmpty ? "none" : cookie.prefix(100))...")

        // 必须包含 __pus / __kps / __uid 才算真正获取到登录态 Cookie
        // _up_ 只是 CAS 追踪 Cookie，不是登录态，不能作为判断依据
        let cookieLower = cookie.lowercased()
        let hasUCLogin = cookieLower.contains("__pus=") || cookieLower.contains("__kps=") || cookieLower.contains("__uid=")
        if hasUCLogin {
            print("[VBox UC Exchange] ✅ 获取到 UC 登录态 Cookie")
            try await ucSaveCredentialFromCookie(cookie: cookie, data: data, source: "UC mobileinfo")
            return
        }

        // 回退：尝试 pan.quark.cn account/info（兼容旧版 CAS）
        print("[VBox UC Exchange] mobileinfo 未返回登录态 Cookie，回退 pan.quark.cn")
        let fallbackUrl = URL(string: "https://pan.quark.cn/account/info?st=\(serviceTicket)&fr=pc&platform=pc")!
        var fbRequest = URLRequest(url: fallbackUrl)
        fbRequest.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        fbRequest.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        fbRequest.setValue("Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
        fbRequest.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")

        let (fbData, fbResponse) = try await exchangeSession.data(for: fbRequest)
        let fbBody = String(data: fbData, encoding: .utf8) ?? "nil"
        let fbHttpStatus = (fbResponse as? HTTPURLResponse)?.statusCode ?? 0
        print("[VBox UC Exchange] fallback HTTP \(fbHttpStatus): \(fbBody.prefix(300))")

        let fbAllCookies = collectAllCookiesFromSession(exchangeSession, for: URL(string: "https://pan.quark.cn")!)
        let fbHeaderCookie = collectCookies(from: (fbResponse as? HTTPURLResponse) ?? HTTPURLResponse(), storage: exchangeSession.configuration.httpCookieStorage, url: URL(string: "https://pan.quark.cn")!)

        let fbBodyJSON = (try? JSONSerialization.jsonObject(with: fbData)) as? [String: Any]
        let fbBodyData = fbBodyJSON?["data"] as? [String: Any] ?? [:]
        var fbBodyCookies: [String] = []
        if let pus = fbBodyData["__pus"] as? String, !pus.isEmpty { fbBodyCookies.append("__pus=\(pus)") }
        if let kps = fbBodyData["kps"] as? String, !kps.isEmpty { fbBodyCookies.append("kps=\(kps)") }
        if let uid = fbBodyData["uid"] { fbBodyCookies.append("__uid=\(uid)") }

        let fbCookie = mergeCookieStrings([fbAllCookies, fbHeaderCookie, headerCookie] + (fbBodyCookies.isEmpty ? [] : [fbBodyCookies.joined(separator: "; ")]))
        print("[VBox UC Exchange] fallback merged cookie: \(fbCookie.isEmpty ? "none" : fbCookie.prefix(100))...")

        let fbCookieLower = fbCookie.lowercased()
        guard fbCookieLower.contains("__pus=") || fbCookieLower.contains("__kps=") || fbCookieLower.contains("__uid=") else {
            throw AuthError.invalidResponse("UC Cookie 缺少必须字段，登录可能无效")
        }
        try await ucSaveCredentialFromCookie(cookie: fbCookie, data: fbData, source: "UC pan.quark.cn fallback")
    }

    private func collectAllCookiesFromSession(_ session: URLSession, for url: URL) -> String {
        guard let storage = session.configuration.httpCookieStorage else { return "" }
        let cookies = storage.cookies(for: url) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func ucSaveCredentialFromCookie(cookie: String, data: Data, source: String) async throws {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userName = extractNestedString(json ?? [:], path: ["data", "nickname"])
            ?? extractString(json ?? [:], keys: ["nickname", "nick_name", "user_name"])

        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.uc.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: extractNestedString(json ?? [:], path: ["data", "uid"]) ?? extractString(json ?? [:], keys: ["uid", "user_id"]),
            userName: userName,
            avatar: extractNestedString(json ?? [:], path: ["data", "avatar"]) ?? extractString(json ?? [:], keys: ["avatar"]),
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "UC 扫码登录成功",
            extra: [:]
        )
        // 修复: 同步 syncLegacyToken 会触发 CloudDriveManager.addOrReplaceToken 修改 @Published savedTokens，
        // 导致 CloudAuthCenterView 深度嵌套 body 在同一调用栈内同步求值 → 栈溢出崩溃 (EXC_BAD_ACCESS/SIGBUS)。
        // 百度登录同样使用 syncLegacyToken: false 规避此问题。
        saveCredential(credential, syncLegacyToken: false)
        print("[VBox UC Exchange] ✅ 已保存 UC Cookie (source: \(source)): \(cookie)")
    }

    func ucExchangeTVToken(cookie: String) async throws -> String {
        // 优先走 OAuth 授权流程（需要用户扫码），登录后异步调用时先尝试直接兑换
        // ext screen 服务需要 code 参数，无法用 Cookie 直接兑换
        // 此方法保留作为兼容入口，实际应通过 ucStartTVAuth → ucPollTVAuth → ucExchangeTVCode 流程获取
        let endpoints = ["https://api.extscreen.com/ucdrive/token", "http://api.extscreen.com/ucdrive/token"]
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let reqId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let body: [String: Any] = [
            "build_device": "iPhone",
            "device_name": "iPhone",
            "device_id": deviceId,
            "build_product": "iPhone",
            "platform": "tv",
            "req_id": reqId,
            "app_ver": "1.6.8",
            "device_model": "iPhone",
            "device_brand": "Apple",
            "device_gpu": "Apple",
            "channel": "UCTVOFFICIALWEB",
            "activity_rect": "%7B%7D"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Mozilla/5.0 (Linux; U; Android 12; zh-cn; V2238A Build/V417IR) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1", forHTTPHeaderField: "User-Agent")
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.httpBody = bodyData
            do {
                let (data, _) = try await session.data(for: request)
                let rawBody = String(data: data, encoding: .utf8) ?? "nil"
                print("[VBox UC] UCTV Token 响应: \(rawBody.prefix(500))")
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AuthError.invalidResponse("UCTV Token 返回无法解析")
                }
                if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
                    throw AuthError.remoteError(json["message"] as? String ?? code)
                }
                if let code = json["code"] as? Int, code != 0 && code != 200 {
                    throw AuthError.remoteError(json["message"] as? String ?? "code=\(code)")
                }
                let dataObj = json["data"] as? [String: Any] ?? json
                guard let token = dataObj["access_token"] as? String ?? dataObj["token"] as? String ?? dataObj["uc_tv_token"] as? String, !token.isEmpty else {
                    throw AuthError.invalidResponse("UCTV Token 返回为空")
                }
                return token
            } catch {
                lastError = error
                print("[VBox UC] UCTV Token 端点 \(endpoint) 失败: \(error)")
            }
        }
        throw lastError ?? AuthError.remoteError("UCTV Token 兑换失败，请使用扫码授权 UC TV")
    }

    // MARK: - UC TV OAuth 授权流程

    struct UCTVAuthQR {
        let qrData: String
        let queryToken: String
        let reqId: String
        let deviceId: String
    }

    private let ucTVClientId = "5acf882d27b74502b7040b0c65519aa7"
    private let ucTVSignKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
    private let ucTVAppVer = "1.6.8"
    private let ucTVChannel = "UCTVOFFICIALWEB"
    private let ucTVUserAgent = "Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1"

    /// 生成 x-pan-token 签名：SHA256(method&pathname&timestamp&signKey)
    private func ucTVGenerateSign(method: String, pathname: String, timestamp: String) -> String {
        let tokenData = "\(method)&\(pathname)&\(timestamp)&\(ucTVSignKey)"
        let hash = SHA256.hash(data: Data(tokenData.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 生成 MD5 req_id
    private func ucTVGenerateReqId(deviceId: String, timestamp: String) -> String {
        let data = Data("\(deviceId)\(timestamp)".utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// 启动 UC TV 授权，返回二维码数据（base64 PNG）和 query_token
    func ucStartTVAuth() async throws -> UCTVAuthQR {
        let rawUUID = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let deviceId = rawUUID.lowercased()
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/oauth/authorize"
        let xPanToken = ucTVGenerateSign(method: "GET", pathname: pathname, timestamp: timestamp)
        let reqId = ucTVGenerateReqId(deviceId: deviceId, timestamp: timestamp)

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "access_token", value: ""),
            URLQueryItem(name: "activity_rect", value: "%7B%7D"),
            URLQueryItem(name: "app_ver", value: ucTVAppVer),
            URLQueryItem(name: "auth_type", value: "code"),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "channel", value: ucTVChannel),
            URLQueryItem(name: "client_id", value: ucTVClientId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "qr_height", value: "460"),
            URLQueryItem(name: "qr_width", value: "460"),
            URLQueryItem(name: "qrcode", value: "1"),
            URLQueryItem(name: "req_id", value: reqId),
            URLQueryItem(name: "scope", value: "netdisk")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(ucTVUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(ucTVClientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox UC TV] authorize 响应: \(rawBody.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, status == 0,
              let qrData = json["qr_data"] as? String,
              let queryToken = json["query_token"] as? String else {
            throw AuthError.invalidResponse("UC TV 授权：无法获取二维码，响应: \(rawBody.prefix(200))")
        }
        return UCTVAuthQR(qrData: qrData, queryToken: queryToken, reqId: reqId, deviceId: deviceId)
    }

    /// 轮询 UC TV 授权状态，返回 code 或 nil（未确认）
    func ucPollTVAuth(queryToken: String, deviceId: String) async throws -> String? {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/oauth/code"
        let xPanToken = ucTVGenerateSign(method: "GET", pathname: pathname, timestamp: timestamp)
        let reqId = ucTVGenerateReqId(deviceId: deviceId, timestamp: timestamp)

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "access_token", value: ""),
            URLQueryItem(name: "activity_rect", value: "%7B%7D"),
            URLQueryItem(name: "app_ver", value: ucTVAppVer),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "channel", value: ucTVChannel),
            URLQueryItem(name: "client_id", value: ucTVClientId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "query_token", value: queryToken),
            URLQueryItem(name: "req_id", value: reqId),
            URLQueryItem(name: "scope", value: "netdisk")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(ucTVUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(ucTVClientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        print("[VBox UC TV] code 轮询响应: \(rawBody.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // 检查 errno：11003=用户未确认（继续轮询），其他非零=错误（抛出异常）
        if let errno = json["errno"] as? Int {
            if errno == 11003 { return nil }  // 用户未确认，继续轮询
            if errno != 0 {
                let info = json["error_info"] as? String ?? "errno=\(errno)"
                if errno == 10002 {
                    throw AuthError.remoteError("二维码已过期，请重新获取")
                }
                throw AuthError.remoteError("UC TV 授权错误: \(info)")
            }
        }

        // 检查 status：-1 表示错误
        if let status = json["status"] as? Int, status == -1 {
            let info = json["error_info"] as? String ?? json["message"] as? String ?? "status=-1"
            throw AuthError.remoteError("UC TV 授权错误: \(info)")
        }

        // 成功获取 code：status=0 且 code 为 32 位 hex 字符串
        if let status = json["status"] as? Int, status == 0,
           let code = json["code"] as? String, !code.isEmpty {
            let hexPattern = try? NSRegularExpression(pattern: "^[0-9a-f]{32}$")
            if hexPattern?.firstMatch(in: code, range: NSRange(location: 0, length: code.count)) != nil {
                return code
            }
            // code 格式不对，可能是错误信息
            print("[VBox UC TV] ⚠️ code 格式异常（非32位hex），忽略: \(code)")
            return nil
        }
        if let dataObj = json["data"] as? [String: Any],
           let code = dataObj["code"] as? String, !code.isEmpty {
            let hexPattern = try? NSRegularExpression(pattern: "^[0-9a-f]{32}$")
            if hexPattern?.firstMatch(in: code, range: NSRange(location: 0, length: code.count)) != nil {
                return code
            }
            print("[VBox UC TV] ⚠️ data.code 格式异常（非32位hex），忽略: \(code)")
            return nil
        }
        return nil
    }

    /// 用授权码换取 UC TV Token
    func ucExchangeTVCode(code: String, deviceId: String) async throws -> (accessToken: String, refreshToken: String) {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/token"
        let _ = ucTVGenerateSign(method: "POST", pathname: pathname, timestamp: timestamp)
        let reqId = ucTVGenerateReqId(deviceId: deviceId, timestamp: timestamp)

        let body: [String: Any] = [
            "req_id": reqId,
            "app_ver": ucTVAppVer,
            "device_id": deviceId,
            "device_brand": "Apple",
            "platform": "tv",
            "device_name": "iPhone",
            "device_model": "iPhone",
            "build_device": "iPhone",
            "build_product": "iPhone",
            "device_gpu": "Apple",
            "activity_rect": "{}",
            "channel": ucTVChannel,
            "code": code
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let endpoints = ["https://api.extscreen.com/ucdrive/token", "http://api.extscreen.com/ucdrive/token"]
        var lastError: Error?
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(ucTVUserAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = bodyData
            do {
                let (data, _) = try await ucSession.data(for: request)
                let rawBody = String(data: data, encoding: .utf8) ?? "nil"
                print("[VBox UC TV] token 兑换响应: \(rawBody.prefix(500))")
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AuthError.invalidResponse("UC TV Token 返回无法解析")
                }
                if let code = json["code"] as? Int, code != 200 {
                    throw AuthError.remoteError(json["message"] as? String ?? "code=\(code)")
                }
                let dataObj = json["data"] as? [String: Any] ?? json
                guard let accessToken = dataObj["access_token"] as? String, !accessToken.isEmpty else {
                    throw AuthError.invalidResponse("UC TV Token 返回为空")
                }
                let refreshToken = dataObj["refresh_token"] as? String ?? ""
                print("[VBox UC TV] ✅ 获取到 TV Token")
                return (accessToken, refreshToken)
            } catch {
                lastError = error
                print("[VBox UC TV] Token 端点 \(endpoint) 失败: \(error)")
            }
        }
        throw lastError ?? AuthError.remoteError("UC TV Token 兑换失败")
    }

    /// 保存 UC TV Token 到 credential
    func ucSaveTVToken(accessToken: String, refreshToken: String = "") {
        guard var cred = credentials[CloudDriveManager.DriveType.uc.rawValue] else {
            print("[VBox UC TV] ⚠️ 无法保存 TV Token：credential 不存在，请先登录 UC 网页端")
            return
        }
        var extra = cred.extra
        extra["uc_tv_token"] = accessToken
        if !refreshToken.isEmpty {
            extra["uc_tv_refresh_token"] = refreshToken
        }
        cred.extra = extra
        cred.statusMessage = "UC 已授权 TV（高速通道已就绪）"
        credentials[CloudDriveManager.DriveType.uc.rawValue] = cred
        persist()
        CloudDriveAuthManager.logSensitive("[VBox UC] UC TV Token 已保存", value: accessToken)
    }

    // MARK: - 百度原生扫码

    struct BaiduQrLoginToken {
        let sign: String
        let channelId: String
        let qrURL: String
    }

    enum BaiduQrPollResult {
        case pending
        case scanned
        case success(bdussURL: String?)
        case expired
        case failed(message: String)
    }

    func baiduCreateQrToken() async throws -> BaiduQrLoginToken {
        var components = URLComponents(string: "https://passport.baidu.com/v2/api/getqrcode")!
        components.queryItems = [
            URLQueryItem(name: "lp", value: "pc"),
            URLQueryItem(name: "qrloginfrom", value: "pc"),
            URLQueryItem(name: "gid", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: timestampMS())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        let sign = extractString(json, keys: ["sign"]) ?? extractNestedString(json, path: ["data", "sign"]) ?? ""
        let channelId = extractString(json, keys: ["channel_id"]) ?? extractNestedString(json, path: ["data", "channel_id"]) ?? sign
        let imgurl = extractString(json, keys: ["imgurl"]) ?? extractNestedString(json, path: ["data", "imgurl"]) ?? ""
        guard !sign.isEmpty, !imgurl.isEmpty else {
            throw AuthError.invalidResponse("百度未返回二维码 sign/imgurl")
        }
        let qrURL = imgurl.hasPrefix("http") ? imgurl : "https://\(imgurl.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return BaiduQrLoginToken(sign: sign, channelId: channelId, qrURL: qrURL)
    }

    func baiduPollQrStatus(token: BaiduQrLoginToken) async throws -> BaiduQrPollResult {
        var components = URLComponents(string: "https://passport.baidu.com/channel/unicast")!
        components.queryItems = [
            URLQueryItem(name: "channel_id", value: token.channelId),
            URLQueryItem(name: "tpl", value: "netdisk"),
            URLQueryItem(name: "apiver", value: "v3"),
            URLQueryItem(name: "tt", value: timestampMS())
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        let errno = json["errno"] as? Int ?? -1
        if errno == 1 || errno == 2 { return .pending }
        if errno == 0 {
            var payload: [String: Any] = json
            if let raw = json["channel_v"] as? String,
               let rawData = raw.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] {
                payload = nested
            }
            let status = payload["status"] as? Int ?? -1
            if status == 2 || payload["bduss"] != nil || payload["v"] != nil {
                return .success(bdussURL: payload["bduss"] as? String ?? payload["v"] as? String)
            }
            if status == 0 || status == 1 { return .scanned }
            return .pending
        }
        if errno == 3 || errno == 4 { return .expired }
        return .failed(message: json["errmsg"] as? String ?? "百度轮询 errno=\(errno)")
    }

    func baiduExchangeQrLogin(token: BaiduQrLoginToken, bdussURL: String?) async throws {
        var components = URLComponents(string: "https://passport.baidu.com/v3/login/main/qrbdusslogin")!
        let bdussParam = normalizeBaiduQrBDUSSParam(bdussURL) ?? token.sign
        components.queryItems = [
            URLQueryItem(name: "v", value: timestampMS()),
            URLQueryItem(name: "bduss", value: bdussParam),
            URLQueryItem(name: "u", value: "https://pan.baidu.com/disk/main"),
            URLQueryItem(name: "loginVersion", value: "v4"),
            URLQueryItem(name: "qrcode", value: "1"),
            URLQueryItem(name: "tpl", value: "netdisk")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")

        let cookieCollector = RedirectCookieCollector()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let oneShot = URLSession(configuration: config, delegate: cookieCollector, delegateQueue: nil)
        defer { oneShot.finishTasksAndInvalidate() }
        let (_, response) = try await oneShot.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse("百度登录无响应") }
        let responseCookie = collectCookies(from: http, storage: oneShot.configuration.httpCookieStorage, url: URL(string: "https://pan.baidu.com")!)
        let initialCookie = mergeCookieStrings([cookieCollector.cookieString(), responseCookie])
        let cookie = await baiduEnrichAccountCookie(initialCookie)
        guard isBaiduAccountCookie(cookie) else {
            throw AuthError.invalidResponse("百度扫码未返回完整 BDUSS/STOKEN")
        }
        print("✅ 百度扫码 Cookie 字段：\(baiduCookieNames(in: cookie).joined(separator: ","))")
        let vars = try? await baiduFetchTemplateVariables(cookie: cookie)
        var credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.baidu.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: vars?["uk"],
            userName: vars?["username"] ?? "百度扫码账号",
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "百度扫码登录成功",
            extra: vars ?? [:]
        )
        saveCredential(credential)

        credential.statusMessage = "百度扫码登录成功，已保存 BDUSS/STOKEN"
        credential.extra["cookie_mode"] = "BDUSS_STOKEN"
        saveCredential(credential, syncLegacyToken: false)
        CloudDriveManager.shared.cleanupInvalidBaiduTokens()
    }

    private func baiduEnrichAccountCookie(_ cookie: String) async -> String {
        let normalizedCookie = mergeCookieStrings([cookie])
        guard !normalizedCookie.isEmpty else { return normalizedCookie }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        let storage = config.httpCookieStorage ?? HTTPCookieStorage.shared
        config.httpCookieStorage = storage
        seedBaiduCookies(normalizedCookie, into: storage)

        let oneShot = URLSession(configuration: config)
        defer { oneShot.finishTasksAndInvalidate() }

        var collected = normalizedCookie
        // 扫码完成后强制访问下列五条「只读、不改账号、不写网盘」的端点，
        // 让百度服务端通过 Set-Cookie 把 BFESS 系列字段补齐：
        //   1. www.baidu.com         → BAIDUID / BAIDUID_BFESS / BDORZ / PSTM
        //   2. passport.baidu.com    → STOKEN_BFESS / BDUSS_BFESS / HOSUPPORT
        //   3. pan.baidu.com/disk/main           → 网盘域本地化 cookie
        //   4. pan.baidu.com/api/gettemplatevariable → bdstoken / uk
        //   5. pan.baidu.com/api/getuinfo        → 用户基础信息附带 cookie
        // 全部 GET、单次串行、失败静默回退，不会改账号资料、不会触发风控、不会动网盘文件。
        let endpoints = [
            "https://www.baidu.com/",
            "https://passport.baidu.com/center",
            "https://pan.baidu.com/disk/main",
            "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=250528&web=1&fields=[%22bdstoken%22,%22uk%22,%22username%22]",
            "https://pan.baidu.com/api/getuinfo?clienttype=0&app_id=250528&web=1"
        ]

        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.setValue(collected, forHTTPHeaderField: "Cookie")
            request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            do {
                let (_, response) = try await oneShot.data(for: request)
                if let http = response as? HTTPURLResponse {
                    let responseCookie = collectCookies(from: http, storage: storage, url: url)
                    let storageCookie = CloudDriveAuthManager.cookieString(from: storage.cookies ?? [])
                    collected = mergeCookieStrings([collected, responseCookie, storageCookie])
                }
            } catch {
                continue
            }
        }

        // 只打字段名，不打 cookie 值；用于诊断 BFESS 是否补齐。
        print("ℹ️ 百度扫码 Cookie 补全后字段：\(baiduCookieNames(in: collected).joined(separator: ","))")
        return collected
    }
    
    private func baiduIsVerifyCoolingDown(_ key: String) -> Bool {
        let cooldowns = baiduVerifyCooldownCache()
        return (cooldowns[key] ?? .distantPast) > Date()
    }
    
    private func baiduMarkVerifyCooldown(_ key: String, seconds: TimeInterval = 10 * 60) {
        var cache = baiduVerifyCooldownCache()
        cache[key] = Date().addingTimeInterval(seconds)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: baiduVerifyCooldownKey)
        }
    }
    
    private func baiduVerifyCooldownCache() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: baiduVerifyCooldownKey),
              let cache = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return cache
    }

    // MARK: - 139云盘原生扫码

    @MainActor
    final class Pan139QrLoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }

        func startLogin() {
            statusText = "正在加载139云盘页面..."
            // 139云盘移动端登录页面
            guard let url = URL(string: "https://yun.139.com/w/") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // 等待页面完全加载后再尝试切换扫码标签
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await switchToQRCodeTab()
                startPolling()
            }
        }

        private func switchToQRCodeTab() async {
            // 增强版 JS：多策略查找并点击扫码/二维码入口
            let js = #"""
            (function() {
                // 策略1: 精确查找包含"扫码"/"二维码"的文字元素
                var elems = document.querySelectorAll('div, span, button, a, li, p, label, input[type="button"], input[type="submit"], .tab-item, .login-tab, [class*="tab"], [class*="Tab"], [class*="login"], [class*="Login"]');
                for (var i = 0; i < elems.length; i++) {
                    var el = elems[i];
                    var txt = (el.textContent || '').trim();
                    var cls = ((el.className||'') + ' ' + (el.id||'') + ' ' + (el.getAttribute('data-type')||'')).toLowerCase();
                    if ((txt.indexOf('扫码') !== -1 || txt.indexOf('二维码') !== -1 ||
                         txt.indexOf('QR') !== -1 || txt.indexOf('qr') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked:' + txt.substring(0, 10);
                    }
                    if ((cls.indexOf('qr') !== -1 || cls.indexOf('scan') !== -1 ||
                         cls.indexOf('扫码') !== -1 || cls.indexOf('qrcode') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked_by_class';
                    }
                }
                // 策略2: 尝试通过 URL hash 或路由切换到扫码模式
                if (window.location.hash.indexOf('qrcode') === -1 &&
                    window.location.hash.indexOf('scan') === -1) {
                    try {
                        var newHash = window.location.hash + '#qrcode';
                        window.location.hash = 'qrcode';
                        return 'hash_changed';
                    } catch(e) {}
                }
                // 策略3: 查找所有可见的可点击元素，尝试匹配登录方式切换
                var allClicks = document.querySelectorAll('[onclick], [data-action], [data-type]');
                for (var j = 0; j < allClicks.length; j++) {
                    var cel = allClicks[j];
                    var attr = (cel.getAttribute('onclick')||'') + (cel.getAttribute('data-action')||'') + (cel.getAttribute('data-type')||'');
                    if ((attr.indexOf('qr') !== -1 || attr.indexOf('scan') !== -1 || attr.indexOf('扫码') !== -1) &&
                        cel.offsetWidth > 0 && cel.offsetHeight > 0) {
                        cel.click();
                        return 'clicked_by_attr';
                    }
                }
                return 'notfound';
            })()
            """#
            do {
                let result = try await webView.evaluateJavaScript(js)
                if let r = result as? String {
                    if r.hasPrefix("clicked") {
                        statusText = "已切换到扫码登录，请使用中国移动云盘 APP 扫描二维码"
                    } else if r == "hash_changed" {
                        statusText = "尝试切换扫码模式，请使用中国移动云盘 APP 扫码"
                    } else {
                        statusText = "未找到扫码入口，请在页面中手动切换到扫码登录"
                    }
                } else {
                    statusText = "请使用中国移动云盘 APP 扫码登录"
                }
                print("[Pan139] switchToQRCodeTab result: \(result ?? "nil")")
            } catch {
                statusText = "请使用中国移动云盘 APP 扫码登录"
                print("[Pan139] switchToQRCodeTab error: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan139] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 { return }
            if error.localizedDescription.contains("帧框加载已中断") || error.localizedDescription.contains("Frame load interrupted") { return }
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan139] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                for _ in 1...120 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    
                    print("[Pan139] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    // 检测多个可能的登录成功标志
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        // 139云盘可能的认证 Cookie 名称
                        return (name == "ssotoken" || name == "sso_token" ||
                                name == "aSSOToken" || name == "mcloud_sso" ||
                                name.contains("sso") || name.contains("SSO") ||
                                name.contains("token") && value.count > 20) &&
                               cookie.value.count > 10
                    }

                    if hasLoginCookie {
                        // 检查更具体的认证字段
                        let hasSSO = cookies.contains { $0.name.lowercased().contains("sso") }
                        let hasSession = cookies.contains { $0.name.lowercased().contains("session") }
                        let hasToken = cookies.contains { $0.name.lowercased().contains("token") && $0.value.count > 20 }
                        
                        if hasSSO || hasSession || hasToken {
                            await MainActor.run {
                                self.isLoggedIn = true
                                self.statusText = "登录成功"
                                print("[Pan139] login success, cookieStr length: \(cookieStr.count)")
                                CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan139, cookie: cookieStr)
                            }
                            return
                        }
                    }
                    
                    // 额外检测：URL 是否已重定向到登录后的页面
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("yun.139.com/w/main") ||
                        currentURL.contains("yun.139.com/w/home") ||
                        currentURL.contains("yun.139.com/main")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转）"
                            print("[Pan139] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan139, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时，请重试"
                    self.statusText = "二维码已过期"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 迅雷云盘网页登录

    @MainActor
    final class XunleiLoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载迅雷云盘页面..."
            guard let url = URL(string: "https://i.xunlei.com/xluser/login.html") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // 页面加载后等待一会儿再开始轮询 Cookie
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 { return }
            if error.localizedDescription.contains("帧框加载已中断") || error.localizedDescription.contains("Frame load interrupted") { return }
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录迅雷账号（手机号+密码或扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                    // 检测是否已登录：迅雷登录成功的标志性 Cookie
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        return (name == "userid" || name == "usernewno" ||
                                name == "xunlei_kis" || name == "xunlei_kisp" ||
                                name.contains("gdriveid") || name.contains("xunlei")) && cookie.value.count > 5
                    }

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .xunlei, cookie: cookieStr)
                        }
                        return
                    }

                    // 检测 URL 跳转到主页
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("pan.xunlei.com") && !currentURL.contains("login")) || currentURL.contains("i.xunlei.com/xluser/home") {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .xunlei, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 天翼云盘网页登录

    @MainActor
    final class Pan189LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        }

        func startLogin() {
            statusText = "正在加载天翼云盘页面..."
            guard let url = URL(string: "https://cloud.189.cn/web/login.html") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                // 页面加载后自动尝试切换到扫码登录标签
                await switchToQRCodeTab()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                startPolling()
            }
        }

        private func switchToQRCodeTab() async {
            let js = #"""
            (function() {
                var elems = document.querySelectorAll('div, span, button, a, li, p, label, input[type="button"], input[type="submit"], .tab-item, .login-tab, [class*="tab"], [class*="Tab"], [class*="login"], [class*="Login"]');
                for (var i = 0; i < elems.length; i++) {
                    var el = elems[i];
                    var txt = (el.textContent || '').trim();
                    var cls = ((el.className||'') + ' ' + (el.id||'') + ' ' + (el.getAttribute('data-type')||'')).toLowerCase();
                    if ((txt.indexOf('扫码') !== -1 || txt.indexOf('二维码') !== -1 ||
                         txt.indexOf('QR') !== -1 || txt.indexOf('qr') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked:' + txt.substring(0, 10);
                    }
                    if ((cls.indexOf('qr') !== -1 || cls.indexOf('scan') !== -1 ||
                         cls.indexOf('扫码') !== -1 || cls.indexOf('qrcode') !== -1) &&
                        el.offsetWidth > 0 && el.offsetHeight > 0) {
                        el.click();
                        return 'clicked_by_class';
                    }
                }
                return 'notfound';
            })()
            """#
            do {
                let result = try await webView.evaluateJavaScript(js)
                if let r = result as? String, r.hasPrefix("clicked") {
                    statusText = "已切换到扫码登录，请使用天翼云盘 APP 扫描二维码"
                } else {
                    statusText = "请在页面中点击扫码登录，使用天翼云盘 APP 扫描"
                }
                print("[Pan189] switchToQRCodeTab result: \(result ?? "nil")")
            } catch {
                statusText = "请使用天翼云盘 APP 扫码登录"
                print("[Pan189] switchToQRCodeTab error: \(error)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 { return }
            if error.localizedDescription.contains("帧框加载已中断") || error.localizedDescription.contains("Frame load interrupted") { return }
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录天翼云盘账号（手机号+密码或扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

                    // 检测是否已登录：检查是否有 SSOToken 或 userSession 相关 Cookie
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        // 天翼云盘登录成功的标志性 Cookie
                        return (name.contains("ssotoken") || name.contains("sso_token") ||
                                name.contains("usersession") || name.contains("ec_session") ||
                                name == "CASTGC" || name == "isLogin") && cookie.value.count > 10
                    }

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan189, cookie: cookieStr)
                        }
                        return
                    }

                    // 也尝试检测页面 URL 是否已跳转到主页（登录成功后的跳转）
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("cloud.189.cn/web/main") ||
                        currentURL.contains("cloud.189.cn/main")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan189, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 123云盘网页登录

    @MainActor
    final class Pan123LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载123云盘登录页面..."
            guard let url = URL(string: "https://www.123pan.com/login") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            // 帧框加载已中断（页面跳转/重定向时常见，非真实错误）
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan123] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            // 过滤导航被取消（页面跳转/重定向导致的正常中断）
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            // WebKit 帧框加载已中断（登录跳转时常见，非真实错误）
            if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 { return }
            // 通用：错误描述包含"帧框加载已中断"也跳过
            if error.localizedDescription.contains("帧框加载已中断") || error.localizedDescription.contains("Frame load interrupted") { return }
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan123] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录123云盘（手机号/微信扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    let bearerToken = self.extractBearerToken(from: cookies)
                    let localToken = await self.evaluateLocalStorageToken()
                    let accessToken = (bearerToken ?? localToken)?.trimmingCharacters(in: .whitespacesAndNewlines)

                    print("[Pan123] polling cookies count: \(cookies.count), names: \(cookies.map { "\($0.name)(\($0.value.prefix(10)))" }.joined(separator: ", "))")

                    // 检测登录成功的标志：精确 Cookie 或 JS Token
                    // 123pan 登录后常见 Cookie: 123pan_uid, 123pan_token, pan123_*, authorization, __uid 等
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        return (name == "authorization" ||
                                name == "token" ||
                                name == "userid" ||
                                name == "uid" ||
                                name == "__uid" ||
                                name.hasPrefix("pan123") ||
                                name.hasPrefix("123pan") ||
                                name.hasPrefix("123_") ||
                                name.contains("passport") ||
                                name.contains("login") ||
                                name.contains("_token") ||
                                name.contains("session")) && value.count > 10
                    } || (accessToken?.count ?? 0 > 10)

                    // 宽松检测：登录后 123pan 通常会设置至少 3 个 Cookie，总长度 > 100
                    let hasManyCookies = cookies.count >= 3 && cookieStr.count > 100

                    if hasLoginCookie || hasManyCookies {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Token..."
                            print("[Pan123] login success, cookieStr length: \(cookieStr.count), token length: \(accessToken?.count ?? 0), reason: \(hasLoginCookie ? "cookie_match" : "many_cookies")")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan123, cookie: cookieStr, accessToken: accessToken)
                        }
                        return
                    }

                    // 额外检测：URL 是否跳转到用户首页
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("123pan.com/home") ||
                        currentURL.contains("123pan.com/dashboard") ||
                        currentURL.contains("123pan.com/disk") ||
                        currentURL.contains("123684.com/home") ||
                        currentURL.contains("123684.com/dashboard") ||
                        currentURL.contains("123684.com/disk") ||
                        (currentURL.contains("123pan.com") && !currentURL.contains("login") && !currentURL.contains("passport")) ||
                        (currentURL.contains("123684.com") && !currentURL.contains("login") && !currentURL.contains("passport"))) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转），正在保存 Token..."
                            print("[Pan123] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .pan123, cookie: cookieStr, accessToken: accessToken)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        /// 从 Cookie 中提取 Bearer Token（优先 authorization 或 token 字段）
        private func extractBearerToken(from cookies: [HTTPCookie]) -> String? {
            for cookie in cookies {
                let name = cookie.name.lowercased()
                let value = cookie.value
                if name == "authorization" || name == "token" {
                    if value.hasPrefix("Bearer ") {
                        return String(value.dropFirst(7))
                    }
                    if value.count > 10 {
                        return value
                    }
                }
            }
            return nil
        }

        /// 通过 JS 读取 123pan 的 localStorage / sessionStorage token
        private func evaluateLocalStorageToken() async -> String? {
            let scripts = [
                "localStorage.getItem('token')",
                "sessionStorage.getItem('token')",
                "localStorage.getItem('Authorization')",
                "sessionStorage.getItem('Authorization')"
            ]
            for script in scripts {
                let result: Any? = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        self.webView.evaluateJavaScript(script) { value, _ in
                            continuation.resume(returning: value)
                        }
                    }
                }
                guard let token = result as? String, !token.isEmpty else { continue }
                if token.hasPrefix("Bearer ") {
                    return String(token.dropFirst(7))
                }
                return token
            }
            return nil
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - UC 网盘网页登录兜底

    @MainActor
    final class UCWebLoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载 UC 网盘登录页面..."
            guard let url = URL(string: "https://drive.uc.cn/") else { return }
            var req = URLRequest(url: url)
            req.setValue("https://drive.uc.cn/", forHTTPHeaderField: "Referer")
            webView.load(req)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[UC Web] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[UC Web] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录 UC 网盘（短信/账号/扫码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    print("[UC Web] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    let lower = cookieStr.lowercased()
                    let hasLoginCookie = lower.contains("__pus=") || lower.contains("__kps=") || lower.contains("__uid=") || lower.contains("_up_")

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            print("[UC Web] login success, cookieStr length: \(cookieStr.count)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .uc, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 115网盘网页登录

    @MainActor
    final class Pan115LoginHelper: NSObject, WKNavigationDelegate, ObservableObject {
        @Published var statusText = "正在加载..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        func startLogin() {
            statusText = "正在加载115网盘登录页面..."
            guard let url = URL(string: "https://115.com/?ct=login") else { return }
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            self.errorText = "页面加载失败"
            self.statusText = "请检查网络后重试"
            print("[Pan115] didFail navigation: \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            // 过滤导航被取消（页面跳转/重定向导致的正常中断）
            if nsErr.domain == NSURLErrorDomain && nsErr.code == -999 { return }
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
            // WebKit 帧框加载已中断（登录跳转时常见，非真实错误）
            if nsErr.domain == "WebKitErrorDomain" && nsErr.code == 102 { return }
            // 通用：错误描述包含"帧框加载已中断"也跳过
            if error.localizedDescription.contains("帧框加载已中断") || error.localizedDescription.contains("Frame load interrupted") { return }
            self.errorText = "链接失败: \(error.localizedDescription)"
            self.statusText = "加载失败"
            print("[Pan115] didFailProvisionalNavigation: \(error)")
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { [weak self] in
                guard let self = self else { return }
                self.statusText = "请在页面中登录115网盘（扫码或账号密码）"
                for _ in 1...180 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }

                    let cookies = await self.getAllCookies()
                    let cookieStr = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    
                    print("[Pan115] polling cookies count: \(cookies.count), names: \(cookies.map { $0.name }.joined(separator: ", "))")

                    // 115网盘登录成功的标志性 Cookie
                    let hasLoginCookie = cookies.contains { cookie in
                        let name = cookie.name.lowercased()
                        let value = cookie.value
                        return (name == "uid" || name == "cid" || name == "seid" ||
                                name.contains("user_id") || name.contains("userid") ||
                                name.contains("passport") || name.contains("uc_115")) && value.count > 5
                    }

                    if hasLoginCookie {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功，正在保存 Cookie..."
                            print("[Pan115] login success, cookieStr length: \(cookieStr.count)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .one15, cookie: cookieStr)
                        }
                        return
                    }

                    // 额外检测：URL 跳转到用户首页
                    if let currentURL = self.webView.url?.absoluteString,
                       (currentURL.contains("115.com/?ct=file") ||
                        currentURL.contains("115.com/?ct=disk") ||
                        currentURL.contains("115.com/?ac=space") ||
                        currentURL.contains("115.com/?ct=index") ||
                        currentURL.contains("/main") || currentURL.contains("/home")) {
                        await MainActor.run {
                            self.isLoggedIn = true
                            self.statusText = "登录成功（检测到页面跳转），正在保存 Cookie..."
                            print("[Pan115] login success via URL redirect: \(currentURL)")
                            CloudDriveAuthManager.shared.saveWebViewCookie(type: .one15, cookie: cookieStr)
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.errorText = "登录超时（6分钟），请重试"
                    self.statusText = "登录超时"
                }
            }
        }

        private func getAllCookies() async -> [HTTPCookie] {
            return await withCheckedContinuation { cont in
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    cont.resume(returning: cookies)
                }
            }
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载..."
            isLoggedIn = false
            errorText = ""
        }
    }

    // MARK: - 阿里云盘 OpenList WebView 扫码登录

    @MainActor
    final class AliOpenListQrLoginHelper: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Published var statusText = "正在加载 OpenList 授权页面..."
        @Published var isLoggedIn = false
        @Published var errorText = ""

        let webView: WKWebView
        private var pollTask: Task<Void, Never>?

        override init() {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            webView = WKWebView(frame: frame, configuration: config)
            super.init()
            webView.navigationDelegate = self
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"

            // Register JS message handler for token extraction
            config.userContentController.add(self, name: "aliTokenHandler")
        }

        func startLogin() {
            statusText = "正在加载 OpenList 授权页面..."
            guard let url = URL(string: "https://api.oplist.org/?driver=alicloud&driver_txt=alicloud_qr&server_use=true&server_set=true") else { return }
            webView.load(URLRequest(url: url))
        }

        func cleanup() {
            pollTask?.cancel()
            pollTask = nil
            webView.stopLoading()
            statusText = "正在加载 OpenList 授权页面..."
            isLoggedIn = false
            errorText = ""
        }

        // WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                statusText = "页面已加载，请使用阿里云盘 App 扫码"
                // Inject JS to monitor for token display
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                injectTokenMonitor()
                startPolling()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                statusText = "页面加载失败"
                errorText = error.localizedDescription
            }
        }

        // WKScriptMessageHandler - receives token from JS
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "aliTokenHandler",
               let body = message.body as? [String: Any],
               let refreshToken = body["refresh_token"] as? String ?? body["refreshToken"] as? String,
               !refreshToken.isEmpty {
                Task { @MainActor in
                    CloudDriveAuthManager.shared.saveAliCredentialIfNew(
                        refreshToken: refreshToken,
                        accessToken: body["access_token"] as? String ?? body["accessToken"] as? String
                    )
                    isLoggedIn = true
                    statusText = "阿里云盘登录成功"
                }
            }
        }

        private func injectTokenMonitor() {
            // JS that monitors the page for token display and sends it to native
            let js = """
            (function() {
                function checkToken() {
                    // Look for refresh_token in input/textarea elements (common pattern in token tool pages)
                    var inputs = document.querySelectorAll('input, textarea, [data-token], [data-refresh-token]');
                    for (var i = 0; i < inputs.length; i++) {
                        var val = (inputs[i].value || inputs[i].textContent || inputs[i].getAttribute('data-token') || inputs[i].getAttribute('data-refresh-token') || '').trim();
                        if (val.length > 50 && val.indexOf('.') !== -1) {
                            window.webkit.messageHandlers.aliTokenHandler.postMessage({
                                refresh_token: val,
                                source: 'input_' + i
                            });
                            return true;
                        }
                    }
                    // Also check for visible text that looks like a token
                    var allText = document.body.innerText || '';
                    // Look for patterns like "refresh_token: xxx" or display text
                    var patterns = ['refresh_token', 'refreshToken', 'Refresh Token', 'refresh token'];
                    for (var p = 0; p < patterns.length; p++) {
                        var idx = allText.indexOf(patterns[p]);
                        if (idx !== -1) {
                            // Extract the token value after the label
                            var after = allText.substring(idx + patterns[p].length).replace(/[:\\s：]+/g, '').trim();
                            // Take first long string as token
                            var match = after.match(/^[A-Za-z0-9_\\-\\.]{50,}/);
                            if (match) {
                                window.webkit.messageHandlers.aliTokenHandler.postMessage({
                                    refresh_token: match[0],
                                    source: 'text_' + patterns[p]
                                });
                                return true;
                            }
                        }
                    }
                    return false;
                }

                // Check immediately
                if (checkToken()) return;

                // Also check on DOM changes
                var observer = new MutationObserver(function() {
                    if (checkToken()) observer.disconnect();
                });
                observer.observe(document.body, { childList: true, subtree: true, characterData: true });

                // Periodic check every 3 seconds
                window.__aliTokenInterval = setInterval(function() {
                    if (checkToken()) {
                        clearInterval(window.__aliTokenInterval);
                        observer.disconnect();
                    }
                }, 3000);
            })();
            """
            webView.evaluateJavaScript(js)
        }

        private func startPolling() {
            pollTask?.cancel()
            pollTask = Task { @MainActor in
                while !Task.isCancelled && !isLoggedIn {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // MARK: - 授权有效性测试

    @discardableResult
    func validateCredential(for driveType: CloudDriveManager.DriveType) async -> Bool {
        guard let credential = credential(for: driveType) else { return false }
        do {
            switch driveType {
            case .ali:
                _ = try await refreshAliAccessTokenIfNeeded()
            case .one15:
                try await validateCookie(url: "https://webapi.115.com/files?cid=0&limit=1", cookie: credential.cookie ?? "", referer: "https://115.com/")
            case .quark:
                try await validateCookie(url: "https://drive-pc.quark.cn/1/clouddrive/member?pr=ucpro&fr=pc&sys=darwin&ve=3.19.0", cookie: credential.cookie ?? "", referer: "https://pan.quark.cn/")
            case .uc:
                try await validateCookie(url: "https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc", cookie: credential.cookie ?? "", referer: "https://drive.uc.cn/")
            case .baidu:
                _ = try await baiduFetchTemplateVariables(cookie: credential.cookie ?? "")
            case .pan123:
                // 优先使用 Bearer Token + Cookie 校验；旧版本只有 Cookie 的也能继续校验
                try await validatePan123Credential(credential: credential)
            case .pan139:
                try await validateCookie(url: "https://yun.139.com/", cookie: credential.cookie ?? "", referer: "https://yun.139.com/")
            case .pan189:
                try await validateCookie(url: "https://cloud.189.cn/", cookie: credential.cookie ?? "", referer: "https://cloud.189.cn/")
            case .xunlei:
                try await validateCookie(url: "https://pan.xunlei.com/", cookie: credential.cookie ?? "", referer: "https://pan.xunlei.com/")
            case .guangya, .woniu4k:
                // 光鸭/蜗牛由 Node 常驻系统托管：本地校验核心字段非空即可，
                // 真实有效性由 Node 侧解析链路（A1 接缝）运行时判定。
                try validateNodeManagedCredential(credential, driveType: driveType)
            }
            markValid(driveType, message: "授权检测正常")
            return true
        } catch {
            markInvalid(driveType, reason: error.localizedDescription)
            return false
        }
    }

    func credential(for driveType: CloudDriveManager.DriveType) -> CloudDriveCredential? {
        credentials[driveType.rawValue]
    }

    func displayName(for driveType: CloudDriveManager.DriveType) -> String {
        credential(for: driveType)?.displayName ?? "未授权"
    }

    func statusText(for driveType: CloudDriveManager.DriveType) -> String {
        guard let credential = credential(for: driveType) else { return CloudDriveAuthState.notAuthorized.displayText }
        if let expiresAt = credential.expiresAt {
            if expiresAt < Date() { return CloudDriveAuthState.expired.displayText }
            if expiresAt.timeIntervalSinceNow < 30 * 60 { return CloudDriveAuthState.expiringSoon.displayText }
        }
        if let checked = credential.lastCheckedAt {
            return "\(credential.state.displayText) · \(Self.shortTime(checked))检测"
        }
        return credential.state.displayText
    }

    func isAuthorized(_ driveType: CloudDriveManager.DriveType) -> Bool {
        guard let credential = credential(for: driveType) else { return false }
        if driveType == .baidu, let cookie = credential.cookie {
            return credential.state != .invalid && isBaiduAccountCookie(cookie)
        }
        if driveType == .guangya {
            // Node 托管：Token 落在 extra["token"]（不在 primarySecret 三字段内）
            return credential.state != .invalid && (credential.extra["token"]?.isEmpty == false)
        }
        if driveType == .woniu4k {
            // Node 托管：登录态 Cookie 落在 cookie 字段
            return credential.state != .invalid && (credential.cookie?.isEmpty == false)
        }
        if driveType == .bilibili {
            // Node 托管：B站 Cookie 落在 cookie 字段（与蜗牛同模式）
            return credential.state != .invalid && (credential.cookie?.isEmpty == false)
        }
        return credential.state != .invalid && credential.primarySecret?.isEmpty == false
    }

    func saveCredential(_ credential: CloudDriveCredential, syncLegacyToken: Bool = true) {
        credentials[credential.driveType] = credential
        persist()

        guard syncLegacyToken,
              let driveType = CloudDriveManager.DriveType(rawValue: credential.driveType),
              let value = credential.primarySecret,
              !value.isEmpty else { return }

        if driveType == .baidu, !isBaiduAccountCookie(value) {
            return
        }

        let tokenName = credential.userName?.isEmpty == false
            ? "\(driveType.displayName)-\(credential.userName!)"
            : "\(driveType.displayName)-\(credential.authType.rawValue)"
        CloudDriveManager.shared.addOrReplaceToken(type: driveType, name: tokenName, value: value)
    }

    func saveManualCredential(type: CloudDriveManager.DriveType, name: String, value: String) {
        let normalized = normalizedSecret(type: type, value: value)
        var credential = CloudDriveCredential(
            driveType: type.rawValue,
            authType: .manual,
            accessToken: type == .ali ? normalized : nil,
            refreshToken: type == .ali ? normalized : nil,
            cookie: type == .ali ? nil : normalized,
            driveId: nil,
            userId: nil,
            userName: name.isEmpty ? nil : name,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: nil,
            extra: [:]
        )
        if type == .baidu {
            credential.cookie = normalized
            credential.refreshToken = nil
            credential.accessToken = nil
        }
        saveCredential(credential, syncLegacyToken: false)
    }

    func markInvalid(_ driveType: CloudDriveManager.DriveType, reason: String) {
        guard var credential = credentials[driveType.rawValue] else { return }
        credential.state = .invalid
        credential.statusMessage = reason
        credential.lastCheckedAt = Date()
        credential.updatedAt = Date()
        credentials[driveType.rawValue] = credential
        persist()
    }

    func markValid(_ driveType: CloudDriveManager.DriveType, message: String? = nil) {
        guard var credential = credentials[driveType.rawValue] else { return }
        credential.state = .valid
        credential.statusMessage = message
        credential.lastCheckedAt = Date()
        credential.updatedAt = Date()
        credentials[driveType.rawValue] = credential
        persist()
    }

    func removeCredential(for driveType: CloudDriveManager.DriveType) {
        credentials.removeValue(forKey: driveType.rawValue)
        persist()
    }

    /// 级联删除网盘凭据：同时清除 rawValue 键与 Node 同步使用的 case 名键
    /// （如 115 同时存在 "115" 与 "one15" 两种 key），确保 Node 登录态彻底退出。
    func removeCredentialAndAliases(for driveType: CloudDriveManager.DriveType) {
        var changed = false
        if credentials.removeValue(forKey: driveType.rawValue) != nil { changed = true }
        let aliasKeys: [String]
        switch driveType {
        case .one15: aliasKeys = ["one15"]
        case .pan123: aliasKeys = ["pan123"]
        case .pan139: aliasKeys = ["pan139"]
        case .pan189: aliasKeys = ["pan189"]
        default: aliasKeys = []
        }
        for key in aliasKeys where credentials.removeValue(forKey: key) != nil {
            changed = true
        }
        if changed { persist() }
    }

    func bestTokenValue(for driveType: CloudDriveManager.DriveType) -> String? {
        guard let value = credential(for: driveType)?.primarySecret else { return nil }
        if driveType == .baidu, !isBaiduAccountCookie(value) {
            return nil
        }
        return value
    }

    func saveQuarkLogin(cookie: String, nickName: String?, avatarURL: String?) {
        let credential = CloudDriveCredential(
            driveType: CloudDriveManager.DriveType.quark.rawValue,
            authType: .qr,
            accessToken: nil,
            refreshToken: nil,
            cookie: cookie,
            driveId: nil,
            userId: nil,
            userName: nickName,
            avatar: avatarURL,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "夸克扫码登录成功",
            extra: [:]
        )
        saveCredential(credential)
    }

    @discardableResult
    func saveWebViewCookie(type: CloudDriveManager.DriveType, cookie: String, userName: String? = nil, accessToken: String? = nil) -> Bool {
        if type == .baidu, !isBaiduAccountCookie(cookie) {
            var credential = credentials[type.rawValue]
            credential?.statusMessage = "已捕获百度 Cookie，但未包含完整 BDUSS/STOKEN，未覆盖账号 Cookie"
            credential?.lastCheckedAt = Date()
            credential?.updatedAt = Date()
            if let credential {
                credentials[type.rawValue] = credential
                persist()
            }
            return false
        }
        let credential = CloudDriveCredential(
            driveType: type.rawValue,
            authType: .webView,
            accessToken: accessToken,
            refreshToken: type == .ali ? cookie : nil,
            cookie: type == .ali ? nil : cookie,
            driveId: nil,
            userId: nil,
            userName: userName,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: accessToken != nil ? "WebView 已保存授权（含 Bearer Token）" : "WebView 已保存授权",
            extra: [:]
        )
        saveCredential(credential)
        if type == .baidu {
            CloudDriveManager.shared.cleanupInvalidBaiduTokens()
        }
        return true
    }

    nonisolated static func cookieString(from cookies: [HTTPCookie]) -> String {
        cookies
            .filter { !$0.name.isEmpty && !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private func normalizedSecret(type: CloudDriveManager.DriveType, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .one15:
            if trimmed.lowercased().hasPrefix("cookie:") {
                return String(trimmed.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if trimmed.contains("=") { return trimmed }
            return "CID=\(trimmed)"
        default:
            return trimmed
        }
    }

    /// 光鸭/蜗牛（Node 托管网盘）本地核心字段校验
    /// - guangya: extra["token"] 非空
    /// - woniu4k: cookie 非空
    private func validateNodeManagedCredential(_ credential: CloudDriveCredential, driveType: CloudDriveManager.DriveType) throws {
        switch driveType {
        case .guangya:
            guard let token = credential.extra["token"], !token.isEmpty else {
                throw AuthError.notAuthorized("光鸭网盘未配置 Token，请先扫码授权")
            }
        case .woniu4k:
            guard let cookie = credential.cookie, !cookie.isEmpty else {
                throw AuthError.notAuthorized("蜗牛网盘未配置 Cookie，请先账号登录")
            }
        default:
            break
        }
    }

    private func isBaiduAccountCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("bduss=") && lower.contains("stoken=")
    }

    private var ucUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
    }

    private var aliUserAgent: String {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private var baiduUserAgent: String {
        // 使用更接近真实浏览器的 UA，减少风控风险
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    private var baiduPCSUserAgent: String {
        "netdisk;1.4.2;22021211RC;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;"
    }

    private func seedBaiduCookies(_ cookie: String, into storage: HTTPCookieStorage) {
        let domains = [".baidu.com", "pan.baidu.com", "passport.baidu.com", "d.pcs.baidu.com"]
        for domain in domains {
            for piece in cookie.components(separatedBy: ";") {
                let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                guard let httpCookie = HTTPCookie(properties: [
                    .domain: domain,
                    .path: "/",
                    .name: name,
                    .value: value,
                    .secure: "TRUE",
                    .expires: Date(timeIntervalSinceNow: 30 * 24 * 3600)
                ]) else { continue }
                storage.setCookie(httpCookie)
            }
        }
    }

    private func extractBaiduPCSCookie(from cookie: String) -> String? {
        let pcsNames = Set(["panpsc", "ptoken", "ptoken_bfess", "ndut_fmt", "nd_ftid"])
        var fields: [String] = []
        var used = Set<String>()
        for piece in cookie.components(separatedBy: ";") {
            let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            guard !name.isEmpty, !value.isEmpty, pcsNames.contains(lower), !used.contains(lower) else { continue }
            used.insert(lower)
            fields.append("\(name)=\(value)")
        }
        return fields.isEmpty ? nil : fields.joined(separator: "; ")
    }

    private func baiduCookieNames(in cookie: String) -> [String] {
        cookie.components(separatedBy: ";").compactMap { piece in
            let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = kv.firstIndex(of: "=") else { return nil }
            let name = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
    }

    private func ucQRCodePayload(token: String, clientId: String) -> String {
        // 精简 payload：UC App 扫码后在自带浏览器中打开，设备指纹由 App 自行携带，
        // QR 码只需 token + client_id + 少量必要参数即可，避免 payload 过长导致 QR 生成失败
        var components = URLComponents(string: "https://su.uc.cn/1_n0ZCv")!
        let ucParams: [(String, String)] = [
            ("uc_param_str", "frpfbive"),
            ("fr", "iphone"),
            ("pf", "44"),
            ("bi", "997"),
            ("ve", "18.9.8.2995"),
            ("token", token),
            ("client_id", clientId),
            ("uc_biz_str", "S:custom|C:titlebar_fix")
        ]
        components.queryItems = ucParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        let payload = components.url?.absoluteString ?? "https://su.uc.cn/1_n0ZCv?uc_param_str=frpfbive&fr=iphone&pf=44&bi=997&ve=18.9.8.2995&token=\(token)&client_id=\(clientId)&uc_biz_str=S:custom|C:titlebar_fix"
        print("[VBox UC Payload] QR payload length: \(payload.utf8.count) bytes")
        return payload
    }

    /// 生成一个看起来像 UC 浏览器设备标识的 base64 字符串
    private func ucEncodedDeviceId() -> String {
        let data = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32).data(using: .utf8) ?? Data()
        return data.base64EncodedString()
    }

    private func timestampMS() -> String {
        String(Int(Date().timeIntervalSince1970 * 1000))
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("返回不是 JSON 对象")
        }
        return json
    }

    private func extractString(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return value }
            if let value = json[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private func extractNestedString(_ json: [String: Any], path: [String]) -> String? {
        var current: Any = json
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        if let value = current as? String, !value.isEmpty { return value }
        if let value = current as? NSNumber { return value.stringValue }
        return nil
    }

    private func extractNestedInt(_ json: [String: Any], path: [String]) -> Int? {
        var current: Any = json
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        if let value = current as? Int { return value }
        if let value = current as? NSNumber { return value.intValue }
        return nil
    }

    private func collectCookies(from http: HTTPURLResponse, storage: HTTPCookieStorage?, url: URL) -> String {
        var cookieDict: [String: String] = [:]
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
        
        // 优先从 HTTPURLResponse 中解析 Set-Cookie（支持 iOS 15+ 多值 header）
        if #available(iOS 15.0, *) {
            for (key, value) in http.allHeaderFields {
                guard let lowerKey = key as? String, lowerKey.lowercased() == "set-cookie" else { continue }
                if let cookieValues = value as? [String] {
                    for cookieValue in cookieValues {
                        processSetCookieHeader(cookieValue, into: &cookieDict, for: url)
                    }
                } else if let singleValue = value as? String {
                    processSetCookieHeader(singleValue, into: &cookieDict, for: url)
                }
            }
        } else {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
            if let raw = http.allHeaderFields["Set-Cookie"] as? String {
                processSetCookieHeader(raw, into: &cookieDict, for: url)
            }
        }
        
        if let cookies = storage?.cookies(for: url) {
            for cookie in cookies {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
        }
        if url.host?.contains("baidu.com") == true, let cookies = storage?.cookies {
            for cookie in cookies where cookie.domain.contains("baidu.com") {
                if !cookie.name.isEmpty, !cookie.value.isEmpty {
                    cookieDict[cookie.name] = cookie.value
                }
            }
        }
        
        return cookieDict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
    
    private func processSetCookieHeader(_ header: String, into dict: inout [String: String], for url: URL) {
        for cookieHeader in splitSetCookieHeader(header) {
            processSingleSetCookie(cookieHeader, into: &dict, for: url)
        }
    }

    private func splitSetCookieHeader(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = header.startIndex
        while index < header.endIndex {
            let ch = header[index]
            if ch == "," {
                let nextIndex = header.index(after: index)
                let rest = header[nextIndex...]
                if rest.range(of: #"^\s*[A-Za-z0-9_\-]+="#, options: .regularExpression) != nil {
                    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    index = nextIndex
                    continue
                }
            }
            current.append(ch)
            index = header.index(after: index)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    // 解析单个 Set-Cookie header 的辅助方法，正确处理包含逗号的时间格式
    private func processSingleSetCookie(_ cookieHeader: String, into dict: inout [String: String], for url: URL) {
        let components = cookieHeader.components(separatedBy: "; ")
        guard let mainCookie = components.first, let eqIndex = mainCookie.firstIndex(of: "=") else { return }
        
        let name = String(mainCookie[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(mainCookie[mainCookie.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !name.isEmpty, !value.isEmpty {
            dict[name] = value
        }
    }

    private func mergeCookieStrings(_ values: [String]) -> String {
        var dict: [String: String] = [:]
        for value in values {
            for piece in value.components(separatedBy: ";") {
                let kv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = kv.firstIndex(of: "=") else { continue }
                let key = String(kv[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !val.isEmpty { dict[key] = val }
            }
        }
        return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func normalizeBaiduQrBDUSSParam(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.removingPercentEncoding ?? value
        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let bduss = components.queryItems?.first(where: { $0.name.lowercased() == "bduss" })?.value,
           !bduss.isEmpty {
            return bduss
        }
        if let match = try? NSRegularExpression(pattern: #"(?:^|[?&])bduss=([^&\s]+)"#, options: [.caseInsensitive])
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            return String(value[range])
        }
        return value
    }

    private func baiduFetchTemplateVariables(cookie: String) async throws -> [String: String] {
        guard !cookie.isEmpty else { throw AuthError.notAuthorized("百度 Cookie 为空") }
        var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: "[\"bdstoken\",\"token\",\"uk\",\"username\",\"servertime\"]")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(baiduUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        let json = try parseJSON(data)
        if let errno = json["errno"] as? Int, errno != 0 {
            throw AuthError.remoteError("百度登录态异常 errno=\(errno)")
        }
        let result = (json["result"] as? [String: Any]) ?? json
        var output: [String: String] = [:]
        for key in ["bdstoken", "token", "uk", "username", "servertime"] {
            if let value = result[key] as? String { output[key] = value }
            if let value = result[key] as? NSNumber { output[key] = value.stringValue }
        }
        guard output["bdstoken"] != nil || output["uk"] != nil else {
            throw AuthError.invalidResponse("百度未返回 bdstoken/uk")
        }
        return output
    }

    private func validatePan123Credential(credential: CloudDriveCredential) async throws {
        let cookie = credential.cookie ?? ""
        let token = credential.accessToken ?? ""
        guard !cookie.isEmpty || !token.isEmpty else { throw AuthError.notAuthorized("123云盘 Cookie 与 Token 均为空") }

        // 与 iBox 对齐：123pan Web 版文件列表接口；优先 GET，失败再尝试 POST
        let base = "https://www.123pan.com/api/file/list/new"
        let query = "driveId=0&limit=1&next=1&orderBy=filename&orderDirection=asc&parentFileId=0&trashed=false&operateType=4"
        let methods = ["GET", "POST"]
        var lastHTTPStatus = 0
        var lastRawBody = ""
        for method in methods {
            var components = URLComponents(string: base)!
            if method == "GET" {
                components.query = query
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.setValue("https://www.123pan.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            if !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "driveId": 0, "limit": 1, "next": 1, "orderBy": "filename",
                    "orderDirection": "asc", "parentFileId": 0, "trashed": false, "operateType": 4
                ])
            }
            let (data, response) = try await session.data(for: request)
            lastHTTPStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastRawBody = String(data: data, encoding: .utf8) ?? ""
            if lastHTTPStatus == 401 || lastHTTPStatus == 403 {
                // 继续尝试下一个 method，若全部尝试完仍无效则最后统一抛错
                continue
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 123pan 的 code 可能是 Int 或 String，统一处理
                let codeInt = json["code"] as? Int
                let codeString = json["code"] as? String
                let isSuccess = (codeInt == 0 || codeInt == 200) || (codeString == "0" || codeString == "200" || codeString?.lowercased() == "ok")
                if isSuccess {
                    return // 校验通过
                }
                if let state = json["state"] as? Bool, state == false {
                    let msg = json["error"] as? String ?? json["message"] as? String ?? "123云盘登录态无效"
                    // 业务明确失败时，若还有其他 method 未尝试则继续
                    if method != methods.last {
                        print("[Pan123] 校验返回失败，尝试下一 method: \(msg)")
                        continue
                    }
                    throw AuthError.remoteError(msg)
                }
                let isUnauthorized: Bool = {
                    if let code = codeInt { return code == 401 || code == 403 || code == 40001 }
                    if let code = codeString { return code == "401" || code == "403" || code == "40001" }
                    return false
                }()
                if isUnauthorized {
                    let msg = json["message"] as? String ?? "123云盘登录态无效 code=\(json["code"] ?? "")"
                    if method != methods.last {
                        print("[Pan123] 校验返回 \(json["code"] ?? ""), 尝试下一 method: \(msg)")
                        continue
                    }
                    throw AuthError.remoteError(msg)
                }
            }
        }
        // 把最后尝试的 HTTP 状态码和原始响应体带出来，方便定位问题
        let detail = lastHTTPStatus != 0 ? "HTTP \(lastHTTPStatus)" : "无响应"
        let preview = String(lastRawBody.prefix(200))
        throw AuthError.remoteError("123云盘登录态校验失败 (\(detail)): \(preview)")
    }

    private func validateCookie(url: String, cookie: String, referer: String, authorization: String? = nil) async throws {
        guard !cookie.isEmpty else { throw AuthError.notAuthorized("Cookie 为空") }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = url.contains("/file/sort") ? "POST" : "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        // 115 网盘需要完整 Chrome UA + Origin；其他网盘用通用 UA 即可
        let is115 = url.contains("115.com")
        if is115 {
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("https://115.com", forHTTPHeaderField: "Origin")
        } else {
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        }
        if let auth = authorization, !auth.isEmpty {
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        }
        if request.httpMethod == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["pdir_fid": "0", "page": 1, "size": 1])
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw AuthError.remoteError("HTTP \(http.statusCode)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let state = json["state"] as? Bool, state == false {
                throw AuthError.remoteError(json["error"] as? String ?? json["message"] as? String ?? "Cookie 无效")
            }
            if let code = json["code"] as? Int, code == 401 || code == 403 || code == 40001 {
                throw AuthError.remoteError(json["message"] as? String ?? "Cookie 无效 code=\(code)")
            }
        }
    }

    // MARK: - 全新安装凭据清理（方案 A）
    //
    // iOS 卸载 App 不会清除其写入 Keychain 的条目，导致卸载重装后网盘 Token/授权仍残留。
    // 用 UserDefaults 标记（卸载即清空）识别"全新安装"，首次启动时清空 Keychain 网盘凭据。
    // 幂等：标记已存在（正常升级/重复调用）直接返回 false；仅操作 Keychain，不触碰内存状态，
    // 可在 CloudDriveAuthManager 与 CloudDriveManager 两条加载路径安全调用（无初始化环路）。

    private static let freshInstallMarkerKey = "com.vbox.clouddrive.credentials_initialized_v1"

    @discardableResult
    static func purgeKeychainIfFreshInstall() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: freshInstallMarkerKey) else { return false }
        defaults.set(true, forKey: freshInstallMarkerKey)
        SecureCredentialStore.deleteTokens()
        SecureCredentialStore.deleteCredentials()
        print("[Auth] 检测到全新安装，已清空 Keychain 网盘凭据（Token + 授权）")
        return true
    }

    private func load() {
        // 方案 A：全新安装时清空 Keychain 网盘凭据，避免卸载重装后旧凭据残留
        if Self.purgeKeychainIfFreshInstall() {
            credentials = [:]
            return
        }
        do {
            if let decoded = try SecureCredentialStore.loadCredentials() {
                credentials = decoded
                return
            }
        } catch {
            print("[Auth] Keychain 读取失败: \(error)")
        }

        // 从旧版 UserDefaults 迁移一次，随后删除旧数据
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: CloudDriveCredential].self, from: data) {
            credentials = decoded
            do {
                try SecureCredentialStore.save(credentials: decoded)
                print("[Auth] 已从 UserDefaults 迁移到 Keychain")
            } catch {
                print("[Auth] 迁移到 Keychain 失败: \(error)")
            }
            defaults.removeObject(forKey: storageKey)
        } else {
            credentials = [:]
        }
    }

    private func persist() {
        do {
            try SecureCredentialStore.save(credentials: credentials)
        } catch {
            print("[Auth] Keychain 保存失败: \(error)")
        }
    }

    /// 备份还原写入 Keychain 后，从 Keychain 重载内存缓存
    func reloadCredentialsFromKeychain() {
        load()
    }

    private func syncLegacyTokensIfNeeded() {
        for token in CloudDriveManager.shared.savedTokens {
            guard let type = CloudDriveManager.DriveType(rawValue: token.type),
                  credentials[type.rawValue] == nil else { continue }
            saveManualCredential(type: type, name: token.name, value: token.value)
        }
    }

    /// 启动时批量校验所有已保存凭证，将失效凭证标记为 invalid
    func validateAllCredentials() async {
        for credential in credentials.values {
            guard let type = CloudDriveManager.DriveType(rawValue: credential.driveType) else { continue }
            _ = try? await validateCredential(for: type)
        }
    }

    /// 敏感字段日志脱敏（保留前 6 后 4，中间用 ... 替代）
    static func logSensitive(_ message: String, value: String?) {
        guard let value = value, !value.isEmpty else { return }
        let head = min(6, value.count)
        let tail = min(4, max(0, value.count - head))
        let prefix = String(value.prefix(head))
        let suffix = tail > 0 ? String(value.suffix(tail)) : ""
        print("\(message): \(prefix)...\(suffix) (length=\(value.count))")
    }

    private static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private final class RedirectCookieCollector: NSObject, URLSessionTaskDelegate {
    private var cookies: [String: HTTPCookie] = [:]
    private let lock = NSLock()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        collect(from: response, url: response.url ?? request.url)
        completionHandler(request)
    }

    func cookieString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return CloudDriveAuthManager.cookieString(from: Array(cookies.values))
    }

    private func collect(from response: HTTPURLResponse, url: URL?) {
        guard let url else { return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)"] = "\(value)"
        }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard !parsed.isEmpty else { return }
        lock.lock()
        for cookie in parsed {
            cookies[cookie.name] = cookie
        }
        lock.unlock()
    }
}

enum AuthError: LocalizedError {
    case invalidResponse(String)
    case remoteError(String)
    case notAuthorized(String)
    case keychainError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): return message
        case .remoteError(let message): return message
        case .notAuthorized(let message): return message
        case .keychainError(let message): return "Keychain 错误: \(message)"
        }
    }
}

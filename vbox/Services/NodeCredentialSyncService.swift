import Foundation
import Combine

// MARK: - 通知

extension Notification.Name {
    /// 凭据同步完成（object = NodeCredentialSyncSummary）
    static let nodeCredentialsSynced = Notification.Name("nodeCredentialsSynced")
}

// MARK: - 同步结果摘要

struct NodeCredentialSyncSummary {
    var pushedFields: Int = 0
    var pulledDrives: [String] = []
    var errors: [String] = []
    var startedAt = Date()
    var duration: TimeInterval = 0

    var succeeded: Bool { errors.isEmpty }
}

// MARK: - 同步服务
//
// P1-04/17: token 统一主存（Keychain）+ 配置同步协议（queryProfile/saveProfile）
//
// 职责：
//   - queryProfile：把 vbox Keychain（CloudDriveAuthManager → SecureCredentialStore）
//     中「新增网盘」的凭据推送到 Node 常驻系统（PUT /website/api/credential/:provider/:field）
//   - saveProfile：把 Node 常驻系统中的「新增网盘」凭据拉回并写入 Keychain
//     （GET /website/api/credentials）
//   - syncNow：按方向编排 push/pull
//
// 铁律：
//   1. 同步范围严格限定新增网盘：115/123/139/189/迅雷/光鸭/蜗牛；
//   2. 百度/夸克/UC/阿里的既有凭据与 Node 无交集，本服务不读写它们；
//   3. 凭据落点统一为 Keychain（SecureCredentialStore），Node 仅作镜像。
//
// 协议对齐（bundle kstore_index.js c_t / pK0）：
//   - 写: PUT /website/api/credential/:provider/:field  body {"value": "..."}
//   - 删: DELETE /website/api/credential/:provider/:field
//   - 读: GET  /website/api/credentials  -> {code:0, data:{...}}
//   - 响应统一 {code:0} 表示成功，code!=0 或 HTTP 非 2xx 视为失败

final class NodeCredentialSyncService: NSObject {

    static let shared = NodeCredentialSyncService()

    // MARK: - 映射表

    /// 单字段映射：nodeField（bundle 侧字段）→ keychainSlot（CloudDriveCredential 落点）
    /// slot 取值："cookie" 或 "extra:<key>"；dbPath 为 wexfnwconfig.json 中的存储路径段
    private struct FieldMap {
        let nodeField: String
        let keychainSlot: String
        let dbPath: [String]
    }

    private struct ProviderSpec {
        let nodeProvider: String
        let fields: [FieldMap]
    }

    /// vbox driveType(rawValue) → Node provider（与 bundle c_t / wexfnwconfig.json 对齐）
    private static let managedProviders: [String: ProviderSpec] = [
        "one15": ProviderSpec(nodeProvider: "pan115", fields: [
            FieldMap(nodeField: "cookie", keychainSlot: "cookie", dbPath: ["pan", "pan115", "cookie"]),
        ]),
        "pan123": ProviderSpec(nodeProvider: "pan123", fields: [
            FieldMap(nodeField: "account", keychainSlot: "extra:account", dbPath: ["pan", "pan123", "account"]),
            FieldMap(nodeField: "password", keychainSlot: "extra:password", dbPath: ["pan", "pan123", "password"]),
            FieldMap(nodeField: "auth", keychainSlot: "extra:auth", dbPath: ["pan", "pan123", "auth"]),
        ]),
        "pan139": ProviderSpec(nodeProvider: "new139", fields: [
            FieldMap(nodeField: "session", keychainSlot: "extra:session", dbPath: ["pan", "new139", "session"]),
            FieldMap(nodeField: "device", keychainSlot: "extra:device", dbPath: ["pan", "new139", "device"]),
        ]),
        "pan189": ProviderSpec(nodeProvider: "tyi", fields: [
            FieldMap(nodeField: "account", keychainSlot: "extra:account", dbPath: ["pan", "pan189", "account"]),
            FieldMap(nodeField: "password", keychainSlot: "extra:password", dbPath: ["pan", "pan189", "password"]),
            FieldMap(nodeField: "cookie", keychainSlot: "cookie", dbPath: ["pan", "pan189", "cookie"]),
            FieldMap(nodeField: "refreshCookie", keychainSlot: "extra:refreshCookie", dbPath: ["pan", "pan189", "refreshCookie"]),
        ]),
        "xunlei": ProviderSpec(nodeProvider: "thunder", fields: [
            FieldMap(nodeField: "config", keychainSlot: "extra:config", dbPath: ["pan", "thunder", "config"]),
        ]),
        "guangya": ProviderSpec(nodeProvider: "guangya", fields: [
            FieldMap(nodeField: "token", keychainSlot: "extra:token", dbPath: ["pan", "guangya", "token"]),
        ]),
        "woniu4k": ProviderSpec(nodeProvider: "woniu4k", fields: [
            FieldMap(nodeField: "account", keychainSlot: "extra:account", dbPath: ["siteCookie", "woniu4k", "account"]),
            FieldMap(nodeField: "password", keychainSlot: "extra:password", dbPath: ["siteCookie", "woniu4k", "password"]),
            FieldMap(nodeField: "cookie", keychainSlot: "cookie", dbPath: ["siteCookie", "woniu4k", "cookie"]),
        ]),
    ]

    /// pull 方向：bundle GET /website/api/credentials 的 data key → vbox driveType
    /// 说明：pK0 仅暴露 pan115/pan123/pan189/new139 等条目；
    ///       thunder/guangya/woniu4k 由各自登录路由管理，不走通用读接口，pull 时跳过。
    private static let pullable: [String: String] = [
        "pan115": "one15",
        "pan123": "pan123",
        "pan189": "pan189",
        "new139": "pan139",
    ]

    /// 自动推送去重（Node 就绪后只推一次，避免重复 PUT）
    private var hasAutoSynced = false

    // MARK: - 生命周期

    private override init() {
        super.init()
        // Node 就绪后自动把本地 Keychain 凭据镜像到 Node（幂等 PUT）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNodeStatus),
            name: .nodeRuntimeStatus,
            object: nil
        )
    }

    @objc private func handleNodeStatus(_ note: Notification) {
        guard let status = note.object as? String, status.hasPrefix("node-ready") else { return }
        guard !hasAutoSynced else { return }
        hasAutoSynced = true
        log("✅ Node 就绪，自动推送 Keychain 凭据镜像")
        Task { await queryProfile() }
    }

    // MARK: - 对外接口

    enum SyncDirection {
        case push // vbox → Node（本地登录成功后调用）
        case pull // Node → vbox（Node 网页登录后调用）
        case both
    }

    /// 按方向编排同步，返回合并摘要
    @discardableResult
    func syncNow(direction: SyncDirection = .both) async -> NodeCredentialSyncSummary {
        var merged = NodeCredentialSyncSummary()
        switch direction {
        case .push:
            merged = await performPush()
        case .pull:
            merged = await performPull()
        case .both:
            let push = await performPush()
            let pull = await performPull()
            merged.pushedFields = push.pushedFields
            merged.pulledDrives = pull.pulledDrives
            merged.errors = push.errors + pull.errors
        }
        merged.duration = Date().timeIntervalSince(merged.startedAt)
        postSyncNotification(merged)
        return merged
    }

    /// 查询并推送 vbox Keychain → Node（queryProfile）
    @discardableResult
    func queryProfile() async -> NodeCredentialSyncSummary {
        let summary = await performPush()
        postSyncNotification(summary)
        return summary
    }

    /// 拉取 Node → vbox Keychain（saveProfile）
    @discardableResult
    func saveProfile() async -> NodeCredentialSyncSummary {
        let summary = await performPull()
        postSyncNotification(summary)
        return summary
    }

    // MARK: - 内部实现

    private func performPush() async -> NodeCredentialSyncSummary {
        var summary = NodeCredentialSyncSummary()
        let credentials = CloudDriveAuthManager.shared.credentials

        for (driveType, spec) in Self.managedProviders {
            guard let credential = credentials[driveType] else { continue }
            for field in spec.fields {
                guard let value = value(from: credential, slot: field.keychainSlot), !value.isEmpty else { continue }
                do {
                    let path = "/website/api/credential/\(spec.nodeProvider)/\(field.nodeField)"
                    _ = try await requestJSON("PUT", path, body: ["value": value])
                    summary.pushedFields += 1
                    log("[NodeSync] ✅ 推送 \(driveType).\(field.nodeField)（\(value.count) 字符）")
                } catch {
                    summary.errors.append("push \(driveType).\(field.nodeField): \(error.localizedDescription)")
                    log("[NodeSync] ❌ 推送 \(driveType).\(field.nodeField) 失败: \(error.localizedDescription)", .error)
                }
            }
        }
        summary.duration = Date().timeIntervalSince(summary.startedAt)
        log("[NodeSync] 📤 queryProfile 完成: 推送 \(summary.pushedFields) 个字段, 错误 \(summary.errors.count)")
        return summary
    }

    private func performPull() async -> NodeCredentialSyncSummary {
        var summary = NodeCredentialSyncSummary()
        var pulled = Set<String>()

        // 1) HTTP：GET /website/api/credentials（bundle 权威读接口，覆盖 4 盘）
        do {
            let json = try await requestJSON("GET", "/website/api/credentials")
            if let data = json["data"] as? [String: Any] {
                for (bundleKey, driveType) in Self.pullable {
                    guard let raw = data[bundleKey] as? [String: Any],
                          let spec = Self.managedProviders[driveType] else { continue }
                    var values: [String: String] = [:]
                    for field in spec.fields {
                        if let v = raw[field.nodeField] as? String, !v.isEmpty {
                            values[field.nodeField] = v
                        }
                    }
                    guard !values.isEmpty else { continue }
                    upsertCredential(driveType: driveType, values: values, spec: spec)
                    pulled.insert(driveType)
                    log("[NodeSync] ✅ 拉取 \(driveType)（HTTP，\(values.count) 个字段）")
                }
            }
        } catch {
            summary.errors.append("pull(HTTP): \(error.localizedDescription)")
            log("[NodeSync] ⚠️ saveProfile HTTP 拉取失败: \(error.localizedDescription)", .warn)
        }

        // 2) 配置文件：直接读 wexfnwconfig.json（覆盖全部 7 盘，含 thunder/guangya/woniu4k）
        do {
            let fileValues = try readConfigFileValues()
            for (driveType, spec) in Self.managedProviders {
                var values: [String: String] = [:]
                for field in spec.fields {
                    if let v = fileValues[driveType]?[field.nodeField], !v.isEmpty {
                        values[field.nodeField] = v
                    }
                }
                guard !values.isEmpty else { continue }
                upsertCredential(driveType: driveType, values: values, spec: spec)
                pulled.insert(driveType)
                log("[NodeSync] ✅ 拉取 \(driveType)（配置文件，\(values.count) 个字段）")
            }
        } catch {
            summary.errors.append("pull(file): \(error.localizedDescription)")
            log("[NodeSync] ⚠️ saveProfile 配置文件拉取失败: \(error.localizedDescription)", .warn)
        }

        summary.pulledDrives = Array(pulled).sorted()
        summary.duration = Date().timeIntervalSince(summary.startedAt)
        log("[NodeSync] 📥 saveProfile 完成: 拉取 \(summary.pulledDrives.count) 个网盘, 错误 \(summary.errors.count)")
        return summary
    }

    /// 读取 wexfnwconfig.json，按 dbPath 提取 driveType → [nodeField: value]
    private func readConfigFileValues() throws -> [String: [String: String]] {
        let fileURL = NodeRuntimeManager.shared.runtimeDir.appendingPathComponent("wexfnwconfig.json")
        let data = try Data(contentsOf: fileURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodeCredentialSyncError.nodeRejected("wexfnwconfig.json 格式异常")
        }
        var result: [String: [String: String]] = [:]
        for (driveType, spec) in Self.managedProviders {
            var values: [String: String] = [:]
            for field in spec.fields {
                guard let raw = valueAtPath(root, field.dbPath) else { continue }
                let text: String
                if let s = raw as? String {
                    text = s
                } else if let d = raw as? Double, d == d.rounded() {
                    text = String(Int(d))
                } else {
                    text = String(describing: raw)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values[field.nodeField] = trimmed
                }
            }
            if !values.isEmpty {
                result[driveType] = values
            }
        }
        return result
    }

    /// 按路径段在嵌套字典中取值（["pan","pan115","cookie"] → root["pan"]["pan115"]["cookie"]）
    private func valueAtPath(_ root: [String: Any], _ path: [String]) -> Any? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else {
                return nil
            }
            current = next
        }
        return current
    }

    /// 把 Node 侧字段合并写入 Keychain（统一凭据模型，不触碰百度等旧 token 结构）
    private func upsertCredential(driveType: String, values: [String: String], spec: ProviderSpec) {
        var credential = CloudDriveAuthManager.shared.credentials[driveType] ?? makeEmptyCredential(driveType: driveType)
        for field in spec.fields {
            guard let v = values[field.nodeField], !v.isEmpty else { continue }
            setting(value: v, slot: field.keychainSlot, into: &credential)
        }
        credential.state = .valid
        credential.statusMessage = "已与 Node 常驻系统同步"
        credential.updatedAt = Date()
        credential.lastCheckedAt = Date()
        CloudDriveAuthManager.shared.saveCredential(credential, syncLegacyToken: false)
    }

    private func makeEmptyCredential(driveType: String) -> CloudDriveCredential {
        CloudDriveCredential(
            driveType: driveType,
            authType: .manual,
            accessToken: nil,
            refreshToken: nil,
            cookie: nil,
            driveId: nil,
            userId: nil,
            userName: nil,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: nil,
            state: .unknown,
            statusMessage: nil,
            extra: [:]
        )
    }

    // MARK: - CloudDriveCredential 字段存取

    private func value(from credential: CloudDriveCredential, slot: String) -> String? {
        if slot == "cookie" { return credential.cookie }
        if slot.hasPrefix("extra:") {
            let key = String(slot.dropFirst("extra:".count))
            return credential.extra[key]
        }
        return nil
    }

    private func setting(value: String?, slot: String, into credential: inout CloudDriveCredential) {
        if slot == "cookie" {
            credential.cookie = value
        } else if slot.hasPrefix("extra:") {
            let key = String(slot.dropFirst("extra:".count))
            if let value {
                credential.extra[key] = value
            } else {
                credential.extra.removeValue(forKey: key)
            }
        }
    }

    // MARK: - HTTP 层（带重试）

    private func requestJSON(_ method: String, _ path: String, body: [String: Any]? = nil, attempts: Int = 3) async throws -> [String: Any] {
        guard NodeRuntimeManager.shared.isSystemReady else {
            throw NodeCredentialSyncError.nodeNotReady
        }
        var lastError: Error = NodeCredentialSyncError.unknown
        for attempt in 1...attempts {
            do {
                guard let url = URL(string: NodeRuntimeManager.shared.baseURL + path) else {
                    throw NodeCredentialSyncError.unknown
                }
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.timeoutInterval = 15
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let body {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NodeCredentialSyncError.unknown
                }
                guard (200...299).contains(http.statusCode) else {
                    throw NodeCredentialSyncError.httpStatus(http.statusCode)
                }
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if let code = json["code"] as? Int, code != 0 {
                    throw NodeCredentialSyncError.nodeRejected(json["msg"] as? String ?? "code=\(code)")
                }
                return json
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(attempt)) * 1_000_000_000)
                }
            }
        }
        throw lastError
    }

    // MARK: - 通知与日志

    private func postSyncNotification(_ summary: NodeCredentialSyncSummary) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .nodeCredentialsSynced, object: summary)
        }
    }

    private func log(_ message: String, _ level: LogLevel = .info) {
        print(message)
        AppLogStore.shared.log(level, .cloud, message)
    }
}

// MARK: - 错误类型

enum NodeCredentialSyncError: LocalizedError {
    case nodeNotReady
    case httpStatus(Int)
    case nodeRejected(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .nodeNotReady:
            return "Node 常驻系统未就绪"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .nodeRejected(let msg):
            return "Node 拒绝: \(msg)"
        case .unknown:
            return "未知错误"
        }
    }
}

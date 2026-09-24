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
        "bilibili": ProviderSpec(nodeProvider: "bili", fields: [
            FieldMap(nodeField: "cookie", keychainSlot: "cookie", dbPath: ["siteCookie", "bili", "cookie"]),
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

    /// 是否为 Node 托管网盘（删除展示镜像时级联清除 Node 登录态）。
    /// 显式枚举 7 个 Node 网盘，不依赖 managedProviders 键名（其键为 case 名，
    /// 与 DriveType.rawValue 如 "115"/"123pan" 不一致，避免映射漏判）。
    func isNodeManaged(_ driveType: CloudDriveManager.DriveType) -> Bool {
        switch driveType {
        case .one15, .pan123, .pan139, .pan189, .xunlei, .guangya, .woniu4k, .bilibili:
            return true
        default:
            return false
        }
    }

    /// driveType → managedProviders 键（case 名；与 rawValue 如 "115" 不一致）
    private func providerKey(for driveType: CloudDriveManager.DriveType) -> String? {
        switch driveType {
        case .one15: return "one15"
        case .pan123: return "pan123"
        case .pan139: return "pan139"
        case .pan189: return "pan189"
        case .xunlei: return "xunlei"
        case .guangya: return "guangya"
        case .woniu4k: return "woniu4k"
        case .bilibili: return "bilibili"
        default: return nil
        }
    }

    /// 级联删除 Node 登录态：Node bundle 侧逐字段 DELETE + Keychain 主凭据删除
    /// + wexfnwconfig.json 字段清理（防止 Node DELETE 失败后 pull 复活登录态）。
    /// 供「复制粘贴 Token 兜底」列表删除 Node 镜像条目时调用；
    /// 任一环节失败不中断，错误写入日志（播放/授权中心可查看）。
    @discardableResult
    func deleteNodeCredential(driveType: CloudDriveManager.DriveType) async -> NodeCredentialSyncSummary {
        var summary = NodeCredentialSyncSummary()
        guard let key = providerKey(for: driveType),
              let spec = Self.managedProviders[key] else {
            log("[NodeSync] ⚠️ \(driveType.displayName) 非 Node 托管网盘，跳过级联删除", .warn)
            return summary
        }

        // 1) Node bundle 侧：逐字段 DELETE /website/api/credential/:provider/:field
        for field in spec.fields {
            do {
                let path = "/website/api/credential/\(spec.nodeProvider)/\(field.nodeField)"
                _ = try await requestJSON("DELETE", path)
                log("[NodeSync] 🗑 已删除 Node 凭据 \(driveType.displayName).\(field.nodeField)")
            } catch {
                summary.errors.append("delete \(driveType.displayName).\(field.nodeField): \(error.localizedDescription)")
                log("[NodeSync] ⚠️ 删除 Node 凭据 \(driveType.displayName).\(field.nodeField) 失败: \(error.localizedDescription)", .warn)
            }
        }

        // 2) 配置文件兜底清理：直接从 wexfnwconfig.json 移除该网盘字段
        removeConfigFileFields(driveType: driveType, spec: spec)

        // 3) Keychain 主凭据：本地登录态强制退出（主线程，避免 UI 状态竞争；
        //    同时清除 rawValue 键与 Node 同步的 case 名键）
        await MainActor.run {
            CloudDriveAuthManager.shared.removeCredentialAndAliases(for: driveType)
        }

        summary.duration = Date().timeIntervalSince(summary.startedAt)
        log("[NodeSync] 🗑 \(driveType.displayName) Node 登录态已清除（Keychain + Node bundle）")
        return summary
    }

    /// 直接从 wexfnwconfig.json 移除指定网盘的字段（防止 Node DELETE 失败后配置残留复活登录态）
    private func removeConfigFileFields(driveType: CloudDriveManager.DriveType, spec: ProviderSpec) {
        let fileURL = NodeRuntimeManager.shared.runtimeDir.appendingPathComponent("wexfnwconfig.json")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var changed = false
        for field in spec.fields {
            if removeValueAtPath(&root, field.dbPath) { changed = true }
        }
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let _ = try? out.write(to: fileURL) else { return }
        log("[NodeSync] 🗑 已从 wexfnwconfig.json 清理 \(driveType.displayName) 凭据字段")
    }

    /// 沿路径移除嵌套字典中的值（返回是否发生变更）
    private func removeValueAtPath(_ root: inout [String: Any], _ path: [String]) -> Bool {
        guard let first = path.first else { return false }
        if path.count == 1 {
            guard root[first] != nil else { return false }
            root.removeValue(forKey: first)
            return true
        }
        guard var child = root[first] as? [String: Any] else { return false }
        let changed = removeValueAtPath(&child, Array(path.dropFirst()))
        if changed { root[first] = child }
        return changed
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
        // 统一收集待落库凭据，最后在 MainActor 上一次性写入：
        // 避免在扫码登录等深层 async 调用链内同步触发 @Published（credentials/savedTokens）
        // 导致 CloudAuthCenterView 深度嵌套重绘、主线程栈溢出（SIGBUS / ___chkstk_darwin）。
        var pending: [(driveType: String, values: [String: String], spec: ProviderSpec)] = []

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
                    pending.append((driveType, values, spec))
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
                pending.append((driveType, values, spec))
                pulled.insert(driveType)
                log("[NodeSync] ✅ 拉取 \(driveType)（配置文件，\(values.count) 个字段）")
            }
        } catch {
            summary.errors.append("pull(file): \(error.localizedDescription)")
            log("[NodeSync] ⚠️ saveProfile 配置文件拉取失败: \(error.localizedDescription)", .warn)
        }

        // 3) 统一在 MainActor 浅栈落库：await 挂起后旧调用链栈帧已释放，
        //    saveCredential / addOrReplaceToken 触发的同步重绘不再嵌套在深层链路内。
        await MainActor.run {
            for item in pending {
                upsertCredential(driveType: item.driveType, values: item.values, spec: item.spec)
            }
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
        mirrorToLegacyTokens(driveType: driveType, credential: credential)
    }

    /// 把 Node 托管网盘的登录态镜像到「复制粘贴 Token 兜底」列表（展示 + 可删）。
    /// 覆盖全部 Node 托管网盘：115/123/139/189/迅雷/光鸭/蜗牛。
    /// 镜像条目仅供用户在兜底界面查看/删除，不参与解析决策：
    ///   光鸭/蜗牛解析走 Node（A1 接缝）；115/123/139/189/迅雷 解析读 Keychain primarySecret，
    ///   savedTokens 仅作展示，不会影响解析（tokens(for:) 以 Keychain bestTokenValue 优先）。
    private func mirrorToLegacyTokens(driveType: String, credential: CloudDriveCredential) {
        // managedProviders 键为 case 名（one15/pan123/pan139/pan189），
        // 与 DriveType.rawValue（"115"/"123pan"/"139pan"/"189pan"）不一致，先映射再取 rawValue。
        let mapped: CloudDriveManager.DriveType?
        switch driveType {
        case "one15": mapped = .one15
        case "pan123": mapped = .pan123
        case "pan139": mapped = .pan139
        case "pan189": mapped = .pan189
        case "xunlei": mapped = .xunlei
        case "guangya": mapped = .guangya
        case "woniu4k": mapped = .woniu4k
        default: mapped = CloudDriveManager.DriveType(rawValue: driveType)
        }
        guard let driveType = mapped else { return }
        let primary: String?
        let name: String
        switch driveType {
        case .one15:
            primary = credential.cookie
            name = "115-Node"
        case .pan123:
            primary = credential.extra["auth"] ?? credential.extra["account"]
            name = "123-Node"
        case .pan139:
            primary = credential.extra["session"]
            name = "139-Node"
        case .pan189:
            primary = credential.cookie
            name = "189-Node"
        case .xunlei:
            primary = credential.extra["config"]
            name = "迅雷-Node"
        case .guangya:
            primary = credential.extra["token"]
            name = "光鸭-Node"
        case .woniu4k:
            primary = credential.cookie
            name = "蜗牛-Node"
        case .bilibili:
            primary = credential.cookie
            name = "哔哩-Node"
        default:
            return
        }
        if let primary, !primary.isEmpty {
            CloudDriveManager.shared.addOrReplaceToken(type: driveType, name: name, value: primary)
        }
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
        if !NodeRuntimeManager.shared.isSystemReady {
            try await waitForNodeReady(timeout: 15)
        }
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

    /// 轮询等待 Node 常驻系统就绪；崩溃/启动失败时立即返回
    private func waitForNodeReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NodeRuntimeManager.shared.isSystemReady {
                return
            }
            if NodeRuntimeManager.shared.isCrashed {
                throw NodeCredentialSyncError.nodeNotReady
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
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

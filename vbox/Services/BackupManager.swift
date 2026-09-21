import Foundation
import CryptoKit
import CommonCrypto
import Security
import UIKit

// MARK: - 备份类目

enum BackupCategory: String, CaseIterable, Identifiable {
    case watchHistory
    case favorites
    case downloads
    case subscriptions
    case siteConfigs
    case personalSettings
    case searchHistory
    case cloudCredentials

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watchHistory: return "观看记录"
        case .favorites: return "我的收藏"
        case .downloads: return "下载记录"
        case .subscriptions: return "订阅源"
        case .siteConfigs: return "站点配置"
        case .personalSettings: return "个人设置"
        case .searchHistory: return "搜索历史"
        case .cloudCredentials: return "网盘凭据"
        }
    }

    var subtitle: String {
        switch self {
        case .watchHistory: return "播放历史与观看进度"
        case .favorites: return "收藏的剧集列表"
        case .downloads: return "下载列表与进度（不含本地文件）"
        case .subscriptions: return "订阅的源地址列表"
        case .siteConfigs: return "站点、解析设置等配置"
        case .personalSettings: return "用户名、头像、外观、TMDB 等（不含福利）"
        case .searchHistory: return "搜索关键词记录"
        case .cloudCredentials: return "网盘授权令牌，敏感数据，默认关闭"
        }
    }

    var icon: String {
        switch self {
        case .watchHistory: return "clock.fill"
        case .favorites: return "star.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .subscriptions: return "link"
        case .siteConfigs: return "globe"
        case .personalSettings: return "person.crop.circle"
        case .searchHistory: return "magnifyingglass"
        case .cloudCredentials: return "lock.shield.fill"
        }
    }

    var isSensitive: Bool { self == .cloudCredentials }
    var defaultOn: Bool { !isSensitive }
}

// MARK: - 冲突策略

enum ConflictStrategy: String, CaseIterable, Identifiable {
    case merge = "合并"
    case overwrite = "覆盖"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .merge: return "保留本机现有数据，把备份内容合并进来"
        case .overwrite: return "先清空本机对应类目，再完整写入备份内容"
        }
    }
}

// MARK: - 备份文件结构

struct BackupMeta: Codable {
    var appName: String
    var appVersion: String
    var createdAt: Int64
    var account: String
    var username: String
    var device: String
}

struct BackupFileEnvelope: Codable {
    var schemaVersion: Int
    var meta: BackupMeta
    var encrypted: Bool
    var cipher: String?
    var kdf: String?
    var salt: String?
    var iv: String?
    var authTag: String?
    var payload: String
}

struct BackupPayload: Codable {
    var account: String
    var categories: [String: Data]
}

/// 站点配置快照（站点 + API 源 + 解析设置）
struct SiteConfigsSnapshot: Codable {
    var zhanyuan: [ZhanyuanSite]
    var apiyuan: [ApiYuanSite]
    var jiexi: [JiexiSetting]
}

/// 个人设置快照（settings 表 + UserDefaults 白名单，福利相关键不参与）
struct PersonalSettingsSnapshot: Codable {
    var username: String
    var avatarBase64: String?
    var defaults: [String: String]
}

/// 网盘凭据快照（Keychain 中的授权凭证与手动 Token）
struct CredentialsSnapshot: Codable {
    var credentials: [String: CloudDriveCredential]
    var tokens: [DriveToken]
}

// MARK: - 错误与结果

enum BackupError: LocalizedError {
    case wrongPassword
    case schemaTooNew(Int)
    case invalidFormat(String)
    case cryptoFailed(String)
    case emptyPassword

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "口令错误，无法解密这份备份"
        case .schemaTooNew(let v): return "备份文件格式版本 v\(v) 高于当前 App 支持的 v\(BackupManager.supportedSchemaVersion)，请先升级 App 再还原"
        case .invalidFormat(let s): return "备份文件格式无效：\(s)"
        case .cryptoFailed(let s): return "加密处理失败：\(s)"
        case .emptyPassword: return "这份备份已加密，请输入口令"
        }
    }
}

struct BackupRestoreResult {
    var restored: [BackupCategory]
    var skippedCredentialAccountMismatch: Bool
    var totalCounts: [BackupCategory: Int]

    var summary: String {
        var lines = restored.map { "\($0.title)：\(totalCounts[$0] ?? 0) 条" }
        if skippedCredentialAccountMismatch {
            lines.append("网盘凭据：备份账号与当前账号不一致，已跳过")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 备份管理器

@MainActor
final class BackupManager {
    static let shared = BackupManager()
    static let supportedSchemaVersion = 1

    private static let pbkdf2Iterations = 100_000
    private static let saltLength = 16
    private static let ivLength = 12

    private enum SettingType {
        case string
        case bool
        case int
    }

    /// 个人设置 UserDefaults 白名单（与 AppSettings 键保持一致；福利/远程源键不参与）
    private static let settingsDefaultKeys: [(key: String, type: SettingType)] = [
        ("app_skin_mode", .string),
        ("app_skin_follows_system", .bool),
        ("app_enable_tmdb", .bool),
        ("app_tmdb_proxy_url", .string),
        ("app_tmdb_use_token", .bool),
        ("app_tmdb_proxy_token", .string),
        ("app_dev_log_enabled", .bool),
        ("app_dev_log_level", .int),
    ]

    private init() {}

    // MARK: - 口令派生与加解密（AES-256-GCM + PBKDF2）

    private static func deriveKey(password: String, salt: Data) -> SymmetricKey? {
        var key = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { pw -> Int32 in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                guard let saltBase = saltBuf.bindMemory(to: UInt8.self).baseAddress else {
                    return errSecParam
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw,
                    password.utf8.count,
                    saltBase,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(pbkdf2Iterations),
                    &key,
                    key.count
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: Data(key))
    }

    private static func encrypt(_ data: Data, password: String) throws -> (salt: Data, iv: Data, tag: Data, ciphertext: Data) {
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: .min ... .max) })
        var ivBytes = [UInt8](repeating: 0, count: ivLength)
        guard SecRandomCopyBytes(kSecRandomDefault, ivBytes.count, &ivBytes) == errSecSuccess else {
            throw BackupError.cryptoFailed("随机数生成失败")
        }
        let iv = Data(ivBytes)
        guard let key = deriveKey(password: password, salt: salt) else {
            throw BackupError.cryptoFailed("口令密钥派生失败")
        }
        let sealed = try AES.GCM.seal(data, using: key, nonce: try AES.GCM.Nonce(data: iv))
        return (salt, iv, sealed.tag, sealed.ciphertext)
    }

    private static func decrypt(salt: Data, iv: Data, tag: Data, ciphertext: Data, password: String) throws -> Data {
        guard let key = deriveKey(password: password, salt: salt) else {
            throw BackupError.cryptoFailed("口令密钥派生失败")
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key)
    }

    // MARK: - 备份采集

    func collectCategory(_ category: BackupCategory) throws -> Data? {
        switch category {
        case .watchHistory:
            return try JSONEncoder().encode(DatabaseManager.shared.queryHistory())
        case .favorites:
            return try JSONEncoder().encode(DatabaseManager.shared.queryFavorites())
        case .downloads:
            return try JSONEncoder().encode(DatabaseManager.shared.queryDownloads())
        case .subscriptions:
            return try JSONEncoder().encode(DatabaseManager.shared.querySubscriptions())
        case .siteConfigs:
            return try JSONEncoder().encode(SiteConfigsSnapshot(
                zhanyuan: DatabaseManager.shared.queryAllZhanyuanSites(),
                apiyuan: DatabaseManager.shared.queryAllApiYuanSites(),
                jiexi: DatabaseManager.shared.queryJiexiSettings()
            ))
        case .personalSettings:
            return try JSONEncoder().encode(collectPersonalSettings())
        case .searchHistory:
            return try JSONEncoder().encode(DatabaseManager.shared.querySearchHistory(limit: 100))
        case .cloudCredentials:
            let credentials = (try? SecureCredentialStore.loadCredentials()) ?? [:]
            let tokens = (try? SecureCredentialStore.loadTokens()) ?? []
            return try JSONEncoder().encode(CredentialsSnapshot(credentials: credentials, tokens: tokens))
        }
    }

    private func collectPersonalSettings() -> PersonalSettingsSnapshot {
        let defaults = UserDefaults.standard
        var dict: [String: String] = [:]
        for (key, type) in Self.settingsDefaultKeys {
            switch type {
            case .string:
                if let value = defaults.string(forKey: key) {
                    dict[key] = value
                }
            case .bool:
                if let value = defaults.object(forKey: key) as? Bool {
                    dict[key] = value ? "1" : "0"
                }
            case .int:
                if let value = defaults.object(forKey: key) as? Int {
                    dict[key] = "\(value)"
                }
            }
        }
        return PersonalSettingsSnapshot(
            username: DatabaseManager.shared.getSetting(key: "username") ?? "",
            avatarBase64: DatabaseManager.shared.getSetting(key: "avatar_image"),
            defaults: dict
        )
    }

    // MARK: - 生成备份文件

    func createBackup(categories: [BackupCategory], password: String?) throws -> Data {
        let account = DatabaseManager.shared.getSetting(key: "account")
            ?? DatabaseManager.shared.getSetting(key: "username")
            ?? ""
        let username = DatabaseManager.shared.getSetting(key: "username") ?? account

        var payload = BackupPayload(account: account, categories: [:])
        for category in categories {
            if let data = try collectCategory(category) {
                payload.categories[category.rawValue] = data
            }
        }
        let payloadData = try JSONEncoder().encode(payload)

        let meta = BackupMeta(
            appName: "vbox",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            createdAt: Int64(Date().timeIntervalSince1970),
            account: account,
            username: username,
            device: UIDevice.current.model
        )

        if let password, !password.isEmpty {
            let (salt, iv, tag, ciphertext) = try Self.encrypt(payloadData, password: password)
            let envelope = BackupFileEnvelope(
                schemaVersion: Self.supportedSchemaVersion,
                meta: meta,
                encrypted: true,
                cipher: "AES-256-GCM",
                kdf: "PBKDF2-HMAC-SHA256",
                salt: salt.base64EncodedString(),
                iv: iv.base64EncodedString(),
                authTag: tag.base64EncodedString(),
                payload: ciphertext.base64EncodedString()
            )
            return try JSONEncoder().encode(envelope)
        } else {
            let envelope = BackupFileEnvelope(
                schemaVersion: Self.supportedSchemaVersion,
                meta: meta,
                encrypted: false,
                cipher: nil,
                kdf: nil,
                salt: nil,
                iv: nil,
                authTag: nil,
                payload: String(data: payloadData, encoding: .utf8) ?? ""
            )
            return try JSONEncoder().encode(envelope)
        }
    }

    // MARK: - 备份解析

    func parseEnvelope(data: Data) throws -> BackupFileEnvelope {
        guard let envelope = try? JSONDecoder().decode(BackupFileEnvelope.self, from: data) else {
            throw BackupError.invalidFormat("无法解析 JSON 结构")
        }
        guard envelope.schemaVersion <= Self.supportedSchemaVersion else {
            throw BackupError.schemaTooNew(envelope.schemaVersion)
        }
        return envelope
    }

    private func decodePayload(envelope: BackupFileEnvelope, password: String?) throws -> BackupPayload {
        let payloadData: Data
        if envelope.encrypted {
            guard let password, !password.isEmpty else { throw BackupError.emptyPassword }
            guard let salt = Data(base64Encoded: envelope.salt ?? ""),
                  let iv = Data(base64Encoded: envelope.iv ?? ""),
                  let tag = Data(base64Encoded: envelope.authTag ?? ""),
                  let ciphertext = Data(base64Encoded: envelope.payload) else {
                throw BackupError.invalidFormat("加密字段缺失或损坏")
            }
            do {
                payloadData = try Self.decrypt(salt: salt, iv: iv, tag: tag, ciphertext: ciphertext, password: password)
            } catch {
                throw BackupError.wrongPassword
            }
        } else {
            guard let data = envelope.payload.data(using: .utf8) else {
                throw BackupError.invalidFormat("明文内容损坏")
            }
            payloadData = data
        }
        guard let payload = try? JSONDecoder().decode(BackupPayload.self, from: payloadData) else {
            throw BackupError.invalidFormat("数据内容无法解析")
        }
        return payload
    }

    // MARK: - 还原

    func restore(backupData: Data,
                 categories: [BackupCategory],
                 strategy: ConflictStrategy,
                 password: String?,
                 currentAccount: String) throws -> BackupRestoreResult {
        let envelope = try parseEnvelope(data: backupData)
        let payload = try decodePayload(envelope: envelope, password: password)

        var result = BackupRestoreResult(restored: [], skippedCredentialAccountMismatch: false, totalCounts: [:])

        for category in categories {
            guard let raw = payload.categories[category.rawValue] else { continue }

            // 严格账号绑定：网盘凭据仅在备份账号与当前账号一致时还原
            if category == .cloudCredentials {
                guard payload.account == currentAccount else {
                    result.skippedCredentialAccountMismatch = true
                    continue
                }
            }

            let count = try restoreCategory(category, data: raw, strategy: strategy)
            result.restored.append(category)
            result.totalCounts[category] = count
        }

        return result
    }

    private func restoreCategory(_ category: BackupCategory, data: Data, strategy: ConflictStrategy) throws -> Int {
        let db = DatabaseManager.shared
        let decoder = JSONDecoder()

        switch category {
        case .watchHistory:
            let records = try decoder.decode([HistoryRecord].self, from: data)
            if strategy == .overwrite { db.clearHistory() }
            for var record in records {
                record.id = nil
                db.addOrUpdateHistory(record)
            }
            return records.count

        case .favorites:
            let records = try decoder.decode([FavoriteRecord].self, from: data)
            if strategy == .overwrite { db.clearAllFavorites() }
            for var record in records {
                record.id = nil
                if strategy == .merge, db.isFavorite2(detailurl: record.detailurl, laiyuan: record.laiyuan) != nil { continue }
                db.addFavorite(record)
            }
            return records.count

        case .downloads:
            // 语义：仅还原「列表 + 进度」，本地文件不参与迁移
            let records = try decoder.decode([DownloadRecord].self, from: data)
            if strategy == .overwrite { db.clearDownloads() }
            for var record in records {
                record.id = nil
                record.filePath = "" // 文件不随备份迁移
                if record.status == "completed" { record.status = "pending" } // 文件缺失，标记为可重新下载
                if strategy == .merge, downloadExists(db, record) { continue }
                db.addDownload(record)
            }
            return records.count

        case .subscriptions:
            let records = try decoder.decode([SubscriptionRecord].self, from: data)
            if strategy == .overwrite { db.clearAllSubscriptions() }
            for var record in records {
                record.id = nil
                db.saveSubscription(record)
            }
            return records.count

        case .siteConfigs:
            let snapshot = try decoder.decode(SiteConfigsSnapshot.self, from: data)
            if strategy == .overwrite {
                db.clearAllZhanyuanSites()
                db.clearAllApiYuanSites()
                db.clearAllJiexiSettings()
            }
            // 清空自增 id，避免与本地主键冲突（站点由 (name, dyurl) 唯一约束去重）
            let cleanZhanyuan = snapshot.zhanyuan.map { site -> ZhanyuanSite in
                var s = site
                s.id = nil
                return s
            }
            let cleanApiYuan = snapshot.apiyuan.map { site -> ApiYuanSite in
                var s = site
                s.id = nil
                return s
            }
            let zhanyuanBySource = Dictionary(grouping: cleanZhanyuan, by: { $0.dyurl })
            for (dyurl, sites) in zhanyuanBySource {
                db.saveZhanyuanSites(sites, dyurl: dyurl)
            }
            db.saveApiYuanSites(cleanApiYuan, dyurl: "")
            for setting in snapshot.jiexi { db.saveJiexiSetting(setting) }
            return snapshot.zhanyuan.count + snapshot.apiyuan.count + snapshot.jiexi.count

        case .personalSettings:
            let snapshot = try decoder.decode(PersonalSettingsSnapshot.self, from: data)
            restorePersonalSettings(snapshot, strategy: strategy)
            return 1

        case .searchHistory:
            let records = try decoder.decode([SearchHistoryRecord].self, from: data)
            if strategy == .overwrite { db.clearSearchHistory() }
            let existing = Set(db.querySearchHistory(limit: 200).map { $0.keyword })
            for record in records {
                if strategy == .merge, existing.contains(record.keyword) { continue }
                db.addSearchHistory(keyword: record.keyword)
            }
            return records.count

        case .cloudCredentials:
            let snapshot = try decoder.decode(CredentialsSnapshot.self, from: data)
            try SecureCredentialStore.save(credentials: snapshot.credentials)
            try SecureCredentialStore.save(tokens: snapshot.tokens)
            CloudDriveAuthManager.shared.reloadCredentialsFromKeychain()
            CloudDriveManager.shared.reloadTokensFromKeychain()
            return snapshot.credentials.count + snapshot.tokens.count
        }
    }

    private func downloadExists(_ db: DatabaseManager, _ record: DownloadRecord) -> Bool {
        db.queryDownloads().contains {
            $0.detailurl == record.detailurl && $0.jishu == record.jishu && $0.name == record.name
        }
    }

    private func restorePersonalSettings(_ snapshot: PersonalSettingsSnapshot, strategy: ConflictStrategy) {
        let db = DatabaseManager.shared
        if strategy == .overwrite {
            db.deleteSettings(keys: ["username", "avatar_image"])
        }
        if !snapshot.username.isEmpty {
            db.setSetting(key: "username", value: snapshot.username)
        }
        if let avatar = snapshot.avatarBase64 {
            db.setSetting(key: "avatar_image", value: avatar)
        }
        let defaults = UserDefaults.standard
        for (key, value) in snapshot.defaults {
            guard let entry = Self.settingsDefaultKeys.first(where: { $0.key == key }) else { continue }
            switch entry.type {
            case .string:
                defaults.set(value, forKey: key)
            case .bool:
                defaults.set(value == "1", forKey: key)
            case .int:
                defaults.set(Int(value) ?? 0, forKey: key)
            }
        }
    }
}

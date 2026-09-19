import Foundation
import Combine
import CryptoKit
import WebKit

/// 用于 CloudDriveManager 向播放器 Debug Overlay 广播日志
extension Notification.Name {
    static let cloudDriveLog = Notification.Name("cloudDriveLog")
}

struct DriveToken: Codable {
    let type: String
    let name: String
    let value: String
}

struct BaiduFileItem: Codable {
    let fsId: String
    let name: String
}

class CloudDriveManager: ObservableObject {

    static let shared = CloudDriveManager()

    /// 广播日志到播放器 Debug Overlay + 统一日志系统
    /// 所有网盘 (百度/阿里/夸克/UC/115/迅雷...) 的通用日志都走这里
    private func log(_ message: String) {
        print(message)
        // 转发到统一日志系统 (cloud 分类，自动识别级别)
        let level: LogLevel
        if message.contains("❌") || message.contains("失败") || message.contains("error") || message.contains("Error") {
            level = .error
        } else if message.contains("⚠️") || message.contains("warn") || message.contains("Warn") {
            level = .warn
        } else if message.contains("✅") || message.contains("⏱️") {
            level = .info
        } else {
            level = .verbose
        }
        AppLogStore.shared.log(level, .cloud, message)
        
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cloudDriveLog, object: message)
        }
    }

    private func typeString(for value: Any) -> String {
        if value is String { return "String" }
        if value is Int { return "Int" }
        if value is Double { return "Double" }
        if value is Bool { return "Bool" }
        if value is [String] { return "[String]" }
        if value is [String: Any] { return "[String: Any]" }
        return String(describing: type(of: value))
    }
    private static let baiduPCSUserAgent = "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) AppleWebKit/537.36 (KHTML, like Gecko)&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1&network_type=wifi&app_id=250528&size=c1080_u1600"
    // 严格对齐 iBox 百度路链：分享文件先转存到固定目录，再从用户网盘路径取链播放。
    // 注意：百度 API 的真实根路径是 "/"；App 里看到的“我的资源”是 UI 分类名，不应写进 API path。
    // 因此这里请求用 "/vbox"，在百度网盘 UI 里会显示为“我的资源/vbox”。
    private static let baiduIBoxTransferDir = "/vbox"

    enum DriveType: String, CaseIterable {
        case ali = "ali"
        case quark = "quark"
        case baidu = "baidu"
        case one15 = "115"
        case uc = "uc"
        case pan123 = "123pan"
        case pan139 = "139pan"
        case pan189 = "189pan"
        case xunlei = "xunlei"
        case guangya = "guangya"
        case woniu4k = "woniu4k"

        var displayName: String {
            switch self {
            case .ali: return "阿里云盘"
            case .quark: return "夸克网盘"
            case .baidu: return "百度网盘"
            case .one15: return "115网盘"
            case .uc: return "UC网盘"
            case .pan123: return "123云盘"
            case .pan139: return "139云盘"
            case .pan189: return "天翼云盘"
            case .xunlei: return "迅雷云盘"
            case .guangya: return "光鸭网盘"
            case .woniu4k: return "蜗牛网盘"
            }
        }

        var tokenLabel: String {
            switch self {
            case .ali: return "Refresh Token"
            case .quark: return "Cookie"
            case .baidu: return "完整 Cookie / BDUSS+STOKEN"
            case .one15: return "完整 Cookie / CID"
            case .uc: return "Cookie"
            case .pan123: return "Cookie / Token"
            case .pan139: return "Cookie / Session"
            case .pan189: return "Cookie / 账号密码（短信验证）"
            case .xunlei: return "Cookie / 网页登录"
            case .guangya: return "Token"
            case .woniu4k: return "账号 / 密码"
            }
        }
    }

    private let session: URLSession
    private let ucSession: URLSession
    private let defaults = UserDefaults.standard
    private let tokenKey = "saved_drive_tokens"
    private let baiduPersistedPlayCacheKey = "baidu_play_result_cache_v1"
    private let baiduPersistedPlayItemCacheKey = "baidu_play_item_cache_v1"
    private let baiduIBoxPlayItemCacheKey = "baidu_ibox_play_item_cache_v1"
    private let baiduFileListCacheKey = "baidu_file_list_cache_v1"
    private let baiduShareContextCacheKey = "baidu_share_context_cache_v1"
    private let baiduVerifyCooldownKey = "baidu_verify_cooldown_v1"
    private let unifiedCloudPlayItemCacheKey = "cloud_play_item_cache_v1"
    private let baiduRouteDiagnosticsKey = "baidu_route_diagnostics_v1"
    private let cleanupQueueKey = "cloud_drive_cleanup_queue_v1"
    private let quarkVboxFolderCacheKey = "quark_vbox_folder_cache_v1"
    private let quarkSavedFidCacheKey = "quark_saved_fid_cache_v1"

    private struct CleanupQueueItem: Codable, Hashable {
        let drive: String
        let tokenName: String
        let fileId: String
        let eligibleAt: Date
        let createdAt: Date
    }
    /// 夸克转存后的对象 fid 缓存，用于避免同一资源重复转存
    /// - topLevelFids: sharepage/save 返回的 save_as_top_fids，可能是文件或文件夹
    /// - playbackFileId: 实际用于 v2/play / download_url 的视频文件 fid
    private struct QuarkSavedFidCacheItem: Codable {
        let topLevelFids: [String]
        let playbackFileId: String?
        let fileName: String
        let folderId: String
        let cookieHash: String
        let createdAt: Date
        let expiresAt: Date
    }
    private struct BaiduPlayCacheItem {
        let result: PlayResult
        let expiresAt: Date
    }
    private struct BaiduPersistedPlayCacheItem: Codable {
        let url: String
        let headers: [String: String]
        let expiresAt: Date
    }
    private struct BaiduPlayItem: Codable {
        let fsId: String
        let fileName: String
        let path: String
        let headers: [String: String]
        let compatibilityHint: String
        let updatedAt: Date
    }
    private struct BaiduIBoxPlayItem: Codable {
        let shareURL: String
        let fsId: String
        let fileName: String
        let path: String
        let dlinkURL: String?
        let headers: [String: String]
        let dlinkExpiresAt: Date?
        let compatibilityHint: String
        let preferredEngine: String
        let preparedAt: Date
        let updatedAt: Date
        let lastUsedAt: Date?
        let source: String
    }
    private struct BaiduFileListCacheItem: Codable {
        let files: [BaiduFileItem]
        let expiresAt: Date
    }
    private struct BaiduShareContext: Codable {
        let shareURL: String
        let surl: String
        let pwd: String?
        let shareid: String
        let shareUk: String
        let bdstoken: String?
        let randsk: String?
        let cookie: String
        let files: [BaiduFileItem]
        let source: String
        let expiresAt: Date
    }
    struct BaiduPlaybackCacheSummary {
        let playResultCount: Int
        let expiredPlayResultCount: Int
        let playItemCount: Int
        let iBoxPlayItemCount: Int
        let validIBoxDlinkCount: Int
        let expiredIBoxDlinkCount: Int
        let fileListCount: Int
        let expiredFileListCount: Int
        let storageBytes: Int
        let lastUpdatedAt: Date?

        var totalCount: Int {
            playResultCount + playItemCount + iBoxPlayItemCount + fileListCount
        }
    }
    struct CloudPlayItem: Codable {
        let provider: String
        let sourceKey: String
        let shareURL: String
        let resourceId: String
        let fileName: String
        let ownPath: String?
        let playURL: String?
        let headers: [String: String]
        let expiresAt: Date?
        let compatibilityHint: String
        let preferredEngine: String
        let preparedAt: Date
        let updatedAt: Date
        let source: String
    }
    struct CloudPlayItemSummary {
        let totalCount: Int
        let validPlayURLCount: Int
        let expiredPlayURLCount: Int
        let storageBytes: Int
        let lastUpdatedAt: Date?
    }
    struct BaiduRouteDiagnostic: Codable, Identifiable {
        let id: UUID
        let time: Date
        let stage: String
        let status: String
        let detail: String
        let fsId: String?
        let fileName: String?
    }

    private var baiduPlayCache: [String: BaiduPlayCacheItem] = [:]
    private let baiduPlayCacheLock = NSLock()

    // 夸克：vbox 目录缓存 & 单飞（避免并发/重复创建导致同名冲突）
    private let quarkVboxCacheLock = NSLock()
    private var quarkVboxFolderCache: [String: String] = [:] // accountKey -> folderId
    private var quarkEnsureFolderTasks: [String: Task<(folderId: String, cookie: String), Error>] = [:]

    @Published private(set) var savedTokens: [DriveToken] = []
    private var cleanupWorkerTask: Task<Void, Never>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        
        let ucConfig = URLSessionConfiguration.ephemeral
        ucConfig.timeoutIntervalForRequest = 30
        ucSession = URLSession(configuration: ucConfig)
        
        loadTokens()
        loadQuarkVboxFolderCache()
        startCleanupWorkerIfNeeded()
    }

    static var onLog: ((String) -> Void)?

    /// 统一网盘日志入口 — 所有网盘 (百度/阿里/夸克/UC/115/迅雷...) 都走这里
    /// 自动识别级别并转发到 AppLogStore (cloud 分类)
    /// 新增网盘时直接调用此函数即可，无需修改日志系统
    private func cloudLog(_ msg: String) {
        print(msg)
        
        // 自动识别级别
        let level: LogLevel
        if msg.contains("❌") || msg.contains("失败") {
            level = .error
        } else if msg.contains("⚠️") {
            level = .warn
        } else if msg.contains("⏱️") || msg.contains("✅") {
            level = .info
        } else {
            level = .verbose
        }
        AppLogStore.shared.log(level, .cloud, msg)
        
        if let handler = CloudDriveManager.onLog {
            handler(msg)
        }
    }

    private func baiduLog(_ msg: String) {
        cloudLog(msg)
    }

    private func recordBaiduRouteDiagnostic(stage: String, status: String, detail: String, fsId: String? = nil, fileName: String? = nil) {
        var items = recentBaiduRouteDiagnostics()
        items.insert(
            BaiduRouteDiagnostic(
                id: UUID(),
                time: Date(),
                stage: stage,
                status: status,
                detail: detail,
                fsId: fsId,
                fileName: fileName
            ),
            at: 0
        )
        if items.count > 60 {
            items = Array(items.prefix(60))
        }
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: baiduRouteDiagnosticsKey)
        }
    }

    func recentBaiduRouteDiagnostics() -> [BaiduRouteDiagnostic] {
        guard let data = defaults.data(forKey: baiduRouteDiagnosticsKey),
              let items = try? JSONDecoder().decode([BaiduRouteDiagnostic].self, from: data) else {
            return []
        }
        return items
    }

    func clearBaiduRouteDiagnostics() {
        defaults.removeObject(forKey: baiduRouteDiagnosticsKey)
        baiduLog("[Baidu-Diag] 已清空路链诊断记录")
    }

    private func baiduPlayCacheKey(shareURL: String, fsId: String, bduss: String, pcsCookie: String) -> String {
        "\(shareURL)|\(fsId)|\(baiduStableHash(bduss))|\(baiduStableHash(pcsCookie))"
    }

    private func baiduMainRouteCacheKey(shareURL: String, fsId: String, bduss: String, pcsCookie: String) -> String {
        "main-route-v2|\(baiduPlayCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie))"
    }

    private func baiduFileListCacheKey(shareURL: String, bduss: String) -> String {
        "\(shareURL)|\(baiduStableHash(bduss))"
    }

    private func baiduShareContextKey(shareURL: String, cookie: String) -> String {
        "\(shareURL)|\(baiduStableHash(cookie))"
    }

    private func baiduCachedPlayResult(for key: String) -> PlayResult? {
        baiduPlayCacheLock.lock()
        if let item = baiduPlayCache[key] {
            if item.expiresAt > Date() {
                baiduPlayCacheLock.unlock()
                return item.result
            }
            baiduPlayCache.removeValue(forKey: key)
        }

        if let persisted = baiduLoadPersistedPlayCache()[key], persisted.expiresAt > Date() {
            let result = PlayResult(url: persisted.url, headers: persisted.headers, driveType: .baidu)
            baiduPlayCache[key] = BaiduPlayCacheItem(result: result, expiresAt: persisted.expiresAt)
            baiduPlayCacheLock.unlock()
            return result
        }

        baiduPlayCacheLock.unlock()
        return nil
    }

    private func baiduCachedFileList(for key: String) -> [BaiduFileItem]? {
        var cache = baiduLoadPersistedFileListCache()
        guard let item = cache[key] else { return nil }
        if item.expiresAt > Date(), !item.files.isEmpty {
            return item.files
        }
        cache.removeValue(forKey: key)
        baiduSavePersistedFileListCache(cache)
        return nil
    }

    private func baiduStoreFileList(_ files: [BaiduFileItem], for key: String, ttl: TimeInterval = 8 * 60 * 60) {
        guard !files.isEmpty else { return }
        var cache = baiduLoadPersistedFileListCache()
        cache[key] = BaiduFileListCacheItem(files: files, expiresAt: Date().addingTimeInterval(ttl))
        if cache.count > 80 {
            let now = Date()
            cache = cache.filter { $0.value.expiresAt > now }
        }
        baiduSavePersistedFileListCache(cache)
    }

    private func baiduCachedShareContext(for key: String, currentPwd: String?) -> BaiduShareContext? {
        var cache = baiduLoadPersistedShareContextCache()
        guard let context = cache[key] else { return nil }
        // 缓存版本必须按当前分享链接校验，不能只看旧缓存里的 pwd。
        // 老版本缓存可能没有 randsk/bdstoken，但仍会被命中，导致直接跳过 iBox verify，
        // 最终 share/transfer 缺 sekey 或 api/create 缺 bdstoken，返回 errno=2/-6。
        let currentShareNeedsRandsk = !(currentPwd ?? "").isEmpty
        if context.expiresAt > Date(),
           !context.shareid.isEmpty,
           !context.shareUk.isEmpty,
           !context.files.isEmpty,
           !(context.bdstoken ?? "").isEmpty,
           (!currentShareNeedsRandsk || !(context.randsk ?? "").isEmpty) {
            return context
        }
        baiduLog("[Baidu-ShareContext] ⚠️ 丢弃不完整分享上下文缓存：bdstoken=\(!((context.bdstoken ?? "").isEmpty)), randsk=\(!((context.randsk ?? "").isEmpty)), currentPwd=\(currentShareNeedsRandsk)")
        cache.removeValue(forKey: key)
        baiduSavePersistedShareContextCache(cache)
        return nil
    }

    private func baiduStoreShareContext(
        shareURL: String,
        surl: String,
        pwd: String?,
        shareid: String,
        shareUk: String,
        bdstoken: String? = nil,
        randsk: String? = nil,
        cookie: String,
        files: [BaiduFileItem],
        source: String,
        key: String,
        ttl: TimeInterval = 8 * 60 * 60
    ) {
        guard !shareid.isEmpty, !shareUk.isEmpty, !files.isEmpty else { return }
        var cache = baiduLoadPersistedShareContextCache()
        cache[key] = BaiduShareContext(
            shareURL: shareURL,
            surl: surl,
            pwd: pwd,
            shareid: shareid,
            shareUk: shareUk,
            bdstoken: bdstoken,
            randsk: randsk,
            cookie: cookie,
            files: files,
            source: source,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        if cache.count > 60 {
            let now = Date()
            cache = cache.filter { $0.value.expiresAt > now }
        }
        baiduSavePersistedShareContextCache(cache)
    }

    private func baiduLoadPersistedShareContextCache() -> [String: BaiduShareContext] {
        guard let data = defaults.data(forKey: baiduShareContextCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduShareContext].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduSavePersistedShareContextCache(_ cache: [String: BaiduShareContext]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduShareContextCacheKey)
        }
    }

    private func baiduVerifyCooldownCache() -> [String: Date] {
        guard let data = defaults.data(forKey: baiduVerifyCooldownKey),
              let cache = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduIsVerifyCoolingDown(_ key: String) -> Bool {
        var cache = baiduVerifyCooldownCache()
        let now = Date()
        cache = cache.filter { $0.value > now }
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }
        return (cache[key] ?? .distantPast) > now
    }

    private func baiduMarkVerifyCooldown(_ key: String, seconds: TimeInterval = 10 * 60) {
        var cache = baiduVerifyCooldownCache()
        cache[key] = Date().addingTimeInterval(seconds)
        if cache.count > 60 {
            let now = Date()
            cache = cache.filter { $0.value > now }
        }
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }
    }

    private func baiduLoadPersistedFileListCache() -> [String: BaiduFileListCacheItem] {
        guard let data = defaults.data(forKey: baiduFileListCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduFileListCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduSavePersistedFileListCache(_ cache: [String: BaiduFileListCacheItem]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: baiduFileListCacheKey)
        }
    }

    private func baiduStorePlayResult(_ result: PlayResult, for key: String, ttl: TimeInterval = 6 * 60 * 60) {
        let expiresAt = Date().addingTimeInterval(ttl)
        baiduPlayCacheLock.lock()
        baiduPlayCache[key] = BaiduPlayCacheItem(result: result, expiresAt: expiresAt)
        if baiduPlayCache.count > 80 {
            let now = Date()
            baiduPlayCache = baiduPlayCache.filter { $0.value.expiresAt > now }
        }
        baiduPlayCacheLock.unlock()

        var persisted = baiduLoadPersistedPlayCache()
        persisted[key] = BaiduPersistedPlayCacheItem(url: result.url, headers: result.headers, expiresAt: expiresAt)
        let now = Date()
        persisted = persisted.filter { $0.value.expiresAt > now }
        if persisted.count > 80 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.expiresAt > $1.value.expiresAt }.prefix(80).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }
    }

    func invalidateBaiduPlaybackCache(shareURL: String, fsId: String, bduss: String, pcsCookie: String = "", reason: String = "手动刷新") {
        let cacheKey = baiduPlayCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        let mainRouteKey = baiduMainRouteCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        baiduPlayCacheLock.lock()
        baiduPlayCache.removeValue(forKey: cacheKey)
        baiduPlayCache.removeValue(forKey: mainRouteKey)
        baiduPlayCacheLock.unlock()

        var playCache = baiduLoadPersistedPlayCache()
        playCache.removeValue(forKey: cacheKey)
        playCache.removeValue(forKey: mainRouteKey)
        if let data = try? JSONEncoder().encode(playCache) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }

        var iboxCache = baiduLoadPersistedIBoxPlayItemCache()
        for key in [cacheKey, mainRouteKey] {
            guard let item = iboxCache[key] else {
                invalidateUnifiedCloudPlayItem(provider: .baidu, sourceKey: key, reason: "invalidated")
                continue
            }
            let invalidatedItem = BaiduIBoxPlayItem(
                shareURL: item.shareURL,
                fsId: item.fsId,
                fileName: item.fileName,
                path: item.path,
                dlinkURL: nil,
                headers: item.headers,
                dlinkExpiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: Date(),
                lastUsedAt: item.lastUsedAt,
                source: "\(item.source)-invalidated"
            )
            iboxCache[key] = invalidatedItem
            mirrorBaiduIBoxPlayItemToUnified(invalidatedItem, sourceKey: key)
        }
        if let data = try? JSONEncoder().encode(iboxCache) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }

        baiduLog("[Baidu-Cache] 已清理播放缓存并保留 path：fsId=\(fsId), reason=\(reason)")
        recordBaiduRouteDiagnostic(stage: "播放缓存", status: "失效清理", detail: "已清理旧 dlink/播放缓存，保留 path，原因：\(reason)", fsId: fsId)
    }

    private func baiduCachedPlayItem(for key: String) -> BaiduPlayItem? {
        baiduLoadPersistedPlayItemCache()[key]
    }

    private func baiduStorePlayItem(_ item: BaiduPlayItem, for key: String) {
        var persisted = baiduLoadPersistedPlayItemCache()
        persisted[key] = item
        if persisted.count > 120 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(120).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduPersistedPlayItemCacheKey)
        }
    }

    private func baiduCachedIBoxPlayItem(for key: String) -> BaiduIBoxPlayItem? {
        baiduLoadPersistedIBoxPlayItemCache()[key]
    }

    private func baiduStoreIBoxPlayItem(_ item: BaiduIBoxPlayItem, for key: String) {
        var persisted = baiduLoadPersistedIBoxPlayItemCache()
        persisted[key] = item
        if persisted.count > 160 {
            persisted = Dictionary(uniqueKeysWithValues: persisted.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(160).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(persisted) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }
        mirrorBaiduIBoxPlayItemToUnified(item, sourceKey: key)
    }

    private func baiduLoadPersistedPlayCache() -> [String: BaiduPersistedPlayCacheItem] {
        guard let data = defaults.data(forKey: baiduPersistedPlayCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduPersistedPlayCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduLoadPersistedPlayItemCache() -> [String: BaiduPlayItem] {
        guard let data = defaults.data(forKey: baiduPersistedPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func baiduLoadPersistedIBoxPlayItemCache() -> [String: BaiduIBoxPlayItem] {
        guard let data = defaults.data(forKey: baiduIBoxPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: BaiduIBoxPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func cloudPlayItemCacheKey(provider: DriveType, sourceKey: String) -> String {
        "\(provider.rawValue)|\(sourceKey)"
    }

    private func loadUnifiedCloudPlayItemCache() -> [String: CloudPlayItem] {
        guard let data = defaults.data(forKey: unifiedCloudPlayItemCacheKey),
              let cache = try? JSONDecoder().decode([String: CloudPlayItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func saveUnifiedCloudPlayItemCache(_ cache: [String: CloudPlayItem]) {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: unifiedCloudPlayItemCacheKey)
        }
    }

    private func storeUnifiedCloudPlayItem(_ item: CloudPlayItem, provider: DriveType, sourceKey: String) {
        var cache = loadUnifiedCloudPlayItemCache()
        cache[cloudPlayItemCacheKey(provider: provider, sourceKey: sourceKey)] = item
        if cache.count > 260 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(260).map { ($0.key, $0.value) })
        }
        saveUnifiedCloudPlayItemCache(cache)
    }

    private func mirrorBaiduIBoxPlayItemToUnified(_ item: BaiduIBoxPlayItem, sourceKey: String) {
        storeUnifiedCloudPlayItem(
            CloudPlayItem(
                provider: DriveType.baidu.rawValue,
                sourceKey: sourceKey,
                shareURL: item.shareURL,
                resourceId: item.fsId,
                fileName: item.fileName,
                ownPath: item.path,
                playURL: item.dlinkURL,
                headers: item.headers,
                expiresAt: item.dlinkExpiresAt,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: item.updatedAt,
                source: item.source
            ),
            provider: .baidu,
            sourceKey: sourceKey
        )
    }

    private func invalidateUnifiedCloudPlayItem(provider: DriveType, sourceKey: String, reason: String) {
        var cache = loadUnifiedCloudPlayItemCache()
        let key = cloudPlayItemCacheKey(provider: provider, sourceKey: sourceKey)
        guard let item = cache[key] else { return }
        cache[key] = CloudPlayItem(
            provider: item.provider,
            sourceKey: item.sourceKey,
            shareURL: item.shareURL,
            resourceId: item.resourceId,
            fileName: item.fileName,
            ownPath: item.ownPath,
            playURL: nil,
            headers: item.headers,
            expiresAt: nil,
            compatibilityHint: item.compatibilityHint,
            preferredEngine: item.preferredEngine,
            preparedAt: item.preparedAt,
            updatedAt: Date(),
            source: "\(item.source)-\(reason)"
        )
        saveUnifiedCloudPlayItemCache(cache)
    }

    private func clearExpiredUnifiedCloudPlayItems(provider: DriveType) {
        let now = Date()
        var cache = loadUnifiedCloudPlayItemCache()
        var changed = false
        for (key, item) in cache where item.provider == provider.rawValue {
            guard let expiresAt = item.expiresAt, expiresAt <= now, item.playURL?.isEmpty == false else { continue }
            cache[key] = CloudPlayItem(
                provider: item.provider,
                sourceKey: item.sourceKey,
                shareURL: item.shareURL,
                resourceId: item.resourceId,
                fileName: item.fileName,
                ownPath: item.ownPath,
                playURL: nil,
                headers: item.headers,
                expiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: now,
                source: "\(item.source)-expired-cleaned"
            )
            changed = true
        }
        if changed {
            saveUnifiedCloudPlayItemCache(cache)
        }
    }

    private func clearUnifiedCloudPlayItems(provider: DriveType) {
        var cache = loadUnifiedCloudPlayItemCache()
        cache = cache.filter { $0.value.provider != provider.rawValue }
        saveUnifiedCloudPlayItemCache(cache)
    }

    func cloudPlayItemSummary(for provider: DriveType) -> CloudPlayItemSummary {
        let now = Date()
        let cache = loadUnifiedCloudPlayItemCache().values.filter { $0.provider == provider.rawValue }
        let valid = cache.filter { ($0.expiresAt ?? .distantPast) > now && ($0.playURL?.isEmpty == false) }.count
        let expired = cache.filter { item in
            guard let expiresAt = item.expiresAt, item.playURL?.isEmpty == false else { return false }
            return expiresAt <= now
        }.count
        let storageBytes = defaults.data(forKey: unifiedCloudPlayItemCacheKey)?.count ?? 0
        return CloudPlayItemSummary(
            totalCount: cache.count,
            validPlayURLCount: valid,
            expiredPlayURLCount: expired,
            storageBytes: storageBytes,
            lastUpdatedAt: cache.map(\.updatedAt).max()
        )
    }

    func baiduPlaybackCacheSummary() -> BaiduPlaybackCacheSummary {
        let now = Date()
        let playCache = baiduLoadPersistedPlayCache()
        let playItems = baiduLoadPersistedPlayItemCache()
        let iBoxItems = baiduLoadPersistedIBoxPlayItemCache()
        let fileLists = baiduLoadPersistedFileListCache()

        let expiredPlay = playCache.values.filter { $0.expiresAt <= now }.count
        let expiredFileLists = fileLists.values.filter { $0.expiresAt <= now }.count
        let validIBoxDlinks = iBoxItems.values.filter { ($0.dlinkExpiresAt ?? .distantPast) > now && ($0.dlinkURL?.isEmpty == false) }.count
        let expiredIBoxDlinks = iBoxItems.values.filter { item in
            guard let expiresAt = item.dlinkExpiresAt, item.dlinkURL?.isEmpty == false else { return false }
            return expiresAt <= now
        }.count
        let dates = playCache.values.map(\.expiresAt)
            + playItems.values.map(\.updatedAt)
            + iBoxItems.values.map(\.updatedAt)
            + fileLists.values.map(\.expiresAt)
        let storageBytes = [
            baiduPersistedPlayCacheKey,
            baiduPersistedPlayItemCacheKey,
            baiduIBoxPlayItemCacheKey,
            baiduFileListCacheKey,
            baiduShareContextCacheKey,
            baiduVerifyCooldownKey
        ].reduce(0) { total, key in
            total + (defaults.data(forKey: key)?.count ?? 0)
        }

        return BaiduPlaybackCacheSummary(
            playResultCount: playCache.count,
            expiredPlayResultCount: expiredPlay,
            playItemCount: playItems.count,
            iBoxPlayItemCount: iBoxItems.count,
            validIBoxDlinkCount: validIBoxDlinks,
            expiredIBoxDlinkCount: expiredIBoxDlinks,
            fileListCount: fileLists.count,
            expiredFileListCount: expiredFileLists,
            storageBytes: storageBytes,
            lastUpdatedAt: dates.max()
        )
    }

    @discardableResult
    func clearExpiredBaiduPlaybackCaches() -> BaiduPlaybackCacheSummary {
        let now = Date()

        baiduPlayCacheLock.lock()
        baiduPlayCache = baiduPlayCache.filter { $0.value.expiresAt > now }
        baiduPlayCacheLock.unlock()

        var playCache = baiduLoadPersistedPlayCache().filter { $0.value.expiresAt > now }
        if let data = try? JSONEncoder().encode(playCache) {
            defaults.set(data, forKey: baiduPersistedPlayCacheKey)
        }

        var fileLists = baiduLoadPersistedFileListCache().filter { $0.value.expiresAt > now }
        baiduSavePersistedFileListCache(fileLists)

        let shareContexts = baiduLoadPersistedShareContextCache().filter { $0.value.expiresAt > now }
        baiduSavePersistedShareContextCache(shareContexts)

        let verifyCooldowns = baiduVerifyCooldownCache().filter { $0.value > now }
        if let data = try? JSONEncoder().encode(verifyCooldowns) {
            defaults.set(data, forKey: baiduVerifyCooldownKey)
        }

        var iBoxItems = baiduLoadPersistedIBoxPlayItemCache()
        for (key, item) in iBoxItems {
            guard let expiresAt = item.dlinkExpiresAt, expiresAt <= now else { continue }
            let cleanedItem = BaiduIBoxPlayItem(
                shareURL: item.shareURL,
                fsId: item.fsId,
                fileName: item.fileName,
                path: item.path,
                dlinkURL: nil,
                headers: item.headers,
                dlinkExpiresAt: nil,
                compatibilityHint: item.compatibilityHint,
                preferredEngine: item.preferredEngine,
                preparedAt: item.preparedAt,
                updatedAt: now,
                lastUsedAt: item.lastUsedAt,
                source: "\(item.source)-expired-cleaned"
            )
            iBoxItems[key] = cleanedItem
            mirrorBaiduIBoxPlayItemToUnified(cleanedItem, sourceKey: key)
        }
        if let data = try? JSONEncoder().encode(iBoxItems) {
            defaults.set(data, forKey: baiduIBoxPlayItemCacheKey)
        }
        clearExpiredUnifiedCloudPlayItems(provider: .baidu)

        playCache.removeAll(keepingCapacity: false)
        fileLists.removeAll(keepingCapacity: false)
        baiduLog("[Baidu-Cache] 已清理过期播放缓存，保留可复用 PlayItem/path")
        return baiduPlaybackCacheSummary()
    }

    @discardableResult
    func clearAllBaiduPlaybackCaches() -> BaiduPlaybackCacheSummary {
        baiduPlayCacheLock.lock()
        baiduPlayCache.removeAll()
        baiduPlayCacheLock.unlock()

        defaults.removeObject(forKey: baiduPersistedPlayCacheKey)
        defaults.removeObject(forKey: baiduPersistedPlayItemCacheKey)
        defaults.removeObject(forKey: baiduIBoxPlayItemCacheKey)
        defaults.removeObject(forKey: baiduFileListCacheKey)
        defaults.removeObject(forKey: baiduShareContextCacheKey)
        defaults.removeObject(forKey: baiduVerifyCooldownKey)
        clearUnifiedCloudPlayItems(provider: .baidu)

        baiduLog("[Baidu-Cache] 已清空全部百度播放缓存")
        return baiduPlaybackCacheSummary()
    }

    private func baiduCompatibilityHint(fileName: String) -> String {
        let lower = fileName.lowercased()
        let risky = ["mkv", "hevc", "h265", "x265", "10bit", "hdr", "高码率", "4k"]
        return risky.first(where: { lower.contains($0) }) ?? ""
    }

    private func baiduPreferredEngine(fileName: String) -> String {
        baiduCompatibilityHint(fileName: fileName).isEmpty ? "system" : "compatibility"
    }

    private func baiduIsPlayableVideoFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let videoExts = [
            "mp4", "mkv", "mov", "m4v", "avi", "wmv", "flv", "ts", "m2ts", "mts",
            "webm", "mpg", "mpeg", "3gp", "rm", "rmvb", "asf", "f4v", "m3u8"
        ]
        return videoExts.contains { lower.hasSuffix(".\($0)") }
    }

    private func baiduStableHash(_ input: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func loadTokens() {
        do {
            if let tokens = try SecureCredentialStore.loadTokens() {
                savedTokens = tokens
                return
            }
        } catch {
            print("[CloudDriveManager] Keychain 读取 tokens 失败: \(error)")
        }

        // 从旧版 UserDefaults 迁移一次
        if let data = defaults.data(forKey: tokenKey),
           let tokens = try? JSONDecoder().decode([DriveToken].self, from: data) {
            savedTokens = tokens
            do {
                try SecureCredentialStore.save(tokens: tokens)
                print("[CloudDriveManager] 已从 UserDefaults 迁移 tokens 到 Keychain")
            } catch {
                print("[CloudDriveManager] 迁移 tokens 到 Keychain 失败: \(error)")
            }
            defaults.removeObject(forKey: tokenKey)
        }
    }

    private func saveTokens() {
        do {
            try SecureCredentialStore.save(tokens: savedTokens)
        } catch {
            print("[CloudDriveManager] Keychain 保存 tokens 失败: \(error)")
        }
    }

    private func loadQuarkVboxFolderCache() {
        quarkVboxCacheLock.lock()
        defer { quarkVboxCacheLock.unlock() }
        guard let data = defaults.data(forKey: quarkVboxFolderCacheKey),
              let cache = try? JSONDecoder().decode([String: String].self, from: data) else {
            quarkVboxFolderCache = [:]
            return
        }
        quarkVboxFolderCache = cache
    }

    private func saveQuarkVboxFolderCache() {
        quarkVboxCacheLock.lock()
        let cache = quarkVboxFolderCache
        quarkVboxCacheLock.unlock()
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: quarkVboxFolderCacheKey)
        }
    }

    private func setQuarkVboxFolderCache(accountKey: String, folderId: String) {
        guard !accountKey.isEmpty, !folderId.isEmpty else { return }
        quarkVboxCacheLock.lock()
        quarkVboxFolderCache[accountKey] = folderId
        quarkVboxCacheLock.unlock()
        saveQuarkVboxFolderCache()
    }

    private func clearQuarkVboxFolderCache(accountKey: String) {
        guard !accountKey.isEmpty else { return }
        quarkVboxCacheLock.lock()
        quarkVboxFolderCache.removeValue(forKey: accountKey)
        quarkEnsureFolderTasks.removeValue(forKey: accountKey)
        quarkVboxCacheLock.unlock()
        saveQuarkVboxFolderCache()
    }

    // MARK: - 夸克转存后 fileId 缓存

    private func quarkSavedFidCacheKey(pwdId: String, sourceFid: String, folderId: String, cookie: String) -> String {
        let cookieHash = String(cookie.hash)
        return "\(pwdId)|\(sourceFid)|\(folderId)|\(cookieHash)"
    }

    private func loadQuarkSavedFidCache() -> [String: QuarkSavedFidCacheItem] {
        guard let data = defaults.data(forKey: quarkSavedFidCacheKey),
              let cache = try? JSONDecoder().decode([String: QuarkSavedFidCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func saveQuarkSavedFidCache(_ cache: [String: QuarkSavedFidCacheItem]) {
        var cleaned = cache
        let now = Date()
        cleaned = cleaned.filter { $0.value.expiresAt > now }
        if cleaned.count > 300 {
            cleaned = Dictionary(uniqueKeysWithValues: cleaned.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(300).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: quarkSavedFidCacheKey)
        }
    }

    private func quarkCachedSavedTopFids(pwdId: String, sourceFid: String, folderId: String, cookie: String) -> [String]? {
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        guard let item = cache[key], item.expiresAt > Date() else {
            if cache[key] != nil {
                cache.removeValue(forKey: key)
                saveQuarkSavedFidCache(cache)
            }
            return nil
        }
        self.log("[Quark] ✅ 命中转存 fid 缓存: \(item.topLevelFids)，跳过本次转存")
        return item.topLevelFids
    }

    private func quarkStoreSavedItem(topLevelFids: [String], playbackFileId: String?, fileName: String, folderId: String, cookie: String, pwdId: String, sourceFid: String, ttl: TimeInterval = 5 * 60) {
        guard !topLevelFids.isEmpty, !topLevelFids.allSatisfy({ $0 == "0" }) else { return }
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        cache[key] = QuarkSavedFidCacheItem(
            topLevelFids: topLevelFids,
            playbackFileId: playbackFileId,
            fileName: fileName,
            folderId: folderId,
            cookieHash: String(cookie.hash),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 💾 已缓存转存对象: topLevelFids=\(topLevelFids), playbackFileId=\(playbackFileId ?? "nil")，有效期 \(Int(ttl/60)) 分钟")
    }

    private func quarkInvalidateSavedFidCache(pwdId: String, sourceFid: String, folderId: String, cookie: String) {
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        guard cache[key] != nil else { return }
        cache.removeValue(forKey: key)
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 🗑️ 已清除失效的转存 fid 缓存")
    }

    /// 清理缓存中除当前 key 外的所有历史转存对象，保留当前正在播放的转存文件/文件夹
    private func quarkCleanupPreviousSavedItems(excludingKey currentKey: String, cookie: String) async -> String {
        var currentCookie = cookie
        var cache = loadQuarkSavedFidCache()
        var keysToRemove: [String] = []
        var fidsToDelete: [String] = []
        for (key, item) in cache {
            guard key != currentKey else { continue }
            keysToRemove.append(key)
            fidsToDelete.append(contentsOf: item.topLevelFids)
        }
        guard !fidsToDelete.isEmpty else { return currentCookie }

        let uniqueFids = Array(Set(fidsToDelete)).filter { !$0.isEmpty && $0 != "0" }
        guard !uniqueFids.isEmpty else { return currentCookie }

        self.log("[Quark] 🧹 新转存完成，清理 \(uniqueFids.count) 个历史转存对象：\(uniqueFids)")
        currentCookie = await quarkDeleteFiles(fileIds: uniqueFids, cookie: currentCookie)

        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 🧹 已清理 \(keysToRemove.count) 条历史转存缓存")
        return currentCookie
    }

    func addToken(type: DriveType, name: String, value: String) {
        savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
        Task { @MainActor in
            CloudDriveAuthManager.shared.saveManualCredential(type: type, name: name, value: value)
        }
    }

    func addOrReplaceToken(type: DriveType, name: String, value: String) {
        if type == .baidu {
            // 百度仍保持 Web Cookie + PCS Cookie 的双 Token 设计。
            // 授权中心扫码/WebView 回写的是 BDUSS+STOKEN Web Cookie，不能误删/覆盖原有账号 Cookie 或可选 PCS Cookie。
            guard isBaiduAccountWebCookie(value) else {
                return
            }
            if savedTokens.contains(where: { $0.type == type.rawValue && $0.value == value }) {
                return
            }
            savedTokens.removeAll { $0.type == type.rawValue && $0.name == name }
        } else {
            // 幂等保护：值未变化直接返回，避免镜像同步等重复写入时
            // 无意义地触发 @Published savedTokens 同步重绘（栈溢出防护之一）
            if savedTokens.contains(where: { $0.type == type.rawValue && $0.value == value && $0.name == name }) {
                return
            }
            savedTokens.removeAll { $0.type == type.rawValue }
        }
        savedTokens.append(DriveToken(type: type.rawValue, name: name, value: value))
        saveTokens()
    }

    @discardableResult
    func addOrReplaceBaiduPCSToken(name: String, value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "\n", with: "; ")
            .replacingOccurrences(of: "\r", with: "; ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isBaiduPCSCookie(normalized) else {
            baiduLog("[Baidu-Token] ⚠️ PCS Cookie 未包含 PANPSC/ptoken_bfess/ndut_fmt/nd_ftid，跳过保存")
            return false
        }

        savedTokens.removeAll { token in
            guard token.type == DriveType.baidu.rawValue else { return false }
            if token.name == name || token.value == normalized { return true }
            return isBaiduPCSToken(token) && token.name.hasPrefix("百度PCS-扫码")
        }
        savedTokens.append(DriveToken(type: DriveType.baidu.rawValue, name: name, value: normalized))
        saveTokens()
        baiduLog("[Baidu-Token] ✅ 已保存百度 PCS 高速 Cookie：\(name)")
        return true
    }

    func removeToken(at index: Int) {
        guard index >= 0, index < savedTokens.count else { return }
        let removed = savedTokens[index]
        savedTokens.remove(at: index)
        saveTokens()

        // Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛）：
        // 删除展示镜像 = 退出该网盘 Node 登录态（级联清除 Keychain + Node bundle 凭据）
        if let driveType = DriveType(rawValue: removed.type),
           NodeCredentialSyncService.shared.isNodeManaged(driveType) {
            // 清理该网盘残留的 -Node 镜像条目（登录态已清，避免列表仍显示）
            savedTokens.removeAll { $0.type == removed.type && $0.name.hasSuffix("-Node") }
            saveTokens()
            self.log("[CloudDrive] 🗑 \(driveType.displayName) 展示镜像已删除，级联清除 Node 登录态")
            Task { await NodeCredentialSyncService.shared.deleteNodeCredential(driveType: driveType) }
        }
    }

    private func ensureVboxFolder(drive: DriveType, token: String) async throws -> String {
        switch drive {
        case .quark:
            return try await quarkEnsureFolder(cookie: token)
        case .baidu:
            return try await baiduEnsureFolder(bduss: token)
        case .uc:
            return try await ucEnsureFolder(cookie: token)
        default:
            return ""
        }
    }

    private func scheduleCleanup(drive: DriveType, fileIds: [String], token: String, delay: TimeInterval = 180) {
        guard !fileIds.isEmpty else { return }
        let tokenName = resolveTokenName(drive: drive, tokenValue: token)
        enqueueCleanup(drive: drive, tokenName: tokenName, fileIds: fileIds, delay: delay)
        startCleanupWorkerIfNeeded()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.flushCleanupQueue()
        }
    }

    private func cleanupFiles(drive: DriveType, fileIds: [String], token: String) async {
        self.log("[CloudDrive] 清理 \(drive.rawValue) 转存文件: \(fileIds.count) 个")
        switch drive {
        case .quark: await quarkDeleteFiles(fileIds: fileIds, cookie: token)
        case .baidu: await baiduDeleteFiles(fileIds: fileIds, bduss: token)
        case .uc: await ucDeleteFiles(fileIds: fileIds, cookie: token)
        default: break
        }
    }

    private func resolveTokenName(drive: DriveType, tokenValue: String) -> String {
        // 先尝试完全匹配（常规手动 Token 路径）
        if let exact = savedTokens.first(where: { $0.type == drive.rawValue && $0.value == tokenValue }) {
            return exact.name
        }
        // 对于百度，pureAccountCookie 是合并/过滤后的合成值，与 savedTokens 中的原始 Cookie
        // 不完全相等，但 BDUSS 相同。通过 BDUSS 值匹配来找到对应的 Token。
        if drive == .baidu, let bduss = baiduCookieValue(tokenValue, named: "BDUSS") {
            return savedTokens.first(where: { token in
                guard token.type == drive.rawValue else { return false }
                return baiduCookieValue(token.value, named: "BDUSS") == bduss
            })?.name ?? ""
        }
        return ""
    }

    private func tokenValue(for drive: DriveType, tokenName: String) -> String? {
        if !tokenName.isEmpty,
           let found = tokens(for: drive).first(where: { $0.name == tokenName }) {
            return found.value
        }
        // 兜底：百度优先返回 Account Web Token（含 BDUSS+STOKEN），
        // 避免返回 PCS Token（仅用于下载直链，无法调用 filemanager 删除 API）
        let candidates = tokens(for: drive)
        if drive == .baidu {
            if let account = candidates.first(where: { isBaiduAccountWebToken($0) }) {
                return account.value
            }
        }
        return candidates.first?.value
    }

    private func loadCleanupQueue() -> [CleanupQueueItem] {
        guard let data = defaults.data(forKey: cleanupQueueKey),
              let items = try? JSONDecoder().decode([CleanupQueueItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveCleanupQueue(_ items: [CleanupQueueItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: cleanupQueueKey)
    }

    private func enqueueCleanup(drive: DriveType, tokenName: String, fileIds: [String], delay: TimeInterval) {
        let now = Date()
        let eligibleAt = now.addingTimeInterval(delay)
        var queue = loadCleanupQueue()
        var existing = Set(queue.map { ($0.drive, $0.tokenName, $0.fileId) }.map { "\($0.0)|\($0.1)|\($0.2)" })

        for fid in fileIds where !fid.isEmpty {
            let key = "\(drive.rawValue)|\(tokenName)|\(fid)"
            if existing.contains(key) { continue }
            existing.insert(key)
            queue.append(
                CleanupQueueItem(
                    drive: drive.rawValue,
                    tokenName: tokenName,
                    fileId: fid,
                    eligibleAt: eligibleAt,
                    createdAt: now
                )
            )
        }

        // 防止队列无限增长：保留最新 300 条
        if queue.count > 300 {
            queue.sort { $0.createdAt > $1.createdAt }
            queue = Array(queue.prefix(300))
        }
        saveCleanupQueue(queue)
    }

    private func startCleanupWorkerIfNeeded() {
        guard cleanupWorkerTask == nil else { return }
        cleanupWorkerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flushCleanupQueue()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func flushCleanupQueue() async {
        var queue = loadCleanupQueue()
        guard !queue.isEmpty else { return }
        let now = Date()

        let due = queue.filter { $0.eligibleAt <= now }
        guard !due.isEmpty else { return }

        // 按 drive + tokenName 分组批量删除，减少 API 调用
        var groups: [String: [String]] = [:]
        for item in due {
            let k = "\(item.drive)|\(item.tokenName)"
            groups[k, default: []].append(item.fileId)
        }

        for (key, fids) in groups {
            let parts = key.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let driveRaw = parts[0]
            let tokenName = parts[1]
            guard let drive = DriveType(rawValue: driveRaw) else { continue }
            guard let tokenValue = tokenValue(for: drive, tokenName: tokenName), !tokenValue.isEmpty else {
                continue
            }
            // 去重并控制每批最大数量
            let unique = Array(Set(fids)).filter { !$0.isEmpty }
            if unique.isEmpty { continue }
            let batches = stride(from: 0, to: unique.count, by: 100).map { Array(unique[$0..<min($0 + 100, unique.count)]) }
            for batch in batches {
                await cleanupFiles(drive: drive, fileIds: batch, token: tokenValue)
            }
        }

        // 删除已到期的任务（默认认为提交删除即可；失败会在下次播放/触发兜底清理时再覆盖）
        let dueSet = Set(due)
        queue.removeAll { dueSet.contains($0) }
        saveCleanupQueue(queue)
    }

    func tokens(for type: DriveType) -> [DriveToken] {
        var tokens = savedTokens.filter { $0.type == type.rawValue }
        if type == .baidu {
            tokens = tokens.filter { token in
                isBaiduPCSToken(token) || isBaiduAccountWebToken(token)
            }
        }
        if let value = CloudDriveAuthManager.shared.bestTokenValue(for: type), !value.isEmpty {
            let credential = CloudDriveAuthManager.shared.credential(for: type)
            let name = credential?.userName?.isEmpty == false ? credential!.userName! : "授权中心"
            if !tokens.contains(where: { $0.value == value }) {
                let authToken = DriveToken(type: type.rawValue, name: name, value: value)
                if type == .baidu {
                    // 百度 Worker 链路优先保持旧手动 Token 顺序，授权中心账号只作为兜底，避免改变原本可用 Worker Cookie。
                    tokens.append(authToken)
                } else {
                    tokens.insert(authToken, at: 0)
                }
            }
        }
        return tokens
    }

    func cleanupInvalidBaiduTokens() {
        let before = savedTokens.count
        // 治理隐患 1：先按形式合法过滤；同时把「与授权中心 credential.cookie 不一致的旧账号 cookie」也清掉。
        // 这样能避免历史扫码留下的、形式合法但已过期的 BDUSS+STOKEN 仍被 baiduTokenPair 当作候选。
        let authoritativeCookie = CloudDriveAuthManager.shared.credential(for: .baidu)?.cookie
        savedTokens.removeAll { token in
            guard token.type == DriveType.baidu.rawValue else { return false }
            if !isBaiduPCSToken(token) && !isBaiduAccountWebToken(token) {
                return true
            }
            // 仅对「账号 cookie」做唯一性约束；PCS cookie 不参与 BDUSS/STOKEN 比对。
            if isBaiduAccountWebToken(token),
               let authoritativeCookie,
               isBaiduAccountWebCookie(authoritativeCookie),
               token.value != authoritativeCookie {
                return true
            }
            return false
        }
        if savedTokens.count != before {
            saveTokens()
        }
    }

    private func isBaiduPCSToken(_ token: DriveToken) -> Bool {
        let name = token.name.lowercased()
        if name.contains("pcs") || name.contains("下载") || name.contains("直链") || name.contains("locatedownload") {
            return true
        }
        return isBaiduPCSCookie(token.value)
    }

    private func isBaiduPCSCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("panpsc=") || lower.contains("ptoken=") || lower.contains("ptoken_bfess=") || lower.contains("ndut_fmt=") || lower.contains("nd_ftid=")
    }

    private func isBaiduAccountWebCookie(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("bduss=") && lower.contains("stoken=")
    }

    private func isBaiduAccountWebToken(_ token: DriveToken) -> Bool {
        isBaiduAccountWebCookie(token.value)
    }

    func baiduTokenPair() -> (web: DriveToken, pcs: DriveToken?)? {
        let list = tokens(for: .baidu)
        guard !list.isEmpty else { return nil }

        let preferredWeb: DriveToken?
        if let credential = CloudDriveAuthManager.shared.credential(for: .baidu),
           let cookie = credential.cookie,
           isBaiduAccountWebCookie(cookie) {
            // 百度主路链必须优先使用授权中心最新扫码 Cookie。
            // 旧 legacy Cookie 可能已过期，若排在前面会导致 api/gettemplatevariable/api/create 返回 errno=-6/-9。
            let name = credential.userName?.isEmpty == false ? credential.userName! : "授权中心"
            preferredWeb = DriveToken(type: DriveType.baidu.rawValue, name: name, value: cookie)
        } else {
            preferredWeb = nil
        }

        guard let web = preferredWeb ?? list.first(where: { isBaiduAccountWebToken($0) }) else {
            baiduLog("[Baidu-Token] ❌ 缺少百度 Web Cookie：需要同时包含 BDUSS 和 STOKEN，不能用 PCS Cookie 替代")
            return nil
        }
        // 治理隐患 2：PCS Cookie 仅采用授权中心 credential.extra 中保存的最新值，
        // 不再回退到 legacy savedTokens，避免历史粘贴/旧扫码留下的过期 PCS 被带入 share/transfer。
        let pcs: DriveToken?
        if let credential = CloudDriveAuthManager.shared.credential(for: .baidu),
           let pcsValue = credential.extra["pcs_cookie"], !pcsValue.isEmpty,
           isBaiduPCSCookie(pcsValue) {
            let pcsName = "授权中心-PCS"
            pcs = DriveToken(type: DriveType.baidu.rawValue, name: pcsName, value: pcsValue)
        } else {
            pcs = nil
        }
        return (web, pcs)
    }

    static func detectDrive(from url: String) -> DriveType? {
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return .ali }
        if url.contains("pan.quark.cn") { return .quark }
        if url.contains("pan.baidu.com") { return .baidu }
        if url.contains("115.com") || url.contains("115cdn.com") { return .one15 }
        if url.contains("uc.cn") || url.contains("ucloud.cn") { return .uc }
        if url.contains("123pan.com") || url.contains("123cloud.cn") { return .pan123 }
        if url.contains("yun.139.com") || url.contains("139.com") { return .pan139 }
        if url.contains("cloud.189.cn") || url.contains("189.cn") { return .pan189 }
        if url.contains("pan.xunlei.com") { return .xunlei }
        if url.contains("guangyapan.com") { return .guangya }
        if url.contains("woniu4k.com") || url.contains("wn4k.com") { return .woniu4k }
        return nil
    }

    // MARK: - 阿里云盘原生扫码登录
    // 官方 API: passport.aliyundrive.com
    //  1. generate.do → 拿 ck, t, codeContent (二维码 URL)
    //  2. query.do → 轮询扫码状态 (NEW → SCANED → CONFIRMED)
    //  3. 解码 bizExt → 获取 refresh_token + access_token

    struct AliQrLoginToken {
        let ck: String
        let t: Int64
        let qrURL: String
    }

    enum AliQrPollResult {
        case pending
        case scanned
        case confirmed(refreshToken: String, accessToken: String, nickName: String)
        case expired
        case failed(message: String)
    }

    /// 第一步：生成阿里云盘扫码登录二维码
    func aliCreateQrToken() async throws -> AliQrLoginToken {
        var components = URLComponents(string: "https://passport.aliyundrive.com/newlogin/qrcode/generate.do")!
        components.queryItems = [
            URLQueryItem(name: "appName", value: "aliyun_drive"),
            URLQueryItem(name: "fromSite", value: "52"),
            URLQueryItem(name: "appEntrance", value: "web"),
            URLQueryItem(name: "isMobile", value: "false"),
            URLQueryItem(name: "lang", value: "zh_CN"),
            URLQueryItem(name: "returnUrl", value: ""),
            URLQueryItem(name: "bizParams", value: ""),
            URLQueryItem(name: "_bx-v", value: "2.2.3")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.aliyundrive.com/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.noPlayURL("阿里: 生成二维码 HTTP 失败")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("阿里: 二维码生成响应 JSON 解析失败")
        }
        print("[Ali] generate response: \(json)")
        guard let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any] else {
            throw DriveError.noPlayURL("阿里: 二维码生成响应解析失败")
        }
        guard let ck = dataObj["ck"] as? String,
              let t = dataObj["t"] as? Int64,
              let codeContent = dataObj["codeContent"] as? String else {
            throw DriveError.noPlayURL("阿里: 二维码字段解析失败，keys: \(Array(dataObj.keys))")
        }

        return AliQrLoginToken(ck: ck, t: t, qrURL: codeContent)
    }

    /// 第二步：轮询扫码状态
    func aliPollQrStatus(token: AliQrLoginToken) async throws -> AliQrPollResult {
        var request = URLRequest(url: URL(string: "https://passport.aliyundrive.com/newlogin/qrcode/query.do")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.aliyundrive.com/", forHTTPHeaderField: "Referer")

        let body = "t=\(token.t)&ck=\(token.ck)&appName=aliyun_drive&appEntrance=web&isMobile=false&lang=zh_CN&returnUrl=&fromSite=52&bizParams=&navlanguage=zh-CN&navPlatform=MacIntel&_bx-v=2.2.3"
        request.httpBody = body.data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [String: Any],
              let dataObj = content["data"] as? [String: Any] else {
            throw DriveError.invalidResponse
        }

        print("[Ali] query response keys: \(Array(dataObj.keys))")

        // 打印所有字段用于调试
        for (key, value) in dataObj {
            print("[Ali] key='\(key)' value=\(String(describing: value).prefix(500))")
        }

        // 检查 qrCodeStatus
        let status = dataObj["qrCodeStatus"] as? String ?? ""

        // processFinished 状态 - 已扫码确认
        if status == "processFinished" || status == "CONFIRMED" {
            // 打印所有字段用于调试
            print("[Ali] === processFinished 完整响应 ===")
            for (key, value) in dataObj {
                print("[Ali] key='\(key)' type='\(typeString(for: value))' value=\(String(describing: value).prefix(500))")
            }
            print("[Ali] =========================")

            // 方式1：直接从 dataObj 获取（兼容 snake_case 和 camelCase）
            if let rt = dataObj["refresh_token"] as? String ?? dataObj["refreshToken"] as? String,
               let at = dataObj["access_token"] as? String ?? dataObj["accessToken"] as? String {
                let nickName = dataObj["nick_name"] as? String ?? dataObj["nickName"] as? String ?? "阿里云盘用户"
                print("[Ali] 直接获取 Token 成功")
                return .confirmed(refreshToken: rt, accessToken: at, nickName: nickName)
            }
            // 方式2：从 loginSucResultAction 获取（可能是 URL 格式）
            if let loginAction = dataObj["loginSucResultAction"] as? String,
               !loginAction.isEmpty {
                print("[Ali] loginSucResultAction: \(loginAction)")
                // 尝试从 URL 中提取 token
                if let url = URL(string: loginAction) {
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
                    if let refreshToken = components?.queryItems?.first(where: { $0.name == "refresh_token" })?.value,
                       let accessToken = components?.queryItems?.first(where: { $0.name == "access_token" })?.value {
                        let nickName = components?.queryItems?.first(where: { $0.name == "nick_name" })?.value ?? "阿里云盘用户"
                        print("[Ali] 从 loginSucResultAction URL 中提取 Token 成功")
                        return .confirmed(refreshToken: refreshToken, accessToken: accessToken, nickName: nickName)
                    }
                }
            }
            // 方式3：尝试 bizExt（parseAliBizExt 已包含 base64/URL/字符修复/递归搜索）
            if let bizExt = dataObj["bizExt"] as? String {
                print("[Ali] bizExt 长度: \(bizExt.count), 前200字符: \(bizExt.prefix(200))")
                if let result = parseAliBizExt(bizExt) {
                    return result
                }
            }
            // 方式4：尝试 loginResult
            if let loginResult = dataObj["loginResult"] as? String {
                print("[Ali] loginResult: \(loginResult.prefix(200))")
            }
            // 方式4：在 dataObj 中递归搜索 Token（兜底，处理 API 返回新字段的情况）
            if let result = extractTokensRecursive(dataObj) {
                print("[Ali] 从 dataObj 递归搜索找到 Token")
                return result
            }
            // 方式5（v2.3新增）：将整个 dataObj 序列化为字符串，正则提取
            if let jsonData = try? JSONSerialization.data(withJSONObject: dataObj),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                if let result = extractTokensViaRegex(from: jsonString) {
                    print("[Ali] ✅ 从整个响应正则提取 Token 成功")
                    return result
                }
            }
            // 收集所有可能包含 token 的字段
            let loginAction = dataObj["loginSucResultAction"] as? String ?? ""
            let bizExt = dataObj["bizExt"] as? String ?? ""
            let loginResult = dataObj["loginResult"] as? String ?? ""
            let bizExtLen = bizExt.count
            // v2.3.2: 收集所有响应字段名，用于诊断
            let allKeys = Array(dataObj.keys).sorted().joined(separator: ",")
            // 尝试解码 bizExt 用于错误信息（同时尝试 URL-safe base64）
            var bizExtDecoded = ""
            var padded = bizExt.components(separatedBy: .whitespacesAndNewlines).joined()
            while padded.count % 4 != 0 { padded += "=" }
            if let decodedData = Data(base64Encoded: padded),
               let decoded = String(data: decodedData, encoding: .utf8) {
                bizExtDecoded = decoded
            } else {
                // v2.3: 尝试 URL-safe base64
                let urlSafe = padded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                var urlSafePadded = urlSafe
                while urlSafePadded.count % 4 != 0 { urlSafePadded += "=" }
                if let decodedData = Data(base64Encoded: urlSafePadded),
                   let decoded = String(data: decodedData, encoding: .utf8) {
                    bizExtDecoded = decoded
                }
            }
            return .failed(message: "阿里: 已扫码但未找到 Token (bizExt长度=\(bizExtLen)). keys=[\(allKeys)]. loginAction='\(loginAction.prefix(50))', loginResult='\(loginResult.prefix(50))'. bizExt原始前500字符: \(bizExt.prefix(500)). bizExt解码前200字符: \(bizExtDecoded.prefix(200))")
        }

        // NEW/SCANED 状态
        if status == "NEW" {
            return .pending
        }
        if status == "SCANED" {
            return .scanned
        }
        if status == "EXPIRED" {
            return .expired
        }
        if status == "CANCELED" {
            return .failed(message: "阿里: 用户取消扫码")
        }

        // 兜底：尝试直接获取 Token（兼容 snake_case 和 camelCase）
        if let rt = dataObj["refresh_token"] as? String ?? dataObj["refreshToken"] as? String,
           let at = dataObj["access_token"] as? String ?? dataObj["accessToken"] as? String {
            let nickName = dataObj["nick_name"] as? String ?? dataObj["nickName"] as? String ?? "阿里云盘用户"
            return .confirmed(refreshToken: rt, accessToken: at, nickName: nickName)
        }

        return .pending
    }

    /// 解析 bizExt：v2.3.3 重写 — 参考aligo实现
    /// 关键修复: 1) 过滤非base64字符 2) GB18030解码 3) 查找refreshToken(camelCase)
    private func parseAliBizExt(_ bizExt: String) -> AliQrPollResult? {
        // 步骤1: 清理空白字符
        let cleaned = bizExt.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined()

        // 步骤2: 过滤掉所有非base64字符 (Python的base64.b64decode默认忽略非base64字符)
        // 标准base64字符: A-Z a-z 0-9 + / =
        let base64Charset = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let filtered = cleaned.components(separatedBy: base64Charset.inverted).joined()

        print("[Ali] bizExt 原始长度=\(cleaned.count), 过滤后长度=\(filtered.count), 移除了\(cleaned.count - filtered.count)个非base64字符")

        // 步骤3: 补齐 padding
        var padded = filtered
        while padded.count % 4 != 0 { padded += "=" }

        // 步骤4: 尝试 base64 解码
        guard let decodedData = Data(base64Encoded: padded) else {
            print("[Ali] ❌ base64解码失败 (过滤后), 前200字符: \(padded.prefix(200))")
            // 兜底: 尝试原始字符串正则提取
            if let result = extractTokensViaRegex(from: bizExt) {
                print("[Ali] ✅ 原始字符串正则提取成功")
                return result
            }
            return nil
        }

        print("[Ali] base64解码成功, 字节数=\(decodedData.count)")

        // 步骤5: 尝试 GB18030 解码 (aligo使用gb18030, 不是utf-8!)
        // Swift 没有原生 GB18030 支持，用 CFStringTransform 或者手动尝试
        let decodedString = decodeGB18030(decodedData) ?? String(data: decodedData, encoding: .utf8) ?? ""
        if decodedString.isEmpty {
            print("[Ali] ❌ GB18030和UTF-8解码均失败")
            return nil
        }

        print("[Ali] 文本解码成功, 前300字符: \(decodedString.prefix(300))")

        // 步骤6: 尝试 JSON 解析
        if let jsonData = decodedString.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            print("[Ali] JSON解析成功, keys: \(Array(json.keys))")
            if let result = extractAliTokens(from: json) { return result }

            // v2.3.3: 特别检查 pds_login_result.refreshToken (aligo的格式)
            if let pdsResult = json["pds_login_result"] as? [String: Any] {
                print("[Ali] pds_login_result keys: \(Array(pdsResult.keys))")
                if let rt = pdsResult["refreshToken"] as? String,
                   let at = pdsResult["accessToken"] as? String {
                    let nick = pdsResult["nickName"] as? String ?? pdsResult["displayName"] as? String ?? "阿里云盘用户"
                    print("[Ali] ✅ 从 pds_login_result 获取 refreshToken + accessToken 成功!")
                    return .confirmed(refreshToken: rt, accessToken: at, nickName: nick)
                }
                // 可能只有 refreshToken
                if let rt = pdsResult["refreshToken"] as? String {
                    let nick = pdsResult["nickName"] as? String ?? "阿里云盘用户"
                    print("[Ali] ✅ 从 pds_login_result 获取 refreshToken (无accessToken)")
                    return .confirmed(refreshToken: rt, accessToken: "", nickName: nick)
                }
            }
        }

        // 步骤7: JSON解析失败时，正则提取
        if let result = extractTokensViaRegex(from: decodedString) {
            print("[Ali] ✅ 从解码文本正则提取 Token 成功")
            return result
        }

        // 步骤8: 兜底 — 原始 bizExt 正则提取
        if let result = extractTokensViaRegex(from: bizExt) {
            print("[Ali] ✅ 原始 bizExt 正则提取成功")
            return result
        }

        print("[Ali] ❌ 所有 bizExt 解析方式均失败")
        return nil
    }

    /// v2.3.3: GB18030 解码 (Swift 用 Core Foundation 的 CFStringEncodings)
    private func decodeGB18030(_ data: Data) -> String? {
        // CFStringEncodings.GB_18030_2000 (Swift 正确写法)
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        let nsEncoding = String.Encoding(rawValue: cfEncoding)
        return String(data: data, encoding: nsEncoding)
    }

    /// v2.3: 从任意字符串中通过正则提取 refresh_token 和 access_token
    /// 支持格式：JSON 值、URL 查询参数、URL fragment 参数
    private func extractTokensViaRegex(from text: String) -> AliQrPollResult? {
        // 匹配 "refresh_token":"xxx" 或 refresh_token=xxx 或 "refresh_token": "xxx"
        let patterns: [(rtPattern: String, atPattern: String)] = [
            // JSON 格式: "refresh_token":"value"
            (#""refresh_token"\s*:\s*"([^"]+)""#, #""access_token"\s*:\s*"([^"]+)""#),
            // URL 查询参数: refresh_token=value
            (#"refresh_token=([^&\s"\\]+)"#, #"access_token=([^&\s"\\]+)"#),
            // camelCase JSON: "refreshToken":"value"
            (#""refreshToken"\s*:\s*"([^"]+)""#, #""accessToken"\s*:\s*"([^"]+)""#),
            // camelCase URL: refreshToken=value
            (#"refreshToken=([^&\s"\\]+)"#, #"accessToken=([^&\s"\\]+)"#),
        ]

        for (rtPattern, atPattern) in patterns {
            guard let rtRegex = try? NSRegularExpression(pattern: rtPattern, options: []),
                  let atRegex = try? NSRegularExpression(pattern: atPattern, options: []) else { continue }

            let nsText = text as NSString
            let rtRange = NSRange(location: 0, length: nsText.length)
            guard let rtMatch = rtRegex.firstMatch(in: text, options: [], range: rtRange),
                  rtMatch.numberOfRanges > 1,
                  let atMatch = atRegex.firstMatch(in: text, options: [], range: rtRange),
                  atMatch.numberOfRanges > 1 else { continue }

            let rt = nsText.substring(with: rtMatch.range(at: 1))
            let at = nsText.substring(with: atMatch.range(at: 1))

            // 基本有效性检查：token 长度 > 20
            guard rt.count > 20, at.count > 20 else { continue }

            // 尝试提取 nick_name
            var nickName = "阿里云盘用户"
            if let nickRegex = try? NSRegularExpression(pattern: #""nick_name"\s*:\s*"([^"]+)""#, options: []),
               let nickMatch = nickRegex.firstMatch(in: text, options: [], range: rtRange),
               nickMatch.numberOfRanges > 1 {
                nickName = nsText.substring(with: nickMatch.range(at: 1))
            }

            print("[Ali] 正则提取: refreshToken=\(rt.prefix(30))..., accessToken=\(at.prefix(30))...")
            return .confirmed(refreshToken: rt, accessToken: at, nickName: nickName)
        }

        return nil
    }

    /// 从 JSON 中递归搜索 Token（兼容 snake_case / camelCase / URL 格式）
    private func extractAliTokens(from json: [String: Any]) -> AliQrPollResult? {
        // 1. 检查 pds_login_result
        if let pds = json["pds_login_result"] as? [String: Any] {
            print("[Ali] pds_login_result keys: \(Array(pds.keys))")
            if let result = extractTokensFromDict(pds) { return result }
            // 也检查 userData 子对象
            if let userData = pds["userData"] as? [String: Any] {
                print("[Ali] 检查 userData, keys: \(Array(userData.keys))")
                if let result = extractTokensFromDict(userData) { return result }
            }
        }

        // 2. 检查 pds_login_success_url（URL 格式，token 在 query 参数中）
        if let urlString = (json["pds_login_success_url"] as? String) ?? (json["pds_login_success_url"] as? String),
           let url = URL(string: urlString),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            print("[Ali] 检查 pds_login_success_url: \(urlString.prefix(200))")
            let rt = components.queryItems?.first(where: { $0.name == "refresh_token" || $0.name == "refreshToken" })?.value
            let at = components.queryItems?.first(where: { $0.name == "access_token" || $0.name == "accessToken" })?.value
            if let rt = rt, let at = at {
                print("[Ali] 从 pds_login_success_url 提取 Token 成功")
                return .confirmed(refreshToken: rt, accessToken: at, nickName: "阿里云盘用户")
            }
        }

        // 3. 递归搜索整个 JSON 树
        return extractTokensRecursive(json)
    }

    /// 从字典中直接提取 Token（兼容 snake_case 和 camelCase）
    private func extractTokensFromDict(_ dict: [String: Any]) -> AliQrPollResult? {
        let rt = dict["refresh_token"] as? String ?? dict["refreshToken"] as? String
        let at = dict["access_token"] as? String ?? dict["accessToken"] as? String
        let nickName = dict["nick_name"] as? String ?? dict["nickName"] as? String ?? dict["displayName"] as? String ?? "阿里云盘用户"
        if let rt = rt, !rt.isEmpty {
            // v2.3.3: refreshToken 存在即可，accessToken 可选(aligo只取refreshToken)
            print("[Ali] ✅ 找到 Token: refreshToken=\(rt.prefix(20))..., accessToken=\(at?.prefix(20) ?? "nil")")
            return .confirmed(refreshToken: rt, accessToken: at ?? "", nickName: nickName)
        }
        return nil
    }

    /// 递归搜索 JSON 树中的 Token
    private func extractTokensRecursive(_ json: Any) -> AliQrPollResult? {
        guard let dict = json as? [String: Any] else { return nil }

        // 检查当前层
        if let result = extractTokensFromDict(dict) { return result }

        // 检查嵌套对象
        for (key, value) in dict {
            if let nested = value as? [String: Any] {
                if let result = extractTokensRecursive(nested) { return result }
            }
            // 检查 URL 字符串中的 query 参数
            if let urlString = value as? String,
               let url = URL(string: urlString),
               let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
               components.queryItems != nil {
                let rt = components.queryItems?.first(where: { $0.name == "refresh_token" || $0.name == "refreshToken" })?.value
                let at = components.queryItems?.first(where: { $0.name == "access_token" || $0.name == "accessToken" })?.value
                if let rt = rt, let at = at {
                    print("[Ali] ✅ 从 URL 字段 '\(key)' 提取 Token 成功")
                    return .confirmed(refreshToken: rt, accessToken: at, nickName: "阿里云盘用户")
                }
            }
        }

        return nil
    }

    /// 保存阿里云盘 Token 到授权中心
    func aliSaveQrToken(refreshToken: String, accessToken: String, nickName: String) async throws {
        try await CloudDriveAuthManager.shared.saveAliCredential(
            refreshToken: refreshToken,
            accessToken: accessToken,
            nickName: nickName
        )
    }

    // MARK: - 阿里云盘

    func resolveAliPlayURL(shareURL: String, refreshToken: String) async throws -> PlayResult {
        print("[Ali] 开始解析: \(shareURL)")
        // 使用 OpenList 刷新 access_token（与授权获取 token 路径一致，确保 client_id 匹配）
        let cred = try await CloudDriveAuthManager.shared.refreshAliAccessTokenIfNeeded()
        let accessToken = cred.accessToken ?? ""
        guard !accessToken.isEmpty else {
            throw DriveError.noPlayURL("阿里 token 刷新成功但未返回 access_token，请重新授权阿里云盘")
        }

        let shareInfo = extractAliShareInfo(from: shareURL)
        guard !shareInfo.shareId.isEmpty else { throw DriveError.invalidShareURL }

        let shareToken = try await aliGetShareToken(
            shareId: shareInfo.shareId,
            sharePwd: shareInfo.sharePwd,
            token: accessToken
        )
        let file = try await aliFirstPlayableFile(
            shareId: shareInfo.shareId,
            parentFileId: "root",
            shareToken: shareToken,
            token: accessToken
        )
        print("[Ali] 选中资源：\(file.name), fileId=\(file.fileId)")

        var transcodeURL: String?
        do {
            let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: file.fileId, shareToken: shareToken, token: accessToken)
            let taskList = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList ?? []
            let qualityOrder = ["QHD", "FHD", "HD", "SD", "LD"]
            transcodeURL = qualityOrder.compactMap { quality in
                taskList.first { ($0.templateId ?? "").uppercased().contains(quality) }?.url
            }.first ?? taskList.first(where: { ($0.url ?? "").isEmpty == false })?.url
            print("[Ali] 转码线路: \(transcodeURL != nil ? "已获取" : "未获取")")
        } catch {
            print("[Ali] ⚠️ 转码线路获取失败，将尝试原画直链: \(error.localizedDescription)")
        }

        var downloadURL: String?
        do {
            downloadURL = try await aliGetDownloadURL(fileId: file.fileId, shareId: shareInfo.shareId, shareToken: shareToken, token: accessToken)
            print("[Ali] 原画直链: \(downloadURL != nil ? "已获取" : "未获取")")
        } catch {
            print("[Ali] ⚠️ 原画直链获取失败: \(error.localizedDescription)")
        }

        let playbackHeaders = aliPlaybackHeaders(accessToken: accessToken, shareToken: shareToken)

        let playURL: String
        let source: String
        if let url = transcodeURL {
            playURL = url
            source = "transcode"
        } else if let url = downloadURL {
            playURL = url
            source = "download_url"
        } else {
            throw DriveError.noPlayURL("阿里: 转码地址和原画直链均获取失败")
        }

        let fallbackURL: String?
        let fallbackSource: String?
        if source == "transcode", let url = downloadURL {
            fallbackURL = url
            fallbackSource = "download_url"
        } else if source == "download_url", let url = transcodeURL {
            fallbackURL = url
            fallbackSource = "transcode"
        } else {
            fallbackURL = nil
            fallbackSource = nil
        }

        print("[Ali] ✅ 主线路 source=\(source), host=\(URL(string: playURL)?.host ?? "unknown")")
        if let fallbackURL, let fallbackSource {
            print("[Ali] ✅ 兜底线路 source=\(fallbackSource), host=\(URL(string: fallbackURL)?.host ?? "unknown")")
        }

        return PlayResult(
            url: playURL,
            headers: playbackHeaders,
            driveType: .ali,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackURL == nil ? nil : playbackHeaders,
            fallbackSource: fallbackSource
        )
    }

    // MARK: - 阿里云盘文件列表（多文件/文件夹支持）

    struct AliShareFilePublic {
        let fileId: String
        let fileName: String
    }

    /// 获取阿里云盘分享链接中的所有可播放视频文件
    /// 递归遍历子文件夹，返回所有视频文件列表
    func aliGetAllPlayableFiles(shareURL: String) async throws -> [AliShareFilePublic] {
        print("[Ali] 📂 获取所有可播放文件: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [Ali] 获取文件列表...")

        let cred = try await CloudDriveAuthManager.shared.refreshAliAccessTokenIfNeeded()
        let accessToken = cred.accessToken ?? ""
        guard !accessToken.isEmpty else {
            throw DriveError.noPlayURL("阿里 token 刷新成功但未返回 access_token，请重新授权阿里云盘")
        }

        let shareInfo = extractAliShareInfo(from: shareURL)
        guard !shareInfo.shareId.isEmpty else { throw DriveError.invalidShareURL }

        let shareToken = try await aliGetShareToken(
            shareId: shareInfo.shareId,
            sharePwd: shareInfo.sharePwd,
            token: accessToken
        )

        var allVideos: [AliShareFilePublic] = []
        try await aliCollectPlayableFiles(
            shareId: shareInfo.shareId,
            parentFileId: "root",
            shareToken: shareToken,
            token: accessToken,
            into: &allVideos
        )

        print("[Ali] ✅ 可播放文件获取成功: \(allVideos.count) 个")
        self.log("[CloudDrive] [Ali] ✅ 文件列表: \(allVideos.count) 个文件")
        return allVideos
    }

    /// 递归收集文件夹中的所有视频文件
    private func aliCollectPlayableFiles(
        shareId: String, parentFileId: String, shareToken: String, token: String,
        into result: inout [AliShareFilePublic]
    ) async throws {
        let files = try await aliGetShareFileList(
            shareId: shareId,
            parentFileId: parentFileId,
            shareToken: shareToken,
            token: token
        )

        for file in files {
            if aliIsPlayable(file: file) {
                result.append(AliShareFilePublic(fileId: file.fileId, fileName: file.name))
            } else if file.type.lowercased() == "folder" {
                try await aliCollectPlayableFiles(
                    shareId: shareId,
                    parentFileId: file.fileId,
                    shareToken: shareToken,
                    token: token,
                    into: &result
                )
            }
        }
    }

    /// 解析阿里云盘指定文件的播放地址（用于多文件选集播放）
    func resolveAliFilePlayURL(shareURL: String, fileId: String, fileName: String) async throws -> PlayResult {
        print("[Ali] 🎬 解析指定文件: fileId=\(fileId) name=\(fileName)")
        self.log("[CloudDrive] [Ali] 解析文件: \(fileName)")

        // 阿里云盘播放统一走 PG 4kz 路链（原生路链不可用，已移除）
        guard AliyunPgPlayManager.hasPgCredential(),
              let pgCredential = AliyunPgPlayManager.getPgCredential() else {
            self.log("[CloudDrive] ❌ 阿里云盘需要 PG 凭证，请先配置 PG refresh_token")
            throw DriveError.tokenNotConfigured("阿里云盘 PG")
        }

        self.log("[CloudDrive] 🔄 使用 PG 4kz 路链（指定文件）")
        let result = try await AliyunPgPlayManager.shared
            .resolveViaPgChain(
                shareURL: shareURL,
                credential: pgCredential,
                targetFileId: fileId
            )
        self.log("[CloudDrive] ✅ PG 4kz 路链（指定文件）成功")
        return result
    }

    private func aliGetShareToken(shareId: String, sharePwd: String?, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.alipan.com/v2/share_link/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["share_id": shareId]
        if let sharePwd, !sharePwd.isEmpty { body["share_pwd"] = sharePwd }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let codeStr = json["code"] as? String
            let codeInt = json["code"] as? Int
            let isError = (codeStr != nil && codeStr != "OK" && codeStr != "ok" && codeStr != "0")
                        || (codeInt != nil && codeInt != 0 && codeInt != 200)
            if isError {
                let message = json["message"] as? String ?? (codeStr ?? "code=\(codeInt ?? -1)")
                throw DriveError.noPlayURL("阿里分享 token 获取失败：\(message)")
            }
        }
        let result = try JSONDecoder().decode(AliShareTokenResponse.self, from: data)
        return result.shareToken
    }

    private struct AliShareFile {
        let fileId: String
        let name: String
        let type: String
        let category: String
    }

    private func aliGetShareFileList(shareId: String, parentFileId: String, shareToken: String, token: String) async throws -> [AliShareFile] {
        var allItems: [[String: Any]] = []
        var marker: String = ""

        // 分页加载，直到 next_marker 为空或达到上限（最多 10 页 = 1000 个文件/文件夹）
        for page in 0..<10 {
            var request = URLRequest(url: URL(string: "https://api.alipan.com/adrive/v3/file/list")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
            request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
            var body: [String: Any] = [
                "share_id": shareId,
                "parent_file_id": parentFileId,
                "limit": 100,
                "order_by": "name",
                "order_direction": "ASC"
            ]
            if !marker.isEmpty {
                body["marker"] = marker
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)

            if page == 0 {
                let respStr = String(data: data, encoding: .utf8) ?? ""
                print("[Ali] 文件列表响应: \(respStr.prefix(500))")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Ali] ❌ 文件列表响应非JSON")
                throw DriveError.invalidResponse
            }

            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "未知错误"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }

            guard let items = json["items"] as? [[String: Any]] else {
                print("[Ali] ❌ 文件列表为空")
                throw DriveError.noPlayURL("阿里: 分享为空或已失效")
            }

            allItems.append(contentsOf: items)

            // 检查是否有下一页
            if let nextMarker = json["next_marker"] as? String, !nextMarker.isEmpty {
                marker = nextMarker
                // 还有下一页，继续
            } else {
                // 没有更多了
                break
            }
        }

        return allItems.compactMap { item in
            let fileId = item["file_id"] as? String ?? ""
            let name = item["name"] as? String ?? item["file_name"] as? String ?? ""
            let type = item["type"] as? String ?? ""
            let category = item["category"] as? String ?? ""
            guard !fileId.isEmpty, !name.isEmpty else { return nil }
            return AliShareFile(fileId: fileId, name: name, type: type, category: category)
        }
    }

    private func aliFirstPlayableFile(shareId: String, parentFileId: String, shareToken: String, token: String) async throws -> AliShareFile {
        let files = try await aliGetShareFileList(
            shareId: shareId,
            parentFileId: parentFileId,
            shareToken: shareToken,
            token: token
        )
        if let playable = files.first(where: { aliIsPlayable(file: $0) }) {
            return playable
        }
        for folder in files where folder.type.lowercased() == "folder" {
            if let found = try? await aliFirstPlayableFile(
                shareId: shareId,
                parentFileId: folder.fileId,
                shareToken: shareToken,
                token: token
            ) {
                return found
            }
        }
        throw DriveError.noPlayURL("阿里: 分享内未找到可播放视频")
    }

    private func aliIsPlayable(file: AliShareFile) -> Bool {
        if file.category.lowercased() == "video" { return true }
        let lower = file.name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "m4v"].contains { lower.hasSuffix(".\($0)") }
    }

    private func aliGetVideoPreviewPlayInfo(fileId: String, shareToken: String, token: String) async throws -> AliVideoPreviewResponse {
        let url = URL(string: "https://api.alipan.com/adrive/v2/file/get_video_preview_play_info")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = [
            "file_id": fileId,
            "category": "live_transcoding"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] 播放信息响应: \(respStr.prefix(500))")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取播放地址失败"
                print("[Ali] ❌ API错误: \(message)")
                throw DriveError.noPlayURL("阿里: \(message)")
            }
        }

        do {
            let result = try JSONDecoder().decode(AliVideoPreviewResponse.self, from: data)

            guard let taskList = result.videoPreviewPlayInfo?.liveTranscodingTaskList, !taskList.isEmpty else {
                print("[Ali] ❌ 没有可用的转码任务列表")
                throw DriveError.noPlayURL("阿里: 该文件无视频播放地址")
            }

            let qualities = ["FHD", "HD", "SD", "LD"]
            for quality in qualities {
                if let task = taskList.first(where: { $0.templateId?.contains(quality) == true }), let url = task.url {
                    print("[Ali] ✅ 获取到播放地址 (\(quality))")
                    return result
                }
            }

            if taskList.first?.url != nil {
                print("[Ali] ✅ 获取到播放地址")
                return result
            }

            print("[Ali] ❌ 转码任务列表中没有有效的URL")
            throw DriveError.noPlayURL("阿里: 视频转码未完成")
        } catch {
            print("[Ali] ❌ JSON解码失败: \(error)")
            throw DriveError.invalidResponse
        }
    }

    private func aliGetDownloadURL(fileId: String, shareId: String, shareToken: String, token: String) async throws -> String {
        let url = URL(string: "https://api.alipan.com/adrive/v2/file/get_download_url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = [
            "file_id": fileId,
            "share_id": shareId,
            "expire_sec": 14400
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] download_url 响应: \(respStr.prefix(500))")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取下载地址失败"
                print("[Ali] ⚠️ download_url API错误: \(message)")
                throw DriveError.noPlayURL("阿里 download_url: \(message)")
            }
            if let url = json["url"] as? String, !url.isEmpty {
                print("[Ali] ✅ download_url 获取成功")
                return url
            }
        }

        do {
            let result = try JSONDecoder().decode(AliDownloadURLResponse.self, from: data)
            if let downloadURL = result.url, !downloadURL.isEmpty {
                print("[Ali] ✅ download_url 获取成功")
                return downloadURL
            }
        } catch {
            print("[Ali] ⚠️ download_url JSON 解析失败: \(error)")
        }

        throw DriveError.noPlayURL("阿里: 未获取到 download_url")
    }

    private func extractAliShareInfo(from url: String) -> (shareId: String, sharePwd: String?) {
        var shareId = ""
        var sharePwd: String? = nil
        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            shareId = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        } else {
            shareId = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        sharePwd = queryItems.first(where: { ["pwd", "password", "share_pwd"].contains($0.name.lowercased()) })?.value
        if sharePwd == nil, let range = url.range(of: #"(提取码|密码)[:：\s]*([A-Za-z0-9]{4,8})"#, options: .regularExpression) {
            let matched = String(url[range])
            sharePwd = matched.components(separatedBy: CharacterSet(charactersIn: ":： ")).last
        }
        return (shareId, sharePwd)
    }

    private func aliPlaybackHeaders(accessToken: String, shareToken: String) -> [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "x-share-token": shareToken,
            "Referer": "https://www.alipan.com/",
            "Origin": "https://www.alipan.com",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 AliApp(AYSD/6.0.0) Mobile/15E148",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    // MARK: - 夸克网盘

    func resolveQuarkPlayURL(shareURL: String, cookie: String, preferredFid: String? = nil, routePreference: String? = nil) async throws -> PlayResult {
        self.log("[Quark] 开始解析: \(shareURL)")
        let (pwdId, passcode) = quarkExtractShareInfo(shareURL: shareURL)
        self.log("[Quark] pwdId=\(pwdId), passcode=\(passcode.isEmpty ? "无" : "已传递")")
        guard !pwdId.isEmpty else {
            throw DriveError.invalidShareURL
        }

        var authCookie = cookie

        // 播放前检测夸克空间，快满时清理"来自：分享"目录
        authCookie = await quarkCleanShareOriginIfNeeded(cookie: authCookie, thresholdGB: 2.0)

        // 对齐 iBox：不创建自定义目录，to_pdir_fid 传 "0"，让夸克按默认行为保存
        let shareToken = try await quarkGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
        self.log("[Quark] stoken=\(shareToken.isEmpty ? "空" : "已获取")")

        let sourceFile: QuarkShareFile
        if let preferredFid, !preferredFid.isEmpty {
            var files: [QuarkShareFile] = []
            try await quarkCollectAllPlayableFiles(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie, result: &files)
            if let preferredFile = files.first(where: { $0.fid == preferredFid }) {
                sourceFile = preferredFile
            } else {
                sourceFile = try await quarkFirstPlayableFile(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie)
            }
        } else {
            sourceFile = try await quarkFirstPlayableFile(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie)
        }
        let fileExt = (sourceFile.fileName as NSString).pathExtension.lowercased()
        self.log("[Quark] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid), 扩展名=\(fileExt)")

        // 先尝试命中转存 fid 缓存，避免同一资源重复转存
        var topLevelFids: [String]
        var isFileIdsFromCache = false
        if let cachedTopFids = quarkCachedSavedTopFids(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie), !cachedTopFids.isEmpty {
            topLevelFids = cachedTopFids
            isFileIdsFromCache = true
            self.log("[Quark] 转存完成 topLevelFids=\(topLevelFids), fileName=\(sourceFile.fileName)（来自缓存）")
        } else {
            topLevelFids = try await quarkSaveShare(
                pwdId: pwdId,
                stoken: shareToken,
                file: sourceFile,
                folderId: "0",
                cookie: authCookie
            )
            self.log("[Quark] 转存完成 topLevelFids=\(topLevelFids), fileName=\(sourceFile.fileName)")
            // 先按顶层 fid 缓存，后续确定实际播放文件 fid 后再更新 playbackFileId
            let currentCacheKey = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
            quarkStoreSavedItem(topLevelFids: topLevelFids, playbackFileId: nil, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
            // 转存成功即安排 1 小时后清理，不管后续播放是否成功
            scheduleCleanup(drive: .quark, fileIds: topLevelFids, token: authCookie, delay: 60 * 60)
            self.log("[Quark] 🧹 已安排转存文件 1 小时后清理")
            // 同时清理缓存中所有历史转存对象，只保留当前
            authCookie = await quarkCleanupPreviousSavedItems(excludingKey: currentCacheKey, cookie: authCookie)
        }

        guard var playbackFileId = topLevelFids.first else { throw DriveError.noPlayURL("夸克: 转存后未返回文件ID") }

        // 红色封面/被和谐资源的早期判断：转存返回 fileIds=["0"] 时，文件实际未真正保存到网盘
        let isPlaceholderFileId = playbackFileId == "0" || topLevelFids.allSatisfy({ $0 == "0" })
        if isPlaceholderFileId {
            self.log("[Quark] ⚠️ 转存返回占位 fileId=0，疑似资源已被和谐或转码失败")
            throw DriveError.noPlayURL("该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
        }

        // 轮询转存任务状态，等待文件落盘（对齐iBox抓包流程）
        if !isFileIdsFromCache, let taskId = quarkLastSaveTaskId {
            try await quarkPollTask(taskId: taskId, cookie: authCookie)
        }

        // 辅助：缓存命中后若后续确定了新的 playbackFileId，更新缓存
        func updateCachedPlaybackFileId(_ newPlaybackFileId: String) {
            guard !isFileIdsFromCache else { return }
            quarkStoreSavedItem(topLevelFids: topLevelFids, playbackFileId: newPlaybackFileId, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
        }

        // 获取会员信息（对齐iBox抓包：GET /member），用于判断清晰度权限
        if let memberType = await quarkGetMemberInfo(cookie: authCookie) {
            self.log("[Quark] 当前会员: \(memberType)，SVIP可使用原画download_url")
        }
        // 抓包里的实际播放主链路是：先调 v2/play 刷新 Video-Auth，再用 file/download 的 download_url 走 Range 播放。
        // v2/play 返回的 m3u8 只作为兜底，避免直接播放 m3u8 时分片未代理导致 403。
        var transcodeURL = ""
        var effectiveFileId = playbackFileId
        var v2PlayCookie = authCookie
        do {
            let playInfo = try await quarkRefreshVideoAuth(fileId: playbackFileId, cookie: authCookie)
            v2PlayCookie = playInfo.cookie
            transcodeURL = playInfo.playURL
            self.log("[Quark] v2/play 完成 hasVideoAuth=\(v2PlayCookie.contains("Video-Auth=")), transcodeURL=\(transcodeURL.isEmpty ? "空" : "已获取")")
        } catch {
            let errMsg = error.localizedDescription
            self.log("[Quark] ⚠️ v2/play 首次尝试失败(fid=\(playbackFileId)): \(errMsg)")
            // [修复] v2/play 返回 "not video" 说明 fid 是文件夹（转存的是文件夹不是单个文件）
            // 需要递归查找文件夹内的实际视频文件 fid，再重试 v2/play
            if errMsg.contains("not video") {
                self.log("[Quark] 🔍 v2/play 返回 not video，fid=\(playbackFileId) 是文件夹，递归查找视频文件...")
                if let videoFid = await quarkFindFirstVideoInFolder(folderId: playbackFileId, cookie: authCookie) {
                    self.log("[Quark] ✅ 找到实际视频文件 fid=\(videoFid)，重试 v2/play")
                    do {
                        let playInfo = try await quarkRefreshVideoAuth(fileId: videoFid, cookie: authCookie)
                        v2PlayCookie = playInfo.cookie
                        transcodeURL = playInfo.playURL
                        playbackFileId = videoFid
                        effectiveFileId = videoFid
                        updateCachedPlaybackFileId(videoFid)
                        self.log("[Quark] v2/play 重试成功 hasVideoAuth=\(v2PlayCookie.contains("Video-Auth=")), transcodeURL=\(transcodeURL.isEmpty ? "空" : "已获取")")
                    } catch {
                        self.log("[Quark] ⚠️ v2/play 重试失败: \(error.localizedDescription)")
                    }
                } else {
                    self.log("[Quark] ⚠️ 文件夹内未找到视频文件")
                }
            }
            authCookie = v2PlayCookie
        }
        if transcodeURL.isEmpty {
            self.log("[Quark] ⚠️ v2/play 刷新 Video-Auth 失败，继续尝试 download_url")
        }

        var download: (url: String, fileName: String) = ("", "")
        do {
            download = try await quarkGetDownloadURL(fileId: playbackFileId, cookie: authCookie)
        } catch {
            let errMsg = error.localizedDescription
            self.log("[Quark] ⚠️ download_url 首次尝试失败(fid=\(playbackFileId)): \(errMsg)")
            // 文件ID可能不对（save_as_top_fids可能是文件夹ID），尝试通过文件名查找或重新转存
            if errMsg.contains("file not found") || errMsg.contains("not found") {
                if isFileIdsFromCache {
                    // 缓存的 fileId 已失效（可能被清理或过期），清除缓存并重新转存
                    self.log("[Quark] ⚠️ 缓存的 fileId 已失效，清除缓存并重新转存")
                    quarkInvalidateSavedFidCache(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
                    let newTopFids = try await quarkSaveShare(
                        pwdId: pwdId,
                        stoken: shareToken,
                        file: sourceFile,
                        folderId: "0",
                        cookie: authCookie
                    )
                    self.log("[Quark] 重新转存完成 topLevelFids=\(newTopFids), fileName=\(sourceFile.fileName)")
                    // 先缓存顶层对象，确定 playbackFileId 后再更新
                    let newCacheKey = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
                    quarkStoreSavedItem(topLevelFids: newTopFids, playbackFileId: nil, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
                    // 重新转存也安排清理
                    scheduleCleanup(drive: .quark, fileIds: newTopFids, token: authCookie, delay: 60 * 60)
                    self.log("[Quark] 🧹 已安排重新转存文件 1 小时后清理")
                    // 清理历史转存对象，只保留当前
                    authCookie = await quarkCleanupPreviousSavedItems(excludingKey: newCacheKey, cookie: authCookie)
                    // 标记为不再来自缓存，触发任务轮询
                    isFileIdsFromCache = false
                    if let taskId = quarkLastSaveTaskId {
                        try await quarkPollTask(taskId: taskId, cookie: authCookie)
                    }
                    if let newFileId = newTopFids.first, newFileId != "0" {
                        playbackFileId = newFileId
                        effectiveFileId = newFileId
                        download = (try? await quarkGetDownloadURL(fileId: newFileId, cookie: authCookie)) ?? ("", "")
                    }
                } else {
                    // 非缓存失效情况下 file not found，大概率是资源已被和谐或禁止播放，直接提示不再查找
                    self.log("[Quark] ⚠️ download_url 返回 file not found，判定资源已被和谐或禁止播放")
                    throw DriveError.noPlayURL("该资源已被和谐或禁止播放，请尝试其他资源")
                }
            }
            if download.url.isEmpty {
                // 如果转存拿到的是占位 fileId=0，且按文件名也找不到真实文件，说明资源本身已失效
                if isPlaceholderFileId {
                    throw DriveError.noPlayURL("该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
                }
                throw DriveError.noPlayURL("夸克 download_url 获取失败：\(errMsg)")
            }
        }
        // 线路选择：routePreference="original" → 原画(download_url)为主线路；
        //           routePreference="transcode" → 普画(转码m3u8)为主线路；
        //           nil → 默认 original（对齐iBox：优先原画直链高速播放）
        let preferOriginal = routePreference != "transcode"
        let playURL: String
        let source: String
        if preferOriginal && !download.url.isEmpty {
            playURL = download.url
            source = "download_url"
            self.log("[Quark] 📥 主线路: download_url (原画直链, 高速), host=\(URL(string: playURL)?.host ?? "unknown")")
        } else if !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play-m3u8"
            self.log("[Quark] 📥 主线路: v2/play (转码m3u8, 秒开), host=\(URL(string: playURL)?.host ?? "unknown")")
        } else if !download.url.isEmpty {
            playURL = download.url
            source = "download_url"
            self.log("[Quark] 📥 主线路: download_url (直链, m3u8不可用), host=\(URL(string: playURL)?.host ?? "unknown")")
        } else {
            throw DriveError.noPlayURL("夸克: download_url 和转码地址均为空")
        }
        let fallbackURL: String?
        let fallbackSource: String?
        if source == "download_url", !transcodeURL.isEmpty {
            fallbackURL = transcodeURL
            fallbackSource = "v2-play-m3u8"
        } else if source == "v2-play-m3u8", !download.url.isEmpty {
            fallbackURL = download.url
            fallbackSource = "download_url"
        } else {
            fallbackURL = nil
            fallbackSource = nil
        }

        self.log("[Quark] ✅ 主线路 source=\(source), host=\(URL(string: playURL)?.host ?? "unknown")")
        if let fallbackURL, let fallbackSource {
            self.log("[Quark] ✅ 兜底线路 source=\(fallbackSource), host=\(URL(string: fallbackURL)?.host ?? "unknown")")
        } else {
            self.log("[Quark] ⚠️ 兜底线路暂不可用")
        }

        // [优化2] 接入 Go HTTP/2 代理引擎：注册到本地代理，统一处理 m3u8 重写 + ts 鉴权 + Range + 连接池
        let finalURL = GoProxyManager.shared.registerQuarkStream(
            upstreamURL: playURL,
            cookie: authCookie,
            deviceID: quarkDeviceID,
            source: source
        )
        // 代理已处理鉴权头注入；降级（代理未启动）时保留完整 headers
        let playbackHeaders: [String: String]
        if finalURL.hasPrefix("http://127.0.0.1") {
            playbackHeaders = [:]  // 走代理，鉴权由 Go 层处理
            self.log("[Quark] 🔗 Go代理已接管: \(finalURL)")
        } else {
            playbackHeaders = quarkPlaybackHeaders(cookie: authCookie)  // 降级直链
        }

        let fallbackHeaders: [String: String]?
        if let fallbackURL {
            // 兜底线路不提前注册到 Go 代理，避免与主线路共享 stream id 导致互相覆盖
            // （Go 代理 generateStreamID 基于时间戳前缀，短时间内多次注册会得到相同 id）
            // 兜底触发时由 playDriveVideo 走正常路径：
            //   - 转码 m3u8 → DoubanImageProxyServer /quark-m3u8
            //   - 原画直链 → DoubanImageProxyServer /quark-stream
            fallbackHeaders = quarkPlaybackHeaders(cookie: authCookie)
        } else {
            fallbackHeaders = nil
        }

        return PlayResult(
            url: finalURL,
            headers: playbackHeaders,
            driveType: .quark,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackHeaders,
            fallbackSource: fallbackSource
        )
    }

    /// 对齐 iBox parseFile(retry:) 机制：最多重试3次，指数退避（1s/2s/4s）
    private func resolveQuarkPlayURLWithRetry(shareURL: String, cookie: String, maxRetries: Int = 3, preferredFid: String? = nil, routePreference: String? = nil) async throws -> PlayResult {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                let result = try await resolveQuarkPlayURL(shareURL: shareURL, cookie: cookie, preferredFid: preferredFid, routePreference: routePreference)
                if attempt > 0 {
                    self.log("[Quark] 🔄 重试第\(attempt)次成功")
                }
                return result
            } catch {
                lastError = error
                let errMsg = error.localizedDescription.lowercased()
                // 资源已失效、被和谐、禁止播放等确定性错误不重试
                let nonRetryable = errMsg.contains("已失效") || errMsg.contains("已被和谐") || errMsg.contains("禁止播放") || errMsg.contains("转存返回占位")
                if nonRetryable {
                    self.log("[Quark] 🚫 确定性错误，不再重试: \(error.localizedDescription)")
                    throw error
                }
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt) // 1s, 2s, 4s
                    self.log("[Quark] ⚠️ 第\(attempt + 1)次尝试失败: \(error.localizedDescription)，\(String(format: "%.0f", delay))秒后重试...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? DriveError.noPlayURL("夸克播放解析失败（已重试\(maxRetries)次）")
    }

    struct QuarkShareFile {
        let fid: String
        let fileName: String
        let shareFidToken: String
        let pdirFid: String
        let isDir: Bool
    }

    private func quarkExtractShareInfo(shareURL: String) -> (pwdId: String, passcode: String) {
        var pwdId = ""
        if let url = URL(string: shareURL) {
            let comps = url.path.split(separator: "/").map(String.init)
            if let sIndex = comps.firstIndex(of: "s"), comps.count > sIndex + 1 {
                pwdId = comps[sIndex + 1]
            } else if let last = comps.last, !last.isEmpty {
                pwdId = last
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let passcode = query.first(where: { ["pwd", "passcode", "password"].contains($0.name.lowercased()) })?.value ?? ""
            return (pwdId, passcode)
        }

        let cleaned = shareURL
            .replacingOccurrences(of: #".*/s/"#, with: "", options: .regularExpression)
            .components(separatedBy: "?")
            .first ?? shareURL
        pwdId = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        var passcode = ""
        if let range = shareURL.range(of: #"(pwd|passcode|password)=([^&]+)"#, options: .regularExpression) {
            let text = String(shareURL[range])
            passcode = text.components(separatedBy: "=").last ?? ""
        }
        return (pwdId, passcode)
    }

    private func quarkAPIURL(_ path: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://drive-pc.quark.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: "")
        ] + extra
        return components.url!
    }

    private func quarkSetCommonHeaders(_ request: inout URLRequest, cookie: String, referer: String = "https://pan.quark.cn/") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch", forHTTPHeaderField: "User-Agent")
        request.setValue("QingmanLslandApp/1.0", forHTTPHeaderField: "X-Client")
    }

    private func quarkShareReferer(pwdId: String) -> String {
        guard !pwdId.isEmpty else { return "https://pan.quark.cn/" }
        return "https://pan.quark.cn/s/\(pwdId)"
    }

    private func quarkStrictQueryEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func quarkAPIURLWithStrictQuery(_ path: String, queryItems: [URLQueryItem], strictQueryItems: [(String, String)]) -> URL {
        var components = URLComponents(string: "https://drive-pc.quark.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "uc_param_str", value: "")
        ] + queryItems
        var query = components.percentEncodedQuery ?? ""
        for (name, value) in strictQueryItems {
            if !query.isEmpty { query += "&" }
            query += "\(quarkStrictQueryEncode(name))=\(quarkStrictQueryEncode(value))"
        }
        components.percentEncodedQuery = query
        return components.url!
    }

    /// 生成稳定的 X-Device-ID（对齐iBox原画抓包）
    private var quarkDeviceID: String {
        if let cached = UserDefaults.standard.string(forKey: "quark_device_id"), !cached.isEmpty {
            return cached
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(id, forKey: "quark_device_id")
        return id
    }

    private func quarkPlaybackHeaders(cookie: String) -> [String: String] {
        // 对齐iBox 2.4.6：使用桌面端 Electron UA + iboxHeader 自定义头
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch",
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "Accept": "*/*",
            // [优化4] 启用压缩（原 identity 无压缩），对齐 iBox Brotli 优先
            "Accept-Encoding": "br, gzip, deflate",
            "X-Device-Id": quarkDeviceID,
            "X-Client": "QingmanLslandApp/1.0"
        ]
    }

    private func quarkMergeSetCookie(from response: URLResponse, into cookie: String) -> String {
        guard let http = response as? HTTPURLResponse else { return cookie }
        var cookieDict = quarkCookieDictionary(from: cookie)
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headerFields["\(key)"] = "\(value)"
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: URL(string: "https://drive-pc.quark.cn")!)
        for item in responseCookies {
            cookieDict[item.name] = item.value
        }
        return quarkCookieString(from: cookieDict)
    }

    private func quarkCookieDictionary(from cookie: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in cookie.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func quarkCookieString(from dict: [String: String]) -> String {
        let preferred = ["__kps", "__puus", "ctoken", "__pus", "__ktd", "__kp", "__uid", "__sdid", "Video-Auth"]
        var used = Set<String>()
        var parts: [String] = []
        for key in preferred {
            if let value = dict[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
                used.insert(key)
            }
        }
        for key in dict.keys.sorted() where !used.contains(key) {
            if let value = dict[key], !value.isEmpty {
                parts.append("\(key)=\(value)")
            }
        }
        return parts.joined(separator: "; ")
    }

    /// 夸克账号维度的稳定Key，用于：
    /// 1) 缓存 vbox 目录fid；2) 单飞确保并发解析不会重复创建目录。
    private func quarkAccountKey(cookie: String) -> String {
        let dict = quarkCookieDictionary(from: cookie)
        // 优先用能代表账号身份的字段
        for key in ["__uid", "__puus", "__kps", "ctoken", "__sdid", "__kp"] {
            if let value = dict[key], !value.isEmpty {
                return "\(key):\(value)"
            }
        }
        // 兜底：cookie 哈希（避免把整段cookie当key导致过大/不稳定）
        return "cookie:\(baiduStableHash(cookie))"
    }

    /// 生成夸克账号唯一目录名，避免固定名称 vbox 在服务端产生同名冲突/隐藏状态（code=23008）
    /// 基于账号稳定标识生成，确保同一账号始终使用同一个目录
    private func quarkFolderName(cookie: String) -> String {
        let accountKey = quarkAccountKey(cookie: cookie)
        // 取账号key的哈希前缀，保证名称唯一且固定
        let hash = baiduStableHash(accountKey)
        let shortHash = String(hash.prefix(8))
        return "vbox_ios_\(shortHash)"
    }

    private func quarkGetShareToken(pwdId: String, passcode: String, cookie: String) async throws -> String {
        let url = quarkAPIURL("/1/clouddrive/share/sharepage/token", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let body: [String: Any] = ["pwd_id": pwdId, "passcode": passcode]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克分享 token 获取失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let st = dataObj["stoken"] as? String,
              !st.isEmpty else {
            throw DriveError.noPlayURL("夸克未返回 stoken")
        }
        let hasPlus = st.contains("+")
        let hasSlash = st.contains("/")
        let hasEqual = st.contains("=")
        self.log("[Quark] stoken诊断 length=\(st.count), hasPlus=\(hasPlus), hasSlash=\(hasSlash), hasEqual=\(hasEqual)")
        return st
    }

    private func quarkEnsureFolder(cookie: String) async throws -> String {
        (try await quarkEnsureFolderWithCookie(cookie: cookie)).folderId
    }


    private func quarkEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        let accountKey = quarkAccountKey(cookie: cookie)
        let folderName = quarkFolderName(cookie: cookie)

        // 1. 优先使用缓存的 folderId（快速路径）
        quarkVboxCacheLock.lock()
        if let cachedFolderId = quarkVboxFolderCache[accountKey], !cachedFolderId.isEmpty {
            quarkVboxCacheLock.unlock()
            self.log("[Quark] 使用缓存 folderId=\(cachedFolderId) (folder=\(folderName))")
            return (cachedFolderId, cookie)
        }
        quarkVboxCacheLock.unlock()

        // 2. 缓存未命中：按账号唯一目录名查找根目录
        if let folder = try? await quarkFindVisibleFolder(cookie: cookie, folderName: folderName) {
            setQuarkVboxFolderCache(accountKey: accountKey, folderId: folder.folderId)
            return folder
        }

        // 3. 单飞：同一账号并发 ensure 时复用同一个 Task，避免重复创建目录导致 23008/同名冲突。
        quarkVboxCacheLock.lock()
        if let existing = quarkEnsureFolderTasks[accountKey] {
            quarkVboxCacheLock.unlock()
            return try await existing.value
        }

        let task = Task<(folderId: String, cookie: String), Error> { [weak self] in
            guard let self else { throw DriveError.noPlayURL("夸克：内部对象已释放") }
            do {
                let folder = try await self.quarkFindOrCreateVisibleFolder(cookie: cookie, folderName: folderName)
                self.setQuarkVboxFolderCache(accountKey: accountKey, folderId: folder.folderId)
                return folder
            } catch {
                self.log("[Quark] ❌ \(folderName) 目录创建/查找失败：\(error.localizedDescription)")
                throw error
            }
        }
        quarkEnsureFolderTasks[accountKey] = task
        quarkVboxCacheLock.unlock()

        defer {
            quarkVboxCacheLock.lock()
            quarkEnsureFolderTasks.removeValue(forKey: accountKey)
            quarkVboxCacheLock.unlock()
        }

        return try await task.value
    }

    /// 清理指定目录下的转存文件（对齐百度清理逻辑），不清理回收站

    /// 清理夸克"来自：分享"文件夹下的旧转存文件（夸克 sharepage/save 实际落盘位置）
    private func quarkCleanUpShareOriginFolder(cookie: String, excludeFileIds: [String] = []) async -> String {
        var currentCookie = cookie

        // 1. 用 quarkFindVisibleFolder 搜索「来自：分享」（兼容全角/半角冒号）
        var targetFid: String?
        for nameVariant in ["来自：分享", "来自:分享"] {
            if let (fid, mergedCookie) = try? await quarkFindVisibleFolder(
                cookie: currentCookie, folderName: nameVariant
            ) {
                targetFid = fid
                currentCookie = mergedCookie
                self.log("[Quark] 🔍 找到「\(nameVariant)」文件夹 fid=\(fid)")
                break
            }
        }
        guard let targetFid else {
            self.log("[Quark] ⚠️ quarkFindVisibleFolder 未找到「来自：分享」文件夹（尝试了全角/半角冒号），跳过清理")
            return currentCookie
        }

        // 2. 列出目录内容（含子目录递归）
        let listURL = quarkAPIURL("/1/clouddrive/file/sort")
        let pageSize = 200
        let maxPages = 10

        func extractFid(from item: [String: Any]) -> String? {
            for key in ["fid", "file_id", "obj_id", "id"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
                if let value = item[key] as? Int { return String(value) }
            }
            return nil
        }

        func isItemDir(_ item: [String: Any]) -> Bool {
            return (item["file_type"] as? Int) == 0 || (item["is_dir"] as? Bool) == true
        }

        /// 递归收集指定目录下所有文件和子目录的 fid（排除 excludeSet 中的 fid）
        func collectFidsRecursive(dirFid: String, cookie: inout String, excludeSet: Set<String>) async -> (fids: [String], fileCount: Int, dirCount: Int) {
            var allFids: [String] = []
            var fileCount = 0
            var dirCount = 0

            for page in 1...maxPages {
                var request = URLRequest(url: listURL)
                request.httpMethod = "POST"
                quarkSetCommonHeaders(&request, cookie: cookie)
                let body: [String: Any] = [
                    "pdir_fid": dirFid,
                    "_sort": "file_type:asc,file_name:asc",
                    "_page": page,
                    "_size": pageSize,
                    "_fetch_total": 1
                ]
                request.httpBody = (try? JSONSerialization.data(withJSONObject: body))

                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    break
                }
                cookie = quarkMergeSetCookie(from: response, into: cookie)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else { break }
                if list.isEmpty { break }

                for item in list {
                    guard let fid = extractFid(from: item), !fid.isEmpty, !excludeSet.contains(fid) else { continue }
                    allFids.append(fid)
                    if isItemDir(item) {
                        dirCount += 1
                        // 递归收集子目录中的内容
                        let sub = await collectFidsRecursive(dirFid: fid, cookie: &cookie, excludeSet: excludeSet)
                        allFids.append(contentsOf: sub.fids)
                        fileCount += sub.fileCount
                        dirCount += sub.dirCount
                    } else {
                        fileCount += 1
                    }
                }
                if list.count < pageSize { break }
            }

            return (allFids, fileCount, dirCount)
        }

        // 收集要删除的文件和文件夹，排除本次转存
        var fileIdsToDelete: [String] = []
        var deletedFileCount = 0
        var deletedDirCount = 0
        let excludeSet = Set(excludeFileIds)
        self.log("[Quark] 🔍 开始扫描「\"来自：分享\"」目录 (fid=\(targetFid))，排除 \(excludeFileIds.count) 个文件")

        let result = await collectFidsRecursive(dirFid: targetFid, cookie: &currentCookie, excludeSet: excludeSet)
        fileIdsToDelete = result.fids
        deletedFileCount = result.fileCount
        deletedDirCount = result.dirCount

        // 3. 删除旧文件和文件夹
        if !fileIdsToDelete.isEmpty {
            self.log("[Quark] 🔍 「来自：分享」目录: 待删除 \(deletedFileCount) 个旧文件 + \(deletedDirCount) 个旧文件夹")
            let deleteURL = quarkAPIURL("/1/clouddrive/file/delete")
            var deleteReq = URLRequest(url: deleteURL)
            deleteReq.httpMethod = "POST"
            quarkSetCommonHeaders(&deleteReq, cookie: currentCookie)
            let filelistJSON = (try? JSONSerialization.data(withJSONObject: fileIdsToDelete))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let deleteBody: [String: Any] = [
                "action_type": 2,
                "filelist": filelistJSON,
                "exclude_fids": []
            ]
            guard let deleteBodyData = try? JSONSerialization.data(withJSONObject: deleteBody) else {
                self.log("[Quark] ⚠️ 「来自：分享」清理删除Body序列化失败")
                return currentCookie
            }
            deleteReq.httpBody = deleteBodyData
            var deleteResult: (Data, URLResponse)?
            do {
                deleteResult = try await session.data(for: deleteReq)
            } catch {
                self.log("[Quark] ⚠️ 清理「\"来自：分享\"」目录删除请求失败: \(error.localizedDescription)")
                deleteResult = nil
            }
            if let deleteResp = deleteResult?.1 {
                currentCookie = quarkMergeSetCookie(from: deleteResp, into: currentCookie)
            }

            // 验证删除结果
            var deleteOK = true
            if let httpResp = deleteResult?.1 as? HTTPURLResponse {
                deleteOK = (200...299).contains(httpResp.statusCode)
            }
            if deleteOK, let deleteData = deleteResult?.0,
               let deleteJson = try? JSONSerialization.jsonObject(with: deleteData) as? [String: Any] {
                if let code = deleteJson["code"] as? Int, code != 0 {
                    deleteOK = false
                    self.log("[Quark] ⚠️ 「来自：分享」删除API返回错误: code=\(code), message=\(deleteJson["message"] ?? "nil")")
                }
            }
            if deleteOK {
                self.log("[Quark] ✅ 已清理「\"来自：分享\"」目录下 \(deletedFileCount) 个旧文件 + \(deletedDirCount) 个旧文件夹")
            }

            // 4. 彻底清理回收站
            if let deleteData = deleteResult?.0,
               let deleteJson = try? JSONSerialization.jsonObject(with: deleteData) as? [String: Any],
               let taskId = deleteJson["task_id"] as? String {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let recycleURL = quarkAPIURL("/1/clouddrive/file/recycle/list", extra: [
                    URLQueryItem(name: "_page", value: "1"),
                    URLQueryItem(name: "_size", value: "100"),
                    URLQueryItem(name: "_sort", value: "move_recycle_at:desc")
                ])
                var recycleReq = URLRequest(url: recycleURL)
                recycleReq.httpMethod = "GET"
                recycleReq.timeoutInterval = 10
                quarkSetCommonHeaders(&recycleReq, cookie: currentCookie)

                let recycleResult = try? await session.data(for: recycleReq)
                if let recycleResp = recycleResult?.1 {
                    currentCookie = quarkMergeSetCookie(from: recycleResp, into: currentCookie)
                }
                if let recycleData = recycleResult?.0,
                   let recycleJSON = try? JSONSerialization.jsonObject(with: recycleData) as? [String: Any],
                   let recycleList = recycleJSON["data"] as? [[String: Any]] {
                    let recordIds = recycleList.compactMap { item -> String? in
                        let recordId = item["record_id"] as? String ?? ""
                        if recordId.contains(taskId) || fileIdsToDelete.contains(where: { recordId.contains($0) }) {
                            return recordId
                        }
                        return nil
                    }
                    if !recordIds.isEmpty {
                        let removeURL = quarkAPIURL("/1/clouddrive/file/recycle/remove")
                        var removeReq = URLRequest(url: removeURL)
                        removeReq.httpMethod = "POST"
                        quarkSetCommonHeaders(&removeReq, cookie: currentCookie)
                        let removeBody: [String: Any] = ["select_mode": 2, "record_list": recordIds]
                        removeReq.httpBody = try? JSONSerialization.data(withJSONObject: removeBody)
                        let removeResult = try? await session.data(for: removeReq)
                        if let removeResp = removeResult?.1 {
                            currentCookie = quarkMergeSetCookie(from: removeResp, into: currentCookie)
                        }
                        self.log("[Quark] ✅ 已彻底清理回收站 \(recordIds.count) 条记录（来自：分享）")
                    }
                }
            }
        } else {
            self.log("[Quark] ℹ️ 「\"来自：分享\"」目录无可清理的旧文件")
        }

        return currentCookie
    }

    /// 查询夸克网盘容量信息
    private func quarkGetQuotaInfo(cookie: String) async -> (used: Int64, total: Int64, cookie: String) {
        var currentCookie = cookie

        // 对齐 iBox 2.4.6：先通过 member 接口取 capacity 字段（最稳定，不需要 UC 账号）
        if let memberQuota = await quarkGetQuotaFromMember(cookie: currentCookie),
           memberQuota.total > 0 {
            return (memberQuota.used, memberQuota.total, currentCookie)
        }

        // member 失败再尝试标准 quota 端点（只使用夸克域名，避免 UC 域名 cookie 不匹配导致 401）
        let ut = String(Int(Date().timeIntervalSince1970 * 1000))
        let endpoints = [
            ("https://drive-pc.quark.cn", "/1/clouddrive/quota/info", "pr=ucpro&fr=pc&uc_param_str=&ut=\(ut)"),
        ]

        for (host, path, query) in endpoints {
            guard let url = URL(string: "\(host)\(path)?\(query)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            quarkSetCommonHeaders(&request, cookie: cookie)
            // iBox 抓包显示 quota/info 需要 dlt_keys 字段，否则返回 405/参数错误
            let body: [String: Any] = ["dlt_keys": ["uc_nor_dlt"]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, response) = try? await session.data(for: request) else {
                self.log("[Quark] ⚠️ quota端点 \(host) 请求失败")
                continue
            }
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)

            let rawBody = String(data: data, encoding: .utf8) ?? "<非UTF8>"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            self.log("[Quark] 📊 quota端点 \(host) HTTP \(statusCode), 原始响应: \(rawBody.prefix(600))")
            guard statusCode == 200 || statusCode == 201 else {
                self.log("[Quark] ⚠️ quota端点 \(host) 非 200 响应，跳过")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.log("[Quark] ⚠️ quota端点 \(host) 响应不是JSON: \(rawBody.prefix(500))")
                continue
            }

            // 容量字段可能在 data 下，也可能在更深层；兜底直接使用顶层 json
            let dataObj = json["data"] as? [String: Any]
            let capObj: [String: Any] = dataObj?["capinfo"] as? [String: Any]
                ?? dataObj?["capacity"] as? [String: Any]
                ?? dataObj?["account_capacity"] as? [String: Any]
                ?? json

            func parseInt64(_ value: Any?) -> Int64 {
                if let v = value as? Int64 { return v }
                if let v = value as? Int { return Int64(v) }
                if let v = value as? Double { return Int64(v) }
                if let v = value as? String { return Int64(v) ?? 0 }
                return 0
            }

            let used = parseInt64(capObj["used"] ?? capObj["size_used"] ?? dataObj?["used"])
            var total = parseInt64(capObj["total"] ?? capObj["size_total"] ?? dataObj?["total"])
            // 只有剩余量时，用 account.total_capacity 兜底
            if total <= 0, let account = dataObj?["account"] as? [String: Any] {
                total = parseInt64(account["total_capacity"] ?? account["capacity_total"] ?? account["total"])
            }
            if total > 0 {
                self.log("[Quark] ✅ quota端点 \(host) 成功: used=\(used), total=\(total)")
                return (used, total, currentCookie)
            }
            self.log("[Quark] ⚠️ quota端点 \(host) total=0，原始响应: \(rawBody.prefix(500))")
        }

        self.log("[Quark] ⚠️ 所有quota端点均失败")
        return (0, 0, currentCookie)
    }

    /// 兜底：通过 member 接口获取容量信息（对齐 iBox 2.4.6）
    private func quarkGetQuotaFromMember(cookie: String) async -> (used: Int64, total: Int64)? {
        let url = quarkAPIURL("/1/clouddrive/member", extra: [
            URLQueryItem(name: "fetch_subscribe", value: "true"),
            URLQueryItem(name: "fetch_identity", value: "true"),
            URLQueryItem(name: "_ch", value: "home"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        quarkSetCommonHeaders(&req, cookie: cookie)

        do {
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                func p(_ v: Any?) -> Int64 {
                    if let v = v as? Int64 { return v }
                    if let v = v as? Int { return Int64(v) }
                    if let v = v as? Double { return Int64(v) }
                    if let v = v as? String { return Int64(v) ?? 0 }
                    return 0
                }
                // 夸克 member 接口可能把容量放在 capacity 或 capinfo 字段
                let cap = d["capacity"] as? [String: Any]
                    ?? d["capinfo"] as? [String: Any]
                    ?? d["account_capacity"] as? [String: Any]
                var used = p(cap?["used"] ?? cap?["size_used"] ?? d["used"] ?? 0)
                var total = p(cap?["total"] ?? cap?["size_total"] ?? d["total"] ?? 0)

                // 有些接口 capacity 只给剩余，需要拿 account 字段的总容量
                if total <= 0, let account = d["account"] as? [String: Any] {
                    total = p(account["total_capacity"] ?? account["capacity_total"] ?? account["total"] ?? 0)
                }
                if used <= 0, let account = d["account"] as? [String: Any] {
                    used = p(account["used_capacity"] ?? account["capacity_used"] ?? account["used"] ?? 0)
                }

                // 如果只有 total，尝试用 d["remain"] 推算 used
                if total > 0 && used <= 0, let remain = d["remain"] {
                    used = total - p(remain)
                }

                if total > 0 {
                    self.log("[Quark] ✅ member 获取容量成功: used=\(used), total=\(total)")
                    return (used, total)
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                    self.log("[Quark] ⚠️ member 接口未返回有效容量，原始响应: \(raw.prefix(800))")
                }
            } else {
                let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                self.log("[Quark] ⚠️ member 接口响应异常，原始响应: \(raw.prefix(800))")
            }
        } catch {
            self.log("[Quark] ⚠️ member 兜底容量获取失败: \(error.localizedDescription)")
        }
        return nil
    }

    /// 如果剩余空间不足，清理"来自：分享"目录下所有文件
    private func quarkCleanShareOriginIfNeeded(cookie: String, thresholdGB: Double = 1.0) async -> String {
        self.log("[Quark] 🧹 开始容量检测...")
        var currentCookie = cookie
        let (used, total, mergedCookie) = await quarkGetQuotaInfo(cookie: currentCookie)
        currentCookie = mergedCookie

        let quotaAvailable = total > 0
        var freeGB: Double = 0
        if quotaAvailable {
            let free = total - used
            freeGB = Double(free) / 1_073_741_824.0
            let totalGB = Double(total) / 1_073_741_824.0
            let usedGB = Double(used) / 1_073_741_824.0
            let usedPercent = Double(used) * 100.0 / Double(total)

            self.log("[Quark] 📊 容量检测: 已用 \(String(format: "%.2f", usedGB))GB / 总共 \(String(format: "%.2f", totalGB))GB (\(String(format: "%.1f", usedPercent))%)，剩余 \(String(format: "%.2f", freeGB))GB，清理阈值 \(thresholdGB)GB")
        }

        if quotaAvailable {
            // 剩余空间低于阈值时触发清理
            guard freeGB < thresholdGB else {
                self.log("[Quark] ✅ 剩余空间充足(\(String(format: "%.2f", freeGB))GB >= \(thresholdGB)GB)，跳过清理")
                return currentCookie
            }
            self.log("[Quark] 🧹 剩余空间不足 \(String(format: "%.2f", freeGB))GB < \(thresholdGB)GB，开始清理夸克转存文件")
        } else {
            self.log("[Quark] ⚠️ 无法获取夸克容量信息（member+quota端点均失败），按保守策略清理最近转存的文件")
        }

        // 辅助：用 GET 列出目录下所有文件/文件夹
        func collectFids(folderId: String, onlyVideo: Bool = false, limit: Int? = nil, includeFolders: Bool = false) async -> [String] {
            var fids: [String] = []
            let pageSize = 200
            let maxPages = limit != nil ? min(10, (limit! + pageSize - 1) / pageSize) : 10
            for page in 1...maxPages {
                let extra = [
                    URLQueryItem(name: "pdir_fid", value: folderId),
                    URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc"),
                    URLQueryItem(name: "_page", value: String(page)),
                    URLQueryItem(name: "_size", value: String(pageSize)),
                    URLQueryItem(name: "_fetch_total", value: "1")
                ]
                let listURL = quarkAPIURL("/1/clouddrive/file/sort", extra: extra)
                var request = URLRequest(url: listURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                quarkSetCommonHeaders(&request, cookie: currentCookie)

                guard let (data, response) = try? await session.data(for: request) else {
                    self.log("[Quark] ⚠️ file/sort 请求失败 folderId=\(folderId), page=\(page)")
                    break
                }
                currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else {
                    let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                    self.log("[Quark] ⚠️ file/sort 解析失败 folderId=\(folderId), page=\(page), raw=\(raw.prefix(300))")
                    break
                }
                let total = dataObj["_total"] as? Int ?? dataObj["total"] as? Int ?? -1
                self.log("[Quark] 📂 file/sort folderId=\(folderId), page=\(page), 返回 \(list.count) 项, total=\(total)")
                if list.isEmpty { break }

                for item in list {
                    let isDir = (item["file_type"] as? Int) == 0 || (item["is_dir"] as? Bool) == true

                    // 默认跳过文件夹；明确 includeFolders 时收集文件夹 fid
                    if isDir && !includeFolders { continue }

                    // 如仅需视频，过滤后缀（文件夹不应用视频后缀过滤）
                    if onlyVideo && !isDir {
                        let name = (item["file_name"] as? String ?? item["name"] as? String ?? "").lowercased()
                        let videoExts = [".mp4", ".mkv", ".avi", ".ts", ".mov", ".flv", ".wmv", ".m4v", ".3gp"]
                        guard videoExts.contains(where: { name.hasSuffix($0) }) else { continue }
                    }

                    for key in ["fid", "file_id"] {
                        if let fid = item[key] as? String, !fid.isEmpty {
                            fids.append(fid)
                            break
                        } else if let fid = item[key] as? Int {
                            fids.append(String(fid))
                            break
                        }
                    }

                    if let limit = limit, fids.count >= limit {
                        break
                    }
                }
                if list.count < pageSize { break }
                if let limit = limit, fids.count >= limit { break }
            }
            return fids
        }

        // 辅助：批量删除 fileIds（受保护的 fid 不删除）
        func deleteFids(_ fids: [String], excludeFids: Set<String> = []) async -> Int {
            let fidsToDelete = fids.filter { !excludeFids.contains($0) }
            guard !fidsToDelete.isEmpty else { return 0 }
            let batchSize = 100
            var deletedCount = 0
            for i in stride(from: 0, to: fidsToDelete.count, by: batchSize) {
                let batch = Array(fidsToDelete[i..<min(i + batchSize, fidsToDelete.count)])
                let deleteURL = quarkAPIURL("/1/clouddrive/file/delete")
                var deleteReq = URLRequest(url: deleteURL)
                deleteReq.httpMethod = "POST"
                quarkSetCommonHeaders(&deleteReq, cookie: currentCookie)
                let deleteBody: [String: Any] = [
                    "action_type": 2,
                    "filelist": batch,
                    "exclude_fids": []
                ]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: deleteBody) else { continue }
                deleteReq.httpBody = bodyData

                if let (data, response) = try? await session.data(for: deleteReq) {
                    currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let code = json["code"] as? Int, code == 0 {
                        deletedCount += batch.count
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms 间隔，避免风控
            }
            return deletedCount
        }

        // 辅助：收集所有缓存中未过期的对象 fid，避免播放前清理误删正在使用的转存文件
        func protectedCachedFileIds() -> Set<String> {
            let cache = loadQuarkSavedFidCache()
            let now = Date()
            var fids = Set<String>()
            for item in cache.values where item.expiresAt > now {
                item.topLevelFids.forEach { fids.insert($0) }
                if let playbackFileId = item.playbackFileId {
                    fids.insert(playbackFileId)
                }
            }
            return fids
        }

        // 辅助：查找文件夹 fid
        func findFolderId(name: String) async -> String? {
            let searchExtra = [
                URLQueryItem(name: "pdir_fid", value: "0"),
                URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
                URLQueryItem(name: "_page", value: "1"),
                URLQueryItem(name: "_size", value: "200"),
                URLQueryItem(name: "_fetch_total", value: "1")
            ]
            let searchURL = quarkAPIURL("/1/clouddrive/file/sort", extra: searchExtra)
            var searchReq = URLRequest(url: searchURL)
            searchReq.httpMethod = "GET"
            searchReq.timeoutInterval = 15
            quarkSetCommonHeaders(&searchReq, cookie: currentCookie)

            guard let (data, response) = try? await session.data(for: searchReq) else { return nil }
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else { return nil }

            let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for item in list {
                let itemName = (item["file_name"] as? String ?? item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard itemName == targetName else { continue }
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fid = item["file_id"] as? String, !fid.isEmpty { return fid }
                if let fid = item["fid"] as? Int { return String(fid) }
            }
            return nil
        }

        var totalDeleted = 0

        // 同时扫描"来自：分享"目录和根目录视频文件（并行）
        async let shareFids: [String] = {
            for nameVariant in ["来自：分享", "来自:分享", "来自分享的文件", "来自分享"] {
                if let fid = await findFolderId(name: nameVariant) {
                    self.log("[Quark] 🔍 找到清理目标目录「\(nameVariant)」fid=\(fid)")
                    // 分享目录内同时清理子文件夹和文件，避免文件夹形式转存残留
                    return await collectFids(folderId: fid, includeFolders: true)
                }
            }
            return []
        }()
        // 容量检测成功或失败都清理根目录视频；失败时更激进，清理最新 100 个避免空间爆掉
        async let rootFids: [String] = quotaAvailable
            ? collectFids(folderId: "0", onlyVideo: true)
            : collectFids(folderId: "0", onlyVideo: true, limit: 100)

        let shareResult = await shareFids
        let rootResult = await rootFids

        if quotaAvailable {
            self.log("[Quark] 📋 扫描结果：来自分享 \(shareResult.count) 个文件，根目录 \(rootResult.count) 个视频文件")
        } else {
            self.log("[Quark] 📋 容量未知，保守清理：来自分享 \(shareResult.count) 个文件，根目录最新 \(rootResult.count) 个视频文件")
        }

        // 合并去重后批量删除，排除缓存中未过期的 fileId（避免误删正在播放或待播放的转存文件）
        let allFids = Array(Set(shareResult + rootResult))
        let protectedFids = protectedCachedFileIds()
        if !allFids.isEmpty {
            totalDeleted = await deleteFids(allFids, excludeFids: protectedFids)
            self.log("[Quark] ✅ 已清理 \(totalDeleted)/\(allFids.count) 个文件（来自分享 + 根目录，保护缓存 \(protectedFids.count) 个）")
        }

        self.log("[Quark] ✅ 空间清理完成，共删除 \(totalDeleted) 个文件")
        return currentCookie
    }

    private func quarkFindOrCreateVisibleFolder(cookie: String, folderName: String) async throws -> (folderId: String, cookie: String) {
        // 先查找已存在的目录
        if let folder = try await quarkFindVisibleFolder(cookie: cookie, folderName: folderName) {
            self.log("[Quark] 使用根目录 \(folderName) 文件夹 fid=\(folder.folderId)")
            return folder
        }

        // 尝试创建目录
        let createURL = quarkAPIURL("/1/clouddrive/file")
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "file_name": folderName,
            "dir": true,
            "dir_path": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.log("[Quark] ❌ 创建 \(folderName) 目录响应非JSON: \(preview)")
            throw DriveError.invalidResponse
        }

        // 创建成功，提取fid
        if let fid = quarkExtractFirstFid(from: json), !fid.isEmpty {
            self.log("[Quark] ✅ 已创建根目录 \(folderName) 文件夹 fid=\(fid)")
            return (fid, mergedCookie)
        }

        // 检查是否因为"已存在"而失败（覆盖夸克API各种返回格式）
        let message = (json["message"] as? String ?? json["msg"] as? String ?? "").lowercased()
        let code = json["code"] as? Int ?? json["status"] as? Int ?? 0
        // 把“同名冲突/下载中”等视为瞬态问题，等待并重试查找即可恢复
        let isAlreadyExists = message.contains("已存在")
            || message.contains("exist")
            || message.contains("同名")
            || message.contains("already")
            || message.contains("重复")
            || message.contains("冲突")
            || message.contains("downloading")
            || message.contains("file is downloading")
            || code == 23008
            || code == 40003
            || code == 40001
            || code == 40005

        if isAlreadyExists {
            self.log("[Quark] ⚠️ \(folderName) 目录疑似已存在/处理中(code=\(code), message=\(message))，尝试重新查找...")
            // 目录“已存在”但 file/sort 可能存在短暂不可见（或缓存延迟），做几次短重试
            for attempt in 1...5 {
                if attempt > 1 {
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt))
                }
                if let folder = try await quarkFindVisibleFolder(cookie: mergedCookie, folderName: folderName) {
                    self.log("[Quark] ✅ 找到已存在的 \(folderName) 文件夹 fid=\(folder.folderId) (attempt=\(attempt))")
                    return folder
                }
            }

            // 兜底：某些环境下根目录 file/sort 返回结构/字段不稳定，尝试用另一套分页参数再按名称查一次。
            if let fid = await quarkFindSavedFileId(fileName: folderName, folderId: "0", cookie: mergedCookie) {
                self.log("[Quark] ✅ 兜底：按名称在根目录定位 \(folderName)，fid=\(fid)")
                return (fid, mergedCookie)
            }
            self.log("[Quark] ⚠️ 标记已存在但 file/sort 仍找不到，尝试从创建响应取 fid...")
            if let fid = quarkExtractFirstFid(from: json), !fid.isEmpty {
                self.log("[Quark] ✅ 从创建响应提取到 fid=\(fid)")
                return (fid, mergedCookie)
            }
            self.log("[Quark] ⚠️ 创建响应也没有 fid，查看完整响应诊断: \(preview)")
        }

        if code != 0 && code != 200 {
            self.log("[Quark] ❌ 创建 \(folderName) 目录失败: message=\(message), code=\(code), preview=\(preview)")
            throw DriveError.noPlayURL("夸克创建 \(folderName) 目录失败：\(message) (code=\(code))")
        }

        self.log("[Quark] ❌ 创建 \(folderName) 目录成功(status=\(code))但未返回 fid: \(preview)")
        throw DriveError.noPlayURL("夸克创建 \(folderName) 目录后未返回 fid")
    }

    private func quarkFindVisibleFolder(cookie: String, folderName: String) async throws -> (folderId: String, cookie: String)? {
        let listURL = quarkAPIURL("/1/clouddrive/file/sort")
        var currentCookie = cookie
        let pageSize = 200
        let maxPages = 200
        let targetName = folderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func extractName(from item: [String: Any]) -> String {
            if let value = item["file_name"] as? String, !value.isEmpty { return value }
            if let value = item["name"] as? String, !value.isEmpty { return value }
            if let value = item["fileName"] as? String, !value.isEmpty { return value }
            if let value = item["title"] as? String, !value.isEmpty { return value }
            return ""
        }

        func extractFolderId(from item: [String: Any]) -> String? {
            for key in ["fid", "file_id", "obj_id", "id"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
                if let value = item[key] as? Int { return String(value) }
            }
            return nil
        }

        func looksLikeDirectory(_ item: [String: Any]) -> Bool {
            if let b = item["dir"] as? Bool { return b }
            if let i = item["dir"] as? Int { return i != 0 }
            if let s = item["dir"] as? String {
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return v == "1" || v == "true" || v == "yes"
            }
            if let file = item["file"] as? Bool { return file == false }
            if let fileType = item["file_type"] as? Int { return fileType == 0 }
            if let category = item["category"] as? String {
                let lowered = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowered == "folder" || lowered == "dir" || lowered == "directory" {
                    return true
                }
            }
            return false
        }

        func fetchList(page: Int, underscoreStyle: Bool) async throws -> ([[String: Any]]?, Int?, String?, String) {
            var request = URLRequest(url: listURL)
            request.httpMethod = "POST"
            quarkSetCommonHeaders(&request, cookie: currentCookie)
            let body: [String: Any]
            if underscoreStyle {
                // 版本A：参数带下划线（目前大部分接口使用这一套）
                body = [
                    "pdir_fid": "0",
                    "_sort": "file_type:asc,file_name:asc",
                    "_page": page,
                    "_size": pageSize,
                    "_fetch_total": 1
                ]
            } else {
                // 版本B：参数不带下划线（部分环境/接口返回结构更稳定）
                body = [
                    "pdir_fid": "0",
                    "sort_by": "file_name",
                    "sort_order": "asc",
                    "page": page,
                    "size": pageSize
                ]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, nil, nil, preview)
            }
            let code = json["code"] as? Int ?? (json["status"] as? Int)
            let message = json["message"] as? String ?? json["msg"] as? String
            if let code, code != 0 && code != 200 {
                return (nil, code, message, preview)
            }
            guard let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                return (nil, code, message, preview)
            }
            return (list, code, message, preview)
        }

        // 核心策略：先按名称匹配目标目录，命中后再提取 fid；并对两种分页参数风格做兼容兜底。
        for underscoreStyle in [true, false] {
            for page in 1...maxPages {
                let (listOpt, codeOpt, messageOpt, preview) = try await fetchList(page: page, underscoreStyle: underscoreStyle)
                guard let list = listOpt else {
                    if let codeOpt, let messageOpt {
                        self.log("[Quark] ⚠️ 根目录列表返回异常 style=\(underscoreStyle ? "underscore" : "plain") code=\(codeOpt) message=\(messageOpt)，preview=\(preview)")
                    } else {
                        self.log("[Quark] ⚠️ 根目录列表结构异常 style=\(underscoreStyle ? "underscore" : "plain")，preview=\(preview)")
                    }
                    break
                }

                self.log("[Quark] 根目录扫描 style=\(underscoreStyle ? "underscore" : "plain") page=\(page), count=\(list.count)")
                for item in list {
                    let name = extractName(from: item)
                    guard name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetName else { continue }
                    if let folderId = extractFolderId(from: item) {
                        if looksLikeDirectory(item) {
                            self.log("[Quark] ✅ 根目录命中 \(folderName) 文件夹 fid=\(folderId)")
                        } else {
                            self.log("[Quark] ⚠️ 命中名称为 \(folderName) 的对象，但目录字段不典型，仍先使用 fid=\(folderId), item=\(item)")
                        }
                        return (folderId, currentCookie)
                    } else {
                        self.log("[Quark] ⚠️ 命中 \(folderName) 但未提取到 fid，item=\(item)")
                    }
                }

                if list.count < pageSize { break }
            }
        }

        return nil
    }

    private func quarkExtractFirstFid(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["fid", "file_id", "pdir_fid", "obj_id", "target_fid", "conflict_fid", "exist_fid", "id"] {
                if let text = dict[key] as? String, !text.isEmpty { return text }
                if let number = dict[key] as? Int { return String(number) }
            }
            for item in dict.values {
                if let fid = quarkExtractFirstFid(from: item) { return fid }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let fid = quarkExtractFirstFid(from: item) { return fid }
            }
        }
        return nil
    }

    /// 夸克转存任务ID，用于轮询任务状态
    private var quarkLastSaveTaskId: String?

    /// 轮询夸克转存任务状态，等待文件落盘（对齐iBox抓包：GET /1/clouddrive/task）
    private func quarkPollTask(taskId: String, cookie: String, maxRetries: Int = 10, interval: TimeInterval = 1.0) async throws {
        self.log("[Quark] ⏳ 轮询转存任务状态: \(taskId)")
        for i in 0..<maxRetries {
            let url = quarkAPIURL("/1/clouddrive/task", extra: [
                URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "task_id", value: taskId),
                URLQueryItem(name: "retry_index", value: "0")
            ])
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            quarkSetCommonHeaders(&req, cookie: cookie)

            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                let status = d["status"] as? Int ?? -1
                let finish = d["finish"] as? Bool ?? false
                if finish || status == 2 {
                    self.log("[Quark] ✅ 转存任务完成: status=\(status), finish=\(finish)")
                    return
                }
                if status == 3 || status == -1 {
                    self.log("[Quark] ⚠️ 转存任务异常: status=\(status)，继续尝试播放")
                    return
                }
            }
            if i < maxRetries - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        self.log("[Quark] ⚠️ 转存任务轮询超时，继续尝试播放")
    }

    /// 获取夸克会员信息（对齐iBox抓包：GET /1/clouddrive/member）
    private func quarkGetMemberInfo(cookie: String) async -> String? {
        let url = quarkAPIURL("/1/clouddrive/member", extra: [
            URLQueryItem(name: "fetch_subscribe", value: "true"),
            URLQueryItem(name: "fetch_identity", value: "true"),
            URLQueryItem(name: "_ch", value: "home"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        quarkSetCommonHeaders(&req, cookie: cookie)

        do {
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                let memberType = d["member_type"] as? String ?? "normal"
                self.log("[Quark] 会员类型: \(memberType)")
                return memberType
            }
        } catch {
            self.log("[Quark] 获取会员信息失败: \(error.localizedDescription)")
        }
        return nil
    }

    private func quarkDeleteFiles(fileIds: [String], cookie: String) async -> String {
        guard !fileIds.isEmpty else { return cookie }
        var currentCookie = cookie
        let url = quarkAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        quarkSetCommonHeaders(&req, cookie: currentCookie)
        // 对齐 iBox：filelist 字段传字符串数组
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let deleteResult = try? await session.data(for: req)
        if let response = deleteResult?.1 {
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
        }
        self.log("[CloudDrive] ✅ 夸克已提交删除 \(fileIds.count) 个转存文件")

        // 彻底清理回收站（对齐iBox抓包：先 recycle/list 再 recycle/remove）
        if let data = deleteResult?.0,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let taskId = json["task_id"] as? String {
            // 等待删除任务完成
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // 查询回收站找到对应的记录
            let recycleURL = quarkAPIURL("/1/clouddrive/file/recycle/list", extra: [
                URLQueryItem(name: "_page", value: "1"),
                URLQueryItem(name: "_size", value: "100"),
                URLQueryItem(name: "_sort", value: "move_recycle_at:desc")
            ])
            var recycleReq = URLRequest(url: recycleURL)
            recycleReq.httpMethod = "GET"
            recycleReq.timeoutInterval = 10
            quarkSetCommonHeaders(&recycleReq, cookie: currentCookie)

            let recycleResult = try? await session.data(for: recycleReq)
            if let response = recycleResult?.1 {
                currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            }
            if let recycleData = recycleResult?.0,
               let recycleJSON = try? JSONSerialization.jsonObject(with: recycleData) as? [String: Any],
               let list = recycleJSON["data"] as? [[String: Any]] {
                // 找到刚删除的文件记录
                let recordIds = list.compactMap { item -> String? in
                    // record_id 格式: "taskId-fid-时间-recycleV2"
                    let recordId = item["record_id"] as? String ?? ""
                    if recordId.contains(taskId) || fileIds.contains(where: { recordId.contains($0) }) {
                        return recordId
                    }
                    return nil
                }
                if !recordIds.isEmpty {
                    let removeURL = quarkAPIURL("/1/clouddrive/file/recycle/remove")
                    var removeReq = URLRequest(url: removeURL)
                    removeReq.httpMethod = "POST"
                    quarkSetCommonHeaders(&removeReq, cookie: currentCookie)
                    let removeBody: [String: Any] = ["select_mode": 2, "record_list": recordIds]
                    removeReq.httpBody = try? JSONSerialization.data(withJSONObject: removeBody)
                    let removeResult = try? await session.data(for: removeReq)
                    if let response = removeResult?.1 {
                        currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                    }
                    self.log("[CloudDrive] ✅ 夸克已彻底清理回收站 \(recordIds.count) 条记录")
                }
            }
        }
        return currentCookie
    }

    private func quarkFirstPlayableFile(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> QuarkShareFile {
        let files = try await quarkGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie)
        if let playable = files.first(where: { !$0.isDir && quarkIsPlayableFileName($0.fileName) }) {
            return playable
        }
        for dir in files where dir.isDir {
            if let found = try? await quarkFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("夸克分享内未找到可播放视频")
    }

    // MARK: - 夸克网盘完整文件列表获取
    func quarkGetFileList(shareURL: String, cookie: String) async throws -> [QuarkShareFile] {
        let (pwdId, passcode) = quarkExtractShareInfo(shareURL: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        var authCookie = cookie
        let shareToken = try await quarkGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)

        var allPlayable: [QuarkShareFile] = []
        try await quarkCollectAllPlayableFiles(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie, result: &allPlayable)
        return allPlayable
    }

    private func quarkCollectAllPlayableFiles(pwdId: String, stoken: String, pdirFid: String, cookie: String, result: inout [QuarkShareFile]) async throws {
        var page = 1
        var hasMore = true
        while hasMore {
            let files = try await quarkGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie, page: page)
            for file in files where !file.isDir && quarkIsPlayableFileName(file.fileName) {
                result.append(file)
            }
            // 收集子目录，稍后递归
            var subDirs: [QuarkShareFile] = []
            for file in files where file.isDir {
                subDirs.append(file)
            }
            // 递归进入子目录
            for dir in subDirs {
                try await quarkCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie, result: &result)
            }
            hasMore = files.count >= 100
            page += 1
            if page > 20 { break } // 安全限制，最多20页
        }
    }

    private func quarkGetShareDetail(pwdId: String, stoken: String, pdirFid: String, cookie: String, page: Int = 1) async throws -> [QuarkShareFile] {
        let url = quarkAPIURLWithStrictQuery("/1/clouddrive/share/sharepage/detail", queryItems: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: String(page)),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "force", value: "0"),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "pwd_id", value: pwdId)
        ], strictQueryItems: [("stoken", stoken)])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let stokenHasPlus = stoken.contains("+")
        let encodedPlus = url.absoluteString.contains("%2B")
        self.log("[Quark] detail请求诊断 pdirFid=\(pdirFid), stokenLength=\(stoken.count), stokenHasPlus=\(stokenHasPlus), encodedPlus=\(encodedPlus)")
        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            self.log("[Quark] ❌ detail非JSON status=\(httpStatus), preview=\(preview)")
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            self.log("[Quark] ❌ detail失败 status=\(httpStatus), code=\(code), message=\(message), preview=\(preview)")
            throw DriveError.noPlayURL("夸克文件列表失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            throw DriveError.noPlayURL("夸克文件列表为空")
        }
        return list.compactMap { item in
            let fid = item["fid"] as? String ?? ""
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let token = item["share_fid_token"] as? String ?? item["fid_token"] as? String ?? ""
            let isDir = (item["dir"] as? Bool) ?? ((item["file"] as? Bool) == false && (item["file_type"] as? Int) == 0)
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            return QuarkShareFile(fid: fid, fileName: name, shareFidToken: token, pdirFid: pdirFid, isDir: isDir)
        }
    }

    private func quarkIsPlayableFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "mp3", "m4a"].contains { lower.hasSuffix(".\($0)") }
    }

    private func quarkSaveShare(pwdId: String, stoken: String, file: QuarkShareFile, folderId: String, cookie: String) async throws -> [String] {
        let url = quarkAPIURL("/1/clouddrive/share/sharepage/save", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie, referer: quarkShareReferer(pwdId: pwdId))
        let body: [String: Any] = [
            "fid_list": [file.fid],
            "fid_token_list": [file.shareFidToken],
            "to_pdir_fid": folderId,
            "pwd_id": pwdId,
            "stoken": stoken,
            "pdir_fid": file.pdirFid,
            "scene": "link",
            "platform_original": "chrome",
            "nu_distribute": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        self.log("[Quark] save响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.log("[Quark] ❌ 转存响应非JSON")
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            self.log("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            self.log("[Quark] ❌ 转存失败: code=\(code), message=\(message)")
            // 检测容量/配额相关错误，给出更明确的提示
            let lowerMsg = message.lowercased()
            if lowerMsg.contains("空间") || lowerMsg.contains("容量") || lowerMsg.contains("quota")
               || lowerMsg.contains("full") || lowerMsg.contains("insufficient") || lowerMsg.contains("超限") {
                throw DriveError.noPlayURL("夸克容量不足，无法转存此文件。请清理夸克云盘空间后重试")
            }
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let d = json["data"] as? [String: Any] {
            // 保存task_id用于后续轮询
            if let taskId = d["task_id"] as? String {
                quarkLastSaveTaskId = taskId
                self.log("[Quark] 转存任务ID: \(taskId)")
            }
            let taskResp = d["task_resp"] as? [String: Any]
            let taskData = taskResp?["data"] as? [String: Any]
            let saveAs = taskData?["save_as"] as? [String: Any]
            if let ids = saveAs?["save_as_top_fids"] as? [String], !ids.isEmpty {
                self.log("[Quark] ✅ 转存成功，save_as_top_fids: \(ids)")
                // save_as_top_fids 可能返回文件夹ID(如"0")而非文件ID
                if ids.allSatisfy({ $0 == "0" || $0 == folderId }) {
                    self.log("[Quark] ⚠️ save_as_top_fids 返回的是目录ID，尝试按文件名查找实际fid")
                } else {
                    return ids
                }
            }
            if let ids = saveAs?["save_as_select_top_fids"] as? [String], !ids.isEmpty {
                self.log("[Quark] ✅ 转存成功，save_as_select_top_fids: \(ids)")
                if ids.allSatisfy({ $0 == "0" || $0 == folderId }) {
                    self.log("[Quark] ⚠️ save_as_select_top_fids 返回的是目录ID，尝试按文件名查找实际fid")
                } else {
                    return ids
                }
            }
            if let ids = d["file_ids"] as? [String], !ids.isEmpty {
                return ids
            }
            if let list = d["list"] as? [[String: Any]], !list.isEmpty {
                let ids = list.compactMap { $0["fid"] as? String ?? $0["file_id"] as? String }
                if !ids.isEmpty {
                    return ids
                }
            }
        }

        let recursiveIds = quarkExtractSavedFileIds(from: json, excluding: file.fid)
        if !recursiveIds.isEmpty {
            self.log("[Quark] ✅ 转存成功，递归提取 fid: \(recursiveIds)")
            return recursiveIds
        }

        if let existingId = await quarkFindSavedFileId(fileName: file.fileName, folderId: folderId, cookie: cookie) {
            self.log("[Quark] ✅ 转存目录已存在同名文件，使用 fid=\(existingId)")
            return [existingId]
        }

        throw DriveError.noPlayURL("夸克转存成功但未返回已转存 fid")
    }

    private func quarkExtractSavedFileIds(from value: Any, excluding sourceFid: String) -> [String] {
        var result: [String] = []

        func append(_ raw: Any, key: String) {
            let lowerKey = key.lowercased()
            guard lowerKey.contains("fid") || lowerKey.contains("file_id") else { return }
            guard !lowerKey.contains("token") else { return }
            if let text = raw as? String, !text.isEmpty, text != sourceFid {
                result.append(text)
            } else if let number = raw as? Int {
                let text = String(number)
                if text != sourceFid { result.append(text) }
            } else if let texts = raw as? [String] {
                result.append(contentsOf: texts.filter { !$0.isEmpty && $0 != sourceFid })
            } else if let numbers = raw as? [Int] {
                result.append(contentsOf: numbers.map(String.init).filter { $0 != sourceFid })
            }
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (key, item) in dict {
                    append(item, key: key)
                    walk(item)
                }
            } else if let array = node as? [Any] {
                for item in array { walk(item) }
            }
        }

        walk(value)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private func quarkFindSavedFileId(fileName: String, folderId: String, cookie: String) async -> String? {
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 800_000_000)
            }

            let url = quarkAPIURL("/1/clouddrive/file/sort")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            quarkSetCommonHeaders(&request, cookie: cookie)
            let body: [String: Any] = [
                "pdir_fid": folderId,
                "sort_by": "file_name",
                "sort_order": "asc",
                "page": 1,
                "size": 100
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, _) = try? await session.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                continue
            }

            for item in list {
                let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
                guard name == fileName else { continue }
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fileId = item["file_id"] as? String, !fileId.isEmpty { return fileId }
                if let fid = item["fid"] as? Int { return String(fid) }
                if let fileId = item["file_id"] as? Int { return String(fileId) }
            }
        }
        return nil
    }

    /// 查找"来自：分享"目录的fid，用于二次查找转存文件
    private func quarkFindShareOriginFolder(cookie: String) async -> String? {
        let url = quarkAPIURL("/1/clouddrive/file/sort")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "sort_by": "updated_at",
            "sort_order": "desc",
            "page": 1,
            "size": 50
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            return nil
        }

        for item in list {
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            if name.contains("来自") && name.contains("分享") {
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fid = item["fid"] as? Int { return String(fid) }
            }
        }
        return nil
    }

    /// 对齐iBox原画抓包：调用 acquire_dl_token 获取加速下载token
    /// 注意：这个接口的Host是 drive-social-api.quark.cn，不是 drive-pc.quark.cn
    private func quarkAcquireDLToken(cookie: String) async throws -> String {
        var components = URLComponents(string: "https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/acquire_dl_token")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ]
        guard let url = components.url else {
            throw DriveError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "conversation_id": "300000\(timestamp)",
            "conversation_type": 3,
            "msg_id": "\(timestamp)000"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 acquire_dl_token 失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let token = dataObj["token"] as? String, !token.isEmpty else {
            throw DriveError.noPlayURL("夸克 acquire_dl_token 未返回token")
        }
        self.log("[Quark] 获取到加速下载token")
        return token
    }

    private func quarkGetDownloadURL(fileId: String, cookie: String) async throws -> (url: String, fileName: String) {
        // 先获取加速token（对齐iBox原画抓包）
        var dlToken: String? = nil
        do {
            dlToken = try await quarkAcquireDLToken(cookie: cookie)
        } catch {
            self.log("[Quark] ⚠️ acquire_dl_token 失败，继续尝试普通下载：\(error.localizedDescription)")
        }

        let url = quarkAPIURL("/1/clouddrive/file/download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        // 对齐iBox原画抓包：增加 speedup_session 和 token（加速token）
        var body: [String: Any] = [
            "fids": [fileId],
            "speedup_session": ""
        ]
        if let dlToken = dlToken, !dlToken.isEmpty {
            body["token"] = dlToken
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 download_url 获取失败：\(message)")
        }
        guard let list = json["data"] as? [[String: Any]],
              let first = list.first else {
            throw DriveError.noPlayURL("夸克未返回 download_url 数据")
        }
        let downloadURL = first["download_url"] as? String ?? ""
        let fileName = first["file_name"] as? String ?? ""
        let ext = (fileName as NSString).pathExtension.lowercased()
        if downloadURL.isEmpty {
            self.log("[Quark] ⚠️ download_url 为空 (文件: \(fileName), 扩展名: \(ext))，将使用v2/play转码")
        } else {
            self.log("[Quark] 📥 download_url 已获取 (文件: \(fileName), 扩展名: \(ext))")
        }
        return (downloadURL, fileName)
    }

    private func quarkGetPlayURL(fileId: String, cookie: String) async throws -> String {
        let info = try await quarkRefreshVideoAuth(fileId: fileId, cookie: cookie)
        return info.playURL
    }

    /// 递归查找文件夹内的第一个视频文件 fid（BFS，优先第一层）
    /// 用于 v2/play 返回 "not video" 时，从文件夹 fid 定位到实际视频文件
    private func quarkFindFirstVideoInFolder(folderId: String, cookie: String) async -> String? {
        var currentCookie = cookie
        let videoExts = [".mp4", ".mkv", ".avi", ".ts", ".mov", ".flv", ".wmv", ".m4v", ".3gp", ".webm", ".rmvb", ".rm", ".mpg", ".mpeg"]

        // BFS: 先查第一层，再递归子文件夹
        var queue: [String] = [folderId]
        var visited = Set<String>()
        let maxDepth = 3  // 最多递归 3 层，避免无限循环
        var depth = 0

        while !queue.isEmpty && depth < maxDepth {
            let levelCount = queue.count
            for _ in 0..<levelCount {
                let fid = queue.removeFirst()
                guard !visited.contains(fid) else { continue }
                visited.insert(fid)

                let extra = [
                    URLQueryItem(name: "pdir_fid", value: fid),
                    URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc"),
                    URLQueryItem(name: "_page", value: "1"),
                    URLQueryItem(name: "_size", value: "200"),
                    URLQueryItem(name: "_fetch_total", value: "1")
                ]
                let listURL = quarkAPIURL("/1/clouddrive/file/sort", extra: extra)
                var request = URLRequest(url: listURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 10
                quarkSetCommonHeaders(&request, cookie: currentCookie)

                guard let (data, response) = try? await session.data(for: request) else { continue }
                currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else { continue }

                var subFolders: [String] = []

                for item in list {
                    let isDir = (item["file_type"] as? Int) == 0 || (item["is_dir"] as? Bool) == true
                    let name = (item["file_name"] as? String ?? item["name"] as? String ?? "").lowercased()

                    var itemFid = ""
                    for key in ["fid", "file_id"] {
                        if let f = item[key] as? String, !f.isEmpty {
                            itemFid = f
                            break
                        } else if let f = item[key] as? Int {
                            itemFid = String(f)
                            break
                        }
                    }
                    guard !itemFid.isEmpty else { continue }

                    if isDir {
                        subFolders.append(itemFid)
                    } else if videoExts.contains(where: { name.hasSuffix($0) }) {
                        // 找到视频文件，直接返回
                        self.log("[Quark] 🎯 找到视频文件: \(name) (fid=\(itemFid))")
                        return itemFid
                    }
                }

                // 本层没找到视频，把子文件夹加入队列
                queue.append(contentsOf: subFolders)
            }
            depth += 1
        }

        return nil
    }

    private func quarkRefreshVideoAuth(fileId: String, cookie: String) async throws -> (playURL: String, cookie: String) {
        let url = quarkAPIURL("/1/clouddrive/file/v2/play")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "fid": fileId,
            "resolutions": "normal,low,high,super,2k,4k",
            "supports": "fmp4,m3u8"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 v2/play 失败：\(message)")
        }
        if let dataObj = json["data"] as? [String: Any],
           let videos = dataObj["video_list"] as? [[String: Any]] {
            // [优化] 优先选择最低码率的可用转码流，保证秒开和流畅播放
            // 夸克 video_list 按清晰度从高到低排列(4k→super→high→normal→low)
            // 普通会员限速下，low(480p/400kbps) 最流畅，normal/high 码率高容易卡
            // 诊断：打印所有可用转码流信息
            for item in videos {
                if let info = item["video_info"] as? [String: Any] {
                    let res = info["resolution"] as? String ?? "?"
                    let w = info["width"] as? Int ?? 0
                    let h = info["height"] as? Int ?? 0
                    let br = info["bitrate"] as? Double ?? 0
                    let access = item["accessable"] as? Bool ?? true
                    self.log("[Quark] 可用转码流: \(res) \(w)x\(h) \(Int(br))kbps accessable=\(access)")
                }
            }
            let qualityOrder = ["low", "normal", "high", "super", "2k", "4k"]
            for quality in qualityOrder {
                for item in videos {
                    guard let info = item["video_info"] as? [String: Any],
                          let res = info["resolution"] as? String,
                          res == quality else { continue }
                    guard (item["accessable"] as? Bool) != false,
                          let url = info["url"] as? String,
                          !url.isEmpty else { continue }
                    let bitrate = (info["bitrate"] as? Double) ?? 0
                    let width = (info["width"] as? Int) ?? 0
                    let height = (info["height"] as? Int) ?? 0
                    self.log("[Quark] 选中转码流: \(quality) \(width)x\(height) \(Int(bitrate))kbps")
                    return (url, mergedCookie)
                }
            }
            // 兜底：如果按质量排序没找到，返回第一个可用的
            for item in videos {
                guard (item["accessable"] as? Bool) != false,
                      let info = item["video_info"] as? [String: Any],
                      let url = info["url"] as? String,
                      !url.isEmpty else { continue }
                return (url, mergedCookie)
            }
        }
        if let playURL = json["play_url"] as? String, !playURL.isEmpty {
            return (playURL, mergedCookie)
        }
        return ("", mergedCookie)
    }

    // MARK: - 夸克原生扫码登录（测试版）
    // 抓包显示 PC 客户端走 uop.quark.cn/cas/ajax 三步：
    //  1. getTokenForQrcodeLogin → 拿 token
    //  2. getServiceTicketByQrcodeToken（轮询，未扫返回 50004001）
    //  3. 拿到 service_ticket 后，请求 pan.quark.cn/account/info?st=... 让服务端 set-cookie

    struct QuarkQrLoginToken {
        let token: String
        let clientId: String   // 生成 token 时使用 386；轮询时 PC 抓包用 532，这里都保留
        let pollClientId: String
        let qrPayload: String   // 真实二维码内容，抓包为 su.quark.cn 跳转链接，不是 token 原文
    }

    enum QuarkQrPollResult {
        case pending
        case scanned       // 兼容字段，目前接口不区分
        case success(serviceTicket: String)
        case expired
        case failed(message: String)
    }

    struct QuarkQrLoginResult {
        let cookie: String                    // 拼好的 Cookie 字符串：__pus=...; __puus=...; ...
        let cookies: [String: String]         // 单独字段，便于调试展示
        let nickName: String?
        let avatarURL: String?
    }

    /// 第一步：生成扫码登录 token，并拼出抓包里的二维码跳转链接。
    func quarkCreateQrToken(clientId: String = "386", pollClientId: String = "532") async throws -> QuarkQrLoginToken {
        var components = URLComponents(string: "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased())
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.noPlayURL("夸克: 获取扫码 token HTTP 失败")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        let status = (json["status"] as? Int) ?? -1
        guard status == 2000000,
              let dataObj = json["data"] as? [String: Any],
              let members = dataObj["members"] as? [String: Any],
              let token = members["token"] as? String, !token.isEmpty else {
            let message = (json["message"] as? String) ?? "夸克扫码 token 接口异常"
            throw DriveError.noPlayURL("夸克: \(message)")
        }
        let qrPayload = quarkQRCodePayload(token: token, clientId: pollClientId)
        return QuarkQrLoginToken(token: token, clientId: clientId, pollClientId: pollClientId, qrPayload: qrPayload)
    }

    private func quarkQRCodePayload(token: String, clientId: String) -> String {
        var components = URLComponents(string: "https://su.quark.cn/4_eMHBJ")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "ssb", value: "weblogin"),
            URLQueryItem(name: "uc_param_str", value: ""),
            URLQueryItem(name: "uc_biz_str", value: "S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0")
        ]
        return components.url?.absoluteString ?? "https://su.quark.cn/4_eMHBJ?token=\(token)&client_id=\(clientId)&ssb=weblogin"
    }

    /// 第二步：轮询扫码状态。pending 表示用户还没扫码或还没确认；success 时返回 service_ticket。
    func quarkPollQrStatus(token: QuarkQrLoginToken) async throws -> QuarkQrPollResult {
        var components = URLComponents(string: "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: token.pollClientId),
            URLQueryItem(name: "v", value: "1.2"),
            URLQueryItem(name: "request_id", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "token", value: token.token)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        let status = (json["status"] as? Int) ?? -1
        let message = (json["message"] as? String) ?? ""
        switch status {
        case 2000000:
            if let dataObj = json["data"] as? [String: Any],
               let members = dataObj["members"] as? [String: Any],
               let ticket = members["service_ticket"] as? String, !ticket.isEmpty {
                return .success(serviceTicket: ticket)
            }
            return .failed(message: "未返回 service_ticket")
        case 50004001:
            return .pending
        case 50004002, 50004003, 50004004:
            return .expired
        default:
            return .failed(message: "状态码 \(status) \(message)")
        }
    }

    /// 第三步：用 service_ticket 换取浏览器侧 Cookie。响应里的 set-cookie 就是登录态。
    func quarkExchangeServiceTicket(serviceTicket: String) async throws -> QuarkQrLoginResult {
        var components = URLComponents(string: "https://pan.quark.cn/account/info")!
        components.queryItems = [
            URLQueryItem(name: "st", value: serviceTicket),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "platform", value: "pc")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("https://pan.quark.cn", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        // 使用一次性配置以拿到 set-cookie
        let oneShotConfig = URLSessionConfiguration.ephemeral
        oneShotConfig.httpCookieAcceptPolicy = .always
        oneShotConfig.httpShouldSetCookies = true
        let oneShotSession = URLSession(configuration: oneShotConfig)
        defer { oneShotSession.finishTasksAndInvalidate() }

        let (data, response) = try await oneShotSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DriveError.noPlayURL("夸克: account/info HTTP 失败")
        }

        // 解析 set-cookie 头（合并多行的几种 case）
        var cookieDict: [String: String] = [:]
        var stringHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            stringHeaders["\(key)"] = "\(value)"
        }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: URL(string: "https://pan.quark.cn")!)
        for c in responseCookies { cookieDict[c.name] = c.value }

        if let storage = oneShotSession.configuration.httpCookieStorage,
           let cookies = storage.cookies(for: URL(string: "https://pan.quark.cn")!) {
            for c in cookies { cookieDict[c.name] = c.value }
        }
        // 兜底再从响应头里抓一遍
        let headers = http.allHeaderFields
        if let raw = headers["Set-Cookie"] as? String {
            for piece in raw.components(separatedBy: ", ") {
                if let kv = piece.components(separatedBy: ";").first,
                   let eq = kv.firstIndex(of: "=") {
                    let key = String(kv[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty && cookieDict[key] == nil { cookieDict[key] = value }
                }
            }
        }

        // 必备字段校验
        let mustHave = ["__kps", "__pus", "__uid"]
        for key in mustHave where (cookieDict[key] ?? "").isEmpty {
            throw DriveError.noPlayURL("夸克: 未拿到 \(key) Cookie，可能扫码授权失败")
        }

        // 解析昵称/头像（如果接口返回）
        var nick: String? = nil
        var avatar: String? = nil
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let dataObj = json["data"] as? [String: Any] {
                nick = (dataObj["nickname"] as? String) ?? (dataObj["nick_name"] as? String)
                avatar = (dataObj["avatarUri"] as? String) ?? (dataObj["avatar_uri"] as? String)
            }
            if nick == nil { nick = json["nickname"] as? String }
        }

        let cookieString = cookieDict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return QuarkQrLoginResult(cookie: cookieString, cookies: cookieDict, nickName: nick, avatarURL: avatar)
    }

    // MARK: - 百度网盘

    private func parseBaiduToken(_ raw: String) -> (cookie: String, bdussOnly: String) {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression) != nil {
            let normalizedCookie = input
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
                .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)

            var bduss = ""
            if let r1 = normalizedCookie.range(of: #"BDUSS=([^;|]+)"#, options: .regularExpression),
               let eq = normalizedCookie[r1].firstIndex(of: "=") {
                bduss = String(normalizedCookie[normalizedCookie.index(after: eq)..<r1.upperBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if !bduss.isEmpty {
                // 完整 Cookie 模式：如果用户粘贴了 BDUSS/STOKEN/BAIDUID 等多字段，
                // 不再只截取 BDUSS/STOKEN，直接原样交给 iBox-style 本机路链使用。
                return (normalizedCookie, bduss)
            }
        }

        if input.contains("|") {
            let cleaned = input.replacingOccurrences(of: #"^BDUSS="#, with: "", options: .regularExpression)
            let parts = cleaned.components(separatedBy: "|")
            let bduss = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var cookie = "BDUSS=\(bduss)"
            if parts.count >= 2 {
                let stoken = parts[1].replacingOccurrences(of: #"^STOKEN="#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                cookie += "; STOKEN=\(stoken)"
            }
            return (cookie, bduss)
        }

        let bduss = input.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ("BDUSS=\(bduss)", bduss)
    }

    private func normalizeBaiduPCSCookie(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "; ")
            .replacingOccurrences(of: "\r", with: "; ")
            .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
            .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)
    }

    func baiduGetFileList(shareURL: String, bduss: String) async throws -> [BaiduFileItem] {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let cacheKey = baiduFileListCacheKey(shareURL: shareURL, bduss: bduss)

        if let cached = baiduCachedFileList(for: cacheKey) {
            baiduLog("[Baidu-iBox] ✅ 命中文件列表缓存：\(cached.count) 个文件")
            recordBaiduRouteDiagnostic(stage: "文件列表", status: "缓存命中", detail: "命中百度文件列表缓存：\(cached.count) 个文件")
            return cached
        }

        baiduLog("[Baidu-iBox] 文件列表走 iBox-style 本机路链：wap/init → verify → share页/yunData → gettemplatevariable → share/list")
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "iBox开始", detail: "本机 /wap/init + verify + share页/yunData + gettemplatevariable + share/list(web=1)，不走 Worker")
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        let files = context.files
        baiduStoreFileList(files, for: cacheKey)
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "iBox成功", detail: "share/list 返回 \(files.count) 个文件")
        return files
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: nil, pcsCookie: pcsCookie)
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, pwd: String?, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLInternal(shareURL: shareURL, bduss: bduss, pwd: pwd, pcsCookie: pcsCookie)
    }

    private func extractBaiduPwd(from shareURL: String) -> String? {
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#)
            .firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let range = Range(match.range(at: 1), in: shareURL) {
            return String(shareURL[range])
        }
        let patterns = [
            #"提取码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"密码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"码[:：\s]*([A-Za-z0-9]{4,8})"#,
            #"[?&]pwd=([^&\s#]+)"#,
            #"[?&]password=([^&\s#]+)"#
        ]
        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                .firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
               let range = Range(match.range(at: 1), in: shareURL) {
                return String(shareURL[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func baiduExtractSurl(from shareURL: String) throws -> String {
        if let match = try? NSRegularExpression(pattern: #"/s/([^/?#]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let range = Range(match.range(at: 1), in: shareURL) {
            return String(shareURL[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw DriveError.invalidShareURL
    }

    private func baiduShortSurl(_ surl: String) -> String {
        surl.hasPrefix("1") ? String(surl.dropFirst()) : surl
    }

    private func baiduResolveViaIBoxPlayItem(
        cacheKey: String,
        shareURL: String,
        fsId: String,
        fileName: String?,
        cookie: String,
        pcsCookie: String
    ) async throws -> PlayResult? {
        guard let item = baiduCachedIBoxPlayItem(for: cacheKey) else { return nil }
        let now = Date()

        if let expiresAt = item.dlinkExpiresAt,
           expiresAt > now.addingTimeInterval(5 * 60),
           let dlink = item.dlinkURL,
           !dlink.isEmpty {
            baiduLog("[Baidu-iBox] ✅ 命中已准备 dlink：fsId=\(fsId), source=\(item.source), engine=\(item.preferredEngine)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "dlink命中", detail: "命中已准备 dlink，source=\(item.source), engine=\(item.preferredEngine)", fsId: fsId, fileName: item.fileName)
            baiduStoreIBoxPlayItem(
                BaiduIBoxPlayItem(
                    shareURL: item.shareURL,
                    fsId: item.fsId,
                    fileName: item.fileName,
                    path: item.path,
                    dlinkURL: item.dlinkURL,
                    headers: item.headers,
                    dlinkExpiresAt: item.dlinkExpiresAt,
                    compatibilityHint: item.compatibilityHint,
                    preferredEngine: item.preferredEngine,
                    preparedAt: item.preparedAt,
                    updatedAt: now,
                    lastUsedAt: now,
                    source: item.source
                ),
                for: cacheKey
            )
            return PlayResult(url: dlink, headers: item.headers, driveType: .baidu)
        }

        guard !item.path.isEmpty else { return nil }
        baiduLog("[Baidu-iBox] ♻️ dlink 过期/缺失，用 PlayItem path 刷新：\(item.path)")
        recordBaiduRouteDiagnostic(stage: "iBox", status: "path刷新", detail: "dlink 过期/缺失，使用 path 刷新：\(item.path)", fsId: fsId, fileName: item.fileName)
        let mergedCookie = baiduMergeCookieStrings([
            item.headers.first { $0.key.lowercased() == "cookie" }?.value ?? "",
            cookie
        ])
        guard !mergedCookie.isEmpty else {
            baiduLog("[Baidu-iBox] ⚠️ path 刷新缺少 Cookie，转入 iBox 主路链重新验证/转存")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "Cookie缺失", detail: "path 刷新缺少 Cookie，转入 iBox 主路链重新验证/转存", fsId: fsId, fileName: item.fileName)
            return nil
        }

        var mediainfoFallback: PlayResult?
        do {
            mediainfoFallback = try await baiduGetDLNADlinkOnDevice(filePath: item.path, cookie: mergedCookie, source: "ibox-mediainfo-fallback")
            baiduLog("[Baidu-iBox] ✅ mediainfo 探测完成，继续 locatedownload")
        } catch {
            baiduLog("[Baidu-iBox] ⚠️ mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "mediainfo失败", detail: "path mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
        }
        let refreshed: PlayResult
        do {
            refreshed = try await baiduGetLocatedownloadOnDevice(filePath: item.path, cookie: mergedCookie)
        } catch {
            if let mediainfoFallback {
                baiduLog("[Baidu-iBox] ⚠️ locatedownload 失败，使用 mediainfo dlink 兜底：\(error.localizedDescription)")
                refreshed = mediainfoFallback
            } else {
                throw error
            }
        }

        let finalFileName = item.fileName.isEmpty ? (fileName ?? item.path.split(separator: "/").last.map(String.init) ?? "") : item.fileName
        baiduStoreIBoxPlayItem(
            BaiduIBoxPlayItem(
                shareURL: shareURL,
                fsId: fsId,
                fileName: finalFileName,
                path: item.path,
                dlinkURL: refreshed.url,
                headers: refreshed.headers,
                dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                compatibilityHint: baiduCompatibilityHint(fileName: finalFileName),
                preferredEngine: baiduPreferredEngine(fileName: finalFileName),
                preparedAt: item.preparedAt,
                updatedAt: Date(),
                lastUsedAt: Date(),
                source: "ibox-path-refresh"
            ),
            for: cacheKey
        )
        baiduStorePlayResult(refreshed, for: cacheKey)
        baiduLog("[Baidu-iBox] ✅ path 刷新完成：\(item.path)")
        recordBaiduRouteDiagnostic(stage: "iBox", status: "path刷新成功", detail: "path 刷新完成：\(item.path)", fsId: fsId, fileName: finalFileName)
        return refreshed
    }

    /// 严格对齐 iBox：创建目录 / 转存 / 列目录这些「用户态私域接口」
    /// 必须使用登录态 bdstoken，不能复用分享页 yunData 里的 bdstoken；
    /// 否则百度会判定为越权，统一返回 errno=-6 path:""。
    private func baiduFetchUserBdstokenLocal(cookie: String) async -> String? {
        let savedBdstoken = CloudDriveAuthManager.shared.credential(for: .baidu)?.extra["bdstoken"]

        var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: "[\"bdstoken\",\"token\",\"uk\",\"isdocuser\",\"servertime\"]")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
        if let (data, _) = try? await session.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errno = json["errno"] as? Int ?? 0
            if let token = baiduDeepString(json, keys: ["bdstoken"]), !token.isEmpty {
                baiduLog("[Baidu-Local] ✅ 取得登录态 bdstoken：\(token.prefix(6))…")
                baiduPersistUserBdstoken(token, mergedCookie: cookie, source: "urlsession-templatevariable")
                return token
            }
            baiduLog("[Baidu-Local] ⚠️ gettemplatevariable 未返回 bdstoken：errno=\(errno), keys=\(json.keys.sorted().joined(separator: ",")), \(baiduJSONStructureSummary(json["result"], label: "result"))")
        }
        // 回退：直接抓 iBox 登录目标页 disk/main 页面里的用户态 bdstoken
        var pageRequest = URLRequest(url: URL(string: "https://pan.baidu.com/disk/main")!)
        pageRequest.timeoutInterval = 12
        pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        pageRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: pageRequest),
           let html = String(data: data, encoding: .utf8) {
            if let token = baiduExtractBdstokenFromHTML(html), !token.isEmpty {
                baiduLog("[Baidu-Local] ✅ 从 disk/main 抓到 bdstoken：\(token.prefix(6))…")
                baiduPersistUserBdstoken(token, mergedCookie: cookie, source: "urlsession-disk-main")
                return token
            }
            baiduLog("[Baidu-Local] ⚠️ disk/main 未解析到 bdstoken：htmlSize=\(html.count)")
        }
        if let token = await baiduFetchUserBdstokenViaWebView(cookie: cookie) {
            return token
        }
        if let saved = savedBdstoken, !saved.isEmpty {
            baiduLog("[Baidu-Local] ⚠️ 本次未抓到新 bdstoken，临时回退授权中心保存值：\(saved.prefix(6))…")
            return saved
        }
        baiduLog("[Baidu-Local] ⚠️ 未能抓到登录态 bdstoken")
        return nil
    }

    /// 对齐 iBox 的真实浏览器会话：原生 URLSession 无法生成用户态 bdstoken 时，
    /// 使用 WKWebView 载入 pan.baidu.com/disk/main，并复用 WebView CookieJar 中的登录态。
    private func baiduFetchUserBdstokenViaWebView(cookie: String) async -> String? {
        do {
            let result = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie)
            let token = result.bdstoken ?? baiduExtractBdstokenFromHTML(result.html)
            guard let token, !token.isEmpty else {
                baiduLog("[Baidu-Local] ⚠️ WebView disk/main 未解析到 bdstoken：htmlSize=\(result.html.count), cookieHasBDUSS=\(result.cookie.lowercased().contains("bduss=")), cookieHasSTOKEN=\(result.cookie.lowercased().contains("stoken="))")
                return nil
            }
            baiduPersistUserBdstoken(token, mergedCookie: result.cookie, source: "webview-disk-main")
            baiduLog("[Baidu-Local] ✅ WebView 取得登录态 bdstoken：\(token.prefix(6))…")
            return token
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView 获取 bdstoken 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduPersistUserBdstoken(_ token: String, mergedCookie: String, source: String) {
        guard !token.isEmpty,
              var credential = CloudDriveAuthManager.shared.credential(for: .baidu) else { return }
        let cookie = baiduMergeCookieStrings([credential.cookie ?? "", mergedCookie])
        if !cookie.isEmpty {
            credential.cookie = cookie
        }
        credential.extra["bdstoken"] = token
        credential.extra["bdstoken_source"] = source
        credential.updatedAt = Date()
        credential.lastCheckedAt = Date()
        credential.state = .valid
        credential.statusMessage = "百度登录态已补齐 bdstoken"
        CloudDriveAuthManager.shared.saveCredential(credential, syncLegacyToken: false)
    }

    private func baiduExtractBdstokenFromHTML(_ html: String) -> String? {
        let patterns = [
            #"["']bdstoken["']\s*:\s*["']([^"']+)["']"#,
            #"bdstoken\s*=\s*["']([^"']+)["']"#,
            #"bdstoken=([A-Za-z0-9_\-%.]+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let token = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token.removingPercentEncoding ?? token }
            }
        }
        return nil
    }

    private func baiduJSONStructureSummary(_ value: Any?, label: String) -> String {
        guard let value else { return "\(label)=nil" }
        if let dict = value as? [String: Any] {
            return "\(label)Type=dict,\(label)Keys=\(dict.keys.sorted().joined(separator: ","))"
        }
        if let array = value as? [Any] {
            let firstType: String
            if let first = array.first {
                firstType = String(describing: Swift.type(of: first))
            } else {
                firstType = "empty"
            }
            return "\(label)Type=array,\(label)Count=\(array.count),first=\(firstType)"
        }
        if let text = value as? String {
            return "\(label)Type=string,\(label)Length=\(text.count)"
        }
        return "\(label)Type=\(String(describing: Swift.type(of: value)))"
    }

    private func baiduDeepString(_ value: Any, keys: Set<String>) -> String? {
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where keys.contains(key.lowercased()) {
                if let text = raw as? String, !text.isEmpty { return text }
                if let number = raw as? NSNumber { return number.stringValue }
            }
            for raw in dict.values {
                if let found = baiduDeepString(raw, keys: keys), !found.isEmpty { return found }
                if let text = raw as? String,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data),
                   let found = baiduDeepString(json, keys: keys),
                   !found.isEmpty {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = baiduDeepString(raw, keys: keys), !found.isEmpty { return found }
            }
        }
        return nil
    }

    private func baiduEnsureVboxFolderLocal(cookie: String, bdstoken: String, referer: String) async throws {
        let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
        if try await baiduCanListTransferDir(cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA) {
            return
        }

        var lastResponse = ""
        for folder in [Self.baiduIBoxTransferDir] {
            var components = URLComponents(string: "https://pan.baidu.com/api/create")!
            components.queryItems = [
                URLQueryItem(name: "a", value: "commit"),
                URLQueryItem(name: "bdstoken", value: bdstoken),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(webUA, forHTTPHeaderField: "User-Agent")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            // 严格对齐 iBox 抓包：必须带 size=0、method=post，block_list 的 [] 也要 URL 编码
            let encodedPath = folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folder
            let encodedBlockList = "[]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B%5D"
            request.httpBody = "path=\(encodedPath)&size=0&isdir=1&block_list=\(encodedBlockList)&method=post".data(using: .utf8)

            let (data, _) = try await session.data(for: request)
            lastResponse = String(data: data.prefix(220), encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errno = json["errno"] as? Int,
               errno == 0 || errno == -8 {
                continue
            }
            baiduLog("[Baidu-Local] ⚠️ api/create \(folder) 响应：\(lastResponse)")
            try await baiduCreateFolderByFileManager(path: folder, cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA)
            if lastResponse.contains(#""errno":-6"#) || lastResponse.contains(#""errno": -6"#) {
                let ok = await baiduCreateFolderViaWebView(path: folder, cookie: cookie, bdstoken: bdstoken)
                if ok {
                    baiduLog("[Baidu-Local] ✅ WebView XHR create \(folder) 成功或已存在")
                }
            }
        }

        let canListByURLSession = try await baiduCanListTransferDir(cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA)
        let canList: Bool
        if canListByURLSession {
            canList = true
        } else {
            canList = await baiduCanListTransferDirViaWebView(cookie: cookie, bdstoken: bdstoken)
        }
        guard canList else {
            throw DriveError.noPlayURL("百度 vbox 转存目录创建失败：\(lastResponse)")
        }
    }

    private func baiduCreateFolderViaWebView(path: String, cookie: String, bdstoken: String) async -> Bool {
        do {
            let page = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: true)
            let effectiveBdstoken = page.bdstoken ?? bdstoken
            var components = URLComponents(string: "https://pan.baidu.com/api/create")!
            components.queryItems = [
                URLQueryItem(name: "a", value: "commit"),
                URLQueryItem(name: "bdstoken", value: effectiveBdstoken),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            let encodedBlockList = "[]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B%5D"
            let body = "path=\(encodedPath)&size=0&isdir=1&block_list=\(encodedBlockList)&method=post"
            let result = try await BaiduWebViewBridge.shared.request(
                url: components.url!.absoluteString,
                method: "POST",
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Requested-With": "XMLHttpRequest"
                ],
                body: body,
                timeout: 12
            )
            let preview = String(data: result.data.prefix(220), encoding: .utf8) ?? ""
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let errno = json["errno"] as? Int else {
                baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 返回不可解析：\(preview)")
                return false
            }
            if errno == 0 || errno == -8 {
                return true
            }
            baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 响应：\(preview)")
            return false
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 异常：\(error.localizedDescription)")
            return false
        }
    }

    private func baiduCreateFolderByFileManager(path: String, cookie: String, bdstoken: String, referer: String, userAgent: String) async throws {
        var components = URLComponents(string: "https://pan.baidu.com/api/filemanager")!
        components.queryItems = [
            URLQueryItem(name: "opera", value: "create"),
            URLQueryItem(name: "bdstoken", value: bdstoken),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        request.httpBody = "path=\(encodedPath)&isdir=1&block_list=%5B%5D".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errno = json["errno"] as? Int,
              errno == 0 || errno == -8 else {
            let preview = String(data: data.prefix(220), encoding: .utf8) ?? ""
            baiduLog("[Baidu-Local] ⚠️ filemanager create \(path) 响应：\(preview)")
            return
        }
        baiduLog("[Baidu-Local] ✅ filemanager create \(path) 成功或已存在")
    }

    private func baiduCanListTransferDir(cookie: String, bdstoken: String, referer: String, userAgent: String) async throws -> Bool {
        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = [
            URLQueryItem(name: "dir", value: Self.baiduIBoxTransferDir),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "num", value: "1"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "bdstoken", value: bdstoken),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let errno = json["errno"] as? Int ?? 0
        if errno == 0 {
            baiduLog("[Baidu-Local] ✅ vbox 转存目录可访问：\(Self.baiduIBoxTransferDir)")
            return true
        }
        baiduLog("[Baidu-Local] ⚠️ vbox 转存目录不可访问：errno=\(errno)")
        return false
    }

    private func baiduCanListTransferDirViaWebView(cookie: String, bdstoken: String) async -> Bool {
        do {
            let page = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: false)
            let effectiveBdstoken = page.bdstoken ?? bdstoken
            var components = URLComponents(string: "https://pan.baidu.com/api/list")!
            components.queryItems = [
                URLQueryItem(name: "dir", value: Self.baiduIBoxTransferDir),
                URLQueryItem(name: "order", value: "time"),
                URLQueryItem(name: "desc", value: "1"),
                URLQueryItem(name: "num", value: "1"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "bdstoken", value: effectiveBdstoken),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let result = try await BaiduWebViewBridge.shared.request(url: components.url!.absoluteString, timeout: 12)
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
                return false
            }
            let errno = json["errno"] as? Int ?? 0
            if errno == 0 {
                baiduLog("[Baidu-Local] ✅ WebView XHR vbox 转存目录可访问：\(Self.baiduIBoxTransferDir)")
                return true
            }
            baiduLog("[Baidu-Local] ⚠️ WebView XHR vbox 转存目录不可访问：errno=\(errno)")
            return false
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR vbox 目录检查异常：\(error.localizedDescription)")
            return false
        }
    }

    private func baiduFindExistingVboxPath(fileName: String, cookie: String) async throws -> String? {
        func matchedPath(from json: [String: Any]) -> String? {
            let root = (json["data"] as? [String: Any]) ?? json
            let list = root["list"] as? [[String: Any]]
                ?? root["file_list"] as? [[String: Any]]
                ?? root["records"] as? [[String: Any]]
                ?? []
            let normalizedTarget = fileName.split(separator: "/").last.map(String.init) ?? fileName
            let targetBase = (normalizedTarget as NSString).deletingPathExtension
            let targetExt = (normalizedTarget as NSString).pathExtension
            for item in list {
                let name = item["server_filename"] as? String
                    ?? item["filename"] as? String
                    ?? item["name"] as? String
                    ?? ""
                let nameBase = (name as NSString).deletingPathExtension
                let nameExt = (name as NSString).pathExtension
                if name == normalizedTarget || (!targetBase.isEmpty && nameBase.hasPrefix(targetBase) && (targetExt.isEmpty || nameExt == targetExt)) {
                    return item["path"] as? String ?? "\(Self.baiduIBoxTransferDir)/\(normalizedTarget)"
                }
            }
            return nil
        }

        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = [
            URLQueryItem(name: "bdstoken", value: ""),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
        request.httpBody = "dir=\(encodedDir)&order=time&desc=1&num=200&page=1".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
        }

        let errno = json["errno"] as? Int ?? 0
        if errno != 0 {
            baiduLog("[Baidu-Local] ⚠️ URLSession 查找 /vbox 文件失败：errno=\(errno)，改用 WebView XHR")
            return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
        }
        if let path = matchedPath(from: json) {
            return path
        }
        return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
    }

    private func baiduFindExistingVboxPathViaWebView(fileName: String, cookie: String) async -> String? {
        do {
            _ = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: false)
            var components = URLComponents(string: "https://pan.baidu.com/api/list")!
            components.queryItems = [
                URLQueryItem(name: "bdstoken", value: ""),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
            let body = "dir=\(encodedDir)&order=time&desc=1&num=200&page=1"
            let result = try await BaiduWebViewBridge.shared.request(
                url: components.url!.absoluteString,
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body,
                timeout: 12
            )
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
                return nil
            }
            let errno = json["errno"] as? Int ?? 0
            if errno != 0 {
                baiduLog("[Baidu-Local] ⚠️ WebView XHR 查找 /vbox 文件失败：errno=\(errno)")
                return nil
            }
            let root = (json["data"] as? [String: Any]) ?? json
            let list = root["list"] as? [[String: Any]]
                ?? root["file_list"] as? [[String: Any]]
                ?? root["records"] as? [[String: Any]]
                ?? []
            let normalizedTarget = fileName.split(separator: "/").last.map(String.init) ?? fileName
            let targetBase = (normalizedTarget as NSString).deletingPathExtension
            let targetExt = (normalizedTarget as NSString).pathExtension
            for item in list {
                let name = item["server_filename"] as? String
                    ?? item["filename"] as? String
                    ?? item["name"] as? String
                    ?? ""
                let nameBase = (name as NSString).deletingPathExtension
                let nameExt = (name as NSString).pathExtension
                if name == normalizedTarget || (!targetBase.isEmpty && nameBase.hasPrefix(targetBase) && (targetExt.isEmpty || nameExt == targetExt)) {
                    let path = item["path"] as? String ?? "\(Self.baiduIBoxTransferDir)/\(normalizedTarget)"
                    baiduLog("[Baidu-Local] ✅ WebView XHR 查到 /vbox 文件：\(path)")
                    return path
                }
            }
            return nil
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 查找 /vbox 文件异常：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduWaitForTransferredPath(fileName: String, cookie: String, preferredPath: String? = nil) async throws -> String {
        if let preferredPath, !preferredPath.isEmpty {
            baiduLog("[Baidu-Local] 转存返回目标 path：\(preferredPath)")
            return preferredPath
        }

        var lastPath: String?
        for attempt in 1...8 {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(650_000_000 * min(attempt, 4)))
            }
            if let path = try await baiduFindExistingVboxPath(fileName: fileName, cookie: cookie) {
                baiduLog("[Baidu-Local] ✅ 转存落盘确认成功：attempt=\(attempt), path=\(path)")
                return path
            }
            lastPath = "\(Self.baiduIBoxTransferDir)/\(fileName.split(separator: "/").last.map(String.init) ?? fileName)"
            baiduLog("[Baidu-Local] ⏳ 等待转存落盘：attempt=\(attempt)")
        }

        throw DriveError.noPlayURL("百度转存任务未确认落盘：\(lastPath ?? fileName)")
    }

    private func baiduTransferFileOnDevice(
        shareURL: String,
        shareid: String,
        shareUk: String,
        bdstoken: String,
        randsk: String?,
        fsId: String,
        fileName: String,
        cookie: String,
        accountCookie: String,
        referer: String
    ) async throws -> String {
        var transferCookie = cookie
        if let refreshed = await baiduRefreshTransferSekey(shareURL: shareURL, accountCookie: accountCookie, existingCookie: cookie) {
            transferCookie = refreshed
        }
        // 严格对齐 iBox 抓包：share/transfer 的 sekey 优先使用 Cookie 里的 BDCLND 原始值。
        // BDCLND 通常已经是百分号编码形态，不能再交给 URLQueryItem 二次编码，否则百度会认为分享信息不完整。
        let rawSekey = baiduCookieValue(transferCookie, named: "BDCLND") ?? randsk ?? ""
        var query = [
            "shareid=\(baiduQueryEncoded(shareid))",
            "from=\(baiduQueryEncoded(shareUk))",
            "channel=chunlei",
            "web=1",
            "app_id=250528",
            "clienttype=0",
            "bdstoken=\(baiduQueryEncoded(bdstoken))"
        ]
        if !rawSekey.isEmpty {
            let encodedSekey = rawSekey.contains("%") ? rawSekey : baiduQueryEncoded(rawSekey)
            query.append("sekey=\(encodedSekey)")
        }
        guard let transferURL = URL(string: "https://pan.baidu.com/share/transfer?\(query.joined(separator: "&"))") else {
            throw DriveError.invalidShareURL
        }

        var request = URLRequest(url: transferURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(transferCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let transferPath = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
        // 恢复 3.232 已验证可播放行为：fsidlist 必须 URL 编码，并使用百度异步转存队列。
        let encodedFsidList = "[\(fsId)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B\(fsId)%5D"
        let transferBody = "fsidlist=\(encodedFsidList)&path=\(transferPath)&async=1&ondup=newcopy"
        request.httpBody = transferBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let path = try? await baiduTransferFileViaWebView(
                transferURL: transferURL,
                transferCookie: transferCookie,
                transferBody: transferBody,
                fileName: fileName,
                accountCookie: accountCookie
            ) {
                return path
            }
            throw DriveError.noPlayURL("百度本机转存 HTTP \(status)")
        }

        let errno = json["errno"] as? Int ?? -1
        if errno != 0 {
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
            baiduLog("[Baidu-Local] ❌ 本机转存失败：\(msg), hasBDCLND=\(transferCookie.lowercased().contains("bdclnd=")), hasBDUSS=\(transferCookie.lowercased().contains("bduss=")), hasSTOKEN=\(transferCookie.lowercased().contains("stoken="))")
            if let path = try? await baiduTransferFileViaWebView(
                transferURL: transferURL,
                transferCookie: transferCookie,
                transferBody: transferBody,
                fileName: fileName,
                accountCookie: accountCookie
            ) {
                return path
            }
            throw DriveError.noPlayURL("百度本机转存失败：\(msg)")
        }

        let taskID = json["task_id"] as? String
            ?? (json["extra"] as? [String: Any])?["task_id"] as? String
            ?? (json["request_id"] as? NSNumber)?.stringValue
        if let taskID, !taskID.isEmpty {
            baiduLog("[Baidu-Local] 转存返回任务标识：\(taskID)")
        }

        if let extra = json["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]],
           let first = list.first,
           let to = first["to"] as? String,
           !to.isEmpty {
            return to
        }

        let normalizedName = fileName.split(separator: "/").last.map(String.init) ?? fileName
        return try await baiduWaitForTransferredPath(fileName: normalizedName, cookie: accountCookie)
    }

    private func baiduTransferFileViaWebView(
        transferURL: URL,
        transferCookie: String,
        transferBody: String,
        fileName: String,
        accountCookie: String
    ) async throws -> String {
        _ = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: transferCookie, timeout: 12, resetCookies: false)
        let result = try await BaiduWebViewBridge.shared.request(
            url: transferURL.absoluteString,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "X-Requested-With": "XMLHttpRequest"
            ],
            body: transferBody,
            timeout: 25
        )
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            let preview = String(data: result.data.prefix(220), encoding: .utf8) ?? ""
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 转存返回不可解析：\(preview)")
            throw DriveError.noPlayURL("百度 WebView 转存返回不可解析")
        }
        let errno = json["errno"] as? Int ?? -1
        guard errno == 0 else {
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 转存失败：\(msg)")
            throw DriveError.noPlayURL("百度 WebView 转存失败：\(msg)")
        }
        baiduLog("[Baidu-Local] ✅ WebView XHR 转存请求成功")
        if let taskID = json["task_id"] as? String
            ?? (json["extra"] as? [String: Any])?["task_id"] as? String
            ?? (json["request_id"] as? NSNumber)?.stringValue,
           !taskID.isEmpty {
            baiduLog("[Baidu-Local] WebView XHR 转存任务标识：\(taskID)")
        }
        if let extra = json["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]],
           let first = list.first,
           let to = first["to"] as? String,
           !to.isEmpty {
            return to
        }
        let normalizedName = fileName.split(separator: "/").last.map(String.init) ?? fileName
        return try await baiduWaitForTransferredPath(fileName: normalizedName, cookie: accountCookie)
    }

    /// share/list 可以使用匿名分享态验证，但 share/transfer 属于账号转存动作。
    /// 百度会校验 BDCLND/sekey 是否绑定到当前账号会话；否则可能返回 errno=200025。
    private func baiduRefreshTransferSekey(shareURL: String, accountCookie: String, existingCookie: String) async -> String? {
        guard let pwd = extractBaiduPwd(from: shareURL), !pwd.isEmpty,
              let surl = try? baiduExtractSurl(from: shareURL) else {
            return nil
        }
        let shortSurl = baiduShortSurl(surl)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? pwd
        let verifyURL = "https://pan.baidu.com/share/verify?t=\(Int(Date().timeIntervalSince1970 * 1000))&surl=\(shortSurl)&channel=chunlei&web=1&app_id=250528&bdstoken=&clienttype=0"
        guard let url = URL(string: verifyURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accountCookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.baidu.com/s/1\(shortSurl)", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
        request.httpBody = "pwd=\(encodedPwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken=".data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let preview = String(data: data.prefix(160), encoding: .utf8) ?? ""
                baiduLog("[Baidu-Local] ⚠️ 账号态 verify 返回非 JSON：\(preview)")
                return nil
            }
            let errno = json["errno"] as? Int ?? -1
            guard errno == 0 else {
                let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
                baiduLog("[Baidu-Local] ⚠️ 账号态 verify 失败：\(msg)")
                return nil
            }
            var merged = baiduMergeCookieStrings([existingCookie, accountCookie])
            if let sc = (response as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                merged = baiduMergeCookieStrings([merged, sc])
            }
            if let rawRandsk = json["randsk"] as? String, !rawRandsk.isEmpty {
                let decodedRandsk = rawRandsk.removingPercentEncoding ?? rawRandsk
                merged = baiduMergeCookieStrings([merged, "BDCLND=\(rawRandsk); randsk=\(decodedRandsk)"])
                baiduLog("[Baidu-Local] ✅ 账号态 verify 成功，刷新 share/transfer sekey")
            }
            return merged
        } catch {
            baiduLog("[Baidu-Local] ⚠️ 账号态 verify 异常：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduQueryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func baiduCookieValue(_ cookie: String, named name: String) -> String? {
        let lowerName = name.lowercased()
        for part in cookie.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let key = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == lowerName, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func baiduErrorMessage(errno: Int, fallback: String? = nil) -> String {
        switch errno {
        case 0:
            return "成功"
        case -9:
            return "提取码错误"
        case 200025:
            return "分享验证态未绑定当前账号，请重新验证后转存"
        case -8:
            return "目标目录或文件已存在"
        case -7, -10:
            return "账号登录态已过期，请重新扫码登录"
        case -6:
            return "身份验证失败，请重新登录百度网盘"
        case -4, 4:
            return "需要图形验证码或安全验证"
        case 2:
            return "参数错误或分享信息不完整"
        case 5:
            return "分享链接不存在或已失效"
        case 10:
            return "分享内容不存在或已被删除"
        case 12:
            return "分享内容违规或不可访问"
        case 105:
            return "百度风控限制，需要在网页完成验证后重试"
        case 110:
            return "分享文件不可转存"
        case 111:
            return "转存数量或目录限制"
        case 115:
            return "该文件禁止转存或下载"
        default:
            if let fallback, !fallback.isEmpty { return "\(fallback) (errno=\(errno))" }
            return "errno=\(errno)"
        }
    }

    private func baiduGetDLNADlinkOnDevice(filePath: String, cookie: String, source: String = "local-mediainfo") async throws -> PlayResult {
        var components = URLComponents(string: "https://pan.baidu.com/api/mediainfo")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "80"),
            URLQueryItem(name: "origin", value: "dlna")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filePath
        request.httpBody = "path=\(encodedPath)&type=M3U8_FLV_264_480".data(using: .utf8)

        baiduLog("[Baidu-DLNA] 本机调用 mediainfo：path=\(filePath), hasBDUSS=\(cookie.lowercased().contains("bduss=")), hasSTOKEN=\(cookie.lowercased().contains("stoken=")), hasPANPSC=\(cookie.lowercased().contains("panpsc=")), hasPTOKEN=\(cookie.lowercased().contains("ptoken"))")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-DLNA] ❌ HTTP \(status)：\(preview)")
            throw DriveError.noPlayURL("百度 DLNA HTTP \(status)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-DLNA] ❌ 非 JSON 响应：\(preview)")
            throw DriveError.noPlayURL("百度 DLNA 返回非 JSON")
        }

        let info = json["info"] as? [String: Any]
        let dlink = info?["dlink"] as? String
            ?? json["dlink"] as? String
            ?? json["url"] as? String
        if let dlink, !dlink.isEmpty {
            let errno = json["errno"] as? Int ?? 0
            baiduLog("[Baidu-DLNA] ✅ mediainfo 返回 dlink：errno=\(errno), url=\(dlink.prefix(80))...")
            return baiduPlayResult(url: dlink, cookie: cookie, source: source)
        }

        let errno = json["errno"] as? Int ?? -1
        let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String)
        baiduLog("[Baidu-DLNA] ❌ 未返回 dlink：errno=\(errno), msg=\(msg), fields=\(json.keys.sorted().joined(separator: ","))")
        throw DriveError.noPlayURL("百度 DLNA 未返回 dlink：\(msg)")
    }

    private func baiduGetLocatedownloadOnDevice(filePath: String, cookie: String, source: String = "local-locatedownload", enableFastestNode: Bool = false) async throws -> PlayResult {
        var components = URLComponents(string: "https://d.pcs.baidu.com/rest/2.0/pcs/file")!
        components.queryItems = [
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "method", value: "locatedownload"),
            URLQueryItem(name: "check_blue", value: "1"),
            URLQueryItem(name: "path", value: filePath)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        baiduLog("[Baidu-LocalPCS] 本机调用 locatedownload：path=\(filePath), hasBDUSS=\(cookie.lowercased().contains("bduss=")), hasSTOKEN=\(cookie.lowercased().contains("stoken=")), hasPANPSC=\(cookie.lowercased().contains("panpsc=")), hasPTOKEN=\(cookie.lowercased().contains("ptoken")), enableFastestNode=\(enableFastestNode)")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if (status == 200 || status == 206),
           let finalURL = http?.url?.absoluteString,
           finalURL != components.url!.absoluteString,
           !finalURL.contains("d.pcs.baidu.com/rest/2.0/pcs/file") {
            baiduLog("[Baidu-LocalPCS] ✅ locatedownload 302 后最终 CDN：\(finalURL.prefix(80))...")
            return baiduPlayResult(url: finalURL, cookie: cookie, source: source)
        }
        if (300..<400).contains(status),
           let location = http?.allHeaderFields["Location"] as? String,
           !location.isEmpty {
            baiduLog("[Baidu-LocalPCS] ✅ locatedownload 返回 Location：\(location.prefix(80))...")
            return baiduPlayResult(url: location, cookie: cookie, source: source)
        }
        guard status == 200 else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-LocalPCS] ❌ HTTP \(status)：\(preview)")
            throw DriveError.noPlayURL("百度本机取链 HTTP \(status)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(240), encoding: .utf8) ?? ""
            baiduLog("[Baidu-LocalPCS] ❌ 非 JSON 响应：\(preview)")
            throw DriveError.noPlayURL("百度本机取链返回非 JSON")
        }

        if let errno = json["errno"] as? Int, errno != 0 {
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String)
            baiduLog("[Baidu-LocalPCS] ❌ errno=\(errno), msg=\(msg)")
            throw DriveError.noPlayURL("百度本机取链失败：\(msg)")
        }

        let urls = json["urls"] as? [[String: Any]]
        let locatedURL = urls?.first?["url"] as? String
            ?? json["url"] as? String
            ?? json["dlink"] as? String
        guard let locatedURL, !locatedURL.isEmpty else {
            baiduLog("[Baidu-LocalPCS] ❌ 未返回 urls/url 字段，字段=\(json.keys.sorted().joined(separator: ","))")
            throw DriveError.noPlayURL("百度本机取链未返回播放地址")
        }

        // [优化3] 多 CDN 节点测速选优
        if enableFastestNode, let urlDicts = urls, urlDicts.count > 1 {
            let allURLs = urlDicts.compactMap { $0["url"] as? String }.filter { !$0.isEmpty }
            if allURLs.count > 1 {
                baiduLog("[Baidu-LocalPCS] 🚀 多节点测速：共 \(allURLs.count) 个 CDN 节点，并发 HEAD 探测...")
                let fastest = await baiduFindFastestNode(urls: allURLs, cookie: cookie)
                if let fastest, fastest.url != locatedURL {
                    baiduLog("[Baidu-LocalPCS] ✅ 测速选优：选中节点 \(fastest.index)/\(allURLs.count)，RTT=\(fastest.rtt)ms，原首节点被替换")
                    return baiduPlayResult(url: fastest.url, cookie: cookie, source: "\(source)-fastest")
                } else if let fastest {
                    baiduLog("[Baidu-LocalPCS] ✅ 测速选优：首节点已是最快，RTT=\(fastest.rtt)ms")
                } else {
                    baiduLog("[Baidu-LocalPCS] ⚠️ 测速选优：全部节点测速失败，使用首节点")
                }
            }
        }

        baiduLog("[Baidu-LocalPCS] ✅ 本机取链成功：\(locatedURL.prefix(80))...")
        return baiduPlayResult(url: locatedURL, cookie: cookie, source: source)
    }

    // MARK: - [优化3] 多 CDN 节点测速选优
    private struct BaiduNodeSpeedResult {
        let url: String
        let index: Int
        let rtt: Int // 毫秒
    }

    private func baiduFindFastestNode(urls: [String], cookie: String) async -> BaiduNodeSpeedResult? {
        guard !urls.isEmpty else { return nil }
        let timeoutMs = 3000 // 单节点超时 3 秒
        return await withTaskGroup(of: (index: Int, url: String, rtt: Int?)?.self) { group in
            for (idx, urlStr) in urls.enumerated() {
                group.addTask { [weak self] in
                    guard let self, let url = URL(string: urlStr) else { return nil }
                    var req = URLRequest(url: url)
                    req.httpMethod = "HEAD"
                    req.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    req.setValue(Self.baiduPCSUserAgent, forHTTPHeaderField: "User-Agent")
                    req.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
                    let start = Date()
                    do {
                        let (_, resp) = try await self.session.data(for: req)
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        guard status == 200 || status == 206 || (300..<400).contains(status) else {
                            return nil
                        }
                        let rtt = Int(Date().timeIntervalSince(start) * 1000)
                        return (idx, urlStr, rtt)
                    } catch {
                        return nil
                    }
                }
            }
            var results: [BaiduNodeSpeedResult] = []
            for await result in group {
                if let r = result, let rtt = r.rtt {
                    results.append(BaiduNodeSpeedResult(url: r.url, index: r.index, rtt: rtt))
                }
            }
            baiduLog("[Baidu-LocalPCS] 📊 测速结果：成功 \(results.count)/\(urls.count) 个节点，RTT 范围：\(results.map { "\($0.rtt)ms" }.joined(separator: ", "))")
            return results.min { $0.rtt < $1.rtt }
        }
    }

    private func baiduPlayResult(url: String, cookie: String, source: String? = nil) -> PlayResult {
        PlayResult(
            url: url,
            headers: [
                "Cookie": cookie,
                "User-Agent": Self.baiduPCSUserAgent,
                "Referer": "https://pan.baidu.com/",
                "Origin": "https://pan.baidu.com"
            ],
            driveType: .baidu,
            source: source
        )
    }

    private func baiduMergeCookieStrings(_ cookies: [String]) -> String {
        let ignoredAttributes: Set<String> = ["expires", "path", "domain", "max-age", "secure", "httponly", "samesite"]
        var keys: [String] = []
        var values: [String: (name: String, value: String)] = [:]
        for cookie in cookies where !cookie.isEmpty {
            let normalized = cookie
                .replacingOccurrences(of: #",\s*([A-Za-z_][A-Za-z0-9_\-]*)="#, with: ";\n$1=", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: ";")
            for part in normalized.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                guard !ignoredAttributes.contains(key) else { continue }
                if values[key] == nil { keys.append(key) }
                values[key] = (name, value)
            }
        }
        return keys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    /// 治理隐患 3：私域接口（gettemplatevariable / api/create / filemanager / api/list）
    /// 只允许携带账号态 Cookie；从入参 cookie 中剔除分享态字段（BDCLND / BDCLND_BFESS 等），
    /// 避免历史合并产物把分享态混入用户网盘私域请求，导致 errno=-6/-9。
    private func baiduPureAccountCookie(_ cookie: String) -> String {
        guard !cookie.isEmpty else { return cookie }
        let dropList: Set<String> = [
            "bdclnd", "bdclnd_bfess",
            "share_pwd", "share_pwd_bfess"
        ]
        let merged = baiduMergeCookieStrings([cookie])
        let parts = merged.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered: [String] = parts.compactMap { item in
            guard let eq = item.firstIndex(of: "=") else { return nil }
            let name = item[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            return dropList.contains(name) ? nil : item
        }
        return filtered.joined(separator: "; ")
    }

    private func baiduStableDeviceId() -> String {
        let key = "baidu_local_pcs_device_id"
        if let id = defaults.string(forKey: key), !id.isEmpty {
            return id
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        defaults.set(id, forKey: key)
        return id
    }

    private func resolveBaiduPlayURLInternal(shareURL: String, bduss: String, pwd: String?, pcsCookie: String = "") async throws -> PlayResult {
        let parsed = parseBaiduToken(bduss)
        let cookie = parsed.cookie
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: cookie, returnAll: true)
        guard let first = context.files.first, !first.fsId.isEmpty else {
            throw DriveError.noPlayURL("百度 iBox 路链未返回可播放文件")
        }
        return try await resolveBaiduPlayURLViaMainRoute(
            shareURL: shareURL,
            bduss: bduss,
            fsId: first.fsId,
            fileName: first.name,
            pcsCookie: pcsCookie
        )
    }

    func resolveBaiduPlayURL(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        try await resolveBaiduPlayURLViaMainRoute(
            shareURL: shareURL,
            bduss: bduss,
            fsId: fsId,
            fileName: nil,
            pcsCookie: pcsCookie
        )
    }

    /// iBox-style 百度主播放链路：
    /// wap/init → verify → share页/yunData → gettemplatevariable → share/list → transfer → api/list → mediainfo/locatedownload。
    /// 失败时直接向调用方抛出错误，不再回落 Worker 或旧分享直链路。
    func resolveBaiduPlayURLViaMainRoute(
        shareURL: String,
        bduss: String,
        fsId: String,
        fileName hintFileName: String? = nil,
        pcsCookie: String = ""
    ) async throws -> PlayResult {
        // 提前触发兜底清理：无论缓存命中与否，都先清理 /vbox 下超过 2 小时的旧文件
        let parsed = parseBaiduToken(bduss)
        let webCookie = parsed.cookie
        let pcs = normalizeBaiduPCSCookie(pcsCookie)
        let earlyCleanupCookie = baiduMergeCookieStrings([webCookie, pcs])
        let earlyPureCookie = baiduPureAccountCookie(earlyCleanupCookie)
        baiduLog("[Baidu-Cleanup] 🔧 早期清理触发器已启动，准备获取 bdstoken...")
        Task { [weak self] in
            baiduLog("[Baidu-Cleanup] 🔧 开始获取 bdstoken，cookie 中 BDUSS=\(baiduCookieValue(earlyPureCookie, named: "BDUSS")?.prefix(8) ?? "nil")…")
            let token = await self?.baiduFetchUserBdstokenLocal(cookie: earlyPureCookie) ?? ""
            baiduLog("[Baidu-Cleanup] 🔧 bdstoken 获取结果：\(token.isEmpty ? "失败（空）" : "成功 \(token.prefix(8))…")")
            if !token.isEmpty {
                self?.baiduCleanupOldTransferFiles(cookie: earlyPureCookie, bdstoken: token)
            } else {
                baiduLog("[Baidu-Cleanup] ❌ bdstoken 为空，清理未执行")
            }
        }

        let cacheKey = baiduMainRouteCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        if let cached = baiduCachedPlayResult(for: cacheKey) {
            baiduLog("[Baidu-MainRoute] ✅ 命中主路链播放缓存：fsId=\(fsId)")
            recordBaiduRouteDiagnostic(stage: "主路链缓存", status: "命中", detail: "命中主路链 dlink 缓存", fsId: fsId, fileName: hintFileName)
            return cached
        }

        if let itemResult = try? await baiduResolveViaIBoxPlayItem(
            cacheKey: cacheKey,
            shareURL: shareURL,
            fsId: fsId,
            fileName: hintFileName,
            cookie: webCookie,
            pcsCookie: pcs
        ) {
            let result = PlayResult(
                url: itemResult.url,
                headers: itemResult.headers,
                driveType: .baidu,
                source: "baidu-main-playitem"
            )
            baiduStorePlayResult(result, for: cacheKey)
            return result
        }

        baiduLog("[Baidu-iBoxRoute] 开始 iBox-style 百度主路链：fsId=\(fsId), file=\(hintFileName ?? "未知")")
        recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "开始", detail: "wap/init → verify → share页/yunData → gettemplatevariable → share/list → transfer → api/list → locatedownload → 本地代理", fsId: fsId, fileName: hintFileName)

        let pwd = extractBaiduPwd(from: shareURL)
        // [优化2] 分享页解析与 bdstoken 获取并行执行，节省首帧时间
        let accountCookie = baiduMergeCookieStrings([webCookie, pcs])
        let pureAccountCookie = baiduPureAccountCookie(accountCookie)
        let startExtract = Date()
        async let contextAsync = baiduExtractShareMeta(shareURL: shareURL, cookie: webCookie, returnAll: true)
        async let userBdstokenAsync = baiduFetchUserBdstokenLocal(cookie: pureAccountCookie)
        let context = try await contextAsync
        let extractCost = Int(Date().timeIntervalSince(startExtract) * 1000)
        baiduLog("[Baidu-iBoxRoute] ⏱️ 分享页解析+bdstoken并行耗时：\(extractCost)ms")
        guard let userBdstoken = await userBdstokenAsync,
              !userBdstoken.isEmpty else {
            let message = "百度登录态正常，但未取得用户态 bdstoken，无法创建 vbox 转存目录"
            baiduLog("[Baidu-Local] ❌ \(message)")
            recordBaiduRouteDiagnostic(stage: "主路链", status: "缺少用户态bdstoken", detail: message, fsId: fsId, fileName: hintFileName)
            throw DriveError.noPlayURL(message)
        }
        let matched = context.files.first { $0.fsId == fsId }
            ?? context.files.first { $0.fsId.trimmingCharacters(in: .whitespacesAndNewlines) == fsId.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selected: BaiduFileItem?
        if let matched, baiduIsPlayableVideoFileName(matched.name) {
            selected = matched
        } else if let matched {
            let fallback = context.files.first { baiduIsPlayableVideoFileName($0.name) }
            if let fallback {
                baiduLog("[Baidu-iBoxRoute] ⚠️ fsId 命中非视频文件：\(matched.name)，自动切换到视频：\(fallback.name)")
                recordBaiduRouteDiagnostic(stage: "主路链", status: "跳过非视频", detail: "fsId 指向 \(matched.name)，已切换到 \(fallback.name)", fsId: fsId, fileName: matched.name)
            }
            selected = fallback
        } else {
            selected = context.files.first { baiduIsPlayableVideoFileName($0.name) }
        }
        guard let selected else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "文件未找到", detail: "分享列表未找到可播放视频，pwd=\((pwd ?? "").isEmpty ? "无" : "有")", fsId: fsId, fileName: hintFileName)
            throw DriveError.noPlayURL("主路链未找到可播放视频")
        }

        let mergedCookie = baiduMergeCookieStrings([context.cookie, accountCookie])
        guard !mergedCookie.isEmpty else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "Cookie缺失", detail: "无法合并 BDUSS/STOKEN Cookie", fsId: fsId, fileName: selected.name)
            throw DriveError.noPlayURL("主路链缺少百度 Cookie")
        }

        do {
            // 严格对齐 iBox：转存/创建/列目录用登录态 bdstoken；分享页 bdstoken 在私域接口会被判越权 errno=-6。
            // 创建目录/列用户网盘目录只能用账号 Cookie；share/transfer 再使用账号 Cookie + BDCLND 的混合 Cookie。
            // [优化2] userBdstoken 已在上方与分享页解析并行获取，此处直接复用
            try await baiduEnsureVboxFolderLocal(cookie: pureAccountCookie, bdstoken: userBdstoken, referer: "https://pan.baidu.com/disk/main")
            let existingPath = try await baiduFindExistingVboxPath(fileName: selected.name, cookie: pureAccountCookie)
            let filePath: String
            let sourcePrefix: String
            if let existingPath {
                filePath = existingPath
                sourcePrefix = "main-existing"
                baiduLog("[Baidu-iBoxRoute] ✅ \(Self.baiduIBoxTransferDir) 命中已转存文件：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "path命中", detail: "命中 \(Self.baiduIBoxTransferDir) 已转存文件：\(filePath)", fsId: fsId, fileName: selected.name)
            } else {
                filePath = try await baiduTransferFileOnDevice(
                    shareURL: shareURL,
                    shareid: context.shareid,
                    shareUk: context.shareUk,
                    bdstoken: userBdstoken,
                    randsk: context.randsk,
                    fsId: selected.fsId,
                    fileName: selected.name,
                    cookie: mergedCookie,
                    accountCookie: pureAccountCookie,
                    referer: shareURL
                )
                sourcePrefix = "main-transfer"
                baiduLog("[Baidu-iBoxRoute] ✅ 本机转存完成：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "转存成功", detail: "已转存到：\(filePath)", fsId: fsId, fileName: selected.name)
                // 转存成功后立即调度 1 小时后清理（不等播放成功，避免播放失败留下孤儿文件）
                scheduleCleanup(drive: .baidu, fileIds: [filePath], token: pureAccountCookie, delay: 60 * 60)
            }

            // [优化1] 直接 locatedownload 取原画直链，mediainfo 只在失败时才兜底
            // 去掉前置串行 mediainfo 探测，节省一次完整 HTTP 请求时间
            // [优化3] locatedownload 返回多 CDN 节点时，并发 HEAD 测速选最优节点
            let locatedownloadStart = Date()
            let rawResult: PlayResult
            let source: String
            do {
                let ldResult = try await baiduGetLocatedownloadOnDevice(
                    filePath: filePath,
                    cookie: mergedCookie,
                    source: "\(sourcePrefix)-locatedownload",
                    enableFastestNode: true
                )
                let ldCost = Int(Date().timeIntervalSince(locatedownloadStart) * 1000)
                baiduLog("[Baidu-iBoxRoute] ⏱️ locatedownload+测速总耗时：\(ldCost)ms，选中节点：\(ldResult.url.prefix(60))...")
                rawResult = ldResult
                source = "\(sourcePrefix)-locatedownload"
            } catch {
                baiduLog("[Baidu-iBoxRoute] ⚠️ locatedownload 失败，尝试 mediainfo 兜底：\(error.localizedDescription)")
                do {
                    let mediainfoResult = try await baiduGetDLNADlinkOnDevice(
                        filePath: filePath,
                        cookie: mergedCookie,
                        source: "\(sourcePrefix)-mediainfo"
                    )
                    recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "locatedownload失败", detail: "使用 mediainfo dlink 兜底：\(error.localizedDescription)", fsId: fsId, fileName: selected.name)
                    rawResult = mediainfoResult
                    source = "\(sourcePrefix)-mediainfo-fallback"
                } catch {
                    throw error
                }
            }

            let result = PlayResult(
                url: rawResult.url,
                headers: rawResult.headers,
                driveType: .baidu,
                source: source
            )
            let playItem = BaiduIBoxPlayItem(
                shareURL: shareURL,
                fsId: fsId,
                fileName: selected.name,
                path: filePath,
                dlinkURL: result.url,
                headers: result.headers,
                dlinkExpiresAt: Date().addingTimeInterval(6 * 60 * 60),
                compatibilityHint: baiduCompatibilityHint(fileName: selected.name),
                preferredEngine: baiduPreferredEngine(fileName: selected.name),
                preparedAt: Date(),
                updatedAt: Date(),
                lastUsedAt: Date(),
                source: source
            )
            baiduStoreIBoxPlayItem(playItem, for: cacheKey)
            baiduStorePlayResult(result, for: cacheKey)
            recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "成功", detail: "source=\(source)，engine=\(playItem.preferredEngine)", fsId: fsId, fileName: selected.name)
            baiduLog("[Baidu-iBoxRoute] ✅ iBox-style 原画地址获取成功：source=\(source), engine=\(playItem.preferredEngine)")
            return result
        } catch {
            baiduLog("[Baidu-iBoxRoute] ❌ iBox-style 转存/locatedownload 失败：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "失败", detail: error.localizedDescription, fsId: fsId, fileName: selected.name)
            throw error
        }
    }

    @discardableResult
    func prepareBaiduIBoxPlayItem(shareURL: String, bduss: String, fsId: String, pcsCookie: String = "") async throws -> PlayResult {
        baiduLog("[Baidu-iBox] 开始准备 PlayItem：fsId=\(fsId)")
        let result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: bduss, fsId: fsId, pcsCookie: pcsCookie)
        baiduLog("[Baidu-iBox] ✅ PlayItem 准备完成：fsId=\(fsId)")
        return result
    }

    private func baiduExtractShareMeta(shareURL: String, cookie: String, returnAll: Bool = false) async throws -> (shareid: String, shareUk: String, bdstoken: String, surl: String, cookie: String, files: [BaiduFileItem], randsk: String) {
        baiduLog("[Baidu] 提取分享信息：\(shareURL)")

        let surl: String
        if let match = try? NSRegularExpression(pattern: #"/s/1([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            surl = "1" + String(shareURL[r])
        } else if let match = try? NSRegularExpression(pattern: #"/s/([^/?]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
                  let r = Range(match.range(at: 1), in: shareURL) {
            surl = String(shareURL[r])
        } else {
            baiduLog("[Baidu] ❌ 无法提取 surl")
            throw DriveError.invalidShareURL
        }

        let pwd: String?
        if let match = try? NSRegularExpression(pattern: #"[?&]pwd=([^&]+)"#).firstMatch(in: shareURL, range: NSRange(shareURL.startIndex..., in: shareURL)),
           let r = Range(match.range(at: 1), in: shareURL) {
            pwd = String(shareURL[r])
            baiduLog("[Baidu] 检测到提取码: \(pwd!)")
        } else {
            pwd = nil
        }

        let contextKey = baiduShareContextKey(shareURL: shareURL, cookie: cookie)
        let verifyCooldownKey = "\(contextKey)|\(surl)|\(pwd ?? "")"
        if !returnAll, let cached = baiduCachedShareContext(for: contextKey, currentPwd: pwd) {
            baiduLog("[Baidu-ShareContext] ✅ 命中分享上下文缓存：source=\(cached.source), files=\(cached.files.count)")
            recordBaiduRouteDiagnostic(stage: "分享上下文", status: "缓存命中", detail: "命中 ShareContext：source=\(cached.source), files=\(cached.files.count)")
            return (cached.shareid, cached.shareUk, cached.bdstoken ?? "", cached.surl, cached.cookie, cached.files, cached.randsk ?? "")
        } else if returnAll {
            baiduLog("[Baidu-ShareContext] iBox 严格模式：跳过 ShareContext 缓存，重新验证分享上下文")
        }

        do {
            let shortSurl = baiduShortSurl(surl)
            // 按 iBox 抓包：分享验证与 share/list 使用 Mac Chrome UA，不是 iOS Safari UA。
            let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
            let initURL = "https://pan.baidu.com/wap/init?surl=\(shortSurl)"
            let desktopShareURL = "https://pan.baidu.com/s/1\(shortSurl)"
            var iBoxCookie = cookie
            var shareid = ""
            var shareUk = ""
            var bdstoken = ""
            var shareSign = ""
            var shareTimestamp = ""
            var randskForList = ""

            func stringValue(_ value: Any?) -> String {
                if let value = value as? String { return value }
                if let value = value as? Int { return String(value) }
                if let value = value as? Int64 { return String(value) }
                if let value = value as? NSNumber { return value.stringValue }
                return ""
            }

            func firstHTMLValue(_ html: String, patterns: [String]) -> String {
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       match.numberOfRanges > 1,
                       let range = Range(match.range(at: 1), in: html) {
                        return String(html[range])
                    }
                }
                return ""
            }

            func parseFiles(_ rawList: [[String: Any]]) -> [BaiduFileItem] {
                rawList.compactMap { item in
                    let fsId = stringValue(item["fs_id"]).isEmpty ? stringValue(item["fsId"]) : stringValue(item["fs_id"])
                    let name = stringValue(item["server_filename"]).isEmpty
                        ? (stringValue(item["file_name"]).isEmpty ? stringValue(item["name"]) : stringValue(item["file_name"]))
                        : stringValue(item["server_filename"])
                    guard !fsId.isEmpty else { return nil }
                    return BaiduFileItem(fsId: fsId, name: name.isEmpty ? "未知文件" : name)
                }
            }

            func queryEncoded(_ value: String) -> String {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#/")
                return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            }

            func iBoxQueryEncoded(_ value: String, keepSlash: Bool = true) -> String {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#")
                if !keepSlash { allowed.remove(charactersIn: "/") }
                return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            }

            func cookieForShareList(_ cookie: String, includeAccount: Bool) -> String {
                var dropNames: Set<String> = ["stoken", "stoken_bfess", "ptoken", "ptoken_bfess", "passid", "ubi_bfess", "randsk"]
                if !includeAccount {
                    // iBox 抓包：root-shorturl 阶段不能带 BDUSS，只带 BAIDUID/PANPSC/BDCLND 这一类分享态 Cookie。
                    dropNames.formUnion(["bduss", "bduss_bfess"])
                }
                return cookie
                    .split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { part in
                        guard let name = part.split(separator: "=", maxSplits: 1).first?.lowercased() else { return false }
                        return !dropNames.contains(String(name))
                    }
                    .joined(separator: "; ")
            }

            func isDirectory(_ item: [String: Any]) -> Bool {
                let value = stringValue(item["isdir"])
                return value == "1" || value.lowercased() == "true"
            }

            func parsePlayableFiles(_ rawList: [[String: Any]]) -> [BaiduFileItem] {
                let parsed = parseFiles(rawList.filter { !isDirectory($0) })
                let videos = parsed.filter { baiduIsPlayableVideoFileName($0.name) }
                let skipped = parsed.count - videos.count
                if skipped > 0 {
                    baiduLog("[Baidu-iBoxRoute] 已过滤非视频文件：\(skipped) 个（如 .nfo/.srt/.ass/.jpg）")
                }
                return videos
            }

            func parseJSONStringIfNeeded(_ value: Any) -> Any {
                guard let text = value as? String else { return value }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) else {
                    return value
                }
                return json
            }

            func deepString(_ value: Any, keys: Set<String>) -> String {
                let normalized = parseJSONStringIfNeeded(value)
                if let dict = normalized as? [String: Any] {
                    for (key, raw) in dict where keys.contains(key.lowercased()) {
                        let direct = stringValue(raw)
                        if !direct.isEmpty { return direct }
                    }
                    for raw in dict.values {
                        let found = deepString(raw, keys: keys)
                        if !found.isEmpty { return found }
                    }
                } else if let array = normalized as? [Any] {
                    for raw in array {
                        let found = deepString(raw, keys: keys)
                        if !found.isEmpty { return found }
                    }
                }
                return ""
            }

            func deepFiles(_ value: Any) -> [BaiduFileItem] {
                let normalized = parseJSONStringIfNeeded(value)
                if let dict = normalized as? [String: Any] {
                    for key in ["list", "file_list", "records", "filelist", "result", "data", "info"] {
                        if let rawList = dict[key] as? [[String: Any]] {
                            let parsed = parsePlayableFiles(rawList)
                            if !parsed.isEmpty { return parsed }
                        }
                        if let nested = dict[key] {
                            let parsed = deepFiles(nested)
                            if !parsed.isEmpty { return parsed }
                        }
                    }
                    for raw in dict.values {
                        let found = deepFiles(raw)
                        if !found.isEmpty { return found }
                    }
                } else if let rawList = normalized as? [[String: Any]] {
                    let parsed = parsePlayableFiles(rawList)
                    if !parsed.isEmpty { return parsed }
                } else if let array = normalized as? [Any] {
                    for raw in array {
                        let found = deepFiles(raw)
                        if !found.isEmpty { return found }
                    }
                }
                return []
            }

            func applyTemplateVariables(_ json: [String: Any], source: String, files: inout [BaiduFileItem]) {
                let templateBdstoken = deepString(json, keys: ["bdstoken"])
                let templateShareid = deepString(json, keys: ["shareid", "share_id"])
                let templateUk = deepString(json, keys: ["share_uk", "uk"])
                let templateFiles = deepFiles(json)
                if bdstoken.isEmpty, !templateBdstoken.isEmpty { bdstoken = templateBdstoken }
                if shareid.isEmpty, !templateShareid.isEmpty { shareid = templateShareid }
                if shareUk.isEmpty, !templateUk.isEmpty { shareUk = templateUk }
                if files.isEmpty, !templateFiles.isEmpty { files = templateFiles }
                baiduLog("[Baidu-iBoxRoute] \(source) templatevariable：bdstoken=\(!templateBdstoken.isEmpty), shareid=\(!templateShareid.isEmpty), uk=\(!templateUk.isEmpty), files=\(templateFiles.count), keys=\(json.keys.sorted().joined(separator: ","))")
            }

            func fetchTemplateVariables(source: String, referer: String) async -> [String: Any]? {
                var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
                components.queryItems = [
                    URLQueryItem(name: "clienttype", value: "0"),
                    URLQueryItem(name: "app_id", value: "250528"),
                    URLQueryItem(name: "web", value: "1"),
                    URLQueryItem(name: "bdstoken", value: bdstoken),
                    URLQueryItem(name: "fields", value: #"["bdstoken","token","uk","username","shareid","share_id","share_uk","sign","timestamp","file_list","filelist","list","records","shareinfo","share_info","yunData"]"#)
                ]
                guard let url = components.url else { return nil }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                request.setValue(webUA, forHTTPHeaderField: "User-Agent")
                request.setValue(referer, forHTTPHeaderField: "Referer")
                request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                do {
                    let (data, response) = try await session.data(for: request)
                    if let sc = (response as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                        iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        let preview = String(data: data.prefix(180), encoding: .utf8) ?? ""
                        baiduLog("[Baidu-iBoxRoute] \(source) templatevariable 非 JSON：\(preview)")
                        return nil
                    }
                    return json
                } catch {
                    baiduLog("[Baidu-iBoxRoute] \(source) templatevariable 失败：\(error.localizedDescription)")
                    return nil
                }
            }

            func applyYunDataHTML(_ html: String, source: String, files: inout [BaiduFileItem]) {
                let htmlShareid = firstHTMLValue(html, patterns: [
                    #"yunData\.SHAREID\s*=\s*["']?(\d+)"#,
                    #"["']?SHAREID["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?shareid["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?share_id["']?\s*[:=]\s*["']?(\d+)"#,
                    #"shareid=(\d+)"#,
                    #"data-shareid="(\d+)""#
                ])
                let htmlShareUk = firstHTMLValue(html, patterns: [
                    #"yunData\.SHARE_UK\s*=\s*["']?(\d+)"#,
                    #"["']?SHARE_UK["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?share_uk["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?uk["']?\s*[:=]\s*["']?(\d+)"#,
                    #"share_uk=(\d+)"#,
                    #"data-uk="(\d+)""#
                ])
                let htmlBdstoken = firstHTMLValue(html, patterns: [
                    #"yunData\.MYBDSTOKEN\s*=\s*["']([A-Za-z0-9_-]+)["']"#,
                    #"["']?bdstoken["']?\s*[:=]\s*["']([A-Za-z0-9_-]+)["']"#,
                    #"bdstoken=([A-Za-z0-9_-]+)"#
                ])
                let htmlSign = firstHTMLValue(html, patterns: [
                    #"yunData\.SIGN\s*=\s*["']([^"']+)["']"#,
                    #"["']?sign["']?\s*[:=]\s*["']([^"']+)["']"#
                ])
                let htmlTimestamp = firstHTMLValue(html, patterns: [
                    #"yunData\.TIMESTAMP\s*=\s*["']?(\d+)"#,
                    #"["']?timestamp["']?\s*[:=]\s*["']?(\d+)"#
                ])
                if shareid.isEmpty, !htmlShareid.isEmpty { shareid = htmlShareid }
                if shareUk.isEmpty, !htmlShareUk.isEmpty { shareUk = htmlShareUk }
                if bdstoken.isEmpty, !htmlBdstoken.isEmpty { bdstoken = htmlBdstoken }
                if shareSign.isEmpty, !htmlSign.isEmpty { shareSign = htmlSign }
                if shareTimestamp.isEmpty, !htmlTimestamp.isEmpty { shareTimestamp = htmlTimestamp }
                baiduLog("[Baidu-iBoxRoute] \(source) yunData：shareid=\(!htmlShareid.isEmpty), uk=\(!htmlShareUk.isEmpty), bdstoken=\(!htmlBdstoken.isEmpty), sign=\(!htmlSign.isEmpty), html=\(html.count)字符")

                if let fileInfoMatch = try? NSRegularExpression(pattern: #"yunData\.FILEINFO\s*=\s*(\[[\s\S]*?\]);"#).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   fileInfoMatch.numberOfRanges > 1,
                   let r = Range(fileInfoMatch.range(at: 1), in: html) {
                    let raw = String(html[r])
                    if let data = raw.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let parsed = parsePlayableFiles(arr)
                        if files.isEmpty, !parsed.isEmpty { files = parsed }
                        baiduLog("[Baidu-iBoxRoute] \(source) yunData.FILEINFO 解析：files=\(parsed.count)")
                    }
                }
            }

            baiduLog("[Baidu-iBoxRoute] ① GET /wap/init?surl=\(shortSurl)")
            guard let initURLObject = URL(string: initURL) else { throw DriveError.invalidShareURL }
            var initRequest = URLRequest(url: initURLObject)
            initRequest.timeoutInterval = 18
            initRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
            initRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
            initRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            initRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            initRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (initData, initResponse) = try await session.data(for: initRequest)
            let initResp = initResponse as? HTTPURLResponse
            if let sc = initResp?.allHeaderFields["Set-Cookie"] as? String {
                iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
            }
            let initHTML = String(data: initData, encoding: .utf8) ?? String(data: initData, encoding: .ascii) ?? ""
            var files: [BaiduFileItem] = []
            applyYunDataHTML(initHTML, source: "wap/init", files: &files)
            if let pwd, !pwd.isEmpty {
                baiduLog("[Baidu-iBoxRoute] ② POST /share/verify?surl=\(shortSurl)")
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#")
                let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? pwd
                let verifyURL = "https://pan.baidu.com/share/verify?t=\(Int(Date().timeIntervalSince1970 * 1000))&surl=\(shortSurl)&channel=chunlei&web=1&app_id=250528&bdstoken=&clienttype=0"
                let verifyBody = "pwd=\(encodedPwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken="
                guard let verifyURLObject = URL(string: verifyURL) else { throw DriveError.invalidShareURL }
                var verifyRequest = URLRequest(url: verifyURLObject)
                verifyRequest.httpMethod = "POST"
                verifyRequest.timeoutInterval = 18
                verifyRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                // iBox 抓包：share/verify 的 Cookie 为空。这里不能带 BDUSS/STOKEN，否则拿到的 BDCLND 会绑定到登录态上下文，
                // 后续 root-shorturl 匿名 share/list 仍可能不认，返回 errno=2。
                verifyRequest.setValue("", forHTTPHeaderField: "Cookie")
                verifyRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                verifyRequest.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
                verifyRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
                verifyRequest.setValue("*/*", forHTTPHeaderField: "Accept")
                verifyRequest.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
                verifyRequest.httpBody = verifyBody.data(using: .utf8)
                let (verifyData, verifyResponse) = try await session.data(for: verifyRequest)
                if let sc = (verifyResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                }
                guard let verifyJSON = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
                      let errno = verifyJSON["errno"] as? Int else {
                    let preview = String(data: verifyData.prefix(200), encoding: .utf8) ?? ""
                    throw DriveError.noPlayURL("百度 iBox 验证返回非 JSON：\(preview)")
                }
                guard errno == 0 else {
                    let msg = baiduErrorMessage(errno: errno, fallback: verifyJSON["errmsg"] as? String ?? verifyJSON["show_msg"] as? String)
                    throw DriveError.noPlayURL("百度 iBox 验证失败：\(msg)")
                }
                if let rawRandsk = verifyJSON["randsk"] as? String, !rawRandsk.isEmpty {
                    let decodedRandsk = rawRandsk.removingPercentEncoding ?? rawRandsk
                    randskForList = decodedRandsk
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, "BDCLND=\(rawRandsk); randsk=\(decodedRandsk)"])
                    baiduLog("[Baidu-iBoxRoute] ✅ verify 成功，已写入 BDCLND/randsk")
                }
            }

            // 密码分享必须在 verify 写入 BDCLND/randsk 后再抓桌面页，否则 /s/1xxx 会在验证页之间循环重定向。
            baiduLog("[Baidu-iBoxRoute] ②.5 GET 桌面分享页 \(desktopShareURL)")
            if let desktopURLObject = URL(string: desktopShareURL) {
                do {
                    var desktopRequest = URLRequest(url: desktopURLObject)
                    desktopRequest.timeoutInterval = 18
                    desktopRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                    desktopRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                    desktopRequest.setValue(initURL, forHTTPHeaderField: "Referer")
                    desktopRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    desktopRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                    let (desktopData, desktopResponse) = try await session.data(for: desktopRequest)
                    if let sc = (desktopResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                        iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                    }
                    let desktopHTML = String(data: desktopData, encoding: .utf8) ?? String(data: desktopData, encoding: .ascii) ?? ""
                    applyYunDataHTML(desktopHTML, source: "桌面页", files: &files)
                } catch {
                    baiduLog("[Baidu-iBoxRoute] 桌面分享页失败，继续走 share/list 兜底：\(error.localizedDescription)")
                }
            }

            // 对齐 iBox 报告中的 api/gettemplatevariable：必须跟在分享页上下文之后，并使用桌面分享页 Referer。
            if let templateJSON = await fetchTemplateVariables(source: "桌面页后", referer: desktopShareURL) {
                applyTemplateVariables(templateJSON, source: "桌面页后", files: &files)
            }

            baiduLog("[Baidu-iBoxRoute] ③ GET /share/list root shorturl=\(shortSurl)")
            let encodedRandsk = iBoxQueryEncoded(randskForList, keepSlash: true)
            let encodedShortSurl = queryEncoded(shortSurl)
            var lastListError = ""

            func requestShareList(_ listURL: String, source: String, includeAccountCookie: Bool) async throws -> [String: Any]? {
                guard let listURLObject = URL(string: listURL) else { return nil }
                var listRequest = URLRequest(url: listURLObject)
                listRequest.timeoutInterval = 18
                let shareCookie = cookieForShareList(iBoxCookie, includeAccount: includeAccountCookie)
                listRequest.setValue(shareCookie, forHTTPHeaderField: "Cookie")
                listRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                listRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
                listRequest.setValue("*/*", forHTTPHeaderField: "Accept")
                listRequest.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
                listRequest.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
                let (listData, listResponse) = try await session.data(for: listRequest)
                if let sc = (listResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                }
                guard let listJSON = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] else {
                    lastListError = String(data: listData.prefix(200), encoding: .utf8) ?? "非 JSON"
                    return nil
                }
                let errno = listJSON["errno"] as? Int ?? 0
                if errno != 0 {
                    lastListError = baiduErrorMessage(errno: errno, fallback: listJSON["errmsg"] as? String ?? listJSON["show_msg"] as? String)
                    baiduLog("[Baidu-iBoxRoute] share/list(\(source)) 失败：errno=\(errno), msg=\(lastListError), hasBDCLND=\(shareCookie.lowercased().contains("bdclnd=")), shareCookieHasBDUSS=\(shareCookie.lowercased().contains("bduss=")), shareCookieHasSTOKEN=\(shareCookie.lowercased().contains("stoken=")), url=\(listURL)")
                    return nil
                }
                return listJSON
            }

            let rootURL = "https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei&clienttype=0&desc=1&num=20&order=time&page=1&root=1&shorturl=\(encodedShortSurl)&showempty=0&view_mode=1&web=1"
            var dirsToLoad: [String] = []
            if let rootJSON = try await requestShareList(rootURL, source: "root-shorturl", includeAccountCookie: false) {
                let root = (rootJSON["data"] as? [String: Any]) ?? rootJSON
                let rootShareid = stringValue(root["share_id"]).isEmpty ? stringValue(root["shareid"]) : stringValue(root["share_id"])
                let rootUk = stringValue(root["uk"]).isEmpty ? stringValue(root["share_uk"]) : stringValue(root["uk"])
                if !rootShareid.isEmpty { shareid = rootShareid }
                if !rootUk.isEmpty { shareUk = rootUk }
                if let rawList = root["list"] as? [[String: Any]] {
                    let rootFiles = parsePlayableFiles(rawList)
                    if !rootFiles.isEmpty { files.append(contentsOf: rootFiles) }
                    dirsToLoad.append(contentsOf: rawList.filter { isDirectory($0) }.compactMap { item in
                        let path = stringValue(item["path"])
                        return path.isEmpty ? nil : path
                    })
                    baiduLog("[Baidu-iBoxRoute] root-shorturl 成功：shareid=\(!shareid.isEmpty), uk=\(!shareUk.isEmpty), files=\(rootFiles.count), dirs=\(dirsToLoad.count)")
                }
            }

            if !shareid.isEmpty, !shareUk.isEmpty, !randskForList.isEmpty {
                var seenDirs = Set<String>()
                var index = 0
                while index < dirsToLoad.count, index < 30 {
                    let dir = dirsToLoad[index]
                    index += 1
                    guard !dir.isEmpty, !seenDirs.contains(dir) else { continue }
                    seenDirs.insert(dir)
                    let dirEncoded = iBoxQueryEncoded(dir, keepSlash: true)
                    let dirURL = "https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei&clienttype=0&desc=1&dir=\(dirEncoded)&is_from_web=true&num=100&order=other&page=1&sekey=\(encodedRandsk)&shareid=\(queryEncoded(shareid))&showempty=0&uk=\(queryEncoded(shareUk))&view_mode=1&web=1"
                    if let dirJSON = try await requestShareList(dirURL, source: "dir", includeAccountCookie: true) {
                        let root = (dirJSON["data"] as? [String: Any]) ?? dirJSON
                        if let rawList = root["list"] as? [[String: Any]] {
                            let dirFiles = parsePlayableFiles(rawList)
                            if !dirFiles.isEmpty { files.append(contentsOf: dirFiles) }
                            dirsToLoad.append(contentsOf: rawList.filter { isDirectory($0) }.compactMap { item in
                                let path = stringValue(item["path"])
                                return path.isEmpty ? nil : path
                            })
                            baiduLog("[Baidu-iBoxRoute] dir-list 成功：dir=\(dir), files=\(dirFiles.count), subdirs=\(dirsToLoad.count - index)")
                        }
                    }
                }
            }

            guard !shareid.isEmpty, !shareUk.isEmpty else {
                throw DriveError.noPlayURL("百度 iBox 路链未拿到 shareid/uk")
            }
            guard !files.isEmpty else {
                throw DriveError.noPlayURL("百度 iBox share/list 未返回文件列表：\(lastListError)")
            }

            baiduStoreShareContext(
                shareURL: shareURL,
                surl: surl,
                pwd: pwd,
                shareid: shareid,
                shareUk: shareUk,
                bdstoken: bdstoken,
                randsk: randskForList,
                cookie: iBoxCookie,
                files: files,
                source: "ibox-wap-share-list",
                key: contextKey
            )
            baiduLog("[Baidu-iBoxRoute] ✅ shareid=\(shareid), uk=\(shareUk), 文件=\(files.count)")
            return (shareid, shareUk, bdstoken, surl, iBoxCookie, files, randskForList)
        } catch {
            baiduLog("[Baidu-iBoxRoute] ❌ /wap/init → share/list 失败：\(error.localizedDescription)")
            throw error
        }


    }

    private func baiduEnsureFolder(bduss: String) async throws -> String {
        let listURL = URL(string: "https://pan.baidu.com/api/list?dir=/&order=time&desc=1&num=100&page=1&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var req = URLRequest(url: listURL)
        req.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]] {
            for item in list {
                if let name = item["server_filename"] as? String, name == "vbox" { return "/vbox/" }
            }
        }
        let createURL = URL(string: "https://pan.baidu.com/api/create?a=commit&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        createReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "path=/vbox&isdir=1&block_list=[]"
        createReq.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: createReq)
        return "/vbox/"
    }

    private func baiduDeleteFiles(fileIds: [String], bduss: String, bdstoken: String? = nil) async {
        guard !fileIds.isEmpty else { return }

        // 自动检测：bduss 是完整 Cookie 字符串还是纯 BDUSS 值
        let isFullCookie = bduss.contains(";") || bduss.lowercased().contains("stoken=")
        let cookieHeader: String
        let rawBDUSS: String
        if isFullCookie {
            cookieHeader = bduss
            rawBDUSS = baiduCookieValue(bduss, named: "BDUSS") ?? bduss
        } else {
            cookieHeader = "BDUSS=\(bduss)"
            rawBDUSS = bduss
        }

        let effectiveBdstoken: String
        if let bdstoken, !bdstoken.isEmpty {
            effectiveBdstoken = bdstoken
        } else {
            // 延迟清理场景下 bdstoken 可能已过期，实时获取
            // 使用完整 cookieHeader（含 BDUSS+STOKEN）而非仅 BDUSS，确保 gettemplatevariable 认证通过
            effectiveBdstoken = await baiduFetchUserBdstokenLocal(cookie: cookieHeader) ?? ""
        }
        guard !effectiveBdstoken.isEmpty else {
            self.log("[CloudDrive] ❌ 百度删除失败：无法获取 bdstoken，跳过 \(fileIds.count) 个文件")
            return
        }
        // 对齐 iBox 2.4.6 删除 API 格式，提升兼容性
        let url = URL(string: "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&newVerify=1&clienttype=0&app_id=250528&web=1&channel=chunlei&bdstoken=\(effectiveBdstoken)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
        // 支持 fileId 或 path 两种格式：path 以 / 开头，fileId 是纯数字
        let paths = fileIds.map { $0.hasPrefix("/") ? $0 : "/vbox/\($0)" }
        let filelistJSON = (try? JSONSerialization.data(withJSONObject: paths))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let params = "filelist=\(filelistJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filelistJSON)"
        req.httpBody = params.data(using: .utf8)
        // 解析删除 API 响应，校验 errno 判断删除是否成功
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errno = json["errno"] as? Int ?? -1
            if errno == 0 {
                self.log("[CloudDrive] ✅ 百度已删除转存文件: \(paths)")
            } else {
                let errMsg = (json["errmsg"] as? String) ?? (json["error_msg"] as? String) ?? ""
                self.log("[CloudDrive] ❌ 百度删除失败 errno=\(errno)\(errMsg.isEmpty ? "" : " msg=\(errMsg)")，文件: \(paths)")
            }
        } else {
            self.log("[CloudDrive] ❌ 百度删除请求网络失败: \(paths)")
        }
    }

    /// 异步清理 /vbox/ 目录下超过2小时的旧转存文件，不阻塞调用方
    private func baiduCleanupOldTransferFiles(cookie: String, bdstoken: String) {
        baiduLog("[Baidu-Cleanup] 🔧 baiduCleanupOldTransferFiles 入口，bdstoken=\(bdstoken.prefix(8))…")
        // 守卫：bdstoken 为空时无法调用任何百度 API，直接跳过
        guard !bdstoken.isEmpty else {
            baiduLog("[Baidu-Cleanup] ⚠️ bdstoken 为空，跳过旧文件清理")
            return
        }
        guard let bdussVal = baiduCookieValue(cookie, named: "BDUSS") else {
            baiduLog("[Baidu-Cleanup] ⚠️ Cookie 中缺少 BDUSS，跳过旧文件清理")
            return
        }
        baiduLog("[Baidu-Cleanup] 🔧 守卫通过，BDUSS=\(bdussVal.prefix(8))…")

        Task {
            do {
                // 直接使用传入的 bdstoken，不再重新获取。
                // earlyPureCookie 经过过滤后可能缺少 BAIDUID 等字段，导致 gettemplatevariable 返回 errno=-6。
                // 传入的 bdstoken 是在 resolveBaiduPlayURLViaMainRoute 入口处通过完整 Cookie 获取的，有效。
                let freshBdstoken = bdstoken
                baiduLog("[Baidu-Cleanup] 🔧 使用传入的 bdstoken=\(freshBdstoken.prefix(8))…，cutoff=\(Date().addingTimeInterval(-2 * 3600))")

                let cutoff = Date().addingTimeInterval(-2 * 3600) // 2小时前
                let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir

                // 分页列出 /vbox/ 目录，每页 200 个，最多 5 页（1000 个文件）
                var allFiles: [[String: Any]] = []
                for page in 1...5 {
                    let listURL = URL(string: "https://pan.baidu.com/api/list")!
                    var components = URLComponents(url: listURL, resolvingAgainstBaseURL: false)!
                    components.queryItems = [
                        URLQueryItem(name: "bdstoken", value: freshBdstoken),
                        URLQueryItem(name: "channel", value: "chunlei"),
                        URLQueryItem(name: "web", value: "1"),
                        URLQueryItem(name: "app_id", value: "250528"),
                        URLQueryItem(name: "clienttype", value: "0")
                    ]
                    var req = URLRequest(url: components.url!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 12
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                    req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    req.httpBody = "dir=\(encodedDir)&order=time&desc=1&num=200&page=\(page)".data(using: .utf8)

                    let (data, _) = try await session.data(for: req)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        baiduLog("[Baidu-Cleanup] ⚠️ api/list 第\(page)页 JSON 解析失败")
                        break
                    }
                    let listErrno = json["errno"] as? Int ?? -1
                    guard listErrno == 0 else {
                        baiduLog("[Baidu-Cleanup] ⚠️ api/list 第\(page)页 errno=\(listErrno)")
                        break
                    }
                    // 对齐 baiduFindExistingVboxPath：兼容 api/list 多种返回格式
                    let root = (json["data"] as? [String: Any]) ?? json
                    let list = root["list"] as? [[String: Any]]
                        ?? root["file_list"] as? [[String: Any]]
                        ?? root["records"] as? [[String: Any]]
                    guard let list = list, !list.isEmpty else {
                        baiduLog("[Baidu-Cleanup] ℹ️ api/list 第\(page)页无数据，结束分页")
                        break
                    }
                    allFiles.append(contentsOf: list)
                    if list.count < 200 { break }
                }
                guard !allFiles.isEmpty else {
                    baiduLog("[Baidu-Cleanup] ⚠️ /vbox/ 目录为空或 api/list 全部失败，跳过清理")
                    return
                }

                baiduLog("[Baidu-Cleanup] 🔧 api/list 成功获取 \(allFiles.count) 个文件")

                // 找出超过2小时的文件
                // 百度 api/list 返回的时间戳字段为 server_ctime / server_mtime
                let oldFiles: [[String: Any]] = allFiles.filter { item in
                    let ctime = (item["server_ctime"] as? Int)
                        ?? (item["ctime"] as? Int)
                        ?? (item["local_ctime"] as? Int)
                        ?? 0
                    let mtime = (item["server_mtime"] as? Int)
                        ?? (item["mtime"] as? Int)
                        ?? (item["local_mtime"] as? Int)
                        ?? 0
                    let timestamp = max(ctime, mtime)
                    // 首次执行时打印每个文件的时间戳信息用于诊断
                    if let fname = item["server_filename"] as? String ?? item["path"] as? String {
                        baiduLog("[Baidu-Cleanup] 🔍 文件：\(fname)，server_ctime=\(item["server_ctime"] ?? "nil")，server_mtime=\(item["server_mtime"] ?? "nil")，mtime=\(item["mtime"] ?? "nil")，计算timestamp=\(timestamp)")
                    }
                    guard timestamp > 0 else { return false }
                    let fileDate = Date(timeIntervalSince1970: Double(timestamp))
                    return fileDate < cutoff
                }

                guard !oldFiles.isEmpty else {
                    baiduLog("[Baidu-Cleanup] ℹ️ /vbox/ 目录无超过2小时的旧文件（共 \(allFiles.count) 个文件，截止 \(cutoff)）")
                    return
                }

                // 批量删除
                let paths = oldFiles.compactMap { $0["path"] as? String }
                baiduLog("[Baidu-Cleanup] 🔍 待删除文件路径：\(paths)")
                let encodedList = try? JSONSerialization.data(withJSONObject: paths)
                let fileListStr = String(data: encodedList ?? Data(), encoding: .utf8) ?? "[]"
                baiduLog("[Baidu-Cleanup] 🔍 filelist 原始值：\(fileListStr)")
                let encodedFileList = fileListStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileListStr
                baiduLog("[Baidu-Cleanup] 🔍 filelist 编码后：\(encodedFileList)")
                let bodyStr = "filelist=\(encodedFileList)"
                baiduLog("[Baidu-Cleanup] 🔍 删除请求 body：\(bodyStr)")
                baiduLog("[Baidu-Cleanup] 🔍 删除请求 Cookie BDUSS=\(baiduCookieValue(cookie, named: "BDUSS")?.prefix(8) ?? "nil")… STOKEN=\(baiduCookieValue(cookie, named: "STOKEN")?.prefix(8) ?? "nil")… bdstoken=\(freshBdstoken.prefix(8))…")

                // 对齐 iBox 删除 API 格式
                let deleteURL = URL(string: "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&newVerify=1&clienttype=0&app_id=250528&web=1&channel=chunlei&bdstoken=\(freshBdstoken)")!
                var delReq = URLRequest(url: deleteURL)
                delReq.httpMethod = "POST"
                delReq.timeoutInterval = 12
                delReq.setValue(cookie, forHTTPHeaderField: "Cookie")
                delReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                delReq.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
                delReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                delReq.httpBody = bodyStr.data(using: .utf8)

                if let (delData, delResp) = try? await session.data(for: delReq),
                   let delJson = try? JSONSerialization.jsonObject(with: delData) as? [String: Any] {
                    let delErrno = delJson["errno"] as? Int ?? -1
                    if delErrno == 0 {
                        baiduLog("[Baidu-Cleanup] ✅ 已清理 \(oldFiles.count) 个超过2小时的旧转存文件")
                    } else {
                        let delErrMsg = (delJson["errmsg"] as? String) ?? (delJson["error_msg"] as? String) ?? ""
                        baiduLog("[Baidu-Cleanup] ❌ 批量删除失败 errno=\(delErrno)\(delErrMsg.isEmpty ? "" : " msg=\(delErrMsg)")")
                    }
                    baiduLog("[Baidu-Cleanup] 🔍 删除完整响应 HTTP \((delResp as? HTTPURLResponse)?.statusCode ?? 0)：\(String(data: delData, encoding: .utf8) ?? "(非UTF8)")")
                } else {
                    baiduLog("[Baidu-Cleanup] ❌ 批量删除请求网络失败")
                }
            } catch {
                baiduLog("[Baidu-Cleanup] ⚠️ 清理旧转存文件失败（不影响播放）：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 115 网盘

    func resolve115PlayURL(shareURL: String, cid: String) async throws -> PlayResult {
        print("[115] 开始解析: \(shareURL)")
        let cookie = normalize115Cookie(cid)
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        let snapResult = try await one15FirstPlayableFile(
            shareCode: shareCode,
            receiveCode: receiveCode,
            cid: "0",
            cookie: cookie
        )

        let pickCode = snapResult.pickCode
        let fileId = snapResult.cid
        print("[115] 选中资源：\(snapResult.fileName ?? "未知文件"), pickCode=\(pickCode ?? "nil"), fid=\(fileId ?? "nil")")

        let (downloadURL, extraCookie) = try await one15GetDownloadURL(
            pickCode: pickCode,
            cookie: cookie,
            shareCode: shareCode,
            receiveCode: receiveCode,
            fileId: fileId
        )

        // 合并 Set-Cookie 到播放头（115 CDN 要求带下载凭证 cookie）
        var headers = one15PlaybackHeaders(cookie: cookie)
        if let extra = extraCookie, !extra.isEmpty {
            let combined = "\(cookie); \(extra)"
            headers["Cookie"] = combined
            print("[115] 合并 Set-Cookie 到播放头")
        }

        return PlayResult(
            url: downloadURL,
            headers: headers,
            driveType: .one15,
            source: "m115-multi-endpoint"
        )
    }

    private func extract115ShareCode(from url: String) async throws -> (shareCode: String, receiveCode: String) {
        var shareCode = ""
        var receiveCode = ""

        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            shareCode = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        receiveCode = queryItems.first(where: { ["password", "pwd", "passcode"].contains($0.name.lowercased()) })?.value ?? ""
        if receiveCode.isEmpty, let range = url.range(of: #"(提取码|访问码|密码)[:：\s]*([A-Za-z0-9]{4,8})"#, options: .regularExpression) {
            let matched = String(url[range])
            receiveCode = matched.components(separatedBy: CharacterSet(charactersIn: ":： ")).last ?? ""
        }

        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }
        return (shareCode, receiveCode)
    }

    private struct One15SnapResult {
        let pickCode: String?
        let cid: String?
        let fileName: String?
        let isDir: Bool
    }

    private func one15FirstPlayableFile(shareCode: String, receiveCode: String, cid: String, cookie: String) async throws -> One15SnapResult {
        let list = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid, cookie: cookie)
        if let playable = list.first(where: { !$0.isDir && one15IsPlayableFileName($0.fileName ?? "") }) {
            return playable
        }
        for dir in list where dir.isDir {
            guard let nextCid = dir.cid, !nextCid.isEmpty else { continue }
            if let found = try? await one15FirstPlayableFile(shareCode: shareCode, receiveCode: receiveCode, cid: nextCid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("115: 分享内未找到可播放视频")
    }

    private func one15Snap(shareCode: String, receiveCode: String, cid: String, cookie: String) async throws -> [One15SnapResult] {
        // 先调用 share/receive 接收分享（115 要求先接收分享才能获取完整的文件信息含 pick_code）
        await one15ReceiveShare(shareCode: shareCode, receiveCode: receiveCode, cookie: cookie)

        var components = URLComponents(string: "https://webapi.115.com/share/snap")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "limit", value: "100")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("[115] snap 响应: HTTP \(httpStatus), bytes=\(data.count)")

        // 记录原始响应内容用于诊断
        let rawBody = String(data: data.prefix(1000), encoding: .utf8) ?? "(binary)"
        print("[115] snap 原始响应: \(rawBody)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "(binary)"
            print("[115] snap 响应非 JSON: \(bodyPreview)")
            throw DriveError.invalidResponse
        }
        if let state = json["state"] as? Bool, state == false {
            let message = json["error"] as? String ?? json["message"] as? String ?? "115 snap 失败"
            print("[115] snap state=false: \(message), HTTP \(httpStatus), 完整响应: \(json)")
            throw DriveError.noPlayURL("115: \(message)")
        }
        // 兼容 data 在不同层级的情况
        guard let dataDict = json["data"] as? [String: Any] else {
            // 某些情况下 snap 直接返回文件列表（无 data 包裹）
            if let directList = json["list"] as? [[String: Any]], !directList.isEmpty {
                print("[115] snap 直接返回 list（无 data 包裹），共 \(directList.count) 项")
                let results = directList.compactMap { one15ParseSnapItem($0) }
                print("[115] snap 解析结果: \(results.count) 项，其中含 pickCode 的: \(results.filter { $0.pickCode != nil }.count)")
                return results
            }
            print("[115] snap 响应缺少 data 字段，顶层 keys: \(json.keys.sorted())")
            throw DriveError.invalidResponse
        }

        let rawList = (dataDict["list"] as? [[String: Any]])
            ?? (dataDict["data"] as? [[String: Any]])
            ?? []
        print("[115] snap data.list 共 \(rawList.count) 项")
        if let firstItem = rawList.first {
            print("[115] snap 首项所有字段: \(firstItem.keys.sorted())")
            print("[115] snap 首项内容: \(firstItem)")
        }
        let result = rawList.compactMap { one15ParseSnapItem($0) }
        print("[115] snap 解析结果: \(result.count) 项，其中含 pickCode 的: \(result.filter { $0.pickCode != nil }.count)")
        if !result.isEmpty {
            return result
        }

        if let pickCode = (dataDict["pick_code"] as? String) ?? (dataDict["pickcode"] as? String) {
            return [One15SnapResult(pickCode: pickCode, cid: dataDict["cid"] as? String, fileName: dataDict["file_name"] as? String, isDir: false)]
        }

        throw DriveError.noPlayURL("115: 分享列表为空或未返回 pick_code")
    }

    /// 接收 115 分享（在调用 snap 前先接收，确保能获取到 pick_code）
    private func one15ReceiveShare(shareCode: String, receiveCode: String, cookie: String) async {
        var components = URLComponents(string: "https://webapi.115.com/share/receive")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let state = json["state"] as? Bool ?? false
                let msg = json["error"] as? String ?? json["message"] as? String ?? ""
                print("[115] receive: HTTP \(httpStatus), state=\(state), msg=\(msg)")
                if let dataDict = json["data"] as? [String: Any] {
                    print("[115] receive data keys: \(dataDict.keys.sorted())")
                }
            } else {
                print("[115] receive: HTTP \(httpStatus), 响应非 JSON")
            }
        } catch {
            print("[115] receive 请求失败（不影响后续 snap 调用）: \(error.localizedDescription)")
        }
    }

    /// 解析 snap 返回的单个文件项，兼容多种字段名
    private func one15ParseSnapItem(_ item: [String: Any]) -> One15SnapResult? {
        let name = item["n"] as? String
            ?? item["file_name"] as? String
            ?? item["name"] as? String
        // pick_code 字段名兼容：pc / pick_code / pickcode / pick / oid
        let pick = item["pc"] as? String
            ?? item["pick_code"] as? String
            ?? item["pickcode"] as? String
            ?? item["pick"] as? String
            ?? item["oid"] as? String
        let itemCid: String? = {
            if let s = item["cid"] as? String { return s }
            if let s = item["fid"] as? String { return s }
            if let s = item["id"] as? String { return s }
            if let s = item["file_id"] as? String { return s }
            if let i = item["cid"] as? Int { return String(i) }
            if let i = item["fid"] as? Int { return String(i) }
            if let i = item["id"] as? Int { return String(i) }
            return nil
        }()
        let isDir: Bool
        if let boolValue = item["is_dir"] as? Bool {
            isDir = boolValue
        } else if let fc = item["fc"] as? String, !fc.isEmpty {
            isDir = true
        } else if let category = item["file_category"] as? String {
            isDir = category == "0"
        } else if let pid = item["pid"] as? String, !pid.isEmpty {
            isDir = false
        } else {
            isDir = false
        }
        guard name != nil || pick != nil || itemCid != nil else { return nil }
        // pick_code 为空时保留 nil，不再用 fid 冒充（fid ≠ pickcode，会导致下载 API 返回 state:false）
        // fid 仍保留在 cid 字段中，供 share/downurl 兜底端点使用
        let finalPick = pick
        if finalPick == nil {
            print("[115] ⚠️ 文件 '\(name ?? "?")' 无 pick_code，fid=\(itemCid ?? "?")，将走 share/downurl 兜底端点")
        }
        return One15SnapResult(pickCode: finalPick, cid: itemCid, fileName: name, isDir: isDir)
    }

    /// 获取 115 下载直链（4 端点策略，与 aliproxy 一致）
    ///
    /// 端点优先级:
    /// 1. m3u8 流媒体（115.com/api/video/m3u8/）— 视频首选，AVPlayer HLS
    /// 2. chrome/downurl + RSA（proapi.115.com/app/chrome/downurl）— 通用，M115Cipher
    /// 3. files/video（webapi.115.com/files/video）— 视频信息
    /// 4. share/downurl（proapi.115.com/app/share/downurl）— 分享兜底，用 fid
    private func one15GetDownloadURL(
        pickCode: String?,
        cookie: String,
        shareCode: String,
        receiveCode: String,
        fileId: String?
    ) async throws -> (url: String, extraCookie: String?) {
        var lastError: Error?

        // 端点 1: m3u8 流媒体（不需要 RSA，视频播放首选）
        if let pc = pickCode, !pc.isEmpty {
            do {
                let url = try await one15TryM3U8Stream(pickCode: pc, cookie: cookie)
                print("[115] ✅ m3u8 获取成功，host=\(URL(string: url)?.host ?? "unknown")")
                return (url, nil)
            } catch {
                print("[115] ❌ m3u8 失败: \(error.localizedDescription)")
                lastError = error
            }
        }

        // 端点 2: chrome/downurl + RSA
        if let pc = pickCode, !pc.isEmpty {
            do {
                let (url, extra) = try await one15TryChromeDownurl(pickCode: pc, cookie: cookie)
                print("[115] ✅ chrome/downurl(RSA) 获取成功，host=\(URL(string: url)?.host ?? "unknown")")
                return (url, extra)
            } catch {
                print("[115] ❌ chrome/downurl(RSA) 失败: \(error.localizedDescription)")
                lastError = error
            }
        }

        // 端点 3: files/video（不需要 RSA）
        if let pc = pickCode, !pc.isEmpty {
            do {
                let url = try await one15TryFilesVideo(pickCode: pc, cookie: cookie)
                print("[115] ✅ files/video 获取成功，host=\(URL(string: url)?.host ?? "unknown")")
                return (url, nil)
            } catch {
                print("[115] ❌ files/video 失败: \(error.localizedDescription)")
                lastError = error
            }
        }

        // 端点 4: share/downurl 兜底（用 fid，不需要 RSA）
        if let fid = fileId, !fid.isEmpty {
            do {
                let url = try await one15TryShareDownurl(
                    shareCode: shareCode, receiveCode: receiveCode,
                    fileId: fid, cookie: cookie
                )
                print("[115] ✅ share/downurl 获取成功，host=\(URL(string: url)?.host ?? "unknown")")
                return (url, nil)
            } catch {
                print("[115] ❌ share/downurl 失败: \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError ?? DriveError.noPlayURL("115: 所有下载接口均失败（无 pick_code 和 fid）")
    }

    // MARK: - 端点 1: m3u8 流媒体

    /// 115 官方 m3u8 流媒体端点（aliproxy 使用的端点，不需要 RSA）
    /// GET https://115.com/api/video/m3u8/{pickcode}
    private func one15TryM3U8Stream(pickCode: String, cookie: String) async throws -> String {
        let urlStr = "https://115.com/api/video/m3u8/\(pickCode)"
        var request = URLRequest(url: URL(string: urlStr)!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 302 重定向到 CDN m3u8
        if let finalURL = response.url, finalURL.absoluteString.contains(".m3u8") {
            print("[115] m3u8 302 重定向到: \(finalURL.host ?? "")")
            return finalURL.absoluteString
        }

        // 200 返回 m3u8 内容
        if httpStatus == 200 {
            let body = String(data: data.prefix(100), encoding: .utf8) ?? ""
            if body.contains("#EXTM3U") {
                return urlStr  // 直接返回 URL，AVPlayer 自行请求
            }
            // 可能返回 JSON 包含 m3u8 URL
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let m3u8 = json["url"] as? String, m3u8.hasPrefix("http") { return m3u8 }
                if let videoUrl = json["video_url"] as? String, videoUrl.hasPrefix("http") { return videoUrl }
            }
        }

        throw DriveError.noPlayURL("115: m3u8 端点不可用 (HTTP \(httpStatus))")
    }

    // MARK: - 端点 2: chrome/downurl + RSA（M115Cipher）

    /// 115 chrome/downurl 端点（aliproxy 使用的端点，POST + RSA 加解密）
    /// POST https://proapi.115.com/app/chrome/downurl?t={timestamp}
    /// Body: data=RSA_encrypt({"pickcode":"xxx"})
    private func one15TryChromeDownurl(pickCode: String, cookie: String) async throws -> (url: String, extraCookie: String?) {
        let cipher = try M115Cipher()

        // 1. 加密请求: {"pickcode":"xxx"}
        let plainText = "{\"pickcode\":\"\(pickCode)\"}"
        let encryptedData = try cipher.encrypt(Array(plainText.utf8))

        // 2. POST 请求
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var components = URLComponents(string: "https://proapi.115.com/app/chrome/downurl")!
        components.queryItems = [URLQueryItem(name: "t", value: timestamp)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyStr = "data=\(encryptedData)"
        request.httpBody = bodyStr.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 捕获 Set-Cookie
        var extraCookie: String? = nil
        if let setCookie = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie") {
            extraCookie = setCookie
        }

        print("[115] chrome/downurl: HTTP \(httpStatus), bytes=\(data.count)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("115: chrome/downurl 响应非 JSON")
        }

        guard json["state"] as? Bool == true else {
            let msg = json["error"] as? String ?? "chrome/downurl state=false"
            throw DriveError.noPlayURL("115: \(msg)")
        }

        // 响应格式: {"state":true, "data": {"<pickcode>": "<RSA_encrypted_base64>"}}
        guard let dataDict = json["data"] as? [String: Any] else {
            throw DriveError.noPlayURL("115: chrome/downurl 缺少 data 字段")
        }

        // 查找加密的响应值（key 是 pickcode）
        var encryptedResponse: String?
        for (key, value) in dataDict {
            if key == pickCode, let str = value as? String {
                encryptedResponse = str
                break
            }
        }
        // 兜底: 取第一个字符串值
        if encryptedResponse == nil {
            for (_, value) in dataDict {
                if let str = value as? String, !str.isEmpty {
                    encryptedResponse = str
                    break
                }
            }
        }

        guard let encResp = encryptedResponse else {
            throw DriveError.noPlayURL("115: chrome/downurl 未找到加密响应")
        }

        // 3. RSA 解密响应
        let decryptedBytes = try cipher.decrypt(encResp)
        let decryptedStr = String(bytes: decryptedBytes, encoding: .utf8) ?? ""
        print("[115] chrome/downurl 解密结果: \(decryptedStr.prefix(200))")

        // 4. 从解密 JSON 提取下载 URL
        guard let decJson = try? JSONSerialization.jsonObject(
            with: Data(decryptedBytes)
        ) as? [String: Any] else {
            throw DriveError.noPlayURL("115: chrome/downurl 解密结果非 JSON")
        }

        // 格式: {"file_name":"...", "url": {"url":"https://cdn...", ...}}
        if let urlDict = decJson["url"] as? [String: Any],
           let url = urlDict["url"] as? String, url.hasPrefix("http") {
            return (url, extraCookie)
        }
        // 兜底递归搜索
        if let url = one15ExtractURL(from: decJson) {
            return (url, extraCookie)
        }

        throw DriveError.noPlayURL("115: chrome/downurl 解密结果中未找到 URL")
    }

    // MARK: - 端点 3: files/video

    /// 115 files/video 端点（aliproxy 使用的端点，不需要 RSA）
    /// GET https://webapi.115.com/files/video?pick_code={pc}
    private func one15TryFilesVideo(pickCode: String, cookie: String) async throws -> String {
        var components = URLComponents(string: "https://webapi.115.com/files/video")!
        components.queryItems = [URLQueryItem(name: "pick_code", value: pickCode)]

        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("115: files/video 响应非 JSON")
        }

        // video_url 字段包含下载直链
        if let videoUrl = json["video_url"] as? String, videoUrl.hasPrefix("http") {
            return videoUrl
        }
        // 兜底搜索
        if let url = one15ExtractURL(from: json) {
            return url
        }

        throw DriveError.noPlayURL("115: files/video 未返回 video_url")
    }

    // MARK: - 端点 4: share/downurl 兜底

    /// 115 share/downurl 端点（aliproxy 使用的端点，不需要 RSA，用 fid 而非 pickcode）
    /// GET https://proapi.115.com/app/share/downurl?share_code=x&receive_code=x&file_id=x
    private func one15TryShareDownurl(
        shareCode: String, receiveCode: String,
        fileId: String, cookie: String
    ) async throws -> String {
        var components = URLComponents(string: "https://proapi.115.com/app/share/downurl")!
        components.queryItems = [
            URLQueryItem(name: "share_code", value: shareCode),
            URLQueryItem(name: "receive_code", value: receiveCode),
            URLQueryItem(name: "file_id", value: fileId),
            URLQueryItem(name: "app_ver", value: "27.0.5.7")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.one15UA, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("115: share/downurl 响应非 JSON")
        }

        guard json["state"] as? Bool == true else {
            let msg = json["error"] as? String ?? "share/downurl state=false"
            throw DriveError.noPlayURL("115: \(msg)")
        }

        // 响应格式: {state:true, data:{url:{url:"https://cdn...", ...}}}
        if let dataDict = json["data"] as? [String: Any] {
            if let urlDict = dataDict["url"] as? [String: Any],
               let url = urlDict["url"] as? String, url.hasPrefix("http") {
                return url
            }
            if let url = one15ExtractURL(from: dataDict) {
                return url
            }
        }
        if let url = one15ExtractURL(from: json) {
            return url
        }

        throw DriveError.noPlayURL("115: share/downurl 未返回下载 URL")
    }

    private func one15ExtractURL(from value: Any) -> String? {
        if let text = value as? String, text.hasPrefix("http") {
            return text
        }
        if let dict = value as? [String: Any] {
            for key in ["url", "download_url", "dlink", "file_url", "fileUrl", "downloadUrl"] {
                if let text = dict[key] as? String, text.hasPrefix("http") { return text }
                if let nested = dict[key], let url = one15ExtractURL(from: nested) { return url }
            }
            for item in dict.values {
                if let url = one15ExtractURL(from: item) { return url }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let url = one15ExtractURL(from: item) { return url }
            }
        }
        return nil
    }

    /// 115 网盘统一 User-Agent
    /// 使用 115Browser UA（与 aliproxy 一致），115 API 对 UA 敏感
    private static let one15UA = "Mozilla/5.0 115Browser/27.0.5.7"

    private func normalize115Cookie(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var cookie = trimmed
        if cookie.lowercased().hasPrefix("cookie:") {
            cookie = String(cookie.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !cookie.contains("=") {
            cookie = "CID=\(cookie)"
        }
        // 校验 Cookie 完整性：115 网盘要求 UID + CID + SEID，KID 为新版 API 推荐字段
        let lower = cookie.lowercased()
        let hasUID = lower.contains("uid=")
        let hasCID = lower.contains("cid=")
        let hasKID = lower.contains("kid=")
        if !hasUID || !hasCID {
            print("[115] ⚠️ Cookie 可能不完整（UID=\(hasUID), CID=\(hasCID), KID=\(hasKID)），可能导致 API 调用失败")
        } else if !hasKID {
            print("[115] ⚠️ Cookie 缺少 KID 参数，115 新版 API 可能需要此字段")
        } else {
            print("[115] ✅ Cookie 完整性检查通过（UID + CID + KID）")
        }
        return cookie
    }

    private func one15PlaybackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": Self.one15UA,
            "Referer": "https://115.com/",
            "Origin": "https://115.com",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    private func one15IsPlayableFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["mp4", "mkv", "mov", "m3u8", "avi", "wmv", "flv", "ts", "m4v"].contains { lower.hasSuffix(".\($0)") }
    }

    // MARK: - 115网盘文件列表（多文件/文件夹支持）

    struct One15ShareFilePublic {
        let pickCode: String
        let fileName: String
    }

    /// 获取115网盘分享链接中的所有可播放视频文件（递归遍历子文件夹）
    func one15GetAllPlayableFiles(shareURL: String, cid: String) async throws -> [One15ShareFilePublic] {
        print("[115] 📂 获取所有可播放文件: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [115] 获取文件列表...")

        let cookie = normalize115Cookie(cid)
        let (shareCode, receiveCode) = try await extract115ShareCode(from: shareURL)

        var allVideos: [One15ShareFilePublic] = []
        try await one15CollectPlayableFiles(
            shareCode: shareCode, receiveCode: receiveCode, cid: "0", cookie: cookie,
            into: &allVideos
        )

        print("[115] ✅ 可播放文件获取成功: \(allVideos.count) 个")
        self.log("[CloudDrive] [115] ✅ 文件列表: \(allVideos.count) 个文件")
        return allVideos
    }

    private func one15CollectPlayableFiles(
        shareCode: String, receiveCode: String, cid: String, cookie: String,
        into result: inout [One15ShareFilePublic]
    ) async throws {
        let list = try await one15Snap(shareCode: shareCode, receiveCode: receiveCode, cid: cid, cookie: cookie)
        for item in list {
            if !item.isDir && one15IsPlayableFileName(item.fileName ?? "") {
                if let pickCode = item.pickCode, !pickCode.isEmpty {
                    result.append(One15ShareFilePublic(pickCode: pickCode, fileName: item.fileName ?? "未知文件"))
                }
            } else if item.isDir, let nextCid = item.cid, !nextCid.isEmpty {
                try await one15CollectPlayableFiles(
                    shareCode: shareCode, receiveCode: receiveCode, cid: nextCid, cookie: cookie,
                    into: &result
                )
            }
        }
    }

    /// 解析115网盘指定文件的播放地址（用于多文件选集播放）
    func resolve115FilePlayURL(shareURL: String, cid: String, pickCode: String, fileName: String) async throws -> PlayResult {
        print("[115] 🎬 解析指定文件: pickCode=\(pickCode) name=\(fileName)")
        self.log("[CloudDrive] [115] 解析文件: \(fileName)")

        let cookie = normalize115Cookie(cid)
        // 提取 shareCode/receiveCode 供兜底端点使用
        let (shareCode, receiveCode) = (try? await extract115ShareCode(from: shareURL)) ?? ("", "")

        let (downloadURL, extraCookie) = try await one15GetDownloadURL(
            pickCode: pickCode,
            cookie: cookie,
            shareCode: shareCode,
            receiveCode: receiveCode,
            fileId: nil
        )

        var headers = one15PlaybackHeaders(cookie: cookie)
        if let extra = extraCookie, !extra.isEmpty {
            headers["Cookie"] = "\(cookie); \(extra)"
        }

        return PlayResult(
            url: downloadURL,
            headers: headers,
            driveType: .one15,
            source: fileName
        )
    }

    // MARK: - 123云盘

    func resolve123PanPlayURL(shareURL: String, token: String) async throws -> PlayResult {
        print("[123Pan] 开始解析: \(shareURL)")
        let shareCode = extract123PanShareCode(from: shareURL)
        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": "https://www.123pan.com/",
            "Origin": "https://www.123pan.com"
        ]

        let accessToken = CloudDriveAuthManager.shared.credential(for: .pan123)?.accessToken

        // 123云盘分享解析API（使用 URLComponents 避免 shareCode 未编码）
        var components = URLComponents(string: "https://www.123pan.com/b/api/share/get")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "next", value: "1"),
            URLQueryItem(name: "orderBy", value: "share_id"),
            URLQueryItem(name: "orderDirection", value: "desc"),
            URLQueryItem(name: "shareKey", value: shareCode),
            URLQueryItem(name: "SharePwd", value: ""),
            URLQueryItem(name: "ParentFileId", value: "0"),
            URLQueryItem(name: "Page", value: "1")
        ]
        guard let apiURL = components.url else {
            throw DriveError.invalidShareURL
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Cookie")
        if let accessToken = accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("123云盘: 分享列表返回无法解析")
        }
        // 先检查 code 是否表示失败
        if let code = json["code"] as? Int, code != 0, code != 200 {
            let msg = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("123云盘: 分享列表接口返回错误: \(msg)")
        }
        if let code = json["code"] as? String, code != "0", code != "200", code.lowercased() != "ok" {
            let msg = json["message"] as? String ?? code
            throw DriveError.noPlayURL("123云盘: 分享列表接口返回错误: \(msg)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["InfoList"] as? [[String: Any]],
              let firstFile = list.first else {
            throw DriveError.noPlayURL("123云盘: 无法获取文件列表")
        }

        // 兼容 fileId 为 Int/String，eTag 字段大小写
        let fileId: Any
        if let id = firstFile["FileId"] as? Int {
            fileId = id
        } else if let idStr = firstFile["FileId"] as? String, !idStr.isEmpty {
            fileId = idStr
        } else {
            throw DriveError.noPlayURL("123云盘: 无法提取文件信息")
        }
        let eTag = firstFile["Etag"] as? String
            ?? firstFile["ETag"] as? String
            ?? firstFile["etag"] as? String
        guard let eTag, !eTag.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 无法提取 ETag")
        }

        // 获取下载链接
        let downloadURL = URL(string: "https://www.123pan.com/a/api/file/download_info")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        downloadReq.setValue(token, forHTTPHeaderField: "Cookie")
        if let accessToken = accessToken, !accessToken.isEmpty {
            downloadReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["fileId": fileId, "etag": eTag, "shareKey": shareCode, "SharePwd": ""]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any] else {
            throw DriveError.noPlayURL("123云盘: 无法获取下载链接")
        }
        let downloadUrl = dlDataObj["DownloadUrl"] as? String
            ?? dlDataObj["download_url"] as? String
            ?? dlDataObj["url"] as? String
        guard let downloadUrl, !downloadUrl.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 下载链接为空")
        }

        return PlayResult(
            url: downloadUrl,
            headers: headers,
            driveType: .pan123,
            source: "123pan_direct"
        )
    }

    private func extract123PanShareCode(from url: String) -> String {
        if let range = url.range(of: #"/s/([a-zA-Z0-9\-]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        return ""
    }

    // MARK: - 123云盘文件列表（多文件/文件夹支持）

    struct Pan123ShareFile {
        let fileId: String
        let fileName: String
        let eTag: String
    }

    private func pan123IsDirItem(_ item: [String: Any]) -> Bool {
        // 优先检查常见的文件夹类型字段
        if let type = item["Type"] as? Int { return type == 1 || type == 2 }  // 123盘常见 1=文件夹
        if let type = item["ContentType"] as? Int { return type == 1 || type == 2 }
        if let typeStr = item["Type"] as? String {
            return typeStr.lowercased() == "folder" || typeStr.lowercased() == "dir"
        }
        if let isDir = item["IsDir"] as? Bool { return isDir }
        if let isDir = item["isDir"] as? Bool { return isDir }
        if let isDir = item["is_dir"] as? Bool { return isDir }
        // 兜底：无扩展名且有 FileId/FileName 的视为文件夹
        let name = item["FileName"] as? String ?? item["fileName"] as? String ?? ""
        if !name.isEmpty && !name.contains(".") {
            return true
        }
        return false
    }

    private func pan123FetchDir(shareCode: String, parentFileId: String, token: String, accessToken: String?) async throws -> [[String: Any]] {
        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": "https://www.123pan.com/",
            "Origin": "https://www.123pan.com"
        ]

        var allItems: [[String: Any]] = []
        var page = 1
        let maxPages = 10

        while page <= maxPages {
            var components = URLComponents(string: "https://www.123pan.com/b/api/share/get")!
            components.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "next", value: "1"),
                URLQueryItem(name: "orderBy", value: "share_id"),
                URLQueryItem(name: "orderDirection", value: "desc"),
                URLQueryItem(name: "shareKey", value: shareCode),
                URLQueryItem(name: "SharePwd", value: ""),
                URLQueryItem(name: "ParentFileId", value: parentFileId),
                URLQueryItem(name: "Page", value: "\(page)")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "Cookie")
            if let accessToken = accessToken, !accessToken.isEmpty {
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

            let (data, _) = try await session.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DriveError.noPlayURL("123云盘: 分享列表返回无法解析")
            }
            if let code = json["code"] as? Int, code != 0, code != 200 {
                let msg = json["message"] as? String ?? "code=\(code)"
                throw DriveError.noPlayURL("123云盘: \(msg)")
            }
            guard let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["InfoList"] as? [[String: Any]] else {
                break
            }

            allItems.append(contentsOf: list)

            // 检查是否还有下一页
            if list.count < 100 { break }
            page += 1
        }

        return allItems
    }

    /// 获取123云盘分享链接中的所有视频文件（递归遍历子文件夹）
    func pan123GetAllFiles(shareURL: String, token: String) async throws -> [Pan123ShareFile] {
        print("[123Pan] 📂 获取文件列表（递归）: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [123] 获取文件列表...")

        let shareCode = extract123PanShareCode(from: shareURL)
        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }

        let accessToken = CloudDriveAuthManager.shared.credential(for: .pan123)?.accessToken

        let videoExts = ["mp4", "mkv", "mov", "avi", "wmv", "flv", "ts", "m4v", "rmvb", "rm"]
        var allVideoFiles: [Pan123ShareFile] = []
        var allFilesFallback: [Pan123ShareFile] = []

        // BFS 递归遍历所有子文件夹
        var dirsToLoad: [(id: String, name: String)] = [("0", "根目录")]
        var loadedDirs = Set<String>()
        let maxDirs = 30
        let maxVideos = 500

        while !dirsToLoad.isEmpty && allVideoFiles.count < maxVideos {
            guard loadedDirs.count < maxDirs else {
                print("[123Pan] ⚠️ 已达目录数量上限 (\(maxDirs))，停止递归")
                break
            }

            let current = dirsToLoad.removeFirst()
            guard !loadedDirs.contains(current.id) else { continue }
            loadedDirs.insert(current.id)

            let items: [[String: Any]]
            do {
                items = try await pan123FetchDir(
                    shareCode: shareCode,
                    parentFileId: current.id,
                    token: token,
                    accessToken: accessToken
                )
            } catch {
                print("[123Pan] ⚠️ 加载目录失败: \(current.name), \(error.localizedDescription)")
                continue
            }

            for item in items {
                let name = item["FileName"] as? String ?? item["fileName"] as? String ?? "未知文件"
                let fileId: String
                if let id = item["FileId"] as? Int { fileId = String(id) }
                else if let idStr = item["FileId"] as? String, !idStr.isEmpty { fileId = idStr }
                else { continue }
                let eTag = item["Etag"] as? String ?? item["ETag"] as? String ?? item["etag"] as? String ?? ""
                guard !eTag.isEmpty else { continue }

                let isDir = pan123IsDirItem(item)

                if isDir {
                    // 子文件夹，加入队列
                    if !loadedDirs.contains(fileId) {
                        dirsToLoad.append((fileId, name))
                    }
                } else {
                    // 收集所有文件作为兜底
                    allFilesFallback.append(Pan123ShareFile(fileId: fileId, fileName: name, eTag: eTag))
                    // 筛选视频文件
                    let lowerName = name.lowercased()
                    if videoExts.contains(where: { lowerName.hasSuffix(".\($0)") }) {
                        allVideoFiles.append(Pan123ShareFile(fileId: fileId, fileName: name, eTag: eTag))
                    }
                }
            }
        }

        // 如果递归后还是没有视频文件，返回所有文件作为兜底
        let result = allVideoFiles.isEmpty ? allFilesFallback : allVideoFiles

        print("[123Pan] ✅ 递归获取完成: \(result.count) 个文件（视频 \(allVideoFiles.count) 个，遍历了 \(loadedDirs.count) 个目录）")
        self.log("[CloudDrive] [123] ✅ 文件列表: \(result.count) 个文件")

        guard !result.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 分享内未找到文件")
        }

        return result
    }

    /// 解析123云盘指定文件的播放地址（用于多文件选集播放）
    func resolve123FilePlayURL(shareURL: String, token: String, fileId: String, eTag: String, fileName: String) async throws -> PlayResult {
        print("[123Pan] 🎬 解析指定文件: fileId=\(fileId) name=\(fileName)")
        self.log("[CloudDrive] [123] 解析文件: \(fileName)")

        let shareCode = extract123PanShareCode(from: shareURL)
        let accessToken = CloudDriveAuthManager.shared.credential(for: .pan123)?.accessToken
        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": "https://www.123pan.com/",
            "Origin": "https://www.123pan.com"
        ]

        let downloadURL = URL(string: "https://www.123pan.com/a/api/file/download_info")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        downloadReq.setValue(token, forHTTPHeaderField: "Cookie")
        if let accessToken = accessToken, !accessToken.isEmpty {
            downloadReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["fileId": fileId, "etag": eTag, "shareKey": shareCode, "SharePwd": ""]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any] else {
            throw DriveError.noPlayURL("123云盘: 无法获取下载链接")
        }
        let downloadUrl = dlDataObj["DownloadUrl"] as? String
            ?? dlDataObj["download_url"] as? String
            ?? dlDataObj["url"] as? String
        guard let downloadUrl, !downloadUrl.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 下载链接为空")
        }

        return PlayResult(url: downloadUrl, headers: headers, driveType: .pan123, source: fileName)
    }

    // MARK: - 139云盘

    func resolve139PanPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[139Pan] 开始解析: \(shareURL)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36",
            "Referer": "https://yun.139.com/",
            "Origin": "https://yun.139.com",
            "Cookie": cookie
        ]

        // 139云盘分享链接解析
        // 139云盘分享格式: https://yun.139.com/link/w/i/xxx 或 https://caiyun.139.com/w/i/xxx
        guard let urlComponents = URLComponents(string: shareURL),
              let path = urlComponents.path.components(separatedBy: "/").last,
              !path.isEmpty else {
            throw DriveError.invalidShareURL
        }

        // 调用139云盘开放API获取分享内容
        let apiURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentInfoFromOutLink")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["linkId": path, "password": ""]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let contentList = dataObj["contentList"] as? [[String: Any]],
              let firstFile = contentList.first else {
            throw DriveError.noPlayURL("139云盘: 无法获取分享内容")
        }

        guard let contentId = firstFile["contentId"] as? String,
              let catalogId = firstFile["catalogId"] as? String else {
            throw DriveError.noPlayURL("139云盘: 无法提取文件信息")
        }

        // 获取下载链接
        let downloadURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentDownloadUrl")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let dlBody: [String: Any] = [
            "contentId": contentId,
            "catalogId": catalogId,
            "linkId": path
        ]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: dlBody)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any],
              let downloadUrl = dlDataObj["downloadUrl"] as? String else {
            throw DriveError.noPlayURL("139云盘: 无法获取下载链接")
        }

        return PlayResult(
            url: downloadUrl,
            headers: headers,
            driveType: .pan139,
            source: "139pan_direct"
        )
    }

    // MARK: - 139云盘文件列表（多文件支持）

    struct Pan139ShareFile {
        let contentId: String
        let catalogId: String
        let fileName: String
    }

    private func pan139IsDirItem(_ item: [String: Any]) -> Bool {
        // 优先检查类型字段
        if let type = item["contentType"] as? Int { return type == 1 || type == 2 }
        if let type = item["type"] as? Int { return type == 1 || type == 2 }
        if let typeStr = item["contentType"] as? String {
            return typeStr.lowercased() == "folder" || typeStr.lowercased() == "dir" || typeStr.lowercased() == "catalog"
        }
        if let typeStr = item["type"] as? String {
            return typeStr.lowercased() == "folder" || typeStr.lowercased() == "dir"
        }
        if let isDir = item["isDir"] as? Bool { return isDir }
        if let isDir = item["is_dir"] as? Bool { return isDir }
        // 兜底：无扩展名的视为文件夹
        let name = item["contentName"] as? String ?? item["name"] as? String ?? ""
        if !name.isEmpty && !name.contains(".") {
            return true
        }
        return false
    }

    /// 加载139云盘指定目录的内容（根目录传 nil，子目录传 catalogId）
    private func pan139FetchDir(linkId: String, parentCatalogId: String?, cookie: String) async throws -> [[String: Any]]? {
        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36",
            "Referer": "https://yun.139.com/",
            "Origin": "https://yun.139.com",
            "Cookie": cookie
        ]

        let apiURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentInfoFromOutLink")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var body: [String: Any] = ["linkId": linkId, "password": ""]
        // 尝试多种常见的子目录参数名
        if let parentCatalogId = parentCatalogId, !parentCatalogId.isEmpty {
            body["catalogId"] = parentCatalogId
            body["parentCatalogId"] = parentCatalogId
            body["parentId"] = parentCatalogId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let contentList = dataObj["contentList"] as? [[String: Any]] else {
            return nil  // 返回 nil 表示此目录加载失败（可能是不支持子目录查询）
        }
        return contentList
    }

    /// 获取139云盘分享链接中的所有视频文件（递归遍历子文件夹）
    func pan139GetAllFiles(shareURL: String, cookie: String) async throws -> [Pan139ShareFile] {
        print("[139Pan] 📂 获取文件列表（递归）: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [139] 获取文件列表...")

        guard let urlComponents = URLComponents(string: shareURL),
              let path = urlComponents.path.components(separatedBy: "/").last,
              !path.isEmpty else {
            throw DriveError.invalidShareURL
        }

        let videoExts = ["mp4", "mkv", "mov", "avi", "wmv", "flv", "ts", "m4v", "rmvb", "rm"]
        var allVideoFiles: [Pan139ShareFile] = []
        var allFilesFallback: [Pan139ShareFile] = []

        // BFS 递归遍历所有子文件夹
        // catalogId 为 nil 表示根目录
        var dirsToLoad: [(catalogId: String?, name: String)] = [(nil, "根目录")]
        var loadedDirs = Set<String>()
        let maxDirs = 30
        let maxVideos = 500

        while !dirsToLoad.isEmpty && allVideoFiles.count < maxVideos {
            guard loadedDirs.count < maxDirs else {
                print("[139Pan] ⚠️ 已达目录数量上限 (\(maxDirs))，停止递归")
                break
            }

            let current = dirsToLoad.removeFirst()
            let dirKey = current.catalogId ?? "root"
            guard !loadedDirs.contains(dirKey) else { continue }
            loadedDirs.insert(dirKey)

            let items: [[String: Any]]?
            do {
                items = try await pan139FetchDir(
                    linkId: path,
                    parentCatalogId: current.catalogId,
                    cookie: cookie
                )
            } catch {
                print("[139Pan] ⚠️ 加载目录失败: \(current.name), \(error.localizedDescription)")
                if current.catalogId == nil {
                    // 根目录都加载失败，直接抛出
                    throw DriveError.noPlayURL("139云盘: 无法获取分享内容")
                }
                continue
            }

            guard let items = items else {
                // API 返回 nil，可能不支持子目录查询，跳过
                if current.catalogId != nil {
                    print("[139Pan] ℹ️ 子目录查询可能不支持，跳过: \(current.name)")
                }
                continue
            }

            for item in items {
                let contentId = item["contentId"] as? String ?? ""
                let catalogId = item["catalogId"] as? String ?? ""
                let name = item["contentName"] as? String ?? item["name"] as? String ?? "未知文件"
                guard !contentId.isEmpty else { continue }
                // catalogId 可能为空，用 contentId 兜底
                let effectiveCatalogId = catalogId.isEmpty ? contentId : catalogId

                let isDir = pan139IsDirItem(item)

                if isDir {
                    // 子文件夹，加入队列
                    let dirKey = effectiveCatalogId
                    if !loadedDirs.contains(dirKey) {
                        dirsToLoad.append((effectiveCatalogId, name))
                    }
                } else {
                    let file = Pan139ShareFile(contentId: contentId, catalogId: catalogId, fileName: name)
                    allFilesFallback.append(file)
                    // 筛选视频文件
                    let lowerName = name.lowercased()
                    if videoExts.contains(where: { lowerName.hasSuffix(".\($0)") }) {
                        allVideoFiles.append(file)
                    }
                }
            }
        }

        // 如果递归后还是没有视频文件，返回所有文件作为兜底
        let result = allVideoFiles.isEmpty ? allFilesFallback : allVideoFiles

        print("[139Pan] ✅ 递归获取完成: \(result.count) 个文件（视频 \(allVideoFiles.count) 个，遍历了 \(loadedDirs.count) 个目录）")
        self.log("[CloudDrive] [139] ✅ 文件列表: \(result.count) 个文件")

        guard !result.isEmpty else {
            throw DriveError.noPlayURL("139云盘: 分享内未找到文件")
        }

        return result
    }

    /// 解析139云盘指定文件的播放地址（用于多文件选集播放）
    func resolve139FilePlayURL(shareURL: String, cookie: String, contentId: String, catalogId: String, fileName: String) async throws -> PlayResult {
        print("[139Pan] 🎬 解析指定文件: contentId=\(contentId) name=\(fileName)")
        self.log("[CloudDrive] [139] 解析文件: \(fileName)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36",
            "Referer": "https://yun.139.com/",
            "Origin": "https://yun.139.com",
            "Cookie": cookie
        ]

        guard let urlComponents = URLComponents(string: shareURL),
              let path = urlComponents.path.components(separatedBy: "/").last,
              !path.isEmpty else {
            throw DriveError.invalidShareURL
        }

        let downloadURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentDownloadUrl")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let dlBody: [String: Any] = [
            "contentId": contentId,
            "catalogId": catalogId,
            "linkId": path
        ]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: dlBody)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any],
              let downloadUrl = dlDataObj["downloadUrl"] as? String else {
            throw DriveError.noPlayURL("139云盘: 无法获取下载链接")
        }

        return PlayResult(url: downloadUrl, headers: headers, driveType: .pan139, source: fileName)
    }

    // MARK: - 天翼云盘

    func resolve189PanPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[189Pan] 开始解析: \(shareURL)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn",
            "Cookie": cookie
        ]

        // 天翼云盘分享格式: https://cloud.189.cn/web/share?code=xxx 或 ?code=xxx#passcode
        guard let url = URL(string: shareURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveError.invalidShareURL
        }

        // 提取 shareCode
        var shareCode = ""
        if let codeItem = components.queryItems?.first(where: { $0.name == "code" }) {
            shareCode = codeItem.value ?? ""
        }
        // 也尝试从路径中提取
        if shareCode.isEmpty, let path = URLComponents(string: shareURL)?.path {
            let parts = path.components(separatedBy: "/")
            if let last = parts.last, !last.isEmpty {
                shareCode = last
            }
        }
        guard !shareCode.isEmpty else {
            throw DriveError.invalidShareURL
        }

        // 提取 passCode（如果分享链接有密码）
        var accessCode = ""
        if let fragment = url.fragment, !fragment.isEmpty {
            // 天翼云盘密码在 URL fragment 中
            accessCode = fragment
        } else if let pwdItem = components.queryItems?.first(where: { $0.name == "pwd" || $0.name == "accessCode" }) {
            accessCode = pwdItem.value ?? ""
        }

        print("[189Pan] shareCode=\(shareCode), accessCode=\(accessCode.isEmpty ? "无" : accessCode)")

        // 步骤1: 获取分享信息
        let shareInfoURL = URL(string: "https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action")!
        var shareReq = URLRequest(url: shareInfoURL)
        shareReq.httpMethod = "POST"
        shareReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { shareReq.setValue(v, forHTTPHeaderField: k) }

        var shareBody = "shareCode=\(shareCode)"
        if !accessCode.isEmpty {
            shareBody += "&accessCode=\(accessCode)"
        }

        shareReq.httpBody = shareBody.data(using: .utf8)
        let (shareData, shareResp) = try await session.data(for: shareReq)
        guard let httpResp = shareResp as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }

        // 如果返回302重定向到登录页，说明 Cookie 已过期
        if httpResp.statusCode == 302 {
            if let location = httpResp.allHeaderFields["Location"] as? String,
               location.contains("login") {
                throw DriveError.noPlayURL("天翼云盘: Cookie 已过期，请重新登录")
            }
        }

        guard let shareJson = try JSONSerialization.jsonObject(with: shareData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析分享信息响应")
        }

        print("[189Pan] 分享信息响应: \(shareJson.keys)")

        // 检查响应格式
        if let resCode = shareJson["res_code"] as? Int, resCode != 0 {
            let msg = shareJson["res_message"] as? String ?? "未知错误"
            // 某些版本返回外层 code/message
            if let errCode = shareJson["code"] as? String, errCode != "0" {
                throw DriveError.noPlayURL("天翼云盘: \(shareJson["msg"] as? String ?? errCode)")
            }
            throw DriveError.noPlayURL("天翼云盘: \(msg)")
        }

        // 响应可能有两种格式
        var fileId = ""
        var shareId: Int64 = 0
        var fileName = ""

        // 格式1: 直接有 fileId/fileName
        if let fid = shareJson["fileId"] as? String, !fid.isEmpty {
            fileId = fid
        } else if let fid = shareJson["fileId"] as? Int64 {
            fileId = String(fid)
        }
        if let sid = shareJson["shareId"] as? Int64 {
            shareId = sid
        } else if let sid = shareJson["shareId"] as? String {
            shareId = Int64(sid) ?? 0
        }
        if let fn = shareJson["fileName"] as? String {
            fileName = fn
        }

        // 格式2: 嵌套在 data 中
        if fileId.isEmpty, let dataObj = shareJson["data"] as? [String: Any] {
            if let fid = dataObj["fileId"] as? String {
                fileId = fid
            } else if let fid = dataObj["fileId"] as? Int64 {
                fileId = String(fid)
            }
            if let sid = dataObj["shareId"] as? Int64 {
                shareId = sid
            } else if let sid = dataObj["shareId"] as? String {
                shareId = Int64(sid) ?? 0
            }
            if let fn = dataObj["fileName"] as? String {
                fileName = fn
            }
            if shareId == 0, let sidStr = dataObj["shareId"] as? String {
                shareId = Int64(sidStr) ?? 0
            }
        }

        guard !fileId.isEmpty else {
            print("[189Pan] 无法提取 fileId，完整响应: \(shareJson)")
            throw DriveError.noPlayURL("天翼云盘: 无法提取文件信息")
        }

        print("[189Pan] fileId=\(fileId), shareId=\(shareId), fileName=\(fileName)")

        // 步骤2: 获取下载链接
        let downloadURL = URL(string: "https://cloud.189.cn/api/open/share/getFileDownloadUrl.action")!
        var dlReq = URLRequest(url: downloadURL)
        dlReq.httpMethod = "POST"
        dlReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { dlReq.setValue(v, forHTTPHeaderField: k) }

        var dlBody = "fileId=\(fileId)"
        if shareId != 0 {
            dlBody += "&shareId=\(shareId)"
        }
        dlReq.httpBody = dlBody.data(using: .utf8)

        let (dlData, _) = try await session.data(for: dlReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析下载链接响应")
        }

        print("[189Pan] 下载链接响应 keys: \(dlJson.keys)")

        // 检查响应
        if let resCode = dlJson["res_code"] as? Int, resCode != 0 {
            let msg = dlJson["res_message"] as? String ?? "未知错误"
            throw DriveError.noPlayURL("天翼云盘: 获取下载链接失败 - \(msg)")
        }

        var downloadUrlStr = ""

        // 格式1: 直接在 data 中
        if let dataObj = dlJson["data"] as? [String: Any] {
            if let url = dataObj["fileDownloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dataObj["downloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dataObj["url"] as? String, !url.isEmpty {
                downloadUrlStr = url
            }
        }

        // 格式2: 直接在顶层
        if downloadUrlStr.isEmpty {
            if let url = dlJson["fileDownloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dlJson["downloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dlJson["url"] as? String, !url.isEmpty {
                downloadUrlStr = url
            }
        }

        guard !downloadUrlStr.isEmpty else {
            print("[189Pan] 无法提取下载链接，完整响应: \(dlJson)")
            throw DriveError.noPlayURL("天翼云盘: 无法获取下载链接")
        }

        print("[189Pan] 获取到下载链接: \(downloadUrlStr.prefix(80))...")

        // 构建播放请求头（包含 Cookie 和 Referer）
        var playHeaders: [String: String] = [
            "User-Agent": headers["User-Agent"] ?? "",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn"
        ]

        return PlayResult(
            url: downloadUrlStr,
            headers: playHeaders,
            driveType: .pan189,
            source: "189pan_direct"
        )
    }

    // MARK: - 天翼云盘文件列表（多文件/文件夹支持）

    struct Pan189ShareFile {
        let fileId: String
        let fileName: String
    }

    private func pan189IsDirItem(_ item: [String: Any]) -> Bool {
        // 优先检查 isFolder / isDir 字段
        if let isFolder = item["isFolder"] as? Bool { return isFolder }
        if let isDir = item["isDir"] as? Bool { return isDir }
        if let isDir = item["is_dir"] as? Bool { return isDir }
        if let type = item["fileType"] as? Int { return type == 1 || type == 2 }
        if let type = item["type"] as? Int { return type == 1 || type == 2 }
        if let typeStr = item["fileType"] as? String {
            return typeStr.lowercased() == "folder" || typeStr.lowercased() == "dir"
        }
        if let typeStr = item["type"] as? String {
            return typeStr.lowercased() == "folder" || typeStr.lowercased() == "dir"
        }
        // 兜底：无扩展名的视为文件夹
        let name = item["fileName"] as? String ?? item["name"] as? String ?? ""
        if !name.isEmpty && !name.contains(".") {
            return true
        }
        return false
    }

    /// 加载天翼云盘指定目录的文件列表（支持分页）
    private func pan189FetchDir(shareId: Int64, fileId: String, accessCode: String, headers: [String: String]) async throws -> [[String: Any]] {
        let listURL = URL(string: "https://cloud.189.cn/api/open/share/listShareFiles.action")!
        var allItems: [[String: Any]] = []
        var pageNum = 1
        let maxPages = 10

        while pageNum <= maxPages {
            var listReq = URLRequest(url: listURL)
            listReq.httpMethod = "POST"
            listReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { listReq.setValue(v, forHTTPHeaderField: k) }
            var listBody = "shareId=\(shareId)&fileId=\(fileId)&pageNum=\(pageNum)&pageSize=100"
            if !accessCode.isEmpty { listBody += "&accessCode=\(accessCode)" }
            listReq.httpBody = listBody.data(using: .utf8)

            let (listData, _) = try await session.data(for: listReq)
            guard let listJson = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
                  let dataArr = listJson["data"] as? [[String: Any]] else {
                break
            }

            allItems.append(contentsOf: dataArr)

            // 检查是否还有下一页
            if dataArr.count < 100 { break }
            pageNum += 1
        }

        return allItems
    }

    /// 获取天翼云盘分享链接中的所有视频文件（递归遍历子文件夹）
    func pan189GetAllFiles(shareURL: String, cookie: String) async throws -> [Pan189ShareFile] {
        print("[189Pan] 📂 获取文件列表（递归）: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [189] 获取文件列表...")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn",
            "Cookie": cookie
        ]

        guard let url = URL(string: shareURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveError.invalidShareURL
        }

        var shareCode = ""
        if let codeItem = components.queryItems?.first(where: { $0.name == "code" }) {
            shareCode = codeItem.value ?? ""
        }
        if shareCode.isEmpty, let path = URLComponents(string: shareURL)?.path {
            let parts = path.components(separatedBy: "/")
            if let last = parts.last, !last.isEmpty { shareCode = last }
        }
        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }

        var accessCode = ""
        if let fragment = url.fragment, !fragment.isEmpty {
            accessCode = fragment
        } else if let pwdItem = components.queryItems?.first(where: { $0.name == "pwd" || $0.name == "accessCode" }) {
            accessCode = pwdItem.value ?? ""
        }

        // 步骤1: 获取分享信息（shareId + 根目录 fileId）
        let shareInfoURL = URL(string: "https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action")!
        var shareReq = URLRequest(url: shareInfoURL)
        shareReq.httpMethod = "POST"
        shareReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { shareReq.setValue(v, forHTTPHeaderField: k) }
        var shareBody = "shareCode=\(shareCode)"
        if !accessCode.isEmpty { shareBody += "&accessCode=\(accessCode)" }
        shareReq.httpBody = shareBody.data(using: .utf8)

        let (shareData, _) = try await session.data(for: shareReq)
        guard let shareJson = try JSONSerialization.jsonObject(with: shareData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析分享信息响应")
        }

        var rootFileId = ""
        var shareId: Int64 = 0
        var rootFileName = ""
        if let fid = shareJson["fileId"] as? String, !fid.isEmpty {
            rootFileId = fid
        } else if let fid = shareJson["fileId"] as? Int64 {
            rootFileId = String(fid)
        }
        if let sid = shareJson["shareId"] as? Int64 { shareId = sid }
        else if let sid = shareJson["shareId"] as? String { shareId = Int64(sid) ?? 0 }
        if let fn = shareJson["fileName"] as? String { rootFileName = fn }

        if rootFileId.isEmpty, let dataObj = shareJson["data"] as? [String: Any] {
            if let fid = dataObj["fileId"] as? String { rootFileId = fid }
            else if let fid = dataObj["fileId"] as? Int64 { rootFileId = String(fid) }
            if let sid = dataObj["shareId"] as? Int64 { shareId = sid }
            else if let sid = dataObj["shareId"] as? String { shareId = Int64(sid) ?? 0 }
            if let fn = dataObj["fileName"] as? String { rootFileName = fn }
        }

        guard !rootFileId.isEmpty else {
            throw DriveError.noPlayURL("天翼云盘: 无法提取文件信息")
        }

        let videoExts = ["mp4", "mkv", "mov", "avi", "wmv", "flv", "ts", "m4v", "rmvb", "rm"]
        var allVideoFiles: [Pan189ShareFile] = []
        var allFilesFallback: [Pan189ShareFile] = []

        // BFS 递归遍历所有子文件夹
        var dirsToLoad: [(fileId: String, name: String)] = [(rootFileId, rootFileName)]
        var loadedDirs = Set<String>()
        let maxDirs = 30
        let maxVideos = 500

        while !dirsToLoad.isEmpty && allVideoFiles.count < maxVideos {
            guard loadedDirs.count < maxDirs else {
                print("[189Pan] ⚠️ 已达目录数量上限 (\(maxDirs))，停止递归")
                break
            }

            let current = dirsToLoad.removeFirst()
            guard !loadedDirs.contains(current.fileId) else { continue }
            loadedDirs.insert(current.fileId)

            let items: [[String: Any]]
            do {
                items = try await pan189FetchDir(
                    shareId: shareId,
                    fileId: current.fileId,
                    accessCode: accessCode,
                    headers: headers
                )
            } catch {
                print("[189Pan] ⚠️ 加载目录失败: \(current.name), \(error.localizedDescription)")
                if current.fileId == rootFileId {
                    // 根目录加载失败，抛出
                    throw DriveError.noPlayURL("天翼云盘: 无法获取文件列表")
                }
                continue
            }

            for item in items {
                let fId = (item["fileId"] as? String) ?? (item["fileId"] as? Int64).map { String($0) } ?? ""
                let fName = item["fileName"] as? String ?? item["name"] as? String ?? "未知文件"
                guard !fId.isEmpty else { continue }

                let isDir = pan189IsDirItem(item)

                if isDir {
                    // 子文件夹，加入队列
                    if !loadedDirs.contains(fId) {
                        dirsToLoad.append((fId, fName))
                    }
                } else {
                    let file = Pan189ShareFile(fileId: fId, fileName: fName)
                    allFilesFallback.append(file)
                    // 筛选视频文件
                    let lowerName = fName.lowercased()
                    if videoExts.contains(where: { lowerName.hasSuffix(".\($0)") }) {
                        allVideoFiles.append(file)
                    }
                }
            }
        }

        // 如果递归后没有视频也没有普通文件（可能根目录本身就是一个视频文件）
        if allVideoFiles.isEmpty && allFilesFallback.isEmpty {
            // 检查根目录是不是单文件
            if !rootFileName.isEmpty {
                let lowerName = rootFileName.lowercased()
                if videoExts.contains(where: { lowerName.hasSuffix(".\($0)") }) {
                    allVideoFiles.append(Pan189ShareFile(fileId: rootFileId, fileName: rootFileName))
                } else {
                    allFilesFallback.append(Pan189ShareFile(fileId: rootFileId, fileName: rootFileName))
                }
            }
        }

        // 如果没有视频文件，返回所有文件作为兜底
        let result = allVideoFiles.isEmpty ? allFilesFallback : allVideoFiles

        print("[189Pan] ✅ 递归获取完成: \(result.count) 个文件（视频 \(allVideoFiles.count) 个，遍历了 \(loadedDirs.count) 个目录）")
        self.log("[CloudDrive] [189] ✅ 文件列表: \(result.count) 个文件")

        guard !result.isEmpty else {
            throw DriveError.noPlayURL("天翼云盘: 分享内未找到文件")
        }

        return result
    }

    /// 解析天翼云盘指定文件的播放地址（用于多文件选集播放）
    func resolve189FilePlayURL(shareURL: String, cookie: String, fileId: String, fileName: String) async throws -> PlayResult {
        print("[189Pan] 🎬 解析指定文件: fileId=\(fileId) name=\(fileName)")
        self.log("[CloudDrive] [189] 解析文件: \(fileName)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn",
            "Cookie": cookie
        ]

        // 提取 shareCode 和 accessCode
        guard let url = URL(string: shareURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveError.invalidShareURL
        }
        var shareCode = ""
        if let codeItem = components.queryItems?.first(where: { $0.name == "code" }) {
            shareCode = codeItem.value ?? ""
        }
        var accessCode = ""
        if let fragment = url.fragment, !fragment.isEmpty {
            accessCode = fragment
        } else if let pwdItem = components.queryItems?.first(where: { $0.name == "pwd" || $0.name == "accessCode" }) {
            accessCode = pwdItem.value ?? ""
        }

        // 获取 shareId
        var shareId: Int64 = 0
        if !shareCode.isEmpty {
            let shareInfoURL = URL(string: "https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action")!
            var shareReq = URLRequest(url: shareInfoURL)
            shareReq.httpMethod = "POST"
            shareReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { shareReq.setValue(v, forHTTPHeaderField: k) }
            var shareBody = "shareCode=\(shareCode)"
            if !accessCode.isEmpty { shareBody += "&accessCode=\(accessCode)" }
            shareReq.httpBody = shareBody.data(using: .utf8)
            let (shareData, _) = try await session.data(for: shareReq)
            if let shareJson = try JSONSerialization.jsonObject(with: shareData) as? [String: Any] {
                if let sid = shareJson["shareId"] as? Int64 { shareId = sid }
                else if let sid = shareJson["shareId"] as? String { shareId = Int64(sid) ?? 0 }
                if shareId == 0, let dataObj = shareJson["data"] as? [String: Any] {
                    if let sid = dataObj["shareId"] as? Int64 { shareId = sid }
                    else if let sid = dataObj["shareId"] as? String { shareId = Int64(sid) ?? 0 }
                }
            }
        }

        // 获取下载链接
        let downloadURL = URL(string: "https://cloud.189.cn/api/open/share/getFileDownloadUrl.action")!
        var dlReq = URLRequest(url: downloadURL)
        dlReq.httpMethod = "POST"
        dlReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { dlReq.setValue(v, forHTTPHeaderField: k) }
        var dlBody = "fileId=\(fileId)"
        if shareId != 0 { dlBody += "&shareId=\(shareId)" }
        dlReq.httpBody = dlBody.data(using: .utf8)

        let (dlData, _) = try await session.data(for: dlReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析下载链接响应")
        }

        var downloadUrlStr = ""
        if let dataObj = dlJson["data"] as? [String: Any] {
            if let url = dataObj["fileDownloadUrl"] as? String, !url.isEmpty { downloadUrlStr = url }
            else if let url = dataObj["downloadUrl"] as? String, !url.isEmpty { downloadUrlStr = url }
            else if let url = dataObj["url"] as? String, !url.isEmpty { downloadUrlStr = url }
        }
        if downloadUrlStr.isEmpty {
            if let url = dlJson["fileDownloadUrl"] as? String, !url.isEmpty { downloadUrlStr = url }
            else if let url = dlJson["downloadUrl"] as? String, !url.isEmpty { downloadUrlStr = url }
            else if let url = dlJson["url"] as? String, !url.isEmpty { downloadUrlStr = url }
        }

        guard !downloadUrlStr.isEmpty else {
            throw DriveError.noPlayURL("天翼云盘: 无法获取下载链接")
        }

        let playHeaders: [String: String] = [
            "User-Agent": headers["User-Agent"] ?? "",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn"
        ]
        return PlayResult(url: downloadUrlStr, headers: playHeaders, driveType: .pan189, source: fileName)
    }

    // MARK: - UC 网盘

    /// 将刷新后的 Cookie 持久化回 UC 凭证，防止下次请求仍用过期 Cookie
    private func ucPersistRefreshedCookie(_ refreshedCookie: String) {
        guard !refreshedCookie.isEmpty,
              var cred = CloudDriveAuthManager.shared.credential(for: .uc) else { return }
        // 仅当 Cookie 确实变化时才写入，避免无谓的磁盘 I/O
        guard cred.cookie != refreshedCookie else { return }
        cred.cookie = refreshedCookie
        cred.updatedAt = Date()
        cred.lastCheckedAt = Date()
        cred.state = .valid
        CloudDriveAuthManager.shared.saveCredential(cred, syncLegacyToken: false)
        self.log("[CloudDrive] ✅ UC Cookie 已自动刷新并持久化")
    }

    func resolveUCPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[UC] 开始解析: \(shareURL)")
        let (pwdId, passcode) = ucExtractShareInfo(from: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        var authCookie = cookie
        let folder = try await ucEnsureFolderWithCookie(cookie: authCookie)
        authCookie = folder.cookie
        ucPersistRefreshedCookie(authCookie)
        let stoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)

        // 尝试获取文件列表，stoken 失效时自动刷新
        let resolveResult = try await ucResolveUCShareFile(
            pwdId: pwdId,
            passcode: passcode,
            stoken: stoken,
            folderId: folder.folderId,
            cookie: authCookie
        )
        let sourceFile = resolveResult.sourceFile
        let fileId = resolveResult.fileId
        let fileIds = resolveResult.fileIds
        print("[UC] 最终选中资源：\(sourceFile.fileName), fid=\(fileId)")

        var transcodeURL = ""
        do {
            transcodeURL = try await ucGetPlayURL(fileId: fileId, cookie: authCookie)
        } catch {
            print("[UC] ⚠️ v2/play 失败，继续尝试：\(error.localizedDescription)")
        }
        let downloadURL = try await ucGetDownloadURL(fileId: fileId, cookie: authCookie)

        // 优先级：TV Token streaming（原片最高画质） > v2/play（m3u8转码流） > download_url（慢速）
        var playURL = ""
        var source = ""

        // 1. 优先 TV Token streaming — 原片流媒体直链，最高画质，不限速
        if let tvToken = CloudDriveAuthManager.shared.credential(for: .uc)?.extra["uc_tv_token"],
           !tvToken.isEmpty {
            self.log("[CloudDrive] 🔍 TV Token 高速通道...")
            do {
                playURL = try await ucGetPlayURLWithTVToken(fileId: fileId, tvToken: tvToken)
                source = "uc_tv_token"
                self.log("[CloudDrive] ✅ TV Token 高速通道成功")
            } catch {
                self.log("[CloudDrive] ⚠️ TV Token 失败: \(error.localizedDescription)")
            }
        } else {
            self.log("[CloudDrive] ℹ️ 无 TV Token")
        }

        // 2. TV Token 不可用，降级到 v2/play m3u8 转码流
        if playURL.isEmpty && !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play"
            self.log("[CloudDrive] 🎬 降级到 v2/play m3u8 流")
        }

        // 3. 兜底 download_url
        if playURL.isEmpty {
            playURL = downloadURL
            source = "download_url"
            self.log("[CloudDrive] ⚠️ 降级到 download_url")
        }

        return try resolveUCPlayResult(playURL: playURL, source: source, transcodeURL: transcodeURL, downloadURL: downloadURL, fileIds: fileIds, authCookie: authCookie)
    }

    /// 构建 UC 播放结果（复用逻辑，供 resolveUCPlayURL 和 resolveUCPlayURLForFile 共用）
    private func resolveUCPlayResult(playURL: String, source: String, transcodeURL: String, downloadURL: String, fileIds: [String], authCookie: String) throws -> PlayResult {
        var playURL = playURL
        var source = source
        var transcodeURL = transcodeURL
        var downloadURL = downloadURL

        guard !playURL.isEmpty else { throw DriveError.noPlayURL("UC: download_url、转码地址和 UCTV Token 兜底均为空") }

        self.log("[CloudDrive] ℹ️ UC 播放源: \(source)")
        if source == "uc_tv_token" {
            self.log("[CloudDrive] 🔗 TV CDN: \(playURL.prefix(200))")
            if playURL.contains("sp=") {
                self.log("[CloudDrive] ⚠️ CDN 仍含 sp 参数，限速未解除！")
            } else {
                self.log("[CloudDrive] ✅ CDN 限速已解除")
            }
        }

        scheduleCleanup(drive: .uc, fileIds: fileIds, token: authCookie, delay: 60 * 60)

        // TV Token CDN 直链：不传自定义 Header，让播放器原生网络栈处理 Range 请求
        // v2/play m3u8 和 download_url：需要 UC Cookie 头
        let headers: [String: String]
        let fallbackURL: String?
        let fallbackHeaders: [String: String]?
        let fallbackSource: String?

        switch source {
        case "uc_tv_token":
            headers = [:]
            fallbackURL = !transcodeURL.isEmpty ? transcodeURL : (!downloadURL.isEmpty ? downloadURL : nil)
            fallbackHeaders = !transcodeURL.isEmpty ? ucPlaybackHeaders(cookie: authCookie) : (!downloadURL.isEmpty ? ucPlaybackHeaders(cookie: authCookie) : nil)
            fallbackSource = !transcodeURL.isEmpty ? "v2-play" : (!downloadURL.isEmpty ? "download_url" : nil)
        case "v2-play":
            headers = ucPlaybackHeaders(cookie: authCookie)
            fallbackURL = !downloadURL.isEmpty ? downloadURL : nil
            fallbackHeaders = !downloadURL.isEmpty ? headers : nil
            fallbackSource = !downloadURL.isEmpty ? "download_url" : nil
        default: // download_url
            headers = ucPlaybackHeaders(cookie: authCookie)
            fallbackURL = nil
            fallbackHeaders = nil
            fallbackSource = nil
        }

        return PlayResult(
            url: playURL,
            headers: headers,
            driveType: .uc,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackHeaders,
            fallbackSource: fallbackSource
        )
    }

    /// 解析指定 UC 文件的播放地址（切换集数使用）
    /// 三层容错：刷新Cookie → stoken失效重试 → 清晰错误提示
    func resolveUCPlayURLForFile(shareURL: String, cookie: String, fileFid: String, shareFidToken: String) async throws -> PlayResult {
        print("[UC] 切集解析: fid=\(fileFid)")
        let (pwdId, passcode) = ucExtractShareInfo(from: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        var authCookie = cookie
        let folder = try await ucEnsureFolderWithCookie(cookie: authCookie)
        authCookie = folder.cookie
        ucPersistRefreshedCookie(authCookie)
        var stoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)

        // 获取文件列表，stoken 失效时刷新重试一次
        var files: [UCShareFile] = []
        do {
            try await ucCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: authCookie, result: &files)
        } catch let error as DriveError {
            let errMsg = error.localizedDescription
            guard errMsg.contains("非法token") || errMsg.contains("token") else { throw error }
            // stoken 失效，刷新后重试
            self.log("[CloudDrive] ⚠️ UC 切集 stoken 失效，刷新重试...")
            stoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
            do {
                try await ucCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: authCookie, result: &files)
                self.log("[CloudDrive] ✅ UC 切集 stoken 刷新成功")
            } catch {
                self.log("[CloudDrive] ❌ UC Cookie 已过期，请重新扫码登录")
                throw DriveError.noPlayURL("UC Cookie 已过期，请重新扫码登录")
            }
        }

        guard let sourceFile = files.first(where: { $0.fid == fileFid }) else {
            throw DriveError.noPlayURL("UC 未找到指定文件，无法转存")
        }

        // 转存到 vbox
        let fileIds = try await ucSaveShare(pwdId: pwdId, stoken: stoken, file: sourceFile, folderId: folder.folderId, cookie: authCookie)
        guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 切集转存后未返回文件ID") }

        print("[UC] 切集转存成功: fileId=\(fileId)")

        var transcodeURL = ""
        do {
            transcodeURL = try await ucGetPlayURL(fileId: fileId, cookie: authCookie)
        } catch {
            print("[UC] ⚠️ v2/play 失败: \(error.localizedDescription)")
        }
        let downloadURL = try await ucGetDownloadURL(fileId: fileId, cookie: authCookie)

        // 优先级：TV Token streaming（原片最高画质） > v2/play（m3u8转码流） > download_url（慢速）
        var playURL = ""
        var source = ""

        if let tvToken = CloudDriveAuthManager.shared.credential(for: .uc)?.extra["uc_tv_token"],
           !tvToken.isEmpty {
            do {
                playURL = try await ucGetPlayURLWithTVToken(fileId: fileId, tvToken: tvToken)
                source = "uc_tv_token"
            } catch {
                self.log("[CloudDrive] ⚠️ 切集 TV Token 失败: \(error.localizedDescription)")
            }
        }
        if playURL.isEmpty && !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play"
        }
        if playURL.isEmpty {
            playURL = downloadURL
            source = "download_url"
        }

        return try resolveUCPlayResult(
            playURL: playURL, source: source, transcodeURL: transcodeURL,
            downloadURL: downloadURL, fileIds: fileIds, authCookie: authCookie
        )
    }

    struct UCShareFile {
        let fid: String
        let fileName: String
        let shareFidToken: String
        let pdirFid: String
        let isDir: Bool
    }

    private func ucExtractShareInfo(from url: String) -> (pwdId: String, passcode: String) {
        var pwdId = ""
        if let range = url.range(of: #"/s/([^/?#]+)"#, options: .regularExpression) {
            pwdId = String(url[range]).replacingOccurrences(of: "/s/", with: "")
        } else {
            pwdId = url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let queryItems = URLComponents(string: url)?.queryItems ?? []
        let passcode = queryItems.first(where: { ["pwd", "passcode", "password"].contains($0.name.lowercased()) })?.value ?? ""
        return (pwdId, passcode)
    }

    private func ucAPIURL(_ path: String, extra: [URLQueryItem] = []) -> URL {
        var components = URLComponents(string: "https://pc-api.uc.cn\(path)")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "ve", value: "1.8.5")
        ] + extra
        return components.url!
    }

    private func ucSetCommonHeaders(_ request: inout URLRequest, cookie: String, referer: String = "https://drive.uc.cn/") {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://drive.uc.cn", forHTTPHeaderField: "Origin")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch", forHTTPHeaderField: "User-Agent")
    }

    private func ucShareReferer(pwdId: String) -> String {
        "https://drive.uc.cn/s/\(pwdId)"
    }

    private func ucPlaybackHeaders(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36",
            "Referer": "https://drive.uc.cn/",
            "Origin": "https://drive.uc.cn",
            "Accept": "*/*"
        ]
    }

    private func ucSaveShare(pwdId: String, stoken: String, file: UCShareFile, folderId: String, cookie: String) async throws -> [String] {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/save", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))
        let body: [String: Any] = [
            "fid_list": [file.fid],
            "fid_token_list": [file.shareFidToken],
            "to_pdir_fid": folderId,
            "pwd_id": pwdId,
            "stoken": stoken,
            "pdir_fid": file.pdirFid,
            "scene": "link"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await ucSession.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[UC] save 响应：\(respStr.prefix(800))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码：\(status)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码：\(code)"
            throw DriveError.noPlayURL("UC 转存失败：\(message)")
        }

        if let dataObj = json["data"] as? [String: Any] {
            let taskResp = dataObj["task_resp"] as? [String: Any]
            let taskData = taskResp?["data"] as? [String: Any]
            let saveAs = taskData?["save_as"] as? [String: Any]
            if let ids = saveAs?["save_as_top_fids"] as? [String], !ids.isEmpty { return ids }
            if let ids = saveAs?["save_as_select_top_fids"] as? [String], !ids.isEmpty { return ids }
            if let fileIds = dataObj["file_ids"] as? [String] { return fileIds }
            if let fileIds = dataObj["file_ids"] as? [Int] { return fileIds.map { String($0) } }
            if let list = dataObj["list"] as? [[String: Any]], !list.isEmpty {
                let ids = list.compactMap { $0["fid"] as? String ?? $0["file_id"] as? String }
                if !ids.isEmpty { return ids }
            }
        }

        let recursiveIds = quarkExtractSavedFileIds(from: json, excluding: file.fid)
        if !recursiveIds.isEmpty { return recursiveIds }

        throw DriveError.noPlayURL("UC 转存成功但未返回已转存 fid")
    }

    private func ucGetShareToken(pwdId: String, passcode: String, cookie: String) async throws -> String {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/token", extra: [URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000)))])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))

        let body: [String: Any] = ["pwd_id": pwdId, "passcode": passcode]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC 分享 token 获取失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let stoken = dataObj["stoken"] as? String,
              !stoken.isEmpty else {
            throw DriveError.noPlayURL("UC 未返回 stoken")
        }
        return stoken
    }

    private struct UCResolveResult {
        let sourceFile: UCShareFile
        let fileId: String
        let fileIds: [String]
    }

    /// 检查 vbox 文件夹中是否已有同名文件，有则返回其 fid，避免重复转存
    private func ucFindExistingFileInVBox(fileName: String, folderId: String, cookie: String) async throws -> String? {
        let sortQueryItems: [URLQueryItem] = [
            URLQueryItem(name: "pdir_fid", value: folderId),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "50"),
            URLQueryItem(name: "_fetch_total", value: "1")
        ]
        let listURL = ucAPIURL("/1/clouddrive/file/sort", extra: sortQueryItems)
        var request = URLRequest(url: listURL)
        request.httpMethod = "GET"
        ucSetCommonHeaders(&request, cookie: cookie)
        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let dataObj = json["data"] as? [String: Any],
           let files = dataObj["list"] as? [[String: Any]] {
            for f in files {
                if let name = f["file_name"] as? String, name == fileName,
                   let fid = f["fid"] as? String { return fid }
            }
        }
        if let files = json["data"] as? [[String: Any]] {
            for f in files {
                if let name = f["file_name"] as? String, name == fileName,
                   let fid = f["fid"] as? String { return fid }
            }
        }
        return nil
    }

    private func ucResolveUCShareFile(pwdId: String, passcode: String, stoken: String, folderId: String, cookie: String) async throws -> UCResolveResult {
        /// 转存前检查是否已存在，避免重复转存
        func trySave(_ file: UCShareFile, _ tk: String) async throws -> UCResolveResult {
            if let existingFid = try? await ucFindExistingFileInVBox(fileName: file.fileName, folderId: folderId, cookie: cookie) {
                self.log("[CloudDrive] ♻️ 文件已存在，跳过转存: \(file.fileName)")
                return UCResolveResult(sourceFile: file, fileId: existingFid, fileIds: [existingFid])
            }
            let fileIds = try await ucSaveShare(pwdId: pwdId, stoken: tk, file: file, folderId: folderId, cookie: cookie)
            guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
            return UCResolveResult(sourceFile: file, fileId: fileId, fileIds: fileIds)
        }

        // 1. 正常路径
        do {
            let sourceFile = try await ucFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: cookie)
            print("[UC] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid)")
            return try await trySave(sourceFile, stoken)
        } catch let error as DriveError {
            let errMsg = error.localizedDescription
            if errMsg.contains("非法token") || errMsg.contains("token") {
                self.log("[CloudDrive] ⚠️ stoken 失效，尝试刷新...")
                // 2. 刷新 stoken 并重试
                do {
                    let newStoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: cookie)
                    let sf = try await ucFirstPlayableFile(pwdId: pwdId, stoken: newStoken, pdirFid: "0", cookie: cookie)
                    print("[UC] stoken 刷新后选中资源：\(sf.fileName), fid=\(sf.fid)")
                    self.log("[CloudDrive] ✅ stoken 刷新成功")
                    return try await trySave(sf, newStoken)
                } catch {
                    // 3. TV Token 兜底
                    if let tvToken = CloudDriveAuthManager.shared.credential(for: .uc)?.extra["uc_tv_token"],
                       !tvToken.isEmpty {
                        self.log("[CloudDrive] 🔄 stoken 刷新失败，尝试 TV Token 兜底...")
                        let tvFiles = try await ucListFilesWithTVToken(tvToken: tvToken)
                        let playable = tvFiles.first(where: { f in
                            let name = f["filename"] as? String ?? ""
                            let isDir = (f["isdir"] as? Int) == 1
                            return !isDir && quarkIsPlayableFileName(name)
                        })
                        if let pf = playable, let fid = pf["fid"] as? String {
                            self.log("[CloudDrive] ✅ TV Token 兜底找到文件: \(pf["filename"] as? String ?? "")")
                            return UCResolveResult(
                                sourceFile: UCShareFile(fid: fid, fileName: pf["filename"] as? String ?? "", shareFidToken: "", pdirFid: "0", isDir: false),
                                fileId: fid,
                                fileIds: [fid]
                            )
                        } else {
                            self.log("[CloudDrive] ❌ TV Token 兜底也未找到可播放文件")
                            throw error
                        }
                    } else {
                        throw error
                    }
                }
            } else {
                throw error
            }
        }
    }

    private func ucEnsureFolder(cookie: String) async throws -> String {
        (try await ucEnsureFolderWithCookie(cookie: cookie)).folderId
    }

    private func ucEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        let sortQueryItems: [URLQueryItem] = [
            URLQueryItem(name: "pdir_fid", value: "0"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_total", value: "1")
        ]
        let listURL = ucAPIURL("/1/clouddrive/file/sort", extra: sortQueryItems)
        var req = URLRequest(url: listURL)
        req.httpMethod = "GET"
        ucSetCommonHeaders(&req, cookie: cookie)
        let (listData, listResp) = try await ucSession.data(for: req)
        let mergedCookie = quarkMergeSetCookie(from: listResp, into: cookie)
        let listBody = String(data: listData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder list 响应: \(listBody.prefix(500))")
        if let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] {
            if let code = listJson["code"] as? Int, code != 0 {
                print("[UC] ensureFolder list 返回 code=\(code): \(listJson["message"] as? String ?? "")")
                if code == 10001 || code == 10002 || code == 10003 {
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (list code=\(code))")
                }
            }
            if let data = listJson["data"] as? [String: Any],
               let files = data["list"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, mergedCookie) }
                }
            }
            if let files = listJson["data"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, mergedCookie) }
                }
            }
        }

        let cookieAfterList = mergedCookie

        let createURL = ucAPIURL("/1/clouddrive/file")
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        ucSetCommonHeaders(&createReq, cookie: cookieAfterList)
        let createBody: [String: Any] = ["pdir_fid": "0", "file_name": "vbox", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        let (createData, createResp) = try await ucSession.data(for: createReq)
        let createMergedCookie = quarkMergeSetCookie(from: createResp, into: cookieAfterList)
        let createBodyStr = String(data: createData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder create 响应: \(createBodyStr.prefix(300))")
        if let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any] {
            if let code = createJson["code"] as? Int, code != 0 {
                if code == 23008 {
                    print("[UC] ensureFolder create: 文件夹已存在 (code=23008)，重新 list")
                } else {
                    let msg = createJson["message"] as? String ?? "code=\(code)"
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (create code=\(code) msg=\(msg))")
                }
            }
            if let code = createJson["code"] as? Int, code == 0,
               let d = createJson["data"] as? [String: Any],
               let fid = d["fid"] as? String {
                return (fid, createMergedCookie)
            }
        }

        // 文件夹可能已存在（code=23008 或 code 非 0），用 GET 重新 list
        let cookieAfterCreate = createMergedCookie
        let reListURL = ucAPIURL("/1/clouddrive/file/sort", extra: sortQueryItems)
        var reReq = URLRequest(url: reListURL)
        reReq.httpMethod = "GET"
        ucSetCommonHeaders(&reReq, cookie: cookieAfterCreate)
        let (reData, reResp) = try await ucSession.data(for: reReq)
        let reMergedCookie = quarkMergeSetCookie(from: reResp, into: cookieAfterCreate)
        let reBodyStr = String(data: reData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder re-list 响应: \(reBodyStr.prefix(300))")
        if let reJson = try? JSONSerialization.jsonObject(with: reData) as? [String: Any] {
            if let code = reJson["code"] as? Int, code != 0 {
                print("[UC] ensureFolder re-list 返回 code=\(code): \(reJson["message"] as? String ?? "")")
                if code == 10001 || code == 10002 || code == 10003 {
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (re-list code=\(code))")
                }
            }
            if let data = reJson["data"] as? [String: Any],
               let files = data["list"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, reMergedCookie) }
                }
            }
            if let files = reJson["data"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, reMergedCookie) }
                }
            }
        }
        throw DriveError.noPlayURL("UC: 无法找到或创建 vbox 文件夹")
    }

    private func ucDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = ucAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        ucSetCommonHeaders(&req, cookie: cookie)
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await ucSession.data(for: req)
        self.log("[CloudDrive] ✅ UC 已删除 \(fileIds.count) 个转存文件")
    }

    private func ucFirstPlayableFile(pwdId: String, stoken: String, pdirFid: String, cookie: String) async throws -> UCShareFile {
        let files = try await ucGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie)
        if let playable = files.first(where: { !$0.isDir && quarkIsPlayableFileName($0.fileName) }) {
            return playable
        }
        for dir in files where dir.isDir {
            if let found = try? await ucFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie) {
                return found
            }
        }
        throw DriveError.noPlayURL("UC 分享内未找到可播放视频")
    }

    // MARK: - UC 网盘完整文件列表获取（选集用）

    /// 获取 UC 分享链接中所有可播放文件（供选集列表使用）
    /// 三层容错：刷新Cookie → stoken失效重试 → 清晰错误提示
    func ucGetFileList(shareURL: String, cookie: String) async throws -> [UCShareFile] {
        let (pwdId, passcode) = ucExtractShareInfo(from: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        // 第一层：通过 ucEnsureFolderWithCookie 刷新 Cookie（补全外围 session）
        var authCookie = cookie
        do {
            let folder = try await ucEnsureFolderWithCookie(cookie: authCookie)
            authCookie = folder.cookie
            ucPersistRefreshedCookie(authCookie)
        } catch {
            // Cookie 刷新失败（可能核心 session 已过期），继续用原始 Cookie 尝试
            self.log("[CloudDrive] ⚠️ UC ensureFolder 失败，用原始 Cookie 继续: \(error.localizedDescription)")
        }

        let stoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)

        // 正常路径
        var allPlayable: [UCShareFile] = []
        do {
            try await ucCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: authCookie, result: &allPlayable)
            return allPlayable
        } catch let error as DriveError {
            let errMsg = error.localizedDescription

            // 第二层：stoken 失效，刷新后重试一次
            guard errMsg.contains("非法token") || errMsg.contains("token") else { throw error }
            self.log("[CloudDrive] ⚠️ UC 文件列表 stoken 失效，刷新重试...")
            let newStoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
            var retryFiles: [UCShareFile] = []
            do {
                try await ucCollectAllPlayableFiles(pwdId: pwdId, stoken: newStoken, pdirFid: "0", cookie: authCookie, result: &retryFiles)
                self.log("[CloudDrive] ✅ UC stoken 刷新重试成功")
                return retryFiles
            } catch {
                // 第三层：都失败了，给出清晰提示
                self.log("[CloudDrive] ❌ UC Cookie 可能已过期，请重新扫码登录")
                throw DriveError.noPlayURL("UC Cookie 已过期，请重新扫码登录")
            }
        }
    }

    /// 递归收集 UC 分享中所有可播放文件（支持分页和子目录）
    private func ucCollectAllPlayableFiles(pwdId: String, stoken: String, pdirFid: String, cookie: String, result: inout [UCShareFile]) async throws {
        var page = 1
        var hasMore = true
        while hasMore {
            let files = try await ucGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie, page: page, size: 100)
            for file in files where !file.isDir && quarkIsPlayableFileName(file.fileName) {
                result.append(file)
            }
            // 收集子目录，稍后递归
            var subDirs: [UCShareFile] = []
            for file in files where file.isDir {
                subDirs.append(file)
            }
            // 递归进入子目录
            for dir in subDirs {
                try await ucCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie, result: &result)
            }
            hasMore = files.count >= 100
            page += 1
            if page > 20 { break } // 安全限制，最多20页
        }
    }

    private func ucGetShareDetail(pwdId: String, stoken: String, pdirFid: String, cookie: String, page: Int = 1, size: Int = 100) async throws -> [UCShareFile] {
        let url = ucAPIURL("/1/clouddrive/share/sharepage/detail", extra: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: String(page)),
            URLQueryItem(name: "_size", value: String(size)),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "pdir_fid", value: pdirFid),
            URLQueryItem(name: "pwd_id", value: pwdId),
            URLQueryItem(name: "stoken", value: stoken)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ucSetCommonHeaders(&request, cookie: cookie, referer: ucShareReferer(pwdId: pwdId))
        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            if message.contains("非法token") || message.contains("token") {
                self.log("[CloudDrive] ⚠️ UC Cookie 已过期，请重新扫码登录")
            }
            throw DriveError.noPlayURL("UC 文件列表失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            throw DriveError.noPlayURL("UC 文件列表为空")
        }
        return list.compactMap { item in
            let fid = item["fid"] as? String ?? ""
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            let token = item["share_fid_token"] as? String ?? item["fid_token"] as? String ?? ""
            let isDir = (item["dir"] as? Bool) ?? ((item["file"] as? Bool) == false && (item["file_type"] as? Int) == 0)
            guard !fid.isEmpty, !name.isEmpty else { return nil }
            return UCShareFile(fid: fid, fileName: name, shareFidToken: token, pdirFid: pdirFid, isDir: isDir)
        }
    }

    private func ucGetPlayURL(fileId: String, cookie: String) async throws -> String {
        // iBox 加了 pr/fr/sys/ve 参数，返回更高质量/更兼容的流
        var request = URLRequest(url: ucAPIURL("/1/clouddrive/file/v2/play", extra: [
            URLQueryItem(name: "pr", value: "UCBrowser"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "ios"),
            URLQueryItem(name: "ve", value: "1.8.5")
        ]))
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie)

        let body: [String: Any] = [
            "fid": fileId,
            "resolutions": "normal,low,high,super,2k,4k",
            "supports": "fmp4,m3u8"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC v2/play 失败: \(message)")
        }
        if let dataObj = json["data"] as? [String: Any],
           let videos = dataObj["video_list"] as? [[String: Any]] {
            // 按分辨率从高到低排序：4k > 2k > super > high > normal > low
            let order: [String] = ["4k", "2k", "super", "high", "normal", "low"]
            let sorted = videos.sorted { a, b in
                let ra = (a["video_info"] as? [String: Any])?["resolution"] as? String ?? ""
                let rb = (b["video_info"] as? [String: Any])?["resolution"] as? String ?? ""
                return (order.firstIndex(of: ra) ?? 99) < (order.firstIndex(of: rb) ?? 99)
            }
            for item in sorted {
                guard (item["accessable"] as? Bool) != false,
                      let info = item["video_info"] as? [String: Any],
                      let url = info["url"] as? String,
                      !url.isEmpty else { continue }
                let res = info["resolution"] as? String ?? "?"
                self.log("[CloudDrive] 🎬 v2/play 选中分辨率: \(res)")
                return url
            }
        }
        if let dataObj = json["data"] as? [String: Any],
           let playURL = dataObj["play_url"] as? String,
           !playURL.isEmpty {
            return playURL
        }
        if let playURL = json["play_url"] as? String, !playURL.isEmpty { return playURL }
        throw DriveError.noPlayURL("UC: 未返回播放地址")
    }

    /// 使用 TV Token 列出云盘根目录文件，用于 stoken 失效时的兜底
    private func ucListFilesWithTVToken(tvToken: String, parentFid: String = "0") async throws -> [[String: Any]] {
        let signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
        let clientId = "5acf882d27b74502b7040b0c65519aa7"
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/file"
        let tokenData = "GET&\(pathname)&\(timestamp)&\(signKey)"
        let xPanToken = SHA256.hash(data: Data(tokenData.utf8)).map { String(format: "%02x", $0) }.joined()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let reqId = Insecure.MD5.hash(data: Data("\(deviceId)\(timestamp)".utf8)).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "parent_fid", value: parentFid),
            URLQueryItem(name: "order_by", value: "3"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "category", value: ""),
            URLQueryItem(name: "source", value: ""),
            URLQueryItem(name: "ex_source", value: ""),
            URLQueryItem(name: "list_all", value: "0"),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "page_index", value: "0"),
            URLQueryItem(name: "access_token", value: tvToken),
            URLQueryItem(name: "app_ver", value: "1.6.8"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "device_name", value: "iPhone"),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "activity_rect", value: "{}"),
            URLQueryItem(name: "channel", value: "UCTVOFFICIALWEB"),
            URLQueryItem(name: "req_id", value: reqId)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")
        request.setValue("Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        self.log("[CloudDrive] TV Token 列表响应: \(rawBody.prefix(200))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let status = json["status"] as? Int, status == -1 {
            let info = json["error_info"] as? String ?? "status=-1"
            throw DriveError.noPlayURL("TV Token 列表失败：\(info)")
        }
        if let dataObj = json["data"] as? [String: Any],
           let files = dataObj["files"] as? [[String: Any]] {
            return files
        }
        return []
    }

    private func ucGetDownloadURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: ucAPIURL("/1/clouddrive/file/download"))
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fileId]])
        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC download_url 获取失败：\(message)")
        }
        // data 可能是数组 [{download_url: ...}] 也可能是字典 {download_url: ...}
        if let list = json["data"] as? [[String: Any]],
           let first = list.first,
           let url = first["download_url"] as? String {
            return stripCDNSpeedLimit(url)
        }
        if let dataObj = json["data"] as? [String: Any],
           let url = dataObj["download_url"] as? String {
            return stripCDNSpeedLimit(url)
        }
        return ""
    }

    /// 去掉 CDN URL 中的下载/限速参数，优化为流式播放
    /// sp=100/50/200/500: 阿里云 CDN 下载限速，仅出现在 dl-c- 下载域名
    /// sp=1301 等大值: 流媒体 profile ID，出现在 video-play 域名，不可移除！
    /// response-content-disposition=attachment: 强制下载模式，播放器 Range 请求被拒
    /// x-oss-traffic-limit: 额外限速参数
    private func stripCDNSpeedLimit(_ urlString: String) -> String {
        var result = urlString
        // 仅对下载 CDN (dl-c-) 去除 sp 限速参数，流媒体 CDN (video-play) 的 sp 是 profile ID
        let isDownloadCDN = result.contains("dl-c-") || result.contains("response-content-disposition")
        if isDownloadCDN {
            if let re = try? NSRegularExpression(pattern: "&sp=\\d+", options: []) {
                result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
            if let re = try? NSRegularExpression(pattern: "\\?sp=\\d+&", options: []) {
                result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "?")
            }
            if let re = try? NSRegularExpression(pattern: "\\?sp=\\d+$", options: []) {
                result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        // &response-content-disposition=attachment... (强制下载，破坏流式播放)
        if let re = try? NSRegularExpression(pattern: "&response-content-disposition=[^&]+", options: []) {
            result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // &x-oss-traffic-limit=数字
        if let re = try? NSRegularExpression(pattern: "&x-oss-traffic-limit=\\d+", options: []) {
            result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    private func ucGetPlayURLWithTVToken(fileId: String, tvToken: String) async throws -> String {
        let signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
        let clientId = "5acf882d27b74502b7040b0c65519aa7"
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/file"
        // alist 用 GET 请求 /file 获取下载链接
        let tokenData = "GET&\(pathname)&\(timestamp)&\(signKey)"
        let xPanToken = SHA256.hash(data: Data(tokenData.utf8)).map { String(format: "%02x", $0) }.joined()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let reqId = Insecure.MD5.hash(data: Data("\(deviceId)\(timestamp)".utf8)).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "streaming"),  // iBox 用 streaming 返回流媒体地址，download 返回 OSS 下载地址
            URLQueryItem(name: "group_by", value: "source"),
            URLQueryItem(name: "fid", value: fileId),
            URLQueryItem(name: "resolution", value: "low,normal,high,super,2k,4k"),
            URLQueryItem(name: "support", value: "dolby_vision"),
            URLQueryItem(name: "access_token", value: tvToken),
            URLQueryItem(name: "app_ver", value: "1.6.8"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "device_name", value: "iPhone"),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "activity_rect", value: "{}"),
            URLQueryItem(name: "channel", value: "UCTVOFFICIALWEB"),
            URLQueryItem(name: "req_id", value: reqId)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")
        request.setValue("Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        self.log("[CloudDrive] TV Token streaming 响应: \(rawBody.prefix(300))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        // errno 10001 + status -1 = token 过期
        if let errno = json["errno"] as? Int, errno == 10001,
           let status = json["status"] as? Int, status == -1 {
            throw DriveError.noPlayURL("TV Token 已过期，请重新授权 TV")
        }
        if let status = json["status"] as? Int, status == -1 {
            let info = json["error_info"] as? String ?? json["message"] as? String ?? "status=-1"
            throw DriveError.noPlayURL("UCTV Token 获取播放地址失败：\(info)")
        }
        // streaming 端点返回格式: { "data": { "download_url" / "stream_url" / "video_info": [{ "url" }] } }
        // download 端点返回格式: { "data": { "download_url" / "video_list": [{ "video_info": { "url" } }] } }
        if let dataObj = json["data"] as? [String: Any] {
            if let url = dataObj["download_url"] as? String, !url.isEmpty {
                return stripCDNSpeedLimit(url)
            }
            if let url = dataObj["stream_url"] as? String, !url.isEmpty {
                return stripCDNSpeedLimit(url)
            }
            if let url = dataObj["url"] as? String, !url.isEmpty { return stripCDNSpeedLimit(url) }
            if let url = dataObj["play_url"] as? String, !url.isEmpty { return stripCDNSpeedLimit(url) }
            // streaming 端点: video_info 直接在 data 下
            if let videoInfoList = dataObj["video_info"] as? [[String: Any]] {
                for item in videoInfoList {
                    if let url = item["url"] as? String, !url.isEmpty {
                        return stripCDNSpeedLimit(url)
                    }
                }
            }
            // download 端点: video_list 嵌套 video_info
            if let list = dataObj["video_list"] as? [[String: Any]] {
                for item in list {
                    if let info = item["video_info"] as? [String: Any],
                       let url = info["url"] as? String, !url.isEmpty {
                        return stripCDNSpeedLimit(url)
                    }
                }
            }
        }
        self.log("[CloudDrive] ⚠️ TV Token 响应解析失败: \(rawBody.prefix(500))")
        throw DriveError.noPlayURL("UCTV Token 返回中未找到播放地址")
    }

    // MARK: - 迅雷云盘

    /// 迅雷云盘播放地址解析
    /// 迅雷 API 需要复杂的 captcha_token（无感验证码），纯 Swift 无法生成，
    /// 采用 WebView 方案：在页面上下文中调用 API，自动携带认证信息和 captcha token。
    func resolveXunleiPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[Xunlei] 开始解析: \(shareURL)")

        // 提取分享链接中的密码
        var sharePwd = ""
        if let url = URL(string: shareURL),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if let pwdItem = components.queryItems?.first(where: { $0.name == "pwd" }) {
                sharePwd = pwdItem.value ?? ""
            }
        }

        print("[Xunlei] 分享链接密码: \(sharePwd.isEmpty ? "无" : "有")")

        // 使用 WebView 在页面上下文中解析
        let result = try await xunleiResolveViaWebView(shareURL: shareURL, cookie: cookie, sharePwd: sharePwd)

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36",
            "Referer": "https://pan.xunlei.com/"
        ]

        // 优先使用 medias 视频流地址，退而求其次使用 web_content_link 直链
        if let playURL = result.playURL, !playURL.isEmpty {
            print("[Xunlei] ✅ 播放地址获取成功 (medias): \(playURL.prefix(80))")
            return PlayResult(
                url: playURL,
                headers: headers,
                driveType: .xunlei,
                source: result.fileName,
                fallbackURL: result.fallbackURL,
                fallbackHeaders: headers,
                fallbackSource: result.fileName
            )
        }

        if let fallbackURL = result.fallbackURL, !fallbackURL.isEmpty {
            print("[Xunlei] ⚠️ medias 为空，使用 web_content_link 兜底: \(fallbackURL.prefix(80))")
            return PlayResult(
                url: fallbackURL,
                headers: headers,
                driveType: .xunlei,
                source: result.fileName
            )
        }

        let msg = result.error ?? "迅雷云盘: 未获取到播放地址"
        throw DriveError.noPlayURL(msg)
    }

    /// 通过 WebView 在迅雷页面上下文中解析播放地址
    @MainActor
    private func xunleiResolveViaWebView(shareURL: String, cookie: String, sharePwd: String) async throws -> (playURL: String?, fallbackURL: String?, fileName: String?, error: String?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        // 注入已有的 Cookie
        if !cookie.isEmpty {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let pieces = cookie.components(separatedBy: ";")
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: ".xunlei.com",
                    .path: "/"
                ]
                if let httpCookie = HTTPCookie(properties: properties) {
                    await withCheckedContinuation { cont in
                        store.setCookie(httpCookie) { cont.resume() }
                    }
                }
            }
        }

        // 将 WebView 添加到窗口（WKWebView 需要附加到视图层级才能正常工作）
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.addSubview(webView)
        }

        defer {
            webView.removeFromSuperview()
        }

        // 加载分享链接
        guard let url = URL(string: shareURL) else {
            return (nil, nil, nil, "迅雷云盘: 无效的分享链接")
        }

        print("[Xunlei] WebView 加载分享链接: \(shareURL)")
        webView.load(URLRequest(url: url))

        // 等待页面加载完成
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // 等待 React SPA 渲染文件列表（最多等待 30 秒）
        var fileListReady = false
        for _ in 0..<15 {
            let ready = try await webView.evaluateJavaScript("""
                (function() {
                    // 检查文件列表是否已渲染
                    var items = document.querySelectorAll('[class*="file-item"], [class*="file-list"] > div, [class*="FileList"] > div, [data-file-id]');
                    if (items.length > 0) return true;
                    // 检查是否有"保存到网盘"按钮（表示文件列表已加载）
                    var saveBtn = document.querySelector('[class*="save"], [class*="Save"]');
                    if (saveBtn) return true;
                    // 检查页面是否还在加载
                    var loading = document.querySelector('[class*="loading"], [class*="Loading"]');
                    if (loading) return false;
                    // 检查是否有错误提示
                    var error = document.querySelector('[class*="error"], [class*="Error"]');
                    if (error && error.textContent.length > 5) return true;
                    return items.length > 0;
                })()
            """)
            if let isReady = ready as? Bool, isReady {
                fileListReady = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        print("[Xunlei] 文件列表就绪: \(fileListReady)")

        if !fileListReady {
            return (nil, nil, nil, "迅雷云盘: 页面加载超时，文件列表未渲染")
        }

        // 注入 JavaScript 获取文件列表和播放地址
        // 迅雷网页版的文件列表存储在 React 组件状态中，我们可以从 DOM 或 API 获取
        let jsCode = """
        (async function() {
            try {
                // 步骤1: 获取分享内容（文件列表）
                // 从 URL 提取分享 ID
                var url = window.location.href;
                var shareIdMatch = url.match(/\\/s\\/([A-Za-z0-9]+)/);
                if (!shareIdMatch) return {error: "无法提取分享ID"};
                var shareId = shareIdMatch[1];

                // 获取密码参数
                var pwdMatch = url.match(/[?&]pwd=([^&]+)/);
                var pwd = pwdMatch ? decodeURIComponent(pwdMatch[1]) : "";

                // 步骤2: 调用分享详情 API 获取文件列表
                // 迅雷分享 API: POST https://x-api-pan.xunlei.com/drive/v1/share/detail
                var detailResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/share/detail', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        share_id: shareId,
                        pass_code: pwd,
                        flags: {page: 1, size: 50}
                    })
                });

                if (!detailResp.ok) {
                    // 尝试 GET 方式获取分享文件列表
                    var getListResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/share/files?share_id=' + shareId + '&pass_code=' + pwd, {
                        headers: {'Content-Type': 'application/json'}
                    });
                    var getListData = await getListResp.json();
                    if (getListData.files && getListData.files.length > 0) {
                        var files = getListData.files;
                        // 筛选视频文件
                        var videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.ts', '.m4v', '.rmvb', '.rm'];
                        var videoFile = null;
                        for (var i = 0; i < files.length; i++) {
                            var name = (files[i].name || files[i].file_name || '').toLowerCase();
                            for (var j = 0; j < videoExts.length; j++) {
                                if (name.endsWith(videoExts[j])) {
                                    videoFile = files[i];
                                    break;
                                }
                            }
                            if (videoFile) break;
                        }
                        if (!videoFile && files.length > 0) {
                            // 如果没有找到视频文件，取第一个文件
                            videoFile = files[0];
                        }
                        if (videoFile) {
                            var fileId = videoFile.id || videoFile.file_id || '';
                            var fileName = videoFile.name || videoFile.file_name || '';
                            // 获取文件详情（播放地址）
                            var fileResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + fileId + '?with_audit=true&space=', {
                                headers: {'Content-Type': 'application/json'}
                            });
                            var fileData = await fileResp.json();
                            // 优先使用媒体链接（视频流，不限速）
                            var playUrl = '';
                            if (fileData.medias && fileData.medias.length > 0) {
                                for (var k = 0; k < fileData.medias.length; k++) {
                                    if (fileData.medias[k].link && fileData.medias[k].link.url) {
                                        playUrl = fileData.medias[k].link.url;
                                        break;
                                    }
                                }
                            }
                            var fallbackUrl = fileData.web_content_link || '';
                            return {playUrl: playUrl, fallbackUrl: fallbackUrl, fileName: fileName};
                        }
                    }
                    return {error: '分享文件列表为空或获取失败: ' + getListResp.status};
                }

                var detailData = await detailResp.json();

                // 检查是否需要保存到网盘
                // 迅雷云盘分享链接可能需要先保存到网盘才能获取下载/播放地址
                var shareInfo = detailData.share || {};
                var fileList = detailData.file_list || detailData.files || [];
                var fileListAll = fileList;

                if (fileListAll.length === 0 && detailData.file_infos) {
                    fileListAll = detailData.file_infos;
                }

                if (fileListAll.length === 0) {
                    return {error: "分享内容为空或无文件"};
                }

                // 筛选视频文件
                var videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.ts', '.m4v', '.rmvb', '.rm'];
                var videoFile = null;
                for (var i = 0; i < fileListAll.length; i++) {
                    var name = (fileListAll[i].name || fileListAll[i].file_name || '').toLowerCase();
                    for (var j = 0; j < videoExts.length; j++) {
                        if (name.endsWith(videoExts[j])) {
                            videoFile = fileListAll[i];
                            break;
                        }
                    }
                    if (videoFile) break;
                }
                if (!videoFile && fileListAll.length > 0) {
                    videoFile = fileListAll[0];
                }
                if (!videoFile) return {error: "未找到可播放的文件"};

                var fileId = videoFile.id || videoFile.file_id || '';
                var fileName = videoFile.name || videoFile.file_name || '';

                if (!fileId) return {error: "无法获取文件ID"};

                // 步骤3: 获取文件播放地址
                // 尝试直接获取文件详情
                var fileResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + fileId + '?with_audit=true&space=', {
                    headers: {'Content-Type': 'application/json'}
                });

                if (fileResp.ok) {
                    var fileData = await fileResp.json();
                    var playUrl = '';
                    if (fileData.medias && fileData.medias.length > 0) {
                        for (var k = 0; k < fileData.medias.length; k++) {
                            if (fileData.medias[k].link && fileData.medias[k].link.url) {
                                playUrl = fileData.medias[k].link.url;
                                break;
                            }
                        }
                    }
                    var fallbackUrl = fileData.web_content_link || '';
                    if (playUrl || fallbackUrl) {
                        return {playUrl: playUrl, fallbackUrl: fallbackUrl, fileName: fileName};
                    }
                }

                // 步骤4: 如果直接获取失败，尝试保存到网盘后再获取
                // 先获取根目录 ID
                var listResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files?space=&__type=drive&refresh=true&__sync=true&parent_id=&page_token=&with_audit=true&limit=1', {
                    headers: {'Content-Type': 'application/json'}
                });
                if (listResp.ok) {
                    var listData = await listResp.json();
                    // 创建临时文件夹用于保存分享文件
                    var createResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files', {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({
                            kind: 'drive#folder',
                            name: 'vbox_temp_' + Date.now(),
                            parent_id: '',
                            space: ''
                        })
                    });
                    if (createResp.ok) {
                        var createData = await createResp.json();
                        var tempFolderId = createData.id || '';
                        // 保存分享文件到临时文件夹
                        var saveResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/share/save', {
                            method: 'POST',
                            headers: {'Content-Type': 'application/json'},
                            body: JSON.stringify({
                                share_id: shareId,
                                pass_code: pwd,
                                file_ids: [fileId],
                                parent_id: tempFolderId,
                                space: ''
                            })
                        });
                        if (saveResp.ok) {
                            var saveData = await saveResp.json();
                            var savedFileId = '';
                            if (saveData.tasks && saveData.tasks.length > 0) {
                                // 等待保存完成
                                await new Promise(r => setTimeout(r, 3000));
                                // 获取保存后的文件列表
                                var savedListResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files?space=&__type=drive&refresh=true&__sync=true&parent_id=' + tempFolderId + '&with_audit=true&limit=50', {
                                    headers: {'Content-Type': 'application/json'}
                                });
                                if (savedListResp.ok) {
                                    var savedListData = await savedListResp.json();
                                    var savedFiles = savedListData.files || [];
                                    for (var m = 0; m < savedFiles.length; m++) {
                                        var savedName = (savedFiles[m].name || '').toLowerCase();
                                        for (var n = 0; n < videoExts.length; n++) {
                                            if (savedName.endsWith(videoExts[n])) {
                                                savedFileId = savedFiles[m].id || '';
                                                break;
                                            }
                                        }
                                        if (savedFileId) break;
                                    }
                                    if (!savedFileId && savedFiles.length > 0) {
                                        savedFileId = savedFiles[0].id || '';
                                    }
                                    if (savedFileId) {
                                        var savedFileResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + savedFileId + '?with_audit=true&space=', {
                                            headers: {'Content-Type': 'application/json'}
                                        });
                                        if (savedFileResp.ok) {
                                            var savedFileData = await savedFileResp.json();
                                            var playUrl2 = '';
                                            if (savedFileData.medias && savedFileData.medias.length > 0) {
                                                for (var p = 0; p < savedFileData.medias.length; p++) {
                                                    if (savedFileData.medias[p].link && savedFileData.medias[p].link.url) {
                                                        playUrl2 = savedFileData.medias[p].link.url;
                                                        break;
                                                    }
                                                }
                                            }
                                            var fallbackUrl2 = savedFileData.web_content_link || '';
                                            // 清理临时文件夹
                                            fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + tempFolderId + '/trash', {
                                                method: 'PATCH',
                                                headers: {'Content-Type': 'application/json'},
                                                body: '{}'
                                            });
                                            if (playUrl2 || fallbackUrl2) {
                                                return {playUrl: playUrl2, fallbackUrl: fallbackUrl2, fileName: fileName};
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                return {error: "所有获取播放地址的方式均失败"};
            } catch(e) {
                return {error: 'JS异常: ' + e.message};
            }
        })()
        """

        print("[Xunlei] 开始注入 JavaScript 解析播放地址...")

        let jsResult: Any?
        do {
            jsResult = try await withTimeout(seconds: 30) {
                try await webView.evaluateJavaScript(jsCode)
            }
        } catch {
            print("[Xunlei] ❌ JS 执行超时或失败: \(error.localizedDescription)")
            return (nil, nil, nil, "迅雷云盘: 解析超时，请重试")
        }

        guard let resultDict = jsResult as? [String: Any] else {
            return (nil, nil, nil, "迅雷云盘: 解析结果格式异常")
        }

        let playURL = resultDict["playUrl"] as? String
        let fallbackURL = resultDict["fallbackUrl"] as? String
        let fileName = resultDict["fileName"] as? String
        let error = resultDict["error"] as? String

        print("[Xunlei] 解析结果: playURL=\(playURL != nil ? "有" : "无"), fallbackURL=\(fallbackURL != nil ? "有" : "无"), error=\(error ?? "无")")

        return (playURL, fallbackURL, fileName, error)
    }

    // MARK: - 迅雷云盘文件列表（多文件/文件夹支持）

    struct XunleiShareFile {
        let fileId: String
        let fileName: String
        let isDir: Bool
    }

    /// 获取迅雷云盘分享链接中的所有视频文件（递归遍历子文件夹）
    /// 用于文件夹类型的分享链接，返回所有可播放的视频文件列表
    @MainActor
    func xunleiGetFileList(shareURL: String, cookie: String) async throws -> [XunleiShareFile] {
        print("[Xunlei] 📂 获取文件列表（递归）: \(shareURL.prefix(60))")
        self.log("[CloudDrive] [Xunlei] 获取文件列表...")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        // 注入 Cookie
        if !cookie.isEmpty {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let pieces = cookie.components(separatedBy: ";")
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: ".xunlei.com",
                    .path: "/"
                ]
                if let httpCookie = HTTPCookie(properties: properties) {
                    await withCheckedContinuation { cont in
                        store.setCookie(httpCookie) { cont.resume() }
                    }
                }
            }
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.addSubview(webView)
        }

        defer { webView.removeFromSuperview() }

        guard let url = URL(string: shareURL) else {
            throw DriveError.invalidShareURL
        }

        print("[Xunlei] WebView 加载分享链接: \(shareURL)")
        webView.load(URLRequest(url: url))

        // 等待页面加载完成
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // 等待 React SPA 渲染文件列表
        var fileListReady = false
        for _ in 0..<15 {
            let ready = try await webView.evaluateJavaScript("""
                (function() {
                    var items = document.querySelectorAll('[class*="file-item"], [class*="file-list"] > div, [class*="FileList"] > div, [data-file-id]');
                    if (items.length > 0) return true;
                    var saveBtn = document.querySelector('[class*="save"], [class*="Save"]');
                    if (saveBtn) return true;
                    var loading = document.querySelector('[class*="loading"], [class*="Loading"]');
                    if (loading) return false;
                    var error = document.querySelector('[class*="error"], [class*="Error"]');
                    if (error && error.textContent.length > 5) return true;
                    return items.length > 0;
                })()
            """)
            if let isReady = ready as? Bool, isReady {
                fileListReady = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        print("[Xunlei] 文件列表页就绪: \(fileListReady)")
        if !fileListReady {
            throw DriveError.noPlayURL("迅雷云盘: 页面加载超时，文件列表未渲染")
        }

        // 在 WebView 中注入一个全局函数，用于加载指定目录的文件列表
        let injectJS = """
        window.__vbox_xunlei_loadDir = async function(parentId) {
            try {
                var url = window.location.href;
                var shareIdMatch = url.match(/\\/s\\/([A-Za-z0-9]+)/);
                if (!shareIdMatch) return {error: "无法提取分享ID"};
                var shareId = shareIdMatch[1];

                var pwdMatch = url.match(/[?&]pwd=([^&]+)/);
                var pwd = pwdMatch ? decodeURIComponent(pwdMatch[1]) : "";

                // 使用 share/files API 加载指定目录
                var apiURL = 'https://x-api-pan.xunlei.com/drive/v1/share/files?share_id=' + shareId + '&pass_code=' + pwd;
                if (parentId && parentId !== 'root') {
                    apiURL += '&parent_id=' + encodeURIComponent(parentId);
                }
                apiURL += '&page=1&size=200';

                var resp = await fetch(apiURL);
                if (!resp.ok) {
                    // 兜底：用 share/detail API
                    var detailResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/share/detail', {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({
                            share_id: shareId,
                            pass_code: pwd,
                            parent_file_id: parentId === 'root' ? '' : parentId,
                            flags: {page: 1, size: 200}
                        })
                    });
                    if (!detailResp.ok) {
                        return {error: 'API返回: ' + detailResp.status};
                    }
                    var detailData = await detailResp.json();
                    var list = detailData.file_list || detailData.files || detailData.file_infos || [];
                    return {files: list};
                }

                var data = await resp.json();
                var list = data.file_list || data.files || data.file_infos || (data.data && data.data.files) || [];
                return {files: list};
            } catch(e) {
                return {error: 'JS异常: ' + e.message};
            }
        };
        """
        try await webView.evaluateJavaScript(injectJS)

        // BFS 递归遍历所有子文件夹，收集视频文件
        var allVideoFiles: [XunleiShareFile] = []
        var dirsToLoad: [(id: String, name: String)] = [("root", "根目录")]
        var loadedDirs = Set<String>()
        let maxDirs = 30 // 最多遍历 30 个子目录，防止极端嵌套

        while !dirsToLoad.isEmpty && allVideoFiles.count < 500 {
            guard loadedDirs.count < maxDirs else {
                print("[Xunlei] ⚠️ 已达目录数量上限 (\(maxDirs))，停止递归")
                break
            }

            let current = dirsToLoad.removeFirst()
            guard !loadedDirs.contains(current.id) else { continue }
            loadedDirs.insert(current.id)

            let jsCode = """
            (async function() {
                var result = await window.__vbox_xunlei_loadDir('\(current.id)');
                if (result.error) return {error: result.error};

                var files = result.files || [];
                var videoExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.ts', '.m4v', '.rmvb', '.rm'];
                var videoFiles = [];
                var subDirs = [];

                for (var i = 0; i < files.length; i++) {
                    var fName = files[i].name || files[i].file_name || '';
                    var fId = files[i].id || files[i].file_id || '';
                    if (!fId) continue;

                    // 判断是否为文件夹
                    var isDir = false;
                    if (files[i].type === 'folder' || files[i].type === 'dir' || files[i].is_dir === true || files[i].isDir === true) {
                        isDir = true;
                    } else if (!fName.includes('.')) {
                        // 无扩展名的大概率是文件夹（兜底判断）
                        isDir = true;
                    }

                    if (isDir) {
                        subDirs.push({fileId: fId, fileName: fName, isDir: true});
                    } else {
                        var lowerName = fName.toLowerCase();
                        for (var j = 0; j < videoExts.length; j++) {
                            if (lowerName.endsWith(videoExts[j])) {
                                videoFiles.push({fileId: fId, fileName: fName, isDir: false});
                                break;
                            }
                        }
                    }
                }

                return {videos: videoFiles, dirs: subDirs};
            })()
            """

            let jsResult: Any?
            do {
                jsResult = try await withTimeout(seconds: 15) {
                    try await webView.evaluateJavaScript(jsCode)
                }
            } catch {
                print("[Xunlei] ⚠️ 加载目录失败: \(current.name), 跳过")
                continue
            }

            guard let resultDict = jsResult as? [String: Any] else {
                continue
            }

            if let error = resultDict["error"] as? String {
                print("[Xunlei] ⚠️ 加载目录失败: \(current.name), \(error)")
                continue
            }

            // 收集视频文件
            if let videos = resultDict["videos"] as? [[String: Any]] {
                for v in videos {
                    if let fId = v["fileId"] as? String, !fId.isEmpty,
                       let fName = v["fileName"] as? String {
                        allVideoFiles.append(XunleiShareFile(fileId: fId, fileName: fName, isDir: false))
                    }
                }
            }

            // 收集子文件夹，加入队列
            if let dirs = resultDict["dirs"] as? [[String: Any]] {
                for d in dirs {
                    if let dId = d["fileId"] as? String, !dId.isEmpty,
                       let dName = d["fileName"] as? String {
                        if !loadedDirs.contains(dId) {
                            dirsToLoad.append((dId, dName))
                        }
                    }
                }
            }
        }

        print("[Xunlei] ✅ 递归获取完成: \(allVideoFiles.count) 个视频文件，遍历了 \(loadedDirs.count) 个目录")
        self.log("[CloudDrive] [Xunlei] ✅ 文件列表: \(allVideoFiles.count) 个视频")

        guard !allVideoFiles.isEmpty else {
            throw DriveError.noPlayURL("迅雷云盘: 分享内未找到视频文件")
        }

        return allVideoFiles
    }

    /// 解析迅雷云盘指定文件的播放地址（用于多文件选集播放）
    @MainActor
    func resolveXunleiFilePlayURL(shareURL: String, cookie: String, fileId: String, fileName: String) async throws -> PlayResult {
        print("[Xunlei] 🎬 解析指定文件: fileId=\(fileId) name=\(fileName)")
        self.log("[CloudDrive] [Xunlei] 解析文件: \(fileName)")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

        // 注入 Cookie
        if !cookie.isEmpty {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let pieces = cookie.components(separatedBy: ";")
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: ".xunlei.com",
                    .path: "/"
                ]
                if let httpCookie = HTTPCookie(properties: properties) {
                    await withCheckedContinuation { cont in
                        store.setCookie(httpCookie) { cont.resume() }
                    }
                }
            }
        }

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.addSubview(webView)
        }

        defer { webView.removeFromSuperview() }

        guard let url = URL(string: shareURL) else {
            throw DriveError.invalidShareURL
        }

        webView.load(URLRequest(url: url))
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // 等待页面渲染
        var fileListReady = false
        for _ in 0..<15 {
            let ready = try await webView.evaluateJavaScript("""
                (function() {
                    var items = document.querySelectorAll('[class*="file-item"], [class*="file-list"] > div, [class*="FileList"] > div, [data-file-id]');
                    if (items.length > 0) return true;
                    var saveBtn = document.querySelector('[class*="save"], [class*="Save"]');
                    if (saveBtn) return true;
                    var loading = document.querySelector('[class*="loading"], [class*="Loading"]');
                    if (loading) return false;
                    var error = document.querySelector('[class*="error"], [class*="Error"]');
                    if (error && error.textContent.length > 5) return true;
                    return items.length > 0;
                })()
            """)
            if let isReady = ready as? Bool, isReady {
                fileListReady = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if !fileListReady {
            throw DriveError.noPlayURL("迅雷云盘: 页面加载超时")
        }

        // 转义 fileId 和 fileName 用于 JavaScript 字符串
        let escapedFileId = fileId.replacingOccurrences(of: "'", with: "\\'")
        let escapedFileName = fileName.replacingOccurrences(of: "'", with: "\\'")

        let jsCode = """
        (async function() {
            try {
                var targetFileId = '\(escapedFileId)';
                var targetFileName = '\(escapedFileName)';

                // 步骤1: 尝试直接获取文件详情（播放地址）
                var fileResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + targetFileId + '?with_audit=true&space=', {
                    headers: {'Content-Type': 'application/json'}
                });

                if (fileResp.ok) {
                    var fileData = await fileResp.json();
                    var playUrl = '';
                    if (fileData.medias && fileData.medias.length > 0) {
                        for (var k = 0; k < fileData.medias.length; k++) {
                            if (fileData.medias[k].link && fileData.medias[k].link.url) {
                                playUrl = fileData.medias[k].link.url;
                                break;
                            }
                        }
                    }
                    var fallbackUrl = fileData.web_content_link || '';
                    if (playUrl || fallbackUrl) {
                        return {playUrl: playUrl, fallbackUrl: fallbackUrl, fileName: targetFileName};
                    }
                }

                // 步骤2: 直接获取失败，尝试保存到网盘后再获取
                var url = window.location.href;
                var shareIdMatch = url.match(/\\/s\\/([A-Za-z0-9]+)/);
                if (!shareIdMatch) return {error: "无法提取分享ID"};
                var shareId = shareIdMatch[1];

                var pwdMatch = url.match(/[?&]pwd=([^&]+)/);
                var pwd = pwdMatch ? decodeURIComponent(pwdMatch[1]) : "";

                // 创建临时文件夹
                var createResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        kind: 'drive#folder',
                        name: 'vbox_temp_' + Date.now(),
                        parent_id: '',
                        space: ''
                    })
                });
                if (createResp.ok) {
                    var createData = await createResp.json();
                    var tempFolderId = createData.id || '';

                    // 保存指定文件到临时文件夹
                    var saveResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/share/save', {
                        method: 'POST',
                        headers: {'Content-Type': 'application/json'},
                        body: JSON.stringify({
                            share_id: shareId,
                            pass_code: pwd,
                            file_ids: [targetFileId],
                            parent_id: tempFolderId,
                            space: ''
                        })
                    });
                    if (saveResp.ok) {
                        var saveData = await saveResp.json();
                        if (saveData.tasks && saveData.tasks.length > 0) {
                            await new Promise(r => setTimeout(r, 3000));
                            var savedListResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files?space=&__type=drive&refresh=true&__sync=true&parent_id=' + tempFolderId + '&with_audit=true&limit=50', {
                                headers: {'Content-Type': 'application/json'}
                            });
                            if (savedListResp.ok) {
                                var savedListData = await savedListResp.json();
                                var savedFiles = savedListData.files || [];
                                var savedFileId = '';

                                // 优先通过文件名匹配
                                for (var m = 0; m < savedFiles.length; m++) {
                                    if (savedFiles[m].name === targetFileName) {
                                        savedFileId = savedFiles[m].id || '';
                                        break;
                                    }
                                }
                                if (!savedFileId && savedFiles.length > 0) {
                                    savedFileId = savedFiles[0].id || '';
                                }
                                if (savedFileId) {
                                    var savedFileResp = await fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + savedFileId + '?with_audit=true&space=', {
                                        headers: {'Content-Type': 'application/json'}
                                    });
                                    if (savedFileResp.ok) {
                                        var savedFileData = await savedFileResp.json();
                                        var playUrl2 = '';
                                        if (savedFileData.medias && savedFileData.medias.length > 0) {
                                            for (var p = 0; p < savedFileData.medias.length; p++) {
                                                if (savedFileData.medias[p].link && savedFileData.medias[p].link.url) {
                                                    playUrl2 = savedFileData.medias[p].link.url;
                                                    break;
                                                }
                                            }
                                        }
                                        var fallbackUrl2 = savedFileData.web_content_link || '';
                                        // 清理临时文件夹
                                        fetch('https://x-api-pan.xunlei.com/drive/v1/files/' + tempFolderId + '/trash', {
                                            method: 'PATCH',
                                            headers: {'Content-Type': 'application/json'},
                                            body: '{}'
                                        });
                                        if (playUrl2 || fallbackUrl2) {
                                            return {playUrl: playUrl2, fallbackUrl: fallbackUrl2, fileName: targetFileName};
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                return {error: "无法获取文件播放地址"};
            } catch(e) {
                return {error: 'JS异常: ' + e.message};
            }
        })()
        """

        let jsResult: Any?
        do {
            jsResult = try await withTimeout(seconds: 30) {
                try await webView.evaluateJavaScript(jsCode)
            }
        } catch {
            throw DriveError.noPlayURL("迅雷云盘: 解析超时，请重试")
        }

        guard let resultDict = jsResult as? [String: Any] else {
            throw DriveError.noPlayURL("迅雷云盘: 解析结果格式异常")
        }

        let playURL = resultDict["playUrl"] as? String
        let fallbackURL = resultDict["fallbackUrl"] as? String
        let resultFileName = resultDict["fileName"] as? String ?? fileName
        let error = resultDict["error"] as? String

        if let playURL, !playURL.isEmpty {
            print("[Xunlei] ✅ 播放地址获取成功: \(playURL.prefix(80))")
            let headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36",
                "Referer": "https://pan.xunlei.com/"
            ]
            return PlayResult(
                url: playURL,
                headers: headers,
                driveType: .xunlei,
                source: resultFileName,
                fallbackURL: fallbackURL,
                fallbackHeaders: headers,
                fallbackSource: resultFileName
            )
        }

        if let fallbackURL, !fallbackURL.isEmpty {
            print("[Xunlei] ⚠️ 使用 web_content_link 兜底: \(fallbackURL.prefix(80))")
            let headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/67.0.3396.99 Safari/537.36",
                "Referer": "https://pan.xunlei.com/"
            ]
            return PlayResult(
                url: fallbackURL,
                headers: headers,
                driveType: .xunlei,
                source: resultFileName
            )
        }

        throw DriveError.noPlayURL(error ?? "迅雷云盘: 未获取到播放地址")
    }

    /// 带超时的异步操作包装
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DriveError.noPlayURL("操作超时")
            }
            guard let result = try await group.next() else {
                throw DriveError.noPlayURL("操作无结果")
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - 统一解析入口

    private func splitVboxFragment(from url: String) -> (baseURL: String, params: [String: String]) {
        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (url, [:]) }
        let fragment = String(parts[1])
        var params: [String: String] = [:]
        var passthrough: [String] = []
        for item in fragment.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                passthrough.append(String(item))
                continue
            }
            let key = String(pair[0])
            let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
            if key.hasPrefix("vbox_") {
                params[key] = value
            } else {
                passthrough.append(String(item))
            }
        }
        let base = passthrough.isEmpty ? String(parts[0]) : "\(parts[0])#\(passthrough.joined(separator: "&"))"
        return (base, params)
    }

    func resolvePlayURL(from shareURL: String) async throws -> PlayResult {
        let cleanURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let split = splitVboxFragment(from: cleanURL)
        let baseURL = split.baseURL
        let vboxParams = split.params
        self.log("[CloudDrive] resolvePlayURL 输入: \(baseURL.prefix(80))")
        guard let driveType = Self.detectDrive(from: baseURL) else {
            self.log("[CloudDrive] ❌ detectDrive 返回 nil")
            throw DriveError.invalidShareURL
        }
        self.log("[CloudDrive] ✅ detectDrive: \(driveType.rawValue)")

        // ═══════════════════════════════════════════════════════════
        // ★ 阿里云盘：仅使用 PG 4kz 路链（原生路链播放不可用，已移除回退）
        // 失败直接抛出 PG 错误，方便排查问题
        // ═══════════════════════════════════════════════════════════
        if driveType == .ali {
            guard AliyunPgPlayManager.hasPgCredential(),
                  let pgCredential = AliyunPgPlayManager.getPgCredential() else {
                self.log("[CloudDrive] ❌ 阿里云盘需要 PG 凭证，请先配置 PG refresh_token")
                throw DriveError.tokenNotConfigured("阿里云盘 PG")
            }
            self.log("[CloudDrive] 🔄 使用 PG 4kz 路链 (转存GO原画)")
            let pgResult = try await AliyunPgPlayManager.shared
                .resolveViaPgChain(shareURL: baseURL, credential: pgCredential)
            self.log("[CloudDrive] ✅ PG 4kz 路链成功")
            return pgResult
        }

        // ═══════════════════════════════════════════════════════════
        // ★ Node 托管网盘：115/123/139/189/迅雷/光鸭/蜗牛 全部走 A1 接缝
        // （Node 常驻系统解析），废弃 vbox 原生路链。解析经
        // /spider/push/4/detail → /spider/push/4/play，错误直接抛给播放端。
        // ═══════════════════════════════════════════════════════════
        if driveType == .one15 || driveType == .pan123 || driveType == .pan139
            || driveType == .pan189 || driveType == .xunlei
            || driveType == .guangya || driveType == .woniu4k {
            self.log("[CloudDrive] 🔄 \(driveType.displayName) 走 A1 接缝（Node 常驻系统）")
            return try await resolveViaNodePan(shareURL: baseURL, driveType: driveType)
        }

        let tokens = tokens(for: driveType)
        guard !tokens.isEmpty else {
            throw DriveError.tokenNotConfigured(driveType.displayName)
        }

        var lastError: Error?
        if driveType == .baidu, let pair = baiduTokenPair() {
            self.log("[CloudDrive] 🔄 尝试百度网盘 WebToken: \(pair.web.name)，PCSToken: \(pair.pcs?.name ?? "未配置")")
            if let fsId = vboxParams["vbox_fsid"], !fsId.isEmpty {
                return try await resolveBaiduPlayURL(
                    shareURL: baseURL,
                    bduss: pair.web.value,
                    fsId: fsId,
                    pcsCookie: pair.pcs?.value ?? ""
                )
            }
            return try await resolveBaiduPlayURL(
                shareURL: baseURL,
                bduss: pair.web.value,
                pcsCookie: pair.pcs?.value ?? ""
            )
        }

        for (index, token) in tokens.enumerated() {
            let label = tokens.count > 1 ? " [\(index + 1)/\(tokens.count)]" : ""
            self.log("[CloudDrive] 🔄 尝试 \(driveType.displayName) Token\(label): \(token.name)")
            do {
                let result: PlayResult
                switch driveType {
                case .ali:
                    result = try await resolveAliPlayURL(shareURL: baseURL, refreshToken: token.value)
                case .quark:
                    result = try await resolveQuarkPlayURLWithRetry(shareURL: baseURL, cookie: token.value, preferredFid: vboxParams["vbox_fid"], routePreference: vboxParams["vbox_route"])
                case .baidu:
                    if let fsId = vboxParams["vbox_fsid"], !fsId.isEmpty {
                        result = try await resolveBaiduPlayURL(shareURL: baseURL, bduss: token.value, fsId: fsId)
                    } else {
                        result = try await resolveBaiduPlayURL(shareURL: baseURL, bduss: token.value)
                    }
                case .uc:
                    result = try await resolveUCPlayURL(shareURL: baseURL, cookie: token.value)
                case .one15, .pan123, .pan139, .pan189, .xunlei:
                    // Node 托管网盘：115/123/139/189/迅雷 由 Node 常驻系统解析（A1 接缝），
                    // 原生路链已废弃；到达此分支说明凭据误入原生 Token 列表，明确报错避免静默失败。
                    throw AuthError.notAuthorized("\(driveType.displayName) 由 Node 常驻系统解析（A1 接缝），原生路链已废弃")
                case .guangya, .woniu4k:
                    // 光鸭/蜗牛由 Node 常驻系统解析（A1 接缝），原生链路不参与；
                    // 到达此分支说明凭据误入原生 Token 列表，明确报错避免静默失败。
                    throw AuthError.notAuthorized("光鸭/蜗牛由 Node 常驻系统解析，请确认 Node 状态")
                }
                self.log("[CloudDrive] ✅ \(driveType.displayName) Token \"\(token.name)\" 成功")
                return result
            } catch {
                lastError = error
                self.log("[CloudDrive] ⚠️ \(driveType.displayName) Token \"\(token.name)\" 失败: \(error.localizedDescription)")
                if isLikelyAuthInvalid(error) {
                    CloudDriveAuthManager.shared.markInvalid(driveType, reason: error.localizedDescription)
                }
                continue
            }
        }

        let count = tokens.count
        self.log("[CloudDrive] ❌ 所有 \(count) 个 \(driveType.displayName) Token 均失败")
        throw lastError ?? DriveError.tokenNotConfigured(driveType.displayName)
    }

    // MARK: - A1 接缝：Node 常驻系统解析（光鸭/蜗牛）

    /// 走 Node 常驻系统解析分享链接（P1-08/09/15）
    /// 链路：/spider/push/4/detail（分享→文件列表）→ /spider/push/4/play（条目→播放地址）
    private func resolveViaNodePan(shareURL: String, driveType: DriveType) async throws -> PlayResult {
        let share = try await resolveNodeShare(shareURL, driveType: driveType)
        guard let first = share.entries.first else {
            throw DriveError.noPlayURL("\(driveType.displayName): 分享内未找到可播放视频")
        }
        return try await resolveNodePlay(playID: first.playID, driveType: driveType)
    }

    // MARK: - A1 接缝：Node 托管网盘统一判定与解析（详情页/播放器共用）

    /// Node 托管网盘：115/123/139/189/迅雷/光鸭/蜗牛。
    /// 百度/夸克/阿里/UC 不在此列，原生路链与播放链路不受任何影响。
    static func isNodeManagedDrive(_ driveType: DriveType) -> Bool {
        driveType == .one15 || driveType == .pan123 || driveType == .pan139
            || driveType == .pan189 || driveType == .xunlei
            || driveType == .guangya || driveType == .woniu4k
    }

    /// 解析分享链接 → Node 文件列表（集数），供详情页/播放器展开选集
    /// （A1 接缝 /spider/push/4/detail；失败直接抛出，无原生兜底）
    func resolveNodeShare(_ shareURL: String, driveType: DriveType) async throws -> NodePanShareResult {
        guard NodeRuntimeManager.shared.isSystemReady else {
            self.log("[CloudDrive] ❌ \(driveType.displayName) 需要 Node 常驻系统，但 Node 未就绪")
            throw DriveError.tokenNotConfigured("\(driveType.displayName)（Node 未就绪，请稍后重试）")
        }
        let share = try await NodePanResolver.shared.resolveShare(shareURL)
        self.log("[CloudDrive] ✅ \(driveType.displayName) Node 文件列表: \(share.entries.count) 个文件")
        return share
    }

    /// 用 playID 换取播放地址（A1 接缝 /spider/push/4/play），返回带正确盘别标识的 PlayResult
    func resolveNodePlay(playID: String, driveType: DriveType) async throws -> PlayResult {
        guard NodeRuntimeManager.shared.isSystemReady else {
            self.log("[CloudDrive] ❌ \(driveType.displayName) 需要 Node 常驻系统，但 Node 未就绪")
            throw DriveError.tokenNotConfigured("\(driveType.displayName)（Node 未就绪，请稍后重试）")
        }
        let play = try await NodePanResolver.shared.resolvePlay(playID: playID)
        let alias: DriveTypeAlias
        switch driveType {
        case .one15: alias = .one15
        case .pan123: alias = .pan123
        case .pan139: alias = .pan139
        case .pan189: alias = .pan189
        case .xunlei: alias = .xunlei
        case .guangya: alias = .guangya
        case .woniu4k: alias = .woniu4k
        default: alias = .woniu4k
        }
        let result = PlayResult(
            url: play.url,
            headers: play.headers,
            driveType: alias,
            source: "A1接缝-\(driveType.displayName)"
        )
        self.log("[CloudDrive] ✅ \(driveType.displayName) Node 取链成功: \(play.url.prefix(100))")
        return result
    }

    private func isLikelyAuthInvalid(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("401")
            || text.contains("403")
            || text.contains("未登录")
            || text.contains("登录")
            || text.contains("cookie")
            || text.contains("token")
            || text.contains("access_token")
            || text.contains("refresh_token")
            || text.contains("授权")
            || text.contains("失效")
            || text.contains("invalid")
            || text.contains("expired")
    }
}

// MARK: - 数据结构

struct PlayResult {
    let url: String
    let headers: [String: String]
    let driveType: DriveTypeAlias
    let source: String?
    let fallbackURL: String?
    let fallbackHeaders: [String: String]?
    let fallbackSource: String?

    init(
        url: String,
        headers: [String: String],
        driveType: DriveTypeAlias,
        source: String? = nil,
        fallbackURL: String? = nil,
        fallbackHeaders: [String: String]? = nil,
        fallbackSource: String? = nil
    ) {
        self.url = url
        self.headers = headers
        self.driveType = driveType
        self.source = source
        self.fallbackURL = fallbackURL
        self.fallbackHeaders = fallbackHeaders
        self.fallbackSource = fallbackSource
    }
}

enum DriveTypeAlias: String {
    case ali = "阿里云盘"
    case quark = "夸克"
    case baidu = "百度"
    case one15 = "115"
    case uc = "UC"
    case pan123 = "123云盘"
    case pan139 = "139云盘"
    case pan189 = "天翼云盘"
    case xunlei = "迅雷云盘"
    case guangya = "光鸭网盘"
    case woniu4k = "蜗牛网盘"
}

enum DriveError: LocalizedError {
    case noPlayURL(String)
    case invalidResponse
    case invalidShareURL
    case saveFailed
    case notImplemented
    case tokenNotConfigured(String)

    var errorDescription: String? {
        switch self {
        case .noPlayURL(let reason):
            return "无法获取播放地址：\(reason)"
        case .invalidResponse:
            return "服务器响应无效"
        case .invalidShareURL:
            return "无效的分享链接"
        case .saveFailed:
            return "转存失败"
        case .notImplemented:
            return "该网盘暂不支持"
        case .tokenNotConfigured(let name):
            return "未配置\(name) Token"
        }
    }
}

// MARK: - 阿里云盘 API 响应模型

private struct AliShareTokenResponse: Codable {
    let shareToken: String

    enum CodingKeys: String, CodingKey {
        case shareToken = "share_token"
    }
}

private struct AliVideoPreviewResponse: Codable {
    let videoPreviewPlayInfo: AliVideoPreviewInfo?

    enum CodingKeys: String, CodingKey {
        case videoPreviewPlayInfo = "video_preview_play_info"
    }
}

private struct AliVideoPreviewInfo: Codable {
    let liveTranscodingTaskList: [AliTranscodeTask]?

    enum CodingKeys: String, CodingKey {
        case liveTranscodingTaskList = "live_transcoding_task_list"
    }
}

private struct AliTranscodeTask: Codable {
    let url: String?
    let templateId: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case url
        case templateId = "template_id"
        case status
    }
}

private struct AliDownloadURLResponse: Codable {
    let url: String?
    let expiration: String?
    let method: String?
}

// MARK: - MD5 扩展
extension String {
    func md5() -> String {
        let messageData = self.data(using: .utf8)!
        var digestData = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        
        _ = digestData.withUnsafeMutableBytes { digestBytes in
            messageData.withUnsafeBytes { messageBytes in
                CC_MD5(messageBytes.baseAddress, CC_LONG(messageData.count), digestBytes.baseAddress)
            }
        }
        
        return digestData.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - M115 加解密（内联，避免 pbxproj 注册问题）

// MARK: - M115Error

enum M115Error: Error, LocalizedError {
    case invalidKey
    case encryptionFailed
    case decryptionFailed
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "M115: 无效的 RSA 公钥"
        case .encryptionFailed: return "M115: RSA 加密失败"
        case .decryptionFailed: return "M115: RSA 解密失败"
        case .invalidResponse(let msg): return "M115: \(msg)"
        }
    }
}

// MARK: - M115Cipher

/// 115 网盘 m115 RSA 加解密器
///
/// 基于 fake115uploader cipher.go 移植，实现 115 专有的 RSA+XOR 加密方案。
/// 参考: https://github.com/orzogc/fake115uploader/blob/master/cipher/cipher.go
///
/// 使用流程（有状态）:
/// 1. 创建实例
/// 2. 调用 encrypt() 加密请求 → 内部生成 randKey 和 keyS
/// 3. 发送加密请求到 proapi.115.com/app/chrome/downurl
/// 4. 调用 decrypt() 解密响应 → 复用 step 2 的 keyS
final class M115Cipher {

    // MARK: - 常量（与 Go 源码完全一致）

    /// gKeyL: 12 字节 XOR 密钥，用于加密阶段
    private static let gKeyL: [UInt8] = [
        0x78, 0x06, 0xAD, 0x4C, 0x33, 0x86, 0x5D, 0x18,
        0x4C, 0x01, 0x3F, 0x46
    ]

    /// gKts: 136 字节密钥表，用于 genKey 生成派生密钥
    private static let gKts: [UInt8] = [
        0xF0, 0xE5, 0x69, 0xAE, 0xBF, 0xDC, 0xBF, 0x8A,
        0x1A, 0x45, 0xE8, 0xBE, 0x7D, 0xA6, 0x73, 0xB8,
        0xDE, 0x8F, 0xE7, 0xC4, 0x45, 0xDA, 0x86, 0xC4,
        0x9B, 0x64, 0x8B, 0x14, 0x6A, 0xB4, 0xF1, 0xAA,
        0x38, 0x01, 0x35, 0x9E, 0x26, 0x69, 0x2C, 0x86,
        0x00, 0x6B, 0x4F, 0xA5, 0x36, 0x34, 0x62, 0xA6,
        0x2A, 0x96, 0x68, 0x18, 0xF2, 0x4A, 0xFD, 0xBD,
        0x6B, 0x97, 0x8F, 0x4D, 0x8F, 0x89, 0x13, 0xB7,
        0x6C, 0x8E, 0x93, 0xED, 0x0E, 0x0D, 0x48, 0x3E,
        0xD7, 0x2F, 0x88, 0xD8, 0xFE, 0xFE, 0x7E, 0x86,
        0x50, 0x95, 0x4F, 0xD1, 0xEB, 0x83, 0x26, 0x34,
        0xDB, 0x66, 0x7B, 0x9C, 0x7E, 0x9D, 0x7A, 0x81,
        0x32, 0xEA, 0xB6, 0x33, 0xDE, 0x3A, 0xA9, 0x59,
        0x34, 0x66, 0x3B, 0xAA, 0xBA, 0x81, 0x60, 0x48,
        0xB9, 0xD5, 0x81, 0x9C, 0xF8, 0x6C, 0x84, 0x77,
        0xFF, 0x54, 0x78, 0x26, 0x5F, 0xBE, 0xE8, 0x1E,
        0x36, 0x9F, 0x34, 0x80, 0x5C, 0x45, 0x2C, 0x9B,
        0x76, 0xD5, 0x1B, 0x8F, 0xCC, 0xC3, 0xB8, 0xF5
    ]

    /// RSA 公钥 PEM（1024-bit，与 fake115uploader 一致）
    private static let publicKeyPEM = """
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCGhpgMD1okxLnUMCDNLCJwP/P0
UHVlKQWLHPiPCbhgITZHcZim4mgxSWWb0SLDNZL9ta1HlErR6k02xrFyqtYzjDu2
rGInUC0BCZOsln0a7wDwyOA43i5NO8LsNory6fEKbx7aT3Ji8TZCDAfDMbhxvxOf
dPMBDjxP5X3zr7cWgwIDAQAB
-----END PUBLIC KEY-----
"""

    private static let rsaKeySize = 16       // randKey 字节数
    private static let rsaBlockSize = 128    // RSA 块大小（1024 bit / 8）

    // MARK: - 运行时状态（有状态：encrypt 后 decrypt 复用）

    private let secKey: SecKey
    private let modulusN: RSABigInt
    private let exponentE: UInt32
    private var randKey: [UInt8] = []
    private var keyS: [UInt8] = []

    // MARK: - 初始化

    init() throws {
        // 解析 PEM 公钥
        let base64String = Self.publicKeyPEM
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: base64String) else {
            throw M115Error.invalidKey
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw M115Error.invalidKey
        }
        self.secKey = key

        // 从 PKCS1 外部表示提取 N 和 E（用于解密时的原始 RSA 运算）
        guard let externalData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw M115Error.invalidKey
        }
        let (n, e) = try Self.parseRSAPublicKey(externalData)
        self.modulusN = n
        self.exponentE = e

        print("[M115] 初始化成功，N=\(n.bigEndianBytes().count) 字节, E=\(e)")
    }

    // MARK: - 加密

    /// 加密明文（对应 Go: RsaCipher.Encrypt）
    ///
    /// 流程:
    /// 1. 生成 16 字节随机 randKey
    /// 2. 生成 keyS = genKey(randKey, 4)
    /// 3. tmp = xor(plaintext, keyS)
    /// 4. 反转 tmp
    /// 5. xorText = randKey + xor(reversed_tmp, gKeyL)
    /// 6. RSA PKCS1v15 加密
    /// 7. Base64 编码
    func encrypt(_ plainText: [UInt8]) throws -> String {
        // 1. 生成随机密钥
        randKey = (0..<Self.rsaKeySize).map { _ in UInt8.random(in: 0...255) }
        keyS = Self.genKey(randKey, 4)

        // 2. XOR 明文
        var tmp = Self.xor(plainText, keyS)

        // 3. 反转
        tmp.reverse()

        // 4. 拼接 randKey + xor(reversed, gKeyL)
        var xorText = randKey
        xorText.append(contentsOf: Self.xor(tmp, Self.gKeyL))

        // 5. RSA PKCS1v15 加密
        var error: Unmanaged<CFError>?
        guard let cipherData = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            Data(xorText) as CFData,
            &error
        ) as Data? else {
            print("[M115] 加密失败: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            throw M115Error.encryptionFailed
        }

        // 6. Base64
        return cipherData.base64EncodedString()
    }

    // MARK: - 解密

    /// 解密密文（对应 Go: RsaCipher.Decrypt）
    ///
    /// 流程:
    /// 1. Base64 解码
    /// 2. 对每个 128 字节块做原始 RSA: m = n^e mod N
    /// 3. 去除 PKCS1 填充（找 0x00 分隔符）
    /// 4. 提取 randKey（前 16 字节）
    /// 5. keyL = genKey(randKey, 12)
    /// 6. tmp = xor(data, keyL)
    /// 7. 反转 tmp
    /// 8. result = xor(tmp, keyS)  ← 复用 encrypt 时生成的 keyS
    func decrypt(_ cipherTextBase64: String) throws -> [UInt8] {
        // 1. Base64 解码
        guard let cipherData = Data(base64Encoded: cipherTextBase64) else {
            throw M115Error.decryptionFailed
        }
        let text = [UInt8](cipherData)
        let blockCount = text.count / Self.rsaBlockSize

        print("[M115] 解密: \(text.count) 字节, \(blockCount) 块")

        // 2. 逐块原始 RSA 解密
        var plainText: [UInt8] = []
        for i in 0..<blockCount {
            let block = Array(text[i * Self.rsaBlockSize..<(i + 1) * Self.rsaBlockSize])
            let n = RSABigInt(bigEndianBytes: block)
            let m = n.powMod(exponentE, modulusN)
            let mBytes = m.bigEndianBytes()

            // 3. 查找 0x00 分隔符（PKCS1 v1.5: 0x00 0x02 ... 0x00 message）
            guard let sepIndex = mBytes.firstIndex(of: 0x00) else {
                print("[M115] 块 \(i): 未找到 0x00 分隔符, bytes=\(mBytes.prefix(16).map { String(format: "%02x", $0) }.joined())")
                throw M115Error.decryptionFailed
            }
            plainText.append(contentsOf: mBytes[(sepIndex + 1)...])
        }

        // 4. 提取 randKey
        guard plainText.count >= Self.rsaKeySize else {
            throw M115Error.decryptionFailed
        }
        let extractedRandKey = Array(plainText[0..<Self.rsaKeySize])
        plainText = Array(plainText[Self.rsaKeySize...])

        // 5. 生成 keyL 并 XOR
        let keyL = Self.genKey(extractedRandKey, 12)
        var tmp = Self.xor(plainText, keyL)

        // 6. 反转
        tmp.reverse()

        // 7. XOR with keyS（复用 encrypt 时生成的）
        let result = Self.xor(tmp, keyS)

        return result
    }

    // MARK: - 辅助函数（与 Go 源码逐行对齐）

    /// 生成派生密钥（对应 Go: genKey）
    ///
    /// - Parameters:
    ///   - randKey: 随机密钥
    ///   - keyLen: 输出密钥长度（加密=4, 解密=12）
    private static func genKey(_ randKey: [UInt8], _ keyLen: Int) -> [UInt8] {
        var xorKey: [UInt8] = []
        var length = keyLen * (keyLen - 1)
        var index = 0

        for i in 0..<keyLen {
            // Go: x = byte(uint8(randKey[i]) + uint8(gKts[index]))
            let x = randKey[i] &+ gKts[index]
            // Go: xorKey = append(xorKey, gKts[length]^x)
            xorKey.append(gKts[length] ^ x)
            length -= keyLen
            index += keyLen
        }
        return xorKey
    }

    /// XOR 操作（对应 Go: xor）
    ///
    /// 特殊处理: 先处理 src 长度 % 4 的余数部分，再循环 key
    private static func xor(_ src: [UInt8], _ key: [UInt8]) -> [UInt8] {
        var secret: [UInt8] = []
        let pad = src.count % 4

        // 处理头部余数
        if pad > 0 {
            for i in 0..<pad {
                secret.append(src[i] ^ key[i])
            }
        }

        // 处理剩余部分（循环 key）
        let remaining = Array(src[pad...])
        let keyLen = key.count
        var num = 0

        for s in remaining {
            if num >= keyLen {
                num = num % keyLen
            }
            secret.append(s ^ key[num])
            num += 1
        }

        return secret
    }

    /// 解析 RSA 公钥 ASN.1，提取模数 N 和指数 E
    private static func parseRSAPublicKey(_ data: Data) throws -> (RSABigInt, UInt32) {
        var offset = 0

        func readByte() -> UInt8? {
            guard offset < data.count else { return nil }
            let b = data[offset]; offset += 1; return b
        }

        func readLength() -> Int? {
            guard let first = readByte() else { return nil }
            if first < 0x80 { return Int(first) }
            let numBytes = Int(first & 0x7F)
            var length = 0
            for _ in 0..<numBytes {
                guard let b = readByte() else { return nil }
                length = (length << 8) | Int(b)
            }
            return length
        }

        func readInteger() -> [UInt8]? {
            guard readByte() == 0x02 else { return nil }  // INTEGER tag
            guard let length = readLength() else { return nil }
            guard offset + length <= data.count else { return nil }
            let bytes = Array(data[offset..<(offset + length)])
            offset += length
            // 去除 ASN.1 正数前导 0x00
            var stripped = bytes
            while stripped.count > 1 && stripped[0] == 0 { stripped.removeFirst() }
            return stripped
        }

        // SEQUENCE
        guard readByte() == 0x30 else { throw M115Error.invalidKey }
        _ = readLength()

        // INTEGER (modulus N)
        guard let nBytes = readInteger() else { throw M115Error.invalidKey }
        let n = RSABigInt(bigEndianBytes: nBytes)

        // INTEGER (exponent E)
        guard let eBytes = readInteger() else { throw M115Error.invalidKey }
        var e: UInt32 = 0
        for b in eBytes { e = (e << 8) | UInt32(b) }

        return (n, e)
    }
}

// MARK: - RSABigInt（简易大整数，用于原始 RSA 运算）

/// 1024-bit 大整数，用于 RSA 解密时的原始模幂运算 (n^e mod N)
///
/// Security framework 的 SecKeyCreateDecryptedData 不支持原始 RSA
/// （115 服务端用私钥"签名"响应，客户端用公钥做 n^e mod N "验签"），
/// 因此需要自行实现模幂运算。
///
/// 使用 [UInt32] 小端序字表示，乘法用 UInt64 中间结果。
struct RSABigInt {
    var words: [UInt32]

    init(words: [UInt32]) {
        self.words = words
        normalize()
    }

    init(bigEndianBytes: [UInt8]) {
        var bytes = bigEndianBytes
        while bytes.count % 4 != 0 { bytes.insert(0, at: 0) }
        var result: [UInt32] = []
        let count = bytes.count
        var i = count - 4
        while i >= 0 {
            let b0 = UInt32(bytes[i])
            let b1 = UInt32(bytes[i + 1])
            let b2 = UInt32(bytes[i + 2])
            let b3 = UInt32(bytes[i + 3])
            let word = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            result.append(word)
            i -= 4
        }
        words = result
        normalize()
    }

    func bigEndianBytes() -> [UInt8] {
        var result: [UInt8] = []
        for word in words.reversed() {
            result.append(UInt8(word >> 24))
            result.append(UInt8(word >> 16))
            result.append(UInt8(word >> 8))
            result.append(UInt8(word))
        }
        while result.count > 1 && result[0] == 0 { result.removeFirst() }
        return result
    }

    private mutating func normalize() {
        while words.count > 1 && words.last == 0 { words.removeLast() }
    }

    // MARK: - 比较

    func compare(_ other: RSABigInt) -> Int {
        let maxLen = max(words.count, other.words.count)
        for i in (0..<maxLen).reversed() {
            let a = i < words.count ? words[i] : UInt32(0)
            let b = i < other.words.count ? other.words[i] : UInt32(0)
            if a < b { return -1 }
            if a > b { return 1 }
        }
        return 0
    }

    // MARK: - 减法（假设 self >= other）

    func subtracting(_ other: RSABigInt) -> RSABigInt {
        var result = words
        var borrow: UInt32 = 0
        for i in 0..<max(result.count, other.words.count) {
            let a = i < result.count ? result[i] : UInt32(0)
            let b = i < other.words.count ? other.words[i] : UInt32(0)
            let (diff, overflow1) = a.subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff.subtractingReportingOverflow(borrow)
            if i < result.count {
                result[i] = diff2
            } else {
                result.append(diff2)
            }
            let b1: UInt32 = overflow1 ? 1 : 0
            let b2: UInt32 = overflow2 ? 1 : 0
            borrow = b1 + b2
        }
        return RSABigInt(words: result)
    }

    // MARK: - 乘法（Schoolbook）

    func multiply(_ other: RSABigInt) -> RSABigInt {
        let aLen = words.count
        let bLen = other.words.count
        var result = [UInt32](repeating: 0, count: aLen + bLen)

        for i in 0..<aLen {
            var carry: UInt64 = 0
            let ai = UInt64(words[i])
            for j in 0..<bLen {
                let bj = UInt64(other.words[j])
                let prod = ai * bj
                let cur = UInt64(result[i + j])
                let sum = prod &+ cur &+ carry
                result[i + j] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
            }
            // 传播进位
            var k = i + bLen
            while carry > 0 && k < result.count {
                let s = UInt64(result[k]) &+ carry
                result[k] = UInt32(s & 0xFFFF_FFFF)
                carry = s >> 32
                k += 1
            }
        }
        return RSABigInt(words: result)
    }

    // MARK: - 取模（逐位长除法）

    func mod(_ modulus: RSABigInt) -> RSABigInt {
        var remainder = RSABigInt(words: [0])
        let totalBits = bitCount()

        for i in (0..<totalBits).reversed() {
            // remainder 左移 1 位
            remainder = remainder.shiftedLeftBy1()

            // 设置最低位为 self 的当前位
            if bit(at: i) {
                if remainder.words.isEmpty {
                    remainder.words = [1]
                } else {
                    remainder.words[0] |= 1
                }
            }

            // 如果 remainder >= modulus，减去 modulus
            if remainder.compare(modulus) >= 0 {
                remainder = remainder.subtracting(modulus)
            }
        }
        return remainder
    }

    /// 模幂运算: self^exp mod modulus（平方乘法）
    func powMod(_ exp: UInt32, _ modulus: RSABigInt) -> RSABigInt {
        var result = RSABigInt(words: [1])
        var base = self.mod(modulus)
        var e = exp

        while e > 0 {
            if e & 1 == 1 {
                result = result.multiply(base).mod(modulus)
            }
            base = base.multiply(base).mod(modulus)
            e >>= 1
        }
        return result
    }

    // MARK: - 位操作

    /// 左移 1 位
    func shiftedLeftBy1() -> RSABigInt {
        var result = words
        var carry: UInt32 = 0
        for i in 0..<result.count {
            let newCarry = result[i] >> 31
            result[i] = (result[i] << 1) | carry
            carry = newCarry
        }
        if carry > 0 { result.append(carry) }
        return RSABigInt(words: result)
    }

    /// 获取指定位（0 = 最低位）
    func bit(at position: Int) -> Bool {
        let wordIdx = position / 32
        let bitIdx = position % 32
        guard wordIdx < words.count else { return false }
        return (words[wordIdx] >> bitIdx) & 1 == 1
    }

    /// 总位数
    func bitCount() -> Int {
        guard let lastWord = words.last, lastWord != 0 else { return 0 }
        return (words.count - 1) * 32 + (32 - lastWord.leadingZeroBitCount)
    }
}

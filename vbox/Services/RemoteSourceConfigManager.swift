import Foundation
import Combine
import CryptoKit

// MARK: - 远程默认源管理器

enum RemoteSourceConfigKeys {
    static let remoteDefaultSourceEnabled = "remote_default_source_enabled"
    static let bundleSourcesEnabled = "bundle_sources_enabled"
    static let defaultManifestURL = "remote_default_manifest_url"
    static let lastConfigVersion = "remote_default_last_config_version"
    static let lastSyncTime = "remote_default_last_sync_time"
    static let lastSyncError = "remote_default_last_sync_error"
    static let lastSyncAppVersion = "remote_default_last_sync_app_version"
    static let nodeBundleURL = "remote_node_bundle_url"
    static let nodeBundleVer = "remote_node_bundle_ver"
}

/// 远程默认源管理器
///
/// 负责从公开仓库读取 manifest.json 和 all_sources.json（CI 自动合并 6 个源文件），缓存到 Documents。
/// 启动时通过 manifest.version（约 30 字节）探测版本变化，有更新则自动拉取最新配置。
/// GitHub 域名自动走代理加速（ghfast.top → gh-proxy.com → 直连）。
@MainActor
final class RemoteSourceConfigManager: ObservableObject {
    static let shared = RemoteSourceConfigManager()

    enum LoadState: Equatable {
        case idle
        case loading
        case loadedRemote(version: String)
        case loadedCache(version: String)
        case failed(message: String)

        var displayText: String {
            switch self {
            case .idle:
                return "未同步"
            case .loading:
                return "同步中"
            case .loadedRemote(let version):
                return "远程配置 \(version)"
            case .loadedCache(let version):
                return "缓存配置 \(version)"
            case .failed(let message):
                return "失败：\(message)"
            }
        }
    }

    /// 内置远程默认源地址：全新安装 / 版本升级后，
    /// 「设置 → 启用远程默认源 → 默认源地址」默认填入该 manifest 地址，
    /// 用户仍可在设置里手动修改。
    static let defaultManifestURL = "https://vbox-ai.github.io/api/sources/manifest.json"

    @Published var remoteDefaultSourceEnabled: Bool {
        didSet { UserDefaults.standard.set(remoteDefaultSourceEnabled, forKey: RemoteSourceConfigKeys.remoteDefaultSourceEnabled) }
    }

    @Published var bundleSourcesEnabled: Bool {
        didSet { UserDefaults.standard.set(bundleSourcesEnabled, forKey: RemoteSourceConfigKeys.bundleSourcesEnabled) }
    }

    @Published var defaultManifestURL: String {
        didSet { UserDefaults.standard.set(defaultManifestURL, forKey: RemoteSourceConfigKeys.defaultManifestURL) }
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var lastConfigVersion: String
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastSyncError: String?

    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// 代理列表：复用 UpdateManager 的 GitHub 加速代理（主代理 → 备用代理 → 直连）
    private static let proxyHosts: [(name: String, host: String)] = [
        ("ghfast",    "https://ghfast.top"),
        ("gh-proxy",  "https://gh-proxy.com"),
    ]

    private init() {
        remoteDefaultSourceEnabled = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.remoteDefaultSourceEnabled) as? Bool ?? true
        bundleSourcesEnabled = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.bundleSourcesEnabled) as? Bool ?? false
        defaultManifestURL = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.defaultManifestURL) ?? Self.defaultManifestURL
        lastConfigVersion = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.lastConfigVersion) ?? ""
        lastSyncTime = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.lastSyncTime) as? Date
        lastSyncError = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.lastSyncError)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    // MARK: - Public

    func syncIfNeeded(force: Bool = false) async {
        guard remoteDefaultSourceEnabled else {
            loadCachedManifestState()
            print("[RemoteSource] 远程默认源已关闭，跳过同步")
            return
        }

        // 地址留空 → 按"关闭同步"处理：只加载已有缓存，不再发起必然失败的联网请求。
        // 消除每次启动一次无效网络同步造成的就绪不定时（偶发的"只有网盘/源不齐"）。
        if defaultManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadCachedManifestState()
            print("[RemoteSource] 远程源地址留空，跳过网络同步，仅使用缓存")
            return
        }

        // 方案四：App 升级后强制刷新
        if appVersionChanged() {
            print("[RemoteSource] App 版本变化，强制刷新")
            await syncNow()
            return
        }

        if force {
            await syncNow()
            return
        }

        // 从未同步过 → 必须刷新
        guard let _ = lastSyncTime else {
            await syncNow()
            return
        }

        // 方案一：轻量版本号探测（约 30 字节）
        if let newVersion = await checkManifestVersion() {
            if newVersion != lastConfigVersion {
                print("[RemoteSource] manifest.version 变化: \(lastConfigVersion) → \(newVersion)，触发同步")
                await syncNow()
                return
            }
            // 版本一致，跳过同步
            loadCachedManifestState()
            return
        }

        // manifest.version 请求失败 → 降级到旧 TTL 判断
        if shouldRefresh() {
            await syncNow()
        } else {
            loadCachedManifestState()
        }
    }

    func syncNow() async {
        guard remoteDefaultSourceEnabled else {
            loadCachedManifestState()
            return
        }

        // 地址留空 → 直接使用缓存，不发起必然失败的网络同步
        if defaultManifestURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loadCachedManifestState()
            print("[RemoteSource] 远程源地址留空，syncNow 跳过网络同步，仅使用缓存")
            return
        }

        loadState = .loading

        do {
            // 1. 拉取 manifest
            let manifestData = try await fetchManifestData()
            let manifest = try decoder.decode(RemoteSourceManifest.self, from: manifestData)
            try validate(manifest: manifest)

            // 2. 下载 all_sources.json（CI 自动合并的 6 合 1 文件）
            guard let allSourcesURL = URL(string: manifest.files.allSources) else {
                throw RemoteSourceError.invalidURL(manifest.files.allSources)
            }
            let allSourcesData = try await fetchData(from: allSourcesURL)
            let allSources = try decoder.decode(AllSourcesContainer.self, from: allSourcesData)

            // 3. 写入缓存
            try ensureCacheDirectory()
            try manifestData.write(to: url(for: .manifest), options: .atomic)
            try allSourcesData.write(to: url(for: .allSources), options: .atomic)

            // 4. 下载并缓存 JS 蜘蛛引擎文件
            let spiderSites = allSources.spiderSources?.sites ?? []
            if !spiderSites.isEmpty, let baseURL = URL(string: manifest.files.allSources)?.deletingLastPathComponent().absoluteString {
                await downloadAndCacheSpiderJS(baseURL: baseURL, sites: spiderSites)
            }

            // 4b. 下载并缓存 lx-music 桥接插件（远程上架，P1-A6）
            //     命中 engineType == "lxMusic" 的站点，按其 pluginPath（相对仓库 sources 目录，
            //     与 allSources 同目录；如 lx/daxe.js）下载插件 JS 到 Node lx 插件目录，
            //     并做 md5 完整性校验 + version 版本标记。
            //     失败不阻塞整个同步：lx 不可用由 LXBridgeEngine 温和降级，不影响视频/远程源。
            let allSourcesBase = URL(string: manifest.files.allSources)?.deletingLastPathComponent().absoluteString ?? ""
            await downloadAndCacheLXPlugins(sites: spiderSites, baseURL: allSourcesBase)

            // 缓存 Node bundle 远端地址（供启动时 NodeRuntimeManager 自动拉取）
            if let bundleURL = manifest.files.nodeRuntimeBundle, !bundleURL.isEmpty {
                UserDefaults.standard.set(bundleURL, forKey: RemoteSourceConfigKeys.nodeBundleURL)
            } else {
                UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.nodeBundleURL)
            }
            if let bundleVer = manifest.files.nodeRuntimeBundleVer, !bundleVer.isEmpty {
                UserDefaults.standard.set(bundleVer, forKey: RemoteSourceConfigKeys.nodeBundleVer)
            } else {
                UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.nodeBundleVer)
            }

            updateSuccess(version: manifest.configVersion)
            print("[RemoteSource] 同步完成 version=\(manifest.configVersion)")
        } catch {
            updateFailure(error.localizedDescription)
            loadCachedManifestState()
            print("[RemoteSource] 同步失败: \(error.localizedDescription)")
        }
    }

    /// 请求 manifest.version（约 30 字节）探测是否有新版本
    private func checkManifestVersion() async -> String? {
        // 从 manifest URL 推导 version 文件 URL
        let versionURL: String
        if defaultManifestURL.hasSuffix("/manifest.json") {
            versionURL = defaultManifestURL.replacingOccurrences(of: "/manifest.json", with: "/manifest.version")
        } else {
            versionURL = defaultManifestURL + ".version"
        }

        guard let url = URL(string: versionURL) else { return nil }

        do {
            let data = try await fetchData(from: url)
            let versionInfo = try decoder.decode(ManifestVersionInfo.self, from: data)
            print("[RemoteSource] manifest.version 探测成功: \(versionInfo.configVersion)")
            return versionInfo.configVersion
        } catch {
            print("[RemoteSource] manifest.version 请求失败: \(error.localizedDescription)，降级到 TTL 判断")
            return nil
        }
    }

    private func appVersionChanged() -> Bool {
        let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastAppVersion = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.lastSyncAppVersion) ?? ""
        return currentAppVersion != lastAppVersion
    }

    private func fetchManifestData() async throws -> Data {
        guard let manifestURL = URL(string: defaultManifestURL) else {
            throw RemoteSourceError.invalidURL(defaultManifestURL)
        }
        print("[RemoteSource] 开始同步 manifest: \(defaultManifestURL)")
        return try await fetchData(from: manifestURL)
    }

    func clearCache() {
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            lastConfigVersion = ""
            lastSyncTime = nil
            lastSyncError = nil
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastConfigVersion)
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncTime)
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncError)
            UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncAppVersion)
            loadState = .idle
            print("[RemoteSource] 已清除远程源缓存")
        } catch {
            updateFailure("清除缓存失败：\(error.localizedDescription)")
        }
    }

    /// 刷新 loadState 以反映当前缓存实际状态（供外部调用，如清缓存后）
    func refreshLoadState() {
        loadCachedManifestState()
    }

    /// 探测远程源最新配置版本（供备份还原判断备份缓存是否过期）
    /// 返回 nil 表示探测失败（无网络等），由调用方决定降级策略
    func probeLatestConfigVersion() async -> String? {
        await checkManifestVersion()
    }

    // MARK: - 缓存读取（全部从 all_sources.json 读取）

    private func cachedAllSources() -> AllSourcesContainer? {
        decodeCached(AllSourcesContainer.self, from: .allSources)
    }

    func cachedAPIConfig() -> SubscribeConfig? {
        guard let allSources = cachedAllSources(),
              let apiSources = allSources.apiSources else { return nil }
        // 从 allSources.apiSources 重建 SubscribeConfig
        let jsonData = try? encoder.encode(apiSources)
        return jsonData.flatMap { try? decoder.decode(SubscribeConfig.self, from: $0) }
    }

    func cachedAPISites() -> [SiteConfig] {
        cachedAPIConfig()?.sites ?? []
    }

    func cachedCloudSitesData() -> Data? {
        guard let allSources = cachedAllSources(),
              let cloudSources = allSources.cloudSources else { return nil }
        return try? encoder.encode(cloudSources)
    }

    /// 供非 MainActor 上下文读取用户可配置的默认 manifest URL。
    /// 与 shared.defaultManifestURL 共用同一个 UserDefaults 键，保证与 @Published 值一致。
    /// 用户未配置时回退到内置默认地址（RemoteSourceConfigManager.defaultManifestURL）。
    /// 读取缓存的 Node bundle 远端地址（供 NodeRuntimeManager 启动时自动拉取）。
    /// 未配置远程源或 manifest 未下发该字段时返回 nil，NodeRuntimeManager 按原逻辑回退本地资源。
    nonisolated static func cachedNodeBundleRefreshURL() -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.nodeBundleURL),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: stored.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }

    /// 读取缓存的 Node bundle 版本文件远端地址（版本探针用，NodeRuntimeManager 比对后决定是否下载）
    nonisolated static func cachedNodeBundleVersionURL() -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.nodeBundleVer),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: stored.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return url
    }

    nonisolated static func currentDefaultManifestURL() -> String {
        guard let stored = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.defaultManifestURL) else {
            // 从未配置过 → 回退到内置默认地址
            return Self.defaultManifestURL
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func cachedCloudSitesDataForBackground() -> Data? {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let allSourcesURL = docs
            .appendingPathComponent("remote_sources", isDirectory: true)
            .appendingPathComponent("all_sources.json")

        guard fileManager.fileExists(atPath: allSourcesURL.path),
              let allSourcesData = try? Data(contentsOf: allSourcesURL),
              let allSources = try? JSONDecoder().decode(AllSourcesContainer.self, from: allSourcesData),
              let cloudSources = allSources.cloudSources else { return nil }

        return try? JSONEncoder().encode(cloudSources)
    }

    func cachedParsers() -> [ParseConfig] {
        guard let allSources = cachedAllSources(),
              let parsers = allSources.parsers else { return [] }
        let jsonData = try? encoder.encode(parsers)
        guard let data = jsonData,
              let wrapper = try? decoder.decode(ParserWrapper.self, from: data) else { return [] }
        return wrapper.parses
    }

    func cachedSpiderConfig() -> SubscribeConfig? {
        guard let allSources = cachedAllSources(),
              let spiderSources = allSources.spiderSources else { return nil }
        let jsonData = try? encoder.encode(spiderSources)
        return jsonData.flatMap { try? decoder.decode(SubscribeConfig.self, from: $0) }
    }

    func cachedSpiderSites() -> [SiteConfig] {
        // 直接从 all_sources.json 的 spiderSources.sites 读取，避免 encode→decode 二次转换
        // 可能失败导致返回空（表现为 JS 蜘蛛引擎一个都不加载、切换源里 JS 源缺失）。
        // sites 本身就是 [SiteConfig]（可选），与缓存 API 源同源，无需经 SubscribeConfig 重建。
        guard let allSources = cachedAllSources() else { return [] }
        return allSources.spiderSources?.sites ?? []
    }

    func cachedDisabledHosts() -> [String] {
        guard let allSources = cachedAllSources(),
              let disabledSources = allSources.disabledSources else { return [] }
        let jsonData = try? encoder.encode(disabledSources)
        guard let data = jsonData,
              let wrapper = try? decoder.decode(DisabledSourcesWrapper.self, from: data) else { return [] }
        return wrapper.disabledHosts ?? []
    }

    func cachedDisabledKeys() -> [String] {
        guard let allSources = cachedAllSources(),
              let disabledSources = allSources.disabledSources else { return [] }
        let jsonData = try? encoder.encode(disabledSources)
        guard let data = jsonData,
              let wrapper = try? decoder.decode(DisabledSourcesWrapper.self, from: data) else { return [] }
        return wrapper.disabledKeys ?? []
    }

    func cachedDomainOverrides() -> [DomainOverride] {
        guard let allSources = cachedAllSources(),
              let domainOverrides = allSources.domainOverrides else { return [] }
        let jsonData = try? encoder.encode(domainOverrides)
        guard let data = jsonData,
              let wrapper = try? decoder.decode(DomainOverridesWrapper.self, from: data) else { return [] }
        return wrapper.overrides ?? []
    }

    /// 检查某个 host 是否在禁用列表中
    func isHostDisabled(_ host: String) -> Bool {
        let hosts = cachedDisabledHosts()
        if hosts.contains(host) { return true }
        // 忽略 scheme 差异做 host 匹配（http vs https）
        guard let hostURL = URL(string: host),
              let hostName = hostURL.host else { return false }
        return hosts.contains { disabled in
            guard let disabledURL = URL(string: disabled) else { return false }
            return disabledURL.host == hostName && (disabledURL.port ?? (disabledURL.scheme == "https" ? 443 : 80)) == (hostURL.port ?? (hostURL.scheme == "https" ? 443 : 80))
        }
    }

    /// 对 URL 字符串应用域名覆盖
    func applyDomainOverrides(to urlString: String) -> String {
        let overrides = cachedDomainOverrides()
        guard !overrides.isEmpty else { return urlString }
        var result = urlString
        for override in overrides {
            guard let from = override.from, let to = override.to, !from.isEmpty, !to.isEmpty else { continue }
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    // MARK: - Paths

    private enum CacheFile: String {
        case manifest = "manifest.json"
        case allSources = "all_sources.json"
    }

    private var cacheDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("remote_sources", isDirectory: true)
    }

    /// JS 蜘蛛引擎缓存目录
    var jsCacheDirectory: URL {
        cacheDirectory.appendingPathComponent("js_cache", isDirectory: true)
    }

    private func url(for file: CacheFile) -> URL {
        cacheDirectory.appendingPathComponent(file.rawValue)
    }

    private func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: jsCacheDirectory.path) {
            try fileManager.createDirectory(at: jsCacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - JS 蜘蛛引擎缓存

    /// 下载并缓存所有 JS 蜘蛛引擎文件
    private func downloadAndCacheSpiderJS(baseURL: String, sites: [SiteConfig]) async {
        print("[RemoteSource] 开始缓存 JS 蜘蛛引擎，站点数: \(sites.count)")

        // 收集需要下载的 URL
        var urlsToDownload: [(key: String, url: String, isExt: Bool)] = []

        for site in sites {
            guard let api = site.api, !api.isEmpty else { continue }
            let key = site.key.isEmpty ? site.name : site.key

            // S2-2：Node 托管蜘蛛跳过 JS 缓存下载（api 指向本地 Node 路由，GET 无意义）
            if isNodeManagedSite(site) {
                print("[RemoteSource] ⏭️ Node 托管蜘蛛跳过缓存: \(site.name) (\(key))")
                continue
            }

            // 解析 JS 文件 URL
            let resolvedURL: String
            if api.hasPrefix("./") || (!api.hasPrefix("http://") && !api.hasPrefix("https://") && api.hasSuffix(".js")) {
                let cleanPath = api.hasPrefix("./") ? String(api.dropFirst(2)) : api
                if let base = URL(string: baseURL) {
                    resolvedURL = base.appendingPathComponent(cleanPath).standardized.absoluteString
                } else {
                    continue
                }
            } else if api.hasPrefix("http://") || api.hasPrefix("https://") {
                resolvedURL = api
            } else {
                continue
            }
            urlsToDownload.append((key: key, url: resolvedURL, isExt: false))

            // 如果 ext 是 URL，也缓存
            if let ext = site.ext, !ext.isEmpty {
                let extTrimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
                if extTrimmed.hasPrefix("http://") || extTrimmed.hasPrefix("https://") {
                    urlsToDownload.append((key: "\(key)_ext", url: extTrimmed, isExt: true))
                } else if extTrimmed.hasPrefix("./") || extTrimmed.hasSuffix(".js") {
                    let cleanExtPath = extTrimmed.hasPrefix("./") ? String(extTrimmed.dropFirst(2)) : extTrimmed
                    if let base = URL(string: baseURL) {
                        let extFullURL = base.appendingPathComponent(cleanExtPath).standardized.absoluteString
                        urlsToDownload.append((key: "\(key)_ext", url: extFullURL, isExt: true))
                    }
                }
            }
        }

        guard !urlsToDownload.isEmpty else {
            print("[RemoteSource] 没有需要缓存的 JS 蜘蛛引擎")
            // 清理所有旧缓存（配置中已没有 JS 蜘蛛站点）
            cleanupExpiredJSCache(validKeys: [])
            return
        }

        // 记录当前缓存的文件，用于后续清理过期文件
        var cachedKeys = Set<String>()

        // 使用 TaskGroup 并发下载
        await withTaskGroup(of: (key: String, success: Bool).self) { group in
            for item in urlsToDownload {
                group.addTask {
                    let success = await self.downloadJSFile(key: item.key, urlString: item.url)
                    return (key: item.key, success: success)
                }
            }

            for await result in group {
                if result.success {
                    cachedKeys.insert(result.key)
                }
            }
        }

        // 清理过期缓存（不在当前配置中的文件）
        cleanupExpiredJSCache(validKeys: cachedKeys)

        print("[RemoteSource] JS 蜘蛛引擎缓存完成，有效缓存: \(cachedKeys.count) 个")
    }

    // MARK: - lx-music 桥接插件远程缓存（P1-A6）

    /// 下载并缓存 lx-music 桥接插件到 Node lx 插件目录。
    ///
    /// 识别规则：站点 `engineType == "lxMusic"`（由远程清单下发，见 spider_sources.json），
    /// 按其 `pluginPath`（相对仓库 baseURL，如 sources/lx/daxe.js）下载插件 JS 到
    /// `NodeRuntimeManager.lxPluginsDir`，并以 `md5` 校验完整性、`version` 做版本标记（跳过已同步版本）。
    ///
    /// 约束：失败仅打印日志、不抛错——lx 插件不可用由 LXBridgeEngine.isLXReady 温和降级，
    /// 绝不影响视频 / 网盘 / 远程 kstore 音乐源的主链路。
    private func downloadAndCacheLXPlugins(sites: [SiteConfig], baseURL: String) async {
        let lxSites = sites.filter { $0.engineType == "lxMusic" }
        guard !lxSites.isEmpty else {
            print("[RemoteSource] 无 lx-music 插件站点，跳过插件缓存")
            return
        }

        guard let base = URL(string: baseURL) else { return }

        // Node lx 插件目录（远程下载即远程优先；与 NodeRuntimeManager.prepareRuntimeFiles 兜底配合）
        let pluginsDir = NodeRuntimeManager.shared.lxPluginsDir
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        print("[RemoteSource] 开始缓存 lx-music 插件，站点数: \(lxSites.count)")
        var synced: [String] = []

        await withTaskGroup(of: (String, Bool).self) { group in
            for site in lxSites {
                let key = site.key.isEmpty ? site.name : site.key
                guard let pluginPath = site.pluginPath, !pluginPath.isEmpty else { continue }
                group.addTask {
                    let ok = await self.syncLXPlugin(key: key,
                                                      site: site,
                                                      pluginPath: pluginPath,
                                                      base: base,
                                                      dir: pluginsDir)
                    return (key, ok)
                }
            }
            for await (key, ok) in group {
                if ok { synced.append(key) }
            }
        }

        print("[RemoteSource] lx 插件缓存完成，同步: \(synced.isEmpty ? "无" : synced.joined(separator: ", "))")
    }

    /// 同步单个 lx 插件：版本标记一致则跳过；否则下载 → md5 校验 → 原子写入 + 写版本标记。
    private func syncLXPlugin(key: String, site: SiteConfig,
                              pluginPath: String, base: URL, dir: URL) async -> Bool {
        // 文件名取 pluginPath 末段（daxe.js / nianxin.js，对应 lx-bridge 的插件 key）
        let fileName = URL(string: pluginPath)?.lastPathComponent
            ?? (pluginPath as NSString).lastPathComponent
        guard fileName.hasSuffix(".js") else {
            print("[RemoteSource] ⚠️ lx 插件路径异常，跳过: \(pluginPath)")
            return false
        }
        let destURL = dir.appendingPathComponent(fileName)
        let versionURL = dir.appendingPathComponent(fileName + ".version")

        // 版本标记一致 → 已是最新，跳过下载
        if let expected = site.version, !expected.isEmpty,
           let cachedv = try? String(contentsOf: versionURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           cachedv == expected {
            print("[RemoteSource] ⏭️ lx 插件版本一致，跳过: \(fileName) (v\(expected))")
            return true
        }

        // 解析下载 URL：相对 baseURL；若 pluginPath 为绝对 URL 则直接使用
        let remoteURL: URL?
        if pluginPath.hasPrefix("http://") || pluginPath.hasPrefix("https://") {
            remoteURL = URL(string: pluginPath)
        } else {
            let clean = pluginPath.hasPrefix("./") ? String(pluginPath.dropFirst(2)) : pluginPath
            remoteURL = base.appendingPathComponent(clean).standardized
        }
        guard let url = remoteURL else { return false }

        do {
            let data = try await fetchData(from: url)
            guard data.count > 100 else {
                print("[RemoteSource] ⚠️ lx 插件内容过短，丢弃: \(fileName)")
                return false
            }
            // md5 完整性校验（清单下发则强校验；未下发不强校验）
            let actualMD5 = Data(Insecure.MD5.hash(data: data)).map { String(format: "%02x", $0) }.joined()
            if let expect = site.md5, !expect.isEmpty,
               actualMD5.lowercased() != expect.lowercased() {
                print("[RemoteSource] ❌ lx 插件 md5 不匹配，丢弃: \(fileName) 期望=\(expect) 实际=\(actualMD5)")
                return false
            }
            try fm_createParentIfNeeded(destURL)
            try data.write(to: destURL, options: .atomic)
            if let v = site.version, !v.isEmpty {
                try v.write(to: versionURL, atomically: true, encoding: .utf8)
            }
            print("[RemoteSource] ✅ lx 插件已同步: \(fileName) (\(data.count) 字节\(site.version.map { ", v\($0)" } ?? ""))")
            return true
        } catch {
            print("[RemoteSource] ⚠️ lx 插件下载失败，保留旧版: \(fileName): \(error.localizedDescription)")
            return false
        }
    }

    private func fm_createParentIfNeeded(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Node 托管蜘蛛识别（与 SpiderManager.isNodeSite 同规则，供缓存跳过使用）
    /// - key 前缀 `nodejs_` / `csp_`（type 3）或 group == "node" 或 api 指向本地 Node 路由
    private func isNodeManagedSite(_ site: SiteConfig) -> Bool {
        if site.group == "node" { return true }
        let key = site.key.isEmpty ? site.name : site.key
        if key.hasPrefix("nodejs_") { return true }
        if key.hasPrefix("csp_") && site.type == 3 { return true }
        guard let api = site.api else { return false }
        if api.hasPrefix("nodejs_") { return true }
        if api.hasPrefix("csp_") && site.type == 3 { return true }
        let lower = api.lowercased()
        return lower.contains("://127.0.0.1") && lower.contains("/spider/")
    }

    /// 下载单个 JS 文件到缓存目录
    private func downloadJSFile(key: String, urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let fileURL = jsCacheDirectory.appendingPathComponent("\(key).js")

        do {
            let data = try await fetchData(from: url)
            // 兼容 JS 与 Python 蜘蛛缓存：JS 通常含 function/var/let/const，
            // Python 站点（api 指向 ./js/xxx.py）通常含 def/import/class。
            // 旧实现仅认 JS 关键字，导致含 py 的站点从不进缓存 → 备份缺 py、还原后 py 源不显示。
            guard let jsCode = String(data: data, encoding: .utf8),
                  jsCode.count > 50,
                  (jsCode.contains("function ") || jsCode.contains("var ") || jsCode.contains("let ") || jsCode.contains("const ")
                   || jsCode.contains("def ") || jsCode.contains("import ") || jsCode.contains("class Spider")) else {
                print("[RemoteSource] ⚠️ JS 文件内容无效: \(key)")
                return false
            }
            try data.write(to: fileURL, options: .atomic)
            print("[RemoteSource] ✅ JS 缓存成功: \(key) (\(data.count) bytes)")
            return true
        } catch {
            print("[RemoteSource] ❌ JS 缓存失败: \(key) - \(error.localizedDescription)")
            return false
        }
    }

    /// 获取缓存的 JS 文件路径（如果存在）
    func cachedSpiderJSPath(forKey key: String) -> URL? {
        let fileURL = jsCacheDirectory.appendingPathComponent("\(key).js")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    /// 读取缓存的 JS 文件内容
    func cachedSpiderJSContent(forKey key: String) -> String? {
        guard let fileURL = cachedSpiderJSPath(forKey: key),
              let data = try? Data(contentsOf: fileURL),
              let jsCode = String(data: data, encoding: .utf8),
              jsCode.count > 50 else { return nil }
        return jsCode
    }

    /// 清理过期的 JS 缓存文件
    private func cleanupExpiredJSCache(validKeys: Set<String>) {
        do {
            let files = try fileManager.contentsOfDirectory(at: jsCacheDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "js" {
                let fileName = file.deletingPathExtension().lastPathComponent
                if !validKeys.contains(fileName) {
                    try fileManager.removeItem(at: file)
                    print("[RemoteSource] 🗑️ 清理过期 JS 缓存: \(fileName)")
                }
            }
        } catch {
            print("[RemoteSource] 清理过期 JS 缓存失败: \(error.localizedDescription)")
        }
    }

    // MARK: - IO（带代理加速）

    /// GitHub 域名白名单：只对 GitHub 域名走代理
    private func isGitHubDomain(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "raw.githubusercontent.com" || host.hasSuffix(".github.io") || host == "github.com"
    }

    /// 构造代理 URL 列表：[主代理, 备用代理, 直连]
    private func buildProxyURLs(for url: URL) -> [URL] {
        guard isGitHubDomain(url) else { return [url] }
        var urls: [URL] = []
        let urlString = url.absoluteString
        for (_, host) in Self.proxyHosts {
            if let proxyURL = URL(string: "\(host)/\(urlString)") {
                urls.append(proxyURL)
            }
        }
        urls.append(url) // 直连兜底
        return urls
    }

    /// 带代理降级的数据请求
    private func fetchData(from url: URL) async throws -> Data {
        let urls = buildProxyURLs(for: url)

        for (idx, fetchURL) in urls.enumerated() {
            let label = idx < urls.count - 1 ? "代理" : "直连"
            do {
                var request = URLRequest(url: fetchURL)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw RemoteSourceError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
                }
                return data
            } catch {
                print("[RemoteSource] \(label) 请求失败 (\(fetchURL.host ?? "")): \(error.localizedDescription)")
                if idx == urls.count - 1 { throw error }
            }
        }
        throw RemoteSourceError.httpError(-1)
    }

    // MARK: - State

    private func shouldRefresh() -> Bool {
        guard let lastSyncTime else { return true }
        guard let manifest = decodeCached(RemoteSourceManifest.self, from: .manifest) else { return true }
        let ttl = TimeInterval(manifest.ttlSeconds ?? 21600)
        return Date().timeIntervalSince(lastSyncTime) >= ttl || manifest.forceRefresh == true
    }

    private func loadCachedManifestState() {
        if let manifest = decodeCached(RemoteSourceManifest.self, from: .manifest) {
            loadState = .loadedCache(version: manifest.configVersion)
            lastConfigVersion = manifest.configVersion
        } else if let lastSyncError {
            loadState = .failed(message: lastSyncError)
        } else {
            loadState = .idle
        }
    }

    private func updateSuccess(version: String) {
        lastConfigVersion = version
        lastSyncTime = Date()
        lastSyncError = nil
        let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        UserDefaults.standard.set(version, forKey: RemoteSourceConfigKeys.lastConfigVersion)
        UserDefaults.standard.set(lastSyncTime, forKey: RemoteSourceConfigKeys.lastSyncTime)
        UserDefaults.standard.set(currentAppVersion, forKey: RemoteSourceConfigKeys.lastSyncAppVersion)
        UserDefaults.standard.removeObject(forKey: RemoteSourceConfigKeys.lastSyncError)
        loadState = .loadedRemote(version: version)
    }

    private func updateFailure(_ message: String) {
        lastSyncError = message
        loadState = .failed(message: message)
        UserDefaults.standard.set(message, forKey: RemoteSourceConfigKeys.lastSyncError)
    }

    // MARK: - Validation

    private func validate(manifest: RemoteSourceManifest) throws {
        guard manifest.schemaVersion >= 1 else {
            throw RemoteSourceError.invalidManifest("schemaVersion 必须 >= 1")
        }
        guard !manifest.configVersion.isEmpty else {
            throw RemoteSourceError.invalidManifest("configVersion 不能为空")
        }
    }

    private func decodeCached<T: Decodable>(_ type: T.Type, from file: CacheFile) -> T? {
        let fileURL = url(for: file)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            print("[RemoteSource] 缓存 \(file.rawValue) 解码失败: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Codable Models

private struct RemoteSourceManifest: Codable {
    let schemaVersion: Int
    let configVersion: String
    let minAppVersion: String?
    let updatedAt: String?
    let ttlSeconds: Int?
    let files: RemoteSourceFiles
    let disabledKeys: [String]?
    let forceRefresh: Bool?
}

private struct RemoteSourceFiles: Codable {
    let allSources: String
    let nodeRuntimeBundle: String?
    let nodeRuntimeBundleVer: String?
}

/// manifest.version 文件结构（约 30 字节）
private struct ManifestVersionInfo: Codable {
    let configVersion: String
}

/// all_sources.json 合并后的顶层结构（CI 自动从 6 个源文件生成）
private struct AllSourcesContainer: Codable {
    let apiSources: APISourcesData?
    let cloudSources: CloudSourcesData?
    let spiderSources: SpiderSourcesData?
    let domainOverrides: DomainOverridesData?
    let parsers: ParsersData?
    let disabledSources: DisabledSourcesData?

    struct APISourcesData: Codable {
        let spider: String?
        let sites: [SiteConfig]?
        let parses: [ParseConfig]?
    }

    struct CloudSourcesData: Codable {
        let dyname: String?
        let dyzuozhe: String?
        let cloudSites: [SpiderManager.CloudSiteConfig]?
    }

    struct SpiderSourcesData: Codable {
        let spider: String?
        let sites: [SiteConfig]?
    }

    struct DomainOverridesData: Codable {
        let overrides: [DomainOverride]?
    }

    struct ParsersData: Codable {
        let parses: [ParseConfig]?
    }

    struct DisabledSourcesData: Codable {
        let disabledKeys: [String]?
        let disabledHosts: [String]?
    }
}

private struct ParserWrapper: Codable {
    let parses: [ParseConfig]
}

private struct DisabledSourcesWrapper: Codable {
    let disabledKeys: [String]?
    let disabledHosts: [String]?
}

private struct DomainOverridesWrapper: Codable {
    let overrides: [DomainOverride]?
}

struct DomainOverride: Codable {
    let from: String?
    let to: String?
    let description: String?
}

private enum RemoteSourceError: LocalizedError {
    case invalidURL(String)
    case httpError(Int)
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "URL 无效：\(url)"
        case .httpError(let code):
            return "HTTP 状态异常：\(code)"
        case .invalidManifest(let message):
            return "manifest 无效：\(message)"
        }
    }
}

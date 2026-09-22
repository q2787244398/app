import Foundation
import Combine

// MARK: - 远程默认源管理器

enum RemoteSourceConfigKeys {
    static let remoteDefaultSourceEnabled = "remote_default_source_enabled"
    static let bundleSourcesEnabled = "bundle_sources_enabled"
    static let defaultManifestURL = "remote_default_manifest_url"
    static let lastConfigVersion = "remote_default_last_config_version"
    static let lastSyncTime = "remote_default_last_sync_time"
    static let lastSyncError = "remote_default_last_sync_error"
    static let lastSyncAppVersion = "remote_default_last_sync_app_version"
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

    /// 不再内置默认远程源地址。留空即视为未配置（远程源同步不可用），
    /// 用户需自行在设置里填入远程源 manifest 地址后才启用远程 JS/API/云/音乐源。
    static let defaultManifestURL = ""

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
    /// 不内置任何默认地址：未配置或留空均返回空串（视为未启用远程源）。
    nonisolated static func currentDefaultManifestURL() -> String {
        guard let stored = UserDefaults.standard.string(forKey: RemoteSourceConfigKeys.defaultManifestURL) else {
            // 从未配置过，也没有内置默认 → 返回空串
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
            guard let jsCode = String(data: data, encoding: .utf8),
                  jsCode.count > 50,
                  (jsCode.contains("function ") || jsCode.contains("var ") || jsCode.contains("let ") || jsCode.contains("const ")) else {
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

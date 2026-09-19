import Foundation
import SwiftUI

extension Notification.Name {
    static let spiderSitesDidUpdate = Notification.Name("spiderSitesDidUpdate")
    /// Python 蜘蛛引擎初始化完成通知 — 用于触发短剧等页面重新扫描蜘蛛源
    static let pythonSpiderDidBecomeReady = Notification.Name("pythonSpiderDidBecomeReady")
}

/// 站点模式枚举 — 用于区分站点的实际工作模式
enum SiteMode {
    case jsSpider       // JS蜘蛛模式：加载JS脚本到引擎
    case pythonSpider   // Python蜘蛛模式：加载.py脚本到Python引擎
    case apiEndpoint    // API模式：直接HTTP调用CMS接口
    case zhanyuan       // 站源模式：HTML解析
    case node           // Node 托管蜘蛛模式：桥接 127.0.0.1 Node 常驻系统（形态 A''，P2-03）
    case unsupported    // 不支持的类型（jar包等）
}

/// 蜘蛛管理器 — 统一管理订阅源加载、蜘蛛引擎、数据获取
@MainActor
class SpiderManager: ObservableObject {

    static let shared = SpiderManager()

    @Published var categories: [VodCategory] = []
    @Published var homeVideos: [VodItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isInitialized = false
    @Published var subscribedSites: [String] = []
    @Published var savedURLs: [String] = []
    @Published var loadedSiteCount: Int = 0
    @Published var allSites: [SiteConfig] = [] {
        didSet {
            // allSites 变化时清除缓存，下次调用 fetchAllSourceDisplayItems 时重新计算
            _cachedSourceDisplayItems = nil
        }
    }
    @Published var engineError: String?
    @Published var sourceListReady: Bool = false

    /// 缓存 fetchAllSourceDisplayItems 的结果，避免每次调用都重新计算
    private var _cachedSourceDisplayItems: [SourceDisplayItem]?
    @Published var customParsers: [ParseConfig] = []  // 用户自定义解析器
    @Published var fallbackEnabled: Bool = true {   // 兜底源开关
        didSet { UserDefaults.standard.set(fallbackEnabled, forKey: "fallback_enabled") }
    }
    @Published var customFallbackSites: [(name: String, api: String)] = []  // 自定义兜底源
    var enginesCount: Int { engines.count }

    // 内置兜底采集 API 站 (已废弃，由远程 api_sources.json 替代)
    // 保留此数组仅用于 bundleSourcesEnabled=true 时的兼容模式，后续版本将移除。
    @available(*, deprecated, message: "远程默认源已迁移到 vbox-Ai/api，请使用 RemoteSourceConfigManager.shared.cachedAPISites()")
    static let builtinFallbackSites: [(name: String, api: String)] = [
        ("闪电资源",   "https://sdzyapi.com/api.php/provide/vod"),
        ("光速资源",   "https://api.guangsuapi.com/api.php/provide/vod"),
        ("量子资源",   "https://cj.lziapi.com/api.php/provide/vod"),
        ("暴风资源",   "https://bfzyapi.com/api.php/provide/vod"),
        ("盘Ta资源",   "https://www.91panta.cn/api.php/provide/vod"),
        ("多多资源",   "https://tv.yydsys.top/api.php/provide/vod"),
        ("至臻影视",   "http://www.miqk.cc/api.php/provide/vod"),
    ]

    let subManager = SubscriptionManager()
    /// 主引擎字典 — 统一使用协议类型，支持 JSC 和 QuickJS
    private var engines: [String: SpiderEngineProtocol] = [:]
    /// 记录每个引擎使用的类型（用于诊断显示）
    private var engineTypes: [String: SpiderEngineType] = [:]
    private var cloudPlayCache: [String: (links: [(url: String, name: String)], siteName: String, expiresAt: Date)] = [:]
    /// 初始化任务句柄，确保多次调用 initialize() 时等待首次初始化完成
    private var initializationTask: Task<Void, Never>?
    
    /// 获取指定 key 的引擎类型
    func engineType(forKey key: String) -> SpiderEngineType? {
        return engineTypes[key]
    }
    
    /// 获取所有引擎的统计信息（用于诊断）
    var engineTypeStats: [(key: String, type: SpiderEngineType)] {
        return engineTypes.map { ($0.key, $0.value) }
    }
    
    /// 检查是否有指定 key 的引擎
    func hasEngine(forKey key: String) -> Bool {
        return engines[key] != nil
    }

    /// 获取指定 key 的蜘蛛引擎
    func getEngine(forKey key: String) -> (any SpiderEngineProtocol)? {
        return engines[key]
    }
    
    /// 获取引擎加载统计
    var engineStats: (loaded: Int, total: Int) {
        return (engines.count, allSites.count)
    }

    private init() {
        self.fallbackEnabled = UserDefaults.standard.object(forKey: "fallback_enabled") as? Bool ?? true
        savedURLs = subManager.configURLs
        loadCustomParsers()
        loadCustomFallbackSites()
    }

    // MARK: - 双模式功能开关
    /// 是否启用双模式支持（type=3 HTTP API 站点走原生HTTP链路）
    /// 关闭时完全回到改造前的行为，100%兼容
    var enableDualMode: Bool {
        get { UserDefaults.standard.object(forKey: "enable_dual_mode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enable_dual_mode") }
    }

    // MARK: - 站点模式识别（双模式支持）
    /// 根据站点配置判断其实际工作模式
    /// 核心逻辑：type=3 不一定是JS蜘蛛，需根据 api 字段特征判断
    func resolveSiteMode(site: SiteConfig) -> SiteMode {
        // P2-03：Node 托管蜘蛛识别（形态 A''，优先判断，独立于 type 分支）
        // 识别依据（双保险）：
        //   1. key 前缀 nodejs_（远程源 manifest / 订阅源统一标记）
        //   2. group == "node"（manifest 显式分组标记）
        //   3. api 指向本地 Node 路由（http://127.0.0.1:PORT/spider/...）
        if isNodeSite(site) {
            return .node
        }

        guard let api = site.api, !api.isEmpty else {
            return .unsupported
        }

        // 开关关闭时，type=3 全部按原有逻辑处理（尝试加载JS）
        if !enableDualMode && site.type == 3 {
            // 原有逻辑：非http且非.js的视为jar类名，不支持
            if !api.hasPrefix("http://") && !api.hasPrefix("https://") && !api.hasPrefix("./") && !api.hasSuffix(".js") {
                return .unsupported
            }
            if api.lowercased().contains(".jar") {
                return .unsupported
            }
            return .jsSpider
        }

        switch site.type {
        case 0, 1:
            return .apiEndpoint
        case 2:
            return .zhanyuan
        case 3:
            // jar 包不支持
            if api.lowercased().contains(".jar") {
                return .unsupported
            }
            // 🐍 Python Spider: 以 .py 结尾
            if api.lowercased().hasSuffix(".py") {
                return .pythonSpider
            }
            // HTTP/HTTPS URL：进一步判断是JS文件还是API接口
            if api.hasPrefix("http://") || api.hasPrefix("https://") {
                // 以 .js 结尾的 HTTP URL → JS蜘蛛模式
                if api.lowercased().hasSuffix(".js") {
                    return .jsSpider
                }
                // 不以 .js 结尾的 HTTP URL → 视为CMS API接口
                return .apiEndpoint
            }
            // 相对路径 ./xxx.js 或纯JS文件名 → JS蜘蛛模式
            if api.hasSuffix(".js") || api.hasPrefix("./") {
                return .jsSpider
            }
            // 纯类名如 csp_Douban → jar包，不支持
            return .unsupported
        default:
            return .unsupported
        }
    }

    // MARK: - Node 托管蜘蛛识别与注册（P2-03，形态 A''）

    /// 判断站点是否为 Node 托管蜘蛛（双保险识别）
    /// - key 前缀 `nodejs_`：远程源 manifest / 订阅源统一标记（主依据）
    /// - group == "node"：manifest 显式分组标记（辅助依据，K1 字段扩展后可用）
    /// - api 指向本地 Node 路由（`http://127.0.0.1:PORT/spider/...`）：兼容直链形态
    func isNodeSite(_ site: SiteConfig) -> Bool {
        if site.group == "node" { return true }
        let key = site.key.isEmpty ? site.name : site.key
        if key.hasPrefix("nodejs_") { return true }
        // 订阅源 csp_ 类名形态（TVBox 蜘蛛类名）：key 或 api 为 csp_Xxx → Node 托管（P2csp）
        // 限定 type==3，避免误伤其他类型；此前该类站点被当作 jar 包跳过（.unsupported），
        // 仓库源（type 1 API / .js/.py 相对路径）不包含 csp_ 条目，零影响。
        if key.hasPrefix("csp_") && site.type == 3 { return true }
        if let api = site.api, api.hasPrefix("nodejs_") { return true }
        if let api = site.api, api.hasPrefix("csp_") && site.type == 3 { return true }
        if let api = site.api {
            // 本地 Node 常驻路由：http://127.0.0.1:58080/spider/... 或 https?://127.0.0.1:/spider/
            let lower = api.lowercased()
            if lower.contains("://127.0.0.1") && lower.contains("/spider/") { return true }
        }
        return false
    }

    /// 注册 Node 托管蜘蛛引擎（不下载 JS，直接桥接常驻进程）
    private func registerNodeEngine(for site: SiteConfig) {
        let key = site.key.isEmpty ? site.name : site.key
        if engines[key] != nil { return }
        let engine = NodeSpiderEngine(siteKey: key)
        engines[key] = engine
        engineTypes[key] = .node
        if !subscribedSites.contains(key) { subscribedSites.append(key) }
        let nodeKey = engineNodeKey(key)
        AppLogStore.shared.info(.spider, "[SpiderManager] ✅ Node 蜘蛛注册: \(site.name) (\(key)) → nodeKey=\(nodeKey)")
    }

    /// vbox 站点 key → Node 系统内蜘蛛 key（去掉 nodejs_/csp_ 前缀）
    private func engineNodeKey(_ key: String) -> String {
        var result = key
        for prefix in ["nodejs_", "csp_"] where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        return result
    }

    // MARK: - 兜底源管理
    func saveCustomFallbackSites() {
        let arr = customFallbackSites.map { ["name": $0.name, "api": $0.api] }
        UserDefaults.standard.set(arr, forKey: "custom_fallback_sites")
    }

    private func loadCustomFallbackSites() {
        guard let arr = UserDefaults.standard.array(forKey: "custom_fallback_sites") as? [[String: String]] else { return }
        customFallbackSites = arr.compactMap { dict in
            guard let name = dict["name"], let api = dict["api"] else { return nil }
            return (name, api)
        }
    }

    func addCustomFallbackSite(name: String, api: String) {
        guard !customFallbackSites.contains(where: { $0.api == api }) else { return }
        customFallbackSites.append((name, api))
        saveCustomFallbackSites()
        NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
    }

    func removeCustomFallbackSite(at index: Int) {
        guard index >= 0, index < customFallbackSites.count else { return }
        customFallbackSites.remove(at: index)
        saveCustomFallbackSites()
        NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
    }

    /// 所有兜底源 = 内置（过滤禁用）+ 自定义（过滤禁用）
    var allFallbackSites: [(name: String, api: String)] {
        let remoteSourceManager = RemoteSourceConfigManager.shared
        var sites: [(name: String, api: String)] = []
        if remoteSourceManager.bundleSourcesEnabled {
            for site in Self.builtinFallbackSites {
                let host = extractHost(from: site.api)
                if !remoteSourceManager.isHostDisabled(host) {
                    sites.append(site)
                }
            }
        }
        for cs in customFallbackSites {
            let host = extractHost(from: cs.api)
            if !remoteSourceManager.isHostDisabled(host),
               !sites.contains(where: { $0.api == cs.api }) {
                sites.append(cs)
            }
        }
        return sites
    }

    private static let userParsersKey = "user_parsers"

    /// 加载自定义解析器（远程默认 + 用户自定义，用户自定义优先级更高）
    private func loadCustomParsers() {
        var parsers: [ParseConfig] = []

        // 1. 远程默认解析器（parsers.json）
        let remoteParsers = RemoteSourceConfigManager.shared.cachedParsers()
        if !remoteParsers.isEmpty {
            parsers.append(contentsOf: remoteParsers)
            print("[SpiderManager] 从远程默认源加载解析器: \(remoteParsers.count) 个")
        }

        // 2. 用户自定义解析器（优先级更高，追加到末尾）
        if let data = UserDefaults.standard.data(forKey: Self.userParsersKey),
           let userParsers = try? JSONDecoder().decode([ParseConfig].self, from: data) {
            for parser in userParsers {
                if !parsers.contains(where: { $0.url == parser.url }) {
                    parsers.append(parser)
                }
            }
        }

        customParsers = parsers
    }

    /// 保存自定义解析器（仅保存用户自定义的，不含远程默认）
    func saveCustomParsers() {
        let remoteURLs = Set(RemoteSourceConfigManager.shared.cachedParsers().map { $0.url })
        let userParsers = customParsers.filter { !remoteURLs.contains($0.url) }
        if let data = try? JSONEncoder().encode(userParsers) {
            UserDefaults.standard.set(data, forKey: Self.userParsersKey)
        }
    }

    /// 添加自定义解析器
    func addCustomParser(name: String, url: String) {
        let parser = ParseConfig(name: name, url: url, type: nil)
        if !customParsers.contains(where: { $0.url == url }) {
            customParsers.append(parser)
            saveCustomParsers()
        }
    }

    /// 删除自定义解析器
    func removeCustomParser(at index: Int) {
        guard index >= 0, index < customParsers.count else { return }
        customParsers.remove(at: index)
        saveCustomParsers()
    }

    func initialize() async {
        // 如果已经有初始化任务在进行中，等待它完成
        if let existingTask = initializationTask {
            await existingTask.value
            return
        }
        // 如果已经完成初始化，直接返回
        if isInitialized { return }

        // 创建初始化任务，让后续调用者可以等待
        initializationTask = Task { @MainActor in
            isInitialized = true
            sourceListReady = false

            await RemoteSourceConfigManager.shared.syncIfNeeded()

            // 尝试加载 QuickJS 内置蜘蛛
            await loadBuiltinEngineIfNeeded()

            // 加载激活的订阅源
            if let activeURL = subManager.activeURL {
                print("[SpiderManager] 加载激活的订阅源: \(activeURL)")
                await subManager.loadConfig(from: activeURL)
            }

            // 无论是否有订阅源，都加载站点配置（内置站点作为兜底）
            await loadSitesFromSubscription()

            print("[SpiderManager] 初始化完成，引擎数: \(engines.count), 站点数: \(allSites.count)")

            // 确保源列表缓存刷新
            invalidateSourceDisplayCache()
        }

        await initializationTask!.value
        initializationTask = nil
    }

    /// 加载内置 QuickJS 蜘蛛引擎
    private func loadBuiltinEngineIfNeeded() async {
        guard engines["builtin"] == nil else { return }
        do {
            try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
            print("[SpiderManager] ✅ 内置蜘蛛加载成功")
        } catch {
            engineError = "蜘蛛加载失败: \(error.localizedDescription)"
            print("[SpiderManager] ❌ 内置蜘蛛加载失败: \(error.localizedDescription)")
        }
    }

    /// 获取内置蜘蛛 JS 代码 — 蜘蛛通过 http() 桥接调用原生网络
    private func getBuiltinSpiderJS() -> String {
        return """
function VideoDetail() { this.vod_id = ""; this.vod_name = ""; this.vod_pic = ""; this.vod_remarks = ""; }
function RepVideoList() { this.data = []; this.total = 0; this.error = ""; }

// req — http() 是同步阻塞的，直接取结果
function req(url, options) {
    var opts = options || {};
    var resp = JSON.parse(http(url, JSON.stringify({
        method: opts.method || 'GET',
        headers: opts.headers || {},
        data: opts.data || '',
        timeout: 5
    })));
    resp.data = resp.content;
    return resp;
}

var wooyun = {
    webSite: 'https://wooyun.tv',
    getHeaders: function() {
        return { Referer: this.webSite, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    },
    search: function(keyword, page) {
        var back = new RepVideoList();
        if (!keyword) return JSON.stringify(back);
        try {
            var resp = req(this.webSite + '/api/proxy?url=%2Fmovie%2Fmedia%2Fsearch', {
                method: 'POST', headers: this.getHeaders(),
                data: JSON.stringify({ menuCodeList: [], pageIndex: String(page||1), pageSize: 10, searchKey: keyword, topCode: '' })
            });
            var json = JSON.parse(resp.data || '{}');
            var records = (json.data && json.data.records) || [];
            for (var i = 0; i < records.length; i++) {
                var r = records[i], v = new VideoDetail();
                v.vod_id = String(r.id||''); v.vod_name = r.title||''; v.vod_pic = r.posterUrlS3||r.posterUrl||'';
                v.vod_remarks = '乌云影视'; back.data.push(v);
            }
        } catch(e) { back.error = String(e); }
        return JSON.stringify(back);
    }
};

var _spider = {
    homeContent: function() { return JSON.stringify({ class: [], list: [] }); },
    searchContent: function(k, p) { return wooyun.search(k, p); },
    detailContent: function(i) { return JSON.stringify({ list: [] }); },
    playerContent: function(v,f,u) { return JSON.stringify({ parse: 0, url: u }); }
};
globalThis.__JS_SPIDER__ = _spider;
"""
    }

    /// 加载指定 URL 的订阅源（添加新订阅时用）
    func loadSubscribeConfig(from url: String) async {
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: url)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        // 新加载的设为激活
        if let idx = subManager.configURLs.firstIndex(of: url) {
            subManager.switchToSubscription(at: idx)
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
        NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
    }

    /// 加载当前激活的订阅源
    func loadActiveSubscription() async {
        guard let activeURL = subManager.activeURL else {
            print("[SpiderManager] 没有激活的订阅源")
            return
        }
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: activeURL)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
        NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
    }

    /// 重新合并远程默认源、当前订阅源、用户自定义源和可选 Bundle 内置源。
    /// 用于远程默认源刷新、Bundle 内置源开关切换、清除远程缓存之后重建源列表。
    ///
    /// 修复 (2026-08-11): 清缓存后 Python 资源不显示
    /// 原因: reloadAllSources 不会清除旧的 Python 引擎, loadSitesFromSubscription 中
    ///        `if engines[key] != nil { continue }` 会跳过已存在的引擎, 但清缓存可能
    ///        已删除磁盘上的 .py 文件或引擎状态异常, 导致 Python 资源无法使用
    /// 修复: reloadAllSources 时先清除所有 Python 引擎, 强制重新下载和加载
    func reloadAllSources() async {
        isLoading = true
        errorMessage = nil

        // ★ 清除旧 Python 引擎，确保重新下载和加载
        let pyKeys = engines.compactMap { (k, v) -> String? in v is PythonSpiderEngine ? k : nil }
        for key in pyKeys {
            engines.removeValue(forKey: key)
            if let idx = subscribedSites.firstIndex(of: key) {
                subscribedSites.remove(at: idx)
            }
            engineTypes.removeValue(forKey: key)
        }
        if !pyKeys.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🔄 清除 \(pyKeys.count) 个旧 Python 引擎，准备重新加载")
        }

        if let activeURL = subManager.activeURL {
            await subManager.loadConfig(from: activeURL)
            if let error = subManager.errorMessage {
                print("[SpiderManager] 订阅源刷新失败，继续尝试默认源: \(error)")
            }
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
        NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
    }

    /// 切换激活的订阅源
    func switchToSubscription(at index: Int) {
        subManager.switchToSubscription(at: index)
        engines.removeAll()
        subscribedSites.removeAll()
        allSites = []
        loadedSiteCount = 0
        Task { await loadActiveSubscription() }
    }

    /// 从 URL 字符串中提取 scheme + host（如 https://example.com）
    private func extractHost(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              let host = url.host else { return urlString }
        var result = "\(scheme)://\(host)"
        if let port = url.port {
            result += ":\(port)"
        }
        return result
    }

    private func loadSitesFromSubscription() async {
        let remoteSourceManager = RemoteSourceConfigManager.shared

        // 优先加载远程默认 API 源缓存。远程默认源只替代系统默认源，不覆盖用户订阅和用户自定义源。
        var iboxSites: [SiteConfig] = remoteSourceManager.remoteDefaultSourceEnabled ? remoteSourceManager.cachedAPISites() : []
        var iboxLoaded = !iboxSites.isEmpty
        if iboxLoaded {
            print("[SpiderManager] 从远程默认源缓存读取 API 源: \(iboxSites.count) 个站点")
        }

        // 应用 disabled_sources 过滤和 domain_overrides 域名覆盖
        let disabledHosts = remoteSourceManager.remoteDefaultSourceEnabled ? remoteSourceManager.cachedDisabledHosts() : []
        let disabledKeys = remoteSourceManager.remoteDefaultSourceEnabled ? remoteSourceManager.cachedDisabledKeys() : []
        if !disabledHosts.isEmpty {
            let before = iboxSites.count
            iboxSites = iboxSites.filter { site in
                guard let api = site.api else { return true }
                let host = extractHost(from: api)
                return !remoteSourceManager.isHostDisabled(host)
            }
            if iboxSites.count != before {
                print("[SpiderManager] 🚫 disabled_sources 过滤: \(before - iboxSites.count) 个站点被禁用，剩余 \(iboxSites.count)")
            }
        }
        if !disabledKeys.isEmpty {
            let before = iboxSites.count
            iboxSites = iboxSites.filter { !disabledKeys.contains($0.key) }
            if iboxSites.count != before {
                print("[SpiderManager] 🚫 disabled_sources(keys) 过滤: \(before - iboxSites.count) 个站点被禁用，剩余 \(iboxSites.count)")
            }
        }
        // 应用域名覆盖
        if remoteSourceManager.remoteDefaultSourceEnabled {
            iboxSites = iboxSites.map { site in
                let newAPI = site.api.map { remoteSourceManager.applyDomainOverrides(to: $0) }
                return SiteConfig(
                    key: site.key, name: site.name, type: site.type, api: newAPI,
                    searchable: site.searchable, quickSearch: site.quickSearch, filterable: site.filterable,
                    ext: site.ext, playerType: site.playerType, jar: site.jar, changeable: site.changeable,
                    playStrategy: site.playStrategy, playMode: site.playMode, panHosts: site.panHosts, group: site.group
                )
            }
        }
        if iboxSites.isEmpty { iboxLoaded = false }

        if !iboxLoaded && remoteSourceManager.bundleSourcesEnabled {
            // 加载 Bundle 内置 ibox_sources.json。测试远程源时关闭 bundleSourcesEnabled 后会跳过这里。
            if let iboxPath = Bundle.main.path(forResource: "ibox_sources", ofType: "json", inDirectory: "js"),
               let iboxData = try? Data(contentsOf: URL(fileURLWithPath: iboxPath)) {
                do {
                    let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                    iboxSites = iboxConfig.sites
                    iboxLoaded = true
                    print("[SpiderManager] 从 ibox_sources.json(js/) 读取了 \(iboxSites.count) 个站点")
                } catch {
                    print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                }
            }
            if !iboxLoaded, let iboxPath = Bundle.main.path(forResource: "ibox_sources", ofType: "json"),
               let iboxData = try? Data(contentsOf: URL(fileURLWithPath: iboxPath)) {
                do {
                    let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                    iboxSites = iboxConfig.sites
                    iboxLoaded = true
                    print("[SpiderManager] 从 Bundle 根目录读取 ibox_sources.json: \(iboxSites.count) 个站点")
                } catch {
                    print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                }
            }
            if !iboxLoaded, let iboxURL = Bundle.main.url(forResource: "ibox_sources", withExtension: "json", subdirectory: "js"),
               let iboxData = try? Data(contentsOf: iboxURL) {
                do {
                    let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                    iboxSites = iboxConfig.sites
                    iboxLoaded = true
                    print("[SpiderManager] 从 url(subdirectory:js) 读取 ibox_sources.json: \(iboxSites.count) 个站点")
                } catch {
                    print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                }
            }
            if !iboxLoaded {
                if let jsURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "js"),
                   let iboxFile = jsURLs.first(where: { $0.lastPathComponent == "ibox_sources.json" }),
                   let iboxData = try? Data(contentsOf: iboxFile) {
                    do {
                        let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                        iboxSites = iboxConfig.sites
                        iboxLoaded = true
                        print("[SpiderManager] 从 urls(js/) 枚举找到 ibox_sources.json: \(iboxSites.count) 个站点")
                    } catch {
                        print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                    }
                }
                if !iboxLoaded, let allJSONs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil),
                   let iboxFile = allJSONs.first(where: { $0.lastPathComponent == "ibox_sources.json" }),
                   let iboxData = try? Data(contentsOf: iboxFile) {
                    do {
                        let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                        iboxSites = iboxConfig.sites
                        iboxLoaded = true
                        print("[SpiderManager] 从 urls(根目录) 枚举找到 ibox_sources.json: \(iboxSites.count) 个站点")
                    } catch {
                        print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                    }
                }
            }
        } else if !iboxLoaded {
            print("[SpiderManager] Bundle 内置源已关闭，跳过 ibox_sources.json")
        }
        if !iboxLoaded {
            print("[SpiderManager] ⚠️ 未找到可用 API 默认源")
        }

        // ★ 使用局部变量收集所有站点，避免多次修改 allSites 触发 didSet 缓存失效
        var allSitesBuilder: [SiteConfig] = []

        // 如果 subManager.config 为空但之前通过 apiyuan 转换过站点，
        // 从 subManager 的内部加载
        guard let config = subManager.config else {
            // config 为 nil 说明没有订阅源，直接使用内置 ibox 站点
            if !iboxSites.isEmpty {
                allSitesBuilder = iboxSites
                print("[SpiderManager] 无订阅源，使用内置 ibox_sources: \(allSitesBuilder.count) 个站点")
            } else {
                self.allSites = []
                loadedSiteCount = 0
                errorMessage = "订阅源配置为空"
                DatabaseManager.shared.clearAllZhanyuanSites()
                DatabaseManager.shared.clearAllApiYuanSites()
                print("[SpiderManager] 无订阅源，已清空数据库站源残留")
                return
            }
            // 合并 Bundle 内置兜底 API 站点
            let existingKeys = Set(allSitesBuilder.map { $0.key })
            let fallbackConfigs = (RemoteSourceConfigManager.shared.bundleSourcesEnabled ? Self.builtinFallbackSites : []).compactMap { site -> SiteConfig? in
                let key = "builtin_" + site.name
                guard !existingKeys.contains(key) else { return nil }
                let host = extractHost(from: site.api)
                guard !remoteSourceManager.isHostDisabled(host) else { return nil }
                return SiteConfig(key: key, name: site.name, type: 1, api: site.api, searchable: 1, quickSearch: 0, filterable: 0)
            }
            if !fallbackConfigs.isEmpty {
                allSitesBuilder.append(contentsOf: fallbackConfigs)
                print("[SpiderManager] 合并内置兜底站点: \(fallbackConfigs.count) 个")
            }
            // 合并远程默认 JS 蜘蛛站源
            let spiderSites = remoteSourceManager.remoteDefaultSourceEnabled ? remoteSourceManager.cachedSpiderSites() : []
            if !spiderSites.isEmpty {
                let existingKeys = Set(allSitesBuilder.map { $0.key })
                let newSpiderSites = spiderSites.filter { !existingKeys.contains($0.key) }
                if !newSpiderSites.isEmpty {
                    allSitesBuilder.append(contentsOf: newSpiderSites)
                    print("[SpiderManager] 从远程默认源合并 JS 蜘蛛站: \(newSpiderSites.count) 个")
                }
            }
            // 一次性赋值，避免中间状态触发缓存失效
            self.allSites = allSitesBuilder
            loadedSiteCount = allSitesBuilder.count
            sourceListReady = true

            // 加载引擎
            await loadBuiltinEngineIfNeeded()
            if !spiderSites.isEmpty, let baseURL = remoteSpiderBaseURL() {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📋 开始加载远程默认源蜘蛛引擎 (无订阅源模式)")
                await loadRemoteSpiderEngines(baseURL: baseURL, sites: spiderSites)
            }

            // ★ 加载完成汇总日志
            let pyEngines0 = engines.compactMap { (k, v) -> String? in v is PythonSpiderEngine ? k : nil }
            let jsEngines0 = engines.compactMap { (k, v) -> String? in !(v is PythonSpiderEngine) ? k : nil }
            AppLogStore.shared.info(.spider, "[SpiderManager] 📋 源加载完成(无订阅): \(engines.count)引擎 (\(jsEngines0.count) JS + \(pyEngines0.count) Python), \(allSitesBuilder.count)站点")
            if !pyEngines0.isEmpty {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📋 Python 引擎: \(pyEngines0.joined(separator: ", "))")
            }
            return
        }

        // 有订阅源模式
        allSitesBuilder = config.sites

        // 对订阅源站点应用 disabled 过滤和域名覆盖
        if remoteSourceManager.remoteDefaultSourceEnabled {
            let disabledHosts = remoteSourceManager.cachedDisabledHosts()
            let disabledKeys = remoteSourceManager.cachedDisabledKeys()
            if !disabledHosts.isEmpty || !disabledKeys.isEmpty {
                let before = allSitesBuilder.count
                allSitesBuilder = allSitesBuilder.filter { site in
                    if disabledKeys.contains(site.key) { return false }
                    guard let api = site.api else { return true }
                    return !remoteSourceManager.isHostDisabled(extractHost(from: api))
                }
                if allSitesBuilder.count != before {
                    print("[SpiderManager] 🚫 disabled_sources 过滤订阅源: \(before - allSitesBuilder.count) 个站点被禁用")
                }
            }
            allSitesBuilder = allSitesBuilder.map { site in
                let newAPI = site.api.map { remoteSourceManager.applyDomainOverrides(to: $0) }
                return SiteConfig(
                    key: site.key, name: site.name, type: site.type, api: newAPI,
                    searchable: site.searchable, quickSearch: site.quickSearch, filterable: site.filterable,
                    ext: site.ext, playerType: site.playerType, jar: site.jar, changeable: site.changeable,
                    playStrategy: site.playStrategy, playMode: site.playMode, panHosts: site.panHosts, group: site.group
                )
            }
        }

        // 合并内置 ibox 站点（去重）
        if !iboxSites.isEmpty {
            let existingKeys = Set(allSitesBuilder.map { $0.key })
            let newSites = iboxSites.filter { !existingKeys.contains($0.key) }
            if !newSites.isEmpty {
                allSitesBuilder.append(contentsOf: newSites)
                print("[SpiderManager] 从 ibox_sources.json 合并了 \(newSites.count) 个站点")
            }
        }

        // 合并 Bundle 内置兜底 API 站点（去重）
        let existingKeysForFallback = Set(allSitesBuilder.map { $0.key })
        let fallbackConfigs = (RemoteSourceConfigManager.shared.bundleSourcesEnabled ? Self.builtinFallbackSites : []).compactMap { site -> SiteConfig? in
            let key = "builtin_" + site.name
            guard !existingKeysForFallback.contains(key) else { return nil }
            let host = extractHost(from: site.api)
            guard !remoteSourceManager.isHostDisabled(host) else { return nil }
            return SiteConfig(key: key, name: site.name, type: 1, api: site.api, searchable: 1, quickSearch: 0, filterable: 0)
        }
        if !fallbackConfigs.isEmpty {
            allSitesBuilder.append(contentsOf: fallbackConfigs)
            print("[SpiderManager] 合并内置兜底站点: \(fallbackConfigs.count) 个")
        }

        // 合并远程默认 JS 蜘蛛站源
        let spiderSites = remoteSourceManager.remoteDefaultSourceEnabled ? remoteSourceManager.cachedSpiderSites() : []
        if !spiderSites.isEmpty {
            let spiderExistingKeys = Set(allSitesBuilder.map { $0.key })
            let newSpiderSites = spiderSites.filter { !spiderExistingKeys.contains($0.key) }
            if !newSpiderSites.isEmpty {
                allSitesBuilder.append(contentsOf: newSpiderSites)
                print("[SpiderManager] 从远程默认源合并 JS 蜘蛛站: \(newSpiderSites.count) 个")
            }
        }

        // 先确保内置蜘蛛加载
        await loadBuiltinEngineIfNeeded()

        // 加载远程默认源 JS 蜘蛛引擎
        if !spiderSites.isEmpty, let baseURL = remoteSpiderBaseURL() {
            print("[SpiderManager] 开始加载远程默认源 JS 蜘蛛引擎 (订阅源模式)")
            await loadRemoteSpiderEngines(baseURL: baseURL, sites: spiderSites)
        }

        // 尝试从订阅源的 spider 字段加载全局 JS 蜘蛛
        // P2spider：订阅源含 Node 托管站点时，spider 字段为 Node 蜘蛛库（bundle 无注入接口，
        // 代码实证），跳过 vbox 本地"单蜘蛛"加载——避免无谓下载与错误加载；日志说明原因。
        if config.sites.contains(where: { isNodeSite($0) }) {
            if let spiderField = config.spider, !spiderField.isEmpty {
                AppLogStore.shared.info(.spider, "[SpiderManager] ⏭️ 订阅源含 Node 托管站点，spider 字段由 Node 侧管理，跳过本地加载: \(spiderField.prefix(80))")
            }
        } else if let spiderField = config.spider, !spiderField.isEmpty {
            let spiderURL: String
            if spiderField.contains(";") {
                spiderURL = spiderField.components(separatedBy: ";").first ?? spiderField
            } else {
                spiderURL = spiderField
            }

            if spiderURL.lowercased().contains(".jar") {
                print("[SpiderManager] spider 字段是 jar 包，iOS 不支持 Java 蜘蛛，跳过: \(spiderURL.prefix(80))")
            } else if spiderURL.hasPrefix("http://") || spiderURL.hasPrefix("https://") {
                do {
                    let rawData = try await downloadRawData(url: spiderURL)
                    if let snippet = String(data: rawData, encoding: .utf8),
                       snippet.count > 100,
                       snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ") {
                        try await loadSpiderEngine(jsCode: snippet, key: "remote_spider")
                        print("[SpiderManager] ✅ 远程蜘蛛加载成功")
                    } else {
                        print("[SpiderManager] spider URL 不是纯 JS（可能是 jar 包），使用内置蜘蛛")
                    }
                } catch {
                    print("[SpiderManager] spider URL 加载失败: \(error.localizedDescription)")
                }
            } else if spiderURL.hasPrefix("./") {
                let baseURL = subManager.activeURL ?? ""
                let fullURL: String
                if let url = URL(string: baseURL) {
                    fullURL = url.deletingLastPathComponent().appendingPathComponent(spiderURL).absoluteString
                } else {
                    fullURL = spiderURL
                }
                print("[SpiderManager] spider 相对路径拼接: \(spiderURL) -> \(fullURL)")
                do {
                    let rawData = try await downloadRawData(url: fullURL)
                    if let snippet = String(data: rawData, encoding: .utf8),
                       snippet.count > 100,
                       (snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ")) {
                        try await loadSpiderEngine(jsCode: snippet, key: "remote_spider")
                        print("[SpiderManager] ✅ 远程蜘蛛(相对路径)加载成功")
                    } else {
                        print("[SpiderManager] spider 相对路径内容不是有效 JS，跳过")
                    }
                } catch {
                    print("[SpiderManager] spider 相对路径加载失败: \(error.localizedDescription)")
                }
            } else {
                print("[SpiderManager] spider 字段格式无法识别，跳过: \(spiderURL.prefix(80))")
            }
        }

        // 按模式分类处理订阅源中的站点
        var jsSpiderLoaded = 0
        var jsSpiderFailed = 0
        let subBaseURL = subManager.activeURL ?? ""

        var jsSitesToLoad: [(site: SiteConfig, resolvedURL: String)] = []
        var apiSitesToAdd: [SiteConfig] = []
        var pySitesToLoad: [(site: SiteConfig, resolvedURL: String)] = []

        for site in config.sites {
            let mode = resolveSiteMode(site: site)

            // 🟢 Node 托管蜘蛛（订阅源）：即使 api 为空（group:"node" / nodejs_ 前缀标记）也注册
            if mode == .node {
                registerNodeEngine(for: site)
                continue
            }
            guard let api = site.api, !api.isEmpty else { continue }

            switch mode {
            case .jsSpider:
                let api = site.api!
                if api.hasPrefix("./") {
                    let fullURL: String
                    if let url = URL(string: subBaseURL) {
                        fullURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                    } else {
                        fullURL = api
                    }
                    jsSitesToLoad.append((site: site, resolvedURL: fullURL))
                } else if !api.hasPrefix("http://") && !api.hasPrefix("https://") && api.hasSuffix(".js") {
                    if let url = URL(string: subBaseURL) {
                        let fullURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                        jsSitesToLoad.append((site: site, resolvedURL: fullURL))
                    }
                } else if api.hasPrefix("http://") || api.hasPrefix("https://") {
                    jsSitesToLoad.append((site: site, resolvedURL: api))
                }
            case .apiEndpoint:
                apiSitesToAdd.append(site)
                print("[SpiderManager] API站点标记: \(site.name) (\(site.api ?? ""))")
            case .pythonSpider:
                // 🐍 Python 蜘蛛站点（订阅源）— 收集，稍后加载
                let api = site.api!
                let resolvedPyURL: String
                if api.hasPrefix("./") {
                    // 相对路径: 基于 subBaseURL 解析
                    if let url = URL(string: subBaseURL) {
                        resolvedPyURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                    } else {
                        resolvedPyURL = api
                    }
                } else if !api.hasPrefix("http://") && !api.hasPrefix("https://") && api.hasSuffix(".py") {
                    // 文件名 (无 http 前缀): 基于 subBaseURL 解析
                    if let url = URL(string: subBaseURL) {
                        resolvedPyURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                    } else {
                        resolvedPyURL = api
                    }
                } else {
                    resolvedPyURL = api
                }
                pySitesToLoad.append((site: site, resolvedURL: resolvedPyURL))
                AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 Python 蜘蛛站点: \(site.name) → \(resolvedPyURL)")
            case .node:
                // 🟢 Node 托管蜘蛛（订阅源）：直接注册 NodeSpiderEngine，不下载 JS
                registerNodeEngine(for: site)
            case .zhanyuan:
                break
            case .unsupported:
                AppLogStore.shared.info(.spider, "[SpiderManager] ⏭️ 跳过不支持站点: \(site.name) (type=\(site.type), api=\(site.api ?? ""))")
            }
        }

        print("[SpiderManager] 发现 \(jsSitesToLoad.count) 个 JS 蜘蛛站点待加载")
        print("[SpiderManager] 发现 \(apiSitesToAdd.count) 个 API 模式站点待加入")
        AppLogStore.shared.info(.spider, "[SpiderManager] 📋 订阅源站点分类: \(jsSitesToLoad.count) JS + \(pySitesToLoad.count) Python + \(apiSitesToAdd.count) API")

        // 限制最多加载 30 个蜘蛛（避免内存爆炸）
        for item in jsSitesToLoad.prefix(30) {
            let site = item.site
            let jsURL = item.resolvedURL
            guard let url = URL(string: jsURL) else { continue }
            let key = site.key.isEmpty ? site.name : site.key
            if engines[key] != nil { continue }

            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                if let jsCode = String(data: data, encoding: .utf8),
                   jsCode.count > 200,
                   (jsCode.contains("function ") || jsCode.contains("var ") || jsCode.contains("spider")) {
                    try await loadSpiderEngine(jsCode: jsCode, key: key)

                    if let ext = site.ext, !ext.isEmpty {
                        let extTrimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
                        if extTrimmed.hasPrefix("http://") || extTrimmed.hasPrefix("https://") {
                            print("[SpiderManager] 加载 ext URL: \(extTrimmed.prefix(80))")
                            do {
                                let extData = try await downloadRawData(url: extTrimmed)
                                if let extCode = String(data: extData, encoding: .utf8), extCode.count > 50 {
                                    if let engine = engines[key] {
                                        try engine.loadScript(extCode)
                                        print("[SpiderManager] ✅ ext URL 加载成功: \(site.name)")
                                    }
                                }
                            } catch {
                                print("[SpiderManager] ext URL 加载失败: \(site.name) - \(error.localizedDescription)")
                            }
                        } else if extTrimmed.contains("function ") || extTrimmed.contains("var ") || extTrimmed.contains("let ") || extTrimmed.contains("const ") {
                            print("[SpiderManager] 加载内联 ext JS: \(site.name)")
                            if let engine = engines[key] {
                                try engine.loadScript(extTrimmed)
                                print("[SpiderManager] ✅ 内联 ext 加载成功: \(site.name)")
                            }
                        } else {
                            print("[SpiderManager] ext 不是 JS 代码，可能是配置: \(extTrimmed.prefix(60))")
                        }
                    }

                    jsSpiderLoaded += 1
                    print("[SpiderManager] ✅ JS蜘蛛加载成功: \(site.name) (\(key))")
                } else {
                    jsSpiderFailed += 1
                    print("[SpiderManager] ⚠️ JS蜘蛛内容无效: \(site.name)")
                }
            } catch {
                jsSpiderFailed += 1
                print("[SpiderManager] JS蜘蛛加载失败: \(site.name) - \(error.localizedDescription)")
            }
        }

        // 🐍 加载订阅源中的 Python 蜘蛛（并发）
        // 网络下载并发执行（不受 GIL 限制），init() 仍由 GIL 串行，但整体仍快 50%+
        if !pySitesToLoad.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 订阅源 Python 蜘蛛待加载: \(pySitesToLoad.count) 个（并发）")
            await withTaskGroup(of: (key: String, success: Bool).self) { group in
                for item in pySitesToLoad {
                    let key = item.site.key.isEmpty ? item.site.name : item.site.key
                    if engines[key] != nil { continue }
                    group.addTask {
                        let success = await self.loadSinglePythonSpider(site: item.site, resolvedURL: item.resolvedURL)
                        return (key: key, success: success)
                    }
                }
                for await result in group {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 订阅源 Python 蜘蛛[\(result.success ? "✅" : "❌")] \(result.key)")
                }
            }
        }

        // 加载 zhanyuan (type=2) 站源
        let zhanSites = config.sites.filter { $0.type == 2 && $0.api != nil && !$0.api!.isEmpty }
        print("[SpiderManager] 发现 \(zhanSites.count) 个 zhanyuan 站源")
        for site in zhanSites {
            let key = site.key.isEmpty ? site.name : site.key
            guard engines[key] == nil else { continue }
            let configJSON = site.ext ?? "{}"
            let escapedName = site.name.replacingOccurrences(of: "'", with: "\\'")
            let configBase64 = configJSON.data(using: .utf8)?.base64EncodedString() ?? ""
            let zhanJS = """
            (function() {
                try {
                    var configJSON = atob('\(configBase64)');
                    var config = JSON.parse(configJSON);
                    config.name = config.name || '\(escapedName)';
                    config.searchUrl = config.searchUrl || '';
                    var spider = globalThis.__createZhanyuanSpider(config);
                    globalThis.__JS_SPIDER__ = spider;
                } catch(e) { print('[Zhanyuan] 创建蜘蛛失败: ' + e); }
            })();
            """
            var zhanLoaded = false
            for engineType in [SpiderEngineType.javaScriptCore, .quickJS] {
                do {
                    let engine = try await Self.buildSpiderEngineOffMain(
                        jsCode: zhanJS,
                        extCode: nil,
                        engineType: engineType,
                        key: key
                    )

                    engine.onLog = { [weak self] msg in
                        print("[Zhanyuan|\(key)|\(engineType.displayName)] \(msg)")
                        if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                            Task { @MainActor [weak self] in
                                self?.engineError = msg
                            }
                        }
                    }

                    engines[key] = engine
                    engineTypes[key] = engineType
                    if !subscribedSites.contains(key) { subscribedSites.append(key) }
                    jsSpiderLoaded += 1
                    print("[SpiderManager] ✅ zhanyuan 就绪 [\(engineType.displayName)]: \(site.name)")
                    zhanLoaded = true
                    break
                } catch {
                    print("[SpiderManager] ⚠️ zhanyuan \(engineType.displayName) 失败: \(site.name): \(error)")
                }
            }
            if !zhanLoaded {
                jsSpiderFailed += 1
                print("[SpiderManager] ❌ zhanyuan 全部引擎失败: \(site.name)")
            }
        }

        print("[SpiderManager] JS蜘蛛: 成功\(jsSpiderLoaded) 失败\(jsSpiderFailed), 总引擎: \(engines.count)")

        // 将 API 模式的 type=3 站点合并到 allSitesBuilder
        if !apiSitesToAdd.isEmpty {
            let existingKeys = Set(allSitesBuilder.map { $0.key })
            let newApiSites = apiSitesToAdd.filter { !existingKeys.contains($0.key) }
            if !newApiSites.isEmpty {
                allSitesBuilder.append(contentsOf: newApiSites)
                print("[SpiderManager] ✅ 合并 \(newApiSites.count) 个 API 模式站点")
            }
        }

        // 一次性赋值 allSites，避免中间状态触发多次 didSet 缓存失效
        self.allSites = allSitesBuilder
        loadedSiteCount = allSitesBuilder.count
        sourceListReady = true

        // ★ 加载完成汇总日志 — 输出所有已注册引擎，方便排查 "山有木兮" 等源是否加载
        let pyEngines = engines.compactMap { (k, v) -> String? in v is PythonSpiderEngine ? k : nil }
        let jsEngines = engines.compactMap { (k, v) -> String? in !(v is PythonSpiderEngine) ? k : nil }
        AppLogStore.shared.info(.spider, "[SpiderManager] 📋 源加载完成: \(engines.count)引擎 (\(jsEngines.count) JS + \(pyEngines.count) Python), \(allSitesBuilder.count)站点")
        if !pyEngines.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 📋 Python 引擎: \(pyEngines.joined(separator: ", "))")
        }
        if !jsEngines.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 📋 JS 引擎: \(jsEngines.joined(separator: ", "))")
        }

        // 将当前 allSites 中的 type=2 站源强制同步到 SQLite
        syncZhanyuanSitesToDatabase()

        await loadHomeData()

        // 确保引擎加载完成后缓存失效
        invalidateSourceDisplayCache()
    }

    /// 将内存中的 type=2 站源同步到 SQLite
    private func syncZhanyuanSitesToDatabase() {
        let zhanSites = self.allSites.filter { $0.type == 2 && $0.api?.isEmpty == false }
        guard !zhanSites.isEmpty else {
            print("[SpiderManager] 无 type=2 站源需要同步到 SQLite")
            return
        }

        // 获取当前激活的订阅源 URL 作为 dyurl
        let dyurl = subManager.activeURL ?? ""
        let now = Int64(Date().timeIntervalSince1970)
        let zhanyuanSites: [ZhanyuanSite] = zhanSites.compactMap { site in
            guard let api = site.api, !api.isEmpty else { return nil }
            let extJSON = site.ext ?? "{}"
            if let data = extJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return ZhanyuanSite(
                    name: json["name"] as? String ?? site.name,
                    searchUrl: json["searchUrl"] as? String ?? api,
                    searchUA: json["searchUA"] as? String ?? "",
                    playUA: json["playUA"] as? String ?? "",
                    websearchurl: json["websearchurl"] as? String ?? "",
                    searchname: json["searchname"] as? String ?? "",
                    searchid: json["searchid"] as? String ?? "",
                    searchpic: json["searchpic"] as? String ?? "",
                    searchstarr: json["searchstarr"] as? String ?? "",
                    detaillist: json["detaillist"] as? String ?? "",
                    detailxl: json["detailxl"] as? String ?? "",
                    detailjs: json["detailjs"] as? String ?? "",
                    detailjsurl: json["detailjsurl"] as? String ?? "",
                    isActive: true,
                    updatedAt: now,
                    dyurl: dyurl
                )
            }
            return ZhanyuanSite(
                name: site.name,
                searchUrl: api,
                searchUA: "",
                playUA: "",
                websearchurl: "",
                searchname: "",
                searchid: "",
                searchpic: "",
                searchstarr: "",
                detaillist: "",
                detailxl: "",
                detailjs: "",
                detailjsurl: "",
                isActive: true,
                updatedAt: now,
                dyurl: dyurl
            )
        }

        print("[SpiderManager] 强制同步 \(zhanyuanSites.count) 个 zhanyuan 站点到 SQLite")
        DatabaseManager.shared.saveZhanyuanSites(zhanyuanSites, dyurl: dyurl)
    }

    // MARK: - 远程默认源 JS 蜘蛛引擎加载

    /// 从远程默认源 manifest URL 推导 base URL
    /// 例如：https://raw.githubusercontent.com/vbox-Ai/api/main/sources/manifest.json
    /// ->   https://raw.githubusercontent.com/vbox-Ai/api/main/sources/
    private func remoteSpiderBaseURL() -> String? {
        let manifestURL = RemoteSourceConfigManager.shared.defaultManifestURL
        guard let url = URL(string: manifestURL) else {
            print("[SpiderManager] ⚠️ 无法解析远程默认源 manifest URL: \(manifestURL)")
            return nil
        }
        // 删除最后一个路径组件（manifest.json），得到所在目录
        let baseURL = url.deletingLastPathComponent().absoluteString
        print("[SpiderManager] 远程蜘蛛源 base URL: \(baseURL)")
        return baseURL
    }

    /// 加载远程默认源 JS 蜘蛛引擎
    /// - Parameters:
    ///   - baseURL: 远程源基础 URL（用于解析相对路径，仅作为 fallback）
    ///   - sites: 蜘蛛站点配置列表
    /// 优先从本地缓存读取 JS 代码，缓存不存在时 fallback 到网络下载
    /// 使用 TaskGroup 并发加载多个引擎
    private func loadRemoteSpiderEngines(baseURL: String, sites: [SiteConfig]) async {
        guard !sites.isEmpty else { return }

        // 收集需要加载的 JS 蜘蛛站点 + Python 蜘蛛站点 + Node 托管蜘蛛站点
        var jsSitesToLoad: [(site: SiteConfig, resolvedURL: String)] = []
        var pySitesToLoad: [(site: SiteConfig, resolvedURL: String)] = []
        var nodeSitesToLoad: [SiteConfig] = []

        for site in sites {
            let mode = resolveSiteMode(site: site)

            // 🟢 Node 托管蜘蛛：直接注册 NodeSpiderEngine（不下载 JS、不占 20 引擎上限）。
            //    即使 api 为空（仅 group:"node" / nodejs_ 前缀标记），也允许注册。
            if mode == .node {
                nodeSitesToLoad.append(site)
                continue
            }
            guard let api = site.api, !api.isEmpty else { continue }

            // 🐍 Python Spider
            if mode == .pythonSpider {
                let resolvedURL = resolveSpiderURL(api: api, baseURL: baseURL, site: site)
                if let url = resolvedURL {
                    pySitesToLoad.append((site: site, resolvedURL: url))
                }
                continue
            }
            guard mode == .jsSpider else { continue }

            // 解析相对路径或绝对 URL
            let resolvedURL = resolveSpiderURL(api: api, baseURL: baseURL, site: site)
            if let url = resolvedURL {
                jsSitesToLoad.append((site: site, resolvedURL: url))
            }
        }

        print("[SpiderManager] 远程默认源待加载 JS 蜘蛛: \(jsSitesToLoad.count) 个, Python 蜘蛛: \(pySitesToLoad.count) 个")
        AppLogStore.shared.info(.spider, "[SpiderManager] 📋 远程源待加载: \(jsSitesToLoad.count) JS + \(pySitesToLoad.count) Python")
        for item in pySitesToLoad {
            let key = item.site.key.isEmpty ? item.site.name : item.site.key
            AppLogStore.shared.info(.spider, "[SpiderManager] 📋 Python 蜘蛛待加载: \(item.site.name) (key=\(key))")
        }

        // 限制最多加载 JS 蜘蛛（避免内存）；Node 托管蜘蛛不占此上限（S2-3 豁免）
        let maxRemoteSpiders = 20
        let jsSitesToProcess = Array(jsSitesToLoad.prefix(maxRemoteSpiders))

        // 🟢 注册 Node 托管蜘蛛引擎（轻量桥接，不下载 JS，不受 20 上限约束）
        if !nodeSitesToLoad.isEmpty {
            for site in nodeSitesToLoad {
                registerNodeEngine(for: site)
            }
            AppLogStore.shared.info(.spider, "[SpiderManager] ✅ 远程源 Node 蜘蛛注册完成: \(nodeSitesToLoad.count) 个")
        }

        // 使用 TaskGroup 并发加载多个 JS 引擎
        await withTaskGroup(of: (key: String, success: Bool).self) { group in
            for item in jsSitesToProcess {
                let key = item.site.key.isEmpty ? item.site.name : item.site.key

                // 已加载则跳过
                guard engines[key] == nil else {
                    print("[SpiderManager] 远程蜘蛛已存在，跳过: \(item.site.name) (\(key))")
                    continue
                }

                group.addTask {
                    let success = await self.loadSingleRemoteSpider(site: item.site, resolvedURL: item.resolvedURL, baseURL: baseURL)
                    return (key: key, success: success)
                }
            }

            var loaded = 0
            var failed = 0
            for await result in group {
                if result.success {
                    loaded += 1
                } else {
                    failed += 1
                }
            }
            print("[SpiderManager] 远程默认源 JS 蜘蛛加载完成: 成功 \(loaded) 个，失败 \(failed) 个")
        }

        // 🐍 加载 Python 蜘蛛（并发）
        // 网络下载并发执行（不受 GIL 限制），init() 仍由 GIL 串行，但整体仍快 50%+
        if !pySitesToLoad.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 远程源 Python 蜘蛛待加载: \(pySitesToLoad.count) 个（并发）")
            await withTaskGroup(of: (key: String, success: Bool).self) { group in
                for item in pySitesToLoad {
                    let key = item.site.key.isEmpty ? item.site.name : item.site.key
                    if engines[key] != nil { continue }
                    group.addTask {
                        let success = await self.loadSinglePythonSpider(site: item.site, resolvedURL: item.resolvedURL)
                        return (key: key, success: success)
                    }
                }
                for await result in group {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 远程源 Python 蜘蛛[\(result.success ? "✅" : "❌")] \(result.key)")
                }
            }
        }
    }

    /// 解析蜘蛛脚本 URL（相对路径或绝对URL）
    private func resolveSpiderURL(api: String, baseURL: String, site: SiteConfig) -> String? {
        if api.hasPrefix("./") || (!api.hasPrefix("http://") && !api.hasPrefix("https://") && (api.hasSuffix(".js") || api.hasSuffix(".py"))) {
            let cleanPath = api.hasPrefix("./") ? String(api.dropFirst(2)) : api
            if let base = URL(string: baseURL) {
                return base.appendingPathComponent(cleanPath).standardized.absoluteString
            } else {
                print("[SpiderManager] ⚠️ 远程蜘蛛 baseURL 无效，跳过: \(site.name)")
                return nil
            }
        } else if api.hasPrefix("http://") || api.hasPrefix("https://") {
            return api
        } else {
            print("[SpiderManager] 跳过无法识别的远程蜘蛛 URL: \(site.name) api=\(api.prefix(60))")
            return nil
        }
    }

    /// 加载单个远程蜘蛛（优先本地缓存，fallback 网络）
    private func loadSingleRemoteSpider(site: SiteConfig, resolvedURL: String, baseURL: String) async -> Bool {
        let key = site.key.isEmpty ? site.name : site.key

        do {
            // 1. 优先从本地缓存读取主 JS 代码
            var jsCode: String?
            if let cachedCode = RemoteSourceConfigManager.shared.cachedSpiderJSContent(forKey: key) {
                jsCode = cachedCode
                print("[SpiderManager] 📁 从本地缓存加载蜘蛛: \(site.name) (\(key))")
            } else {
                // 缓存不存在，fallback 到网络下载
                print("[SpiderManager] 🌐 本地缓存不存在，从网络下载: \(site.name) (\(key))")
                guard let url = URL(string: resolvedURL) else { return false }
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                if let code = String(data: data, encoding: .utf8),
                   code.count > 200,
                   (code.contains("function ") || code.contains("var ") || code.contains("spider")) {
                    jsCode = code
                } else {
                    print("[SpiderManager] ⚠️ 远程蜘蛛内容无效: \(site.name)")
                    return false
                }
            }

            guard let finalJSCode = jsCode else { return false }

            // 1.5 特殊处理: TG搜索蜘蛛 - 注入用户自定义配置
            // 在主脚本前 prepend 配置 JS，设置全局变量 __TG_CONFIG__
            var codeToLoad = finalJSCode
            if key == "js_TG搜索" {
                let configJS = TGSearchConfigStore.shared.generateConfigJS()
                if !configJS.isEmpty {
                    codeToLoad = configJS + "\n" + finalJSCode
                    print("[SpiderManager] 🔧 注入TG搜索配置: \(configJS.prefix(100))...")
                }
            }

            // 2. 加载 JS 框架到引擎
            try await loadSpiderEngine(jsCode: codeToLoad, key: key)

            // 3. 加载 ext 字段（优先本地缓存）
            // ext 加载失败不应影响主框架的成功状态
            if let ext = site.ext, !ext.isEmpty {
                let extTrimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    try await loadSpiderExt(site: site, key: key, ext: extTrimmed, baseURL: baseURL)
                } catch {
                    print("[SpiderManager] ⚠️ 远程蜘蛛 ext 加载失败（不影响主框架）: \(site.name) - \(error.localizedDescription)")
                }
            }

            print("[SpiderManager] ✅ 远程蜘蛛加载成功: \(site.name) (\(key))")
            return true
        } catch {
            print("[SpiderManager] 远程蜘蛛加载失败: \(site.name) - \(error.localizedDescription)")
            return false
        }
    }

    /// 🐍 加载单个 Python 蜘蛛（下载 .py 到本地 → 创建 PythonSpiderEngine → 注册）
    private func loadSinglePythonSpider(site: SiteConfig, resolvedURL: String) async -> Bool {
        let key = site.key.isEmpty ? site.name : site.key
        AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 开始加载 Python 蜘蛛: \(site.name) (key=\(key))")
        AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 脚本 URL: \(resolvedURL)")
        do {
            // 1. 下载 .py 脚本
            guard let url = URL(string: resolvedURL) else {
                AppLogStore.shared.info(.spider, "[SpiderManager] ❌ Python 蜘蛛 URL 无效: \(resolvedURL)")
                return false
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            
            if let httpResp = response as? HTTPURLResponse {
                AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 HTTP \(httpResp.statusCode), 收到 \(data.count) 字节")
            }
            
            guard let pyCode = String(data: data, encoding: .utf8),
                  pyCode.count > 100,
                  pyCode.contains("class Spider") || pyCode.contains("class  Spider") else {
                AppLogStore.shared.info(.spider, "[SpiderManager] ❌ Python 蜘蛛内容无效或不含 class Spider: \(site.name) (长度=\(data.count))")
                return false
            }

            // 2. 保存 .py 到本地 Documents（PythonSpiderEngine 需要脚本路径）
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let pyDir = docs.appendingPathComponent("remote_sources/spider_python", isDirectory: true)
            try FileManager.default.createDirectory(at: pyDir, withIntermediateDirectories: true)
            let safeKey = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            let pyURL = pyDir.appendingPathComponent("\(safeKey).py")
            try data.write(to: pyURL, options: .atomic)
            AppLogStore.shared.info(.spider, "[SpiderManager] 🐍 脚本已保存: \(pyURL.lastPathComponent)")

            // 3. 创建 PythonSpiderEngine（就在主线程/当前 actor 创建，模拟器不阻塞太多）
            let engine = PythonSpiderEngine(scriptPath: pyURL.path, key: key)

            // ★ 设置 onLog 回调 → 写入 AppLogStore (否则引擎内部日志丢失)
            engine.onLog = { msg in
                AppLogStore.shared.info(.spider, "[\(key)] \(msg)")
            }

            // 4. 等待 Python 引擎异步初始化完成（最多等待 25 秒）
            // PythonSpiderEngine.init() 在后台线程异步初始化 (Python 解释器 + 脚本 init)
            // 这里轮询等待 _isSpiderReady 变为 true
            // 优化: 轮询间隔从 500ms 降到 50ms，减少就绪后的额外等待延迟
            var waitCount = 0
            while !engine.isSpiderReady && waitCount < 500 {  // 500 × 50ms = 25s 超时
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                waitCount += 1
            }
            if engine.isSpiderReady {
                AppLogStore.shared.info(.spider, "[SpiderManager] ✅ Python 引擎就绪 (等待 \(waitCount * 50)ms): \(site.name)")
            }
            guard engine.isSpiderReady else {
                AppLogStore.shared.info(.spider, "[SpiderManager] ❌ Python 引擎初始化超时(25s): \(site.name) (isSpiderReady=false)")
                return false
            }

            // 5. 注册进 engines
            engines[key] = engine
            if !subscribedSites.contains(key) { subscribedSites.append(key) }
            engineTypes[key] = .javaScriptCore
            AppLogStore.shared.info(.spider, "[SpiderManager] ✅ Python 蜘蛛就绪: \(site.name) (\(key))")
            return true
        } catch {
            AppLogStore.shared.info(.spider, "[SpiderManager] ❌ Python 蜘蛛加载失败: \(site.name) - \(error.localizedDescription)")
            return false
        }
    }

    /// 加载蜘蛛 ext（优先本地缓存，fallback 网络）
    private func loadSpiderExt(site: SiteConfig, key: String, ext: String, baseURL: String) async throws {
        // 优先从本地缓存读取 ext
        if let cachedExt = RemoteSourceConfigManager.shared.cachedSpiderJSContent(forKey: "\(key)_ext") {
            if let engine = engines[key] {
                try engine.loadScript(cachedExt)
                print("[SpiderManager] ✅ 远程蜘蛛 ext 从缓存加载成功: \(site.name)")
            }
            return
        }

        let extTrimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        if extTrimmed.hasPrefix("http://") || extTrimmed.hasPrefix("https://") {
            print("[SpiderManager] 远程蜘蛛加载 ext URL: \(site.name) - \(extTrimmed.prefix(80))")
            do {
                let extData = try await downloadRawData(url: extTrimmed)
                if let extCode = String(data: extData, encoding: .utf8), extCode.count > 50 {
                    if let engine = engines[key] {
                        try engine.loadScript(extCode)
                        print("[SpiderManager] ✅ 远程蜘蛛 ext URL 加载成功: \(site.name)")
                    }
                }
            } catch {
                print("[SpiderManager] 远程蜘蛛 ext URL 加载失败: \(site.name) - \(error.localizedDescription)")
            }
        } else if extTrimmed.hasPrefix("./") || extTrimmed.hasSuffix(".js") {
            let cleanExtPath = extTrimmed.hasPrefix("./") ? String(extTrimmed.dropFirst(2)) : extTrimmed
            if let base = URL(string: baseURL) {
                let extFullURL = base.appendingPathComponent(cleanExtPath).standardized.absoluteString
                print("[SpiderManager] 远程蜘蛛加载 ext 相对路径: \(site.name) - \(extFullURL.prefix(80))")
                do {
                    let extData = try await downloadRawData(url: extFullURL)
                    if let extCode = String(data: extData, encoding: .utf8), extCode.count > 50 {
                        if let engine = engines[key] {
                            try engine.loadScript(extCode)
                            print("[SpiderManager] ✅ 远程蜘蛛 ext 相对路径加载成功: \(site.name)")
                        }
                    }
                } catch {
                    print("[SpiderManager] 远程蜘蛛 ext 相对路径加载失败: \(site.name) - \(error.localizedDescription)")
                }
            }
        } else if extTrimmed.contains("function ") || extTrimmed.contains("var ") || extTrimmed.contains("let ") || extTrimmed.contains("const ") {
            print("[SpiderManager] 远程蜘蛛加载内联 ext JS: \(site.name)")
            if let engine = engines[key] {
                try engine.loadScript(extTrimmed)
                print("[SpiderManager] ✅ 远程蜘蛛内联 ext 加载成功: \(site.name)")
            }
        } else {
            print("[SpiderManager] 远程蜘蛛 ext 不是 JS 代码，可能是配置: \(site.name) - \(extTrimmed.prefix(60))")
        }
    }

    /// 加载蜘蛛 JS 到引擎 — 支持双引擎自动回退（JSC 优先，失败时尝试 QuickJS）
    private func loadSpiderEngine(jsCode: String, key: String = "builtin", preferredEngine: SpiderEngineType = .javaScriptCore) async throws {
        // 先尝试首选引擎
        let enginesToTry: [SpiderEngineType] = preferredEngine == .javaScriptCore
            ? [.javaScriptCore, .quickJS]
            : [.quickJS, .javaScriptCore]
        
        // 安全移除旧引擎，避免在创建新引擎过程中被意外释放
        // 将旧引擎保存到局部变量，延长其生命周期至函数末尾
        let oldEngine = engines.removeValue(forKey: key)
        
        var lastError: Error?
        
        for engineType in enginesToTry {
            do {
                let engine = try await loadSpiderEngineWithType(jsCode: jsCode, key: key, engineType: engineType)
                engines[key] = engine
                engineTypes[key] = engineType
                if !subscribedSites.contains(key) { subscribedSites.append(key) }
                engineError = nil
                print("[SpiderManager] ✅ 蜘蛛就绪 [\(engineType.displayName)]: \(key)")
                return
            } catch {
                lastError = error
                print("[SpiderManager] ⚠️ \(engineType.displayName) 加载失败，尝试下一个引擎: \(error.localizedDescription)")
            }
        }
        
        let err = "蜘蛛注册失败 (\(key)): \(lastError?.localizedDescription ?? "所有引擎均失败")"
        engineError = err
        throw JSError(message: err)
    }
    
    /// 使用指定引擎类型加载蜘蛛 — 重活在后台线程执行
    private func loadSpiderEngineWithType(jsCode: String, key: String, engineType: SpiderEngineType) async throws -> SpiderEngineProtocol {
        // 把引擎创建和预热放到后台线程，避免阻塞主线程 UI
        let engine = try await Self.buildSpiderEngineOffMain(
            jsCode: jsCode,
            extCode: nil,
            engineType: engineType,
            key: key
        )
        
        // 回到主线程设置 UI 相关的日志回调
        engine.onLog = { [weak self] msg in
            print("[SpiderEngine|\(key)|\(engineType.displayName)] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor [weak self] in
                    self?.engineError = msg
                }
            }
        }
        
        return engine
    }

    /// 将 JS 引擎创建和预热明确放到后台队列，避免 MainActor 执行重计算。
    private nonisolated static func buildSpiderEngineOffMain(
        jsCode: String,
        extCode: String?,
        engineType: SpiderEngineType,
        key: String
    ) async throws -> SpiderEngineProtocol {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let engine = try SpiderEngineFactory.buildEngine(
                        jsCode: jsCode,
                        extCode: extCode,
                        engineType: engineType,
                        key: key
                    )
                    continuation.resume(returning: engine)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func downloadRawData(url: String) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw JSError(message: "无效URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        return data
    }

    private func loadSiteEngine(site: SiteConfig, jsURL: String) async throws {
        // 尝试 JSC，失败回退到 QuickJS
        for engineType in [SpiderEngineType.javaScriptCore, .quickJS] {
            do {
                // 先下载脚本，再在后台创建引擎
                let script = try await downloadScript(url: jsURL)
                let engine = try await Self.buildSpiderEngineOffMain(
                    jsCode: script,
                    extCode: nil,
                    engineType: engineType,
                    key: site.key
                )

                engine.onLog = { [weak self] msg in
                    print("[SpiderEngine|\(site.key)|\(engineType.displayName)] \(msg)")
                    if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                        Task { @MainActor [weak self] in
                            self?.engineError = msg
                        }
                    }
                }

                engines[site.key] = engine
                engineTypes[site.key] = engineType
                if !subscribedSites.contains(site.key) { subscribedSites.append(site.key) }
                print("[SpiderManager] ✅ ext站点 [\(engineType.displayName)]: \(site.name)")
                return
            } catch {
                print("[SpiderManager] ⚠️ ext站点 \(engineType.displayName) 失败: \(site.name): \(error)")
            }
        }
        print("[SpiderManager] ❌ ext站点全部引擎失败: \(site.name)")
    }

    private func downloadScript(url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw JSError(message: "无效脚本URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        guard let script = String(data: data, encoding: .utf8) else {
            throw JSError(message: "脚本编码错误")
        }
        return script
    }

    func loadHomeData() async {
        var videos: [VodItem] = []

        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ========== 开始加载首页数据 ==========")
        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 可用蜘蛛引擎: \(engines.count)个 [\(engines.keys.joined(separator: ", "))]")
        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 可用API站点: \(allSites.filter { $0.api?.hasPrefix("http") ?? false }.count)个")

        // 1. 尝试从蜘蛛引擎获取首页数据
        if !engines.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 尝试从蜘蛛引擎获取首页数据...")
            for (key, engine) in engines {
                let isPython = engine is PythonSpiderEngine
                do {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 调用引擎[\(key)] \(isPython ? "🐍 Python" : "JS") homeContent...")
                    let result = try engine.callHomeContent()
                    let catCount = result.class?.count ?? 0
                    let listCount = result.list?.count ?? 0
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 引擎[\(key)] 返回: \(catCount)分类, \(listCount)视频")

                    if let categories = result.class, !categories.isEmpty {
                        self.categories = categories
                        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ✅ 分类已设置: \(categories.map { $0.typeName }.joined(separator: ", "))")
                    }

                    if let list = result.list, !list.isEmpty {
                        for var item in list {
                            item.engineKey = key
                        }
                        videos.append(contentsOf: list)
                        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ✅ 首页[\(key)]: \(list.count)视频")
                        if videos.count >= 20 {
                            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 蜘蛛数据已足够，停止加载")
                            break
                        }
                    }
                } catch {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ❌ 首页[\(key)]失败: \(error.localizedDescription)")
                }
            }
        } else {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ⚠️ 没有可用的蜘蛛引擎")
        }

        // 2. 蜘蛛没数据，用热门关键词走 nativeSearch 填充首页
        if videos.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ⚠️ 蜘蛛首页为空，使用热门关键词通过nativeSearch拉取数据...")
            let hotKeywords = [
                "热播", "电影", "电视剧", "综艺", "动漫", "2026", "最新",
                "热门", "高分", "经典", "动作", "喜剧", "爱情", "科幻",
                "悬疑", "犯罪", "战争", "古装", "现代", "都市"
            ]

            for (index, kw) in hotKeywords.enumerated() {
                let results = await nativeSearch(keyword: kw)
                AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 热门词[\(index+1)/\(hotKeywords.count)] \"\(kw)\": \(results.count)条")
                videos.append(contentsOf: results)

                if videos.count >= 50 {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ✅ 已收集\(videos.count)条视频，停止搜索")
                    break
                }

                // 避免请求过快
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒延迟
            }
        } else {
            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ✅ 蜘蛛数据已收集\(videos.count)条")
        }

        AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 去重已关闭，当前结果: \(videos.count)条")

        await MainActor.run {
            self.homeVideos = videos
            if self.categories.isEmpty {
                AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ⚠️ 分类为空, 使用默认分类")
                self.categories = [
                    VodCategory(typeId: "movie", typeName: "电影"),
                    VodCategory(typeId: "tv", typeName: "电视剧"),
                    VodCategory(typeId: "variety", typeName: "综艺"),
                    VodCategory(typeId: "anime", typeName: "动漫"),
                    VodCategory(typeId: "documentary", typeName: "纪录片"),
                    VodCategory(typeId: "live", typeName: "直播")
                ]
            } else {
                AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ✅ 使用引擎返回的分类: \(categories.count)个")
            }
            AppLogStore.shared.info(.spider, "[SpiderManager] 🏠 ========== 首页数据加载完成: \(videos.count)视频, \(categories.count)分类 ==========")
        }
    }

    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        var allResults: [VodItem] = []

        AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 开始搜索: \"\(keyword)\" (pg=\(pg))")
        AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 已注册引擎: \(engines.count) 个 [\(engines.keys.joined(separator: ", "))]")

        // 先尝试加载内置蜘蛛
        if engines.isEmpty {
            AppLogStore.shared.info(.spider, "[SpiderManager] ⚠️ 引擎为空, 尝试加载内置蜘蛛...")
            await loadBuiltinEngineIfNeeded()
        }

        // 1. 腾讯视频原生搜索（不走 JS 引擎）
        let txItems = await TencentVideoNativeSpider.shared.search(keyword: keyword, pg: pg)
        if !txItems.isEmpty {
            allResults.append(contentsOf: txItems)
            AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 腾讯原生搜索: \(txItems.count) 条")
        }

        // 2. 蜘蛛引擎搜索（跳过腾讯，已走原生）
        let engineKeys = engines.keys.sorted()
        for key in engineKeys {
            guard key != TencentVideoNativeSpider.siteKey else { continue }
            let engine = engines[key]!
            let isPython = engine is PythonSpiderEngine
            AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 搜索引擎[\(key)] \(isPython ? "🐍 Python" : "JS") ...")
            do {
                let result = try engine.callSearchContent(keyword: keyword, pg: pg)
                if let items = result.list, !items.isEmpty {
                    for var item in items {
                        if item.vodRemarks == nil || item.vodRemarks?.isEmpty == true {
                            item.vodRemarks = key
                        }
                        item.engineKey = key
                        allResults.append(item)
                    }
                    AppLogStore.shared.info(.spider, "[SpiderManager] ✅ 搜索[\(key)]: \(items.count) 条")
                } else {
                    AppLogStore.shared.info(.spider, "[SpiderManager] ⚪ 搜索[\(key)]: 0 条 (空结果)")
                }
            } catch {
                engineError = "搜索出错: \(error.localizedDescription)"
                AppLogStore.shared.info(.spider, "[SpiderManager] ❌ 搜索失败[\(key)]: \(error.localizedDescription)")
            }
        }

        // 3. 原生 HTTP 多源搜索（遍历订阅源站点 + 硬编码兜底）
        AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 开始原生 HTTP 多源搜索...")
        let nativeResults = await nativeSearch(keyword: keyword)
        for item in nativeResults {
            allResults.append(item)
        }
        AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 原生 HTTP 搜索: \(nativeResults.count) 条")

        AppLogStore.shared.info(.spider, "[SpiderManager] 🔍 搜索完成: 共 \(allResults.count) 条 (引擎+原生)")
        return allResults.isEmpty ? nativeResults : allResults
    }

    /// 分类筛选参数（全部可选，nil 表示不筛选）
    struct CategoryFilterParams {
        var `class`: String?   // 类型/题材，如 "动作" "喜剧"
        var area: String?      // 地区，如 "大陆" "美国"
        var year: String?      // 年份，如 "2024"
        var sort: String?      // 排序，如 "hits" "addtime" "score"
    }

    /// 通过订阅源获取分类内容（调用 TVBox 标准的 ac=list 接口）
    /// - Parameters:
    ///   - categoryTypeId: 分类 ID
    ///   - page: 页码
    ///   - filters: 多维筛选参数（类型/地区/年份/排序），全部为 nil 时等价于原方法
    func fetchCategoryContent(categoryTypeId: String, page: Int = 1, filters: CategoryFilterParams? = nil) async -> [VodItem] {
        // 先尝试蜘蛛引擎的 categoryContent
        var results: [VodItem] = []

        // 构造筛选查询串
        let filterQuery = Self.buildFilterQuery(filters)

        AppLogStore.shared.info(.spider, "[SpiderManager] 📂 分类请求: tid=\(categoryTypeId), pg=\(page), 引擎数=\(engines.count)")

        // 1. 尝试蜘蛛引擎
        for (key, engine) in engines {
            let isPython = engine is PythonSpiderEngine
            do {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📂 引擎[\(key)] \(isPython ? "🐍 Python" : "JS") categoryContent...")
                let result = try engine.callCategoryContent(tid: categoryTypeId, pg: page, extend: "{}")
                if let list = result.list, !list.isEmpty {
                    for var item in list {
                        if item.vodRemarks == nil || item.vodRemarks?.isEmpty == true {
                            item.vodRemarks = key
                        }
                        item.engineKey = key
                        results.append(item)
                    }
                    AppLogStore.shared.info(.spider, "[SpiderManager] 📂 ✅ 分类[\(categoryTypeId)]引擎[\(key)]: \(list.count)条")
                } else {
                    AppLogStore.shared.info(.spider, "[SpiderManager] 📂 ⚪ 分类[\(categoryTypeId)]引擎[\(key)]: 0条")
                }
            } catch {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📂 ❌ 引擎分类失败[\(key)]: \(error.localizedDescription)")
            }
        }
        
        // 2. 原生 HTTP 兜底 - 调用 TVBox API 站点
        let apiSites = allSites.filter { site in
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }
        AppLogStore.shared.info(.spider, "[SpiderManager] 📂 原生API站点: \(apiSites.count)个")
        for site in apiSites {
            guard let api = site.api else { continue }
            let baseAPI = api.hasSuffix("/") ? String(api.dropLast()) : api
            let urlStr = "\(baseAPI)?ac=list&t=\(categoryTypeId)&pg=\(page)\(filterQuery)"
            guard let url = URL(string: urlStr) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["list"] as? [[String: Any]] {
                    let items = list.compactMap { dict -> VodItem? in
                        guard let vodName = dict["vod_name"] as? String ?? dict["name"] as? String else { return nil }
                        let vodId = dict["vod_id"] as? String ?? dict["id"] as? String ?? UUID().uuidString
                        return VodItem(
                            vodId: vodId,
                            vodName: vodName,
                            vodPic: dict["vod_pic"] as? String ?? dict["pic"] as? String ?? "",
                            vodRemarks: dict["vod_remarks"] as? String ?? dict["remarks"] as? String ?? site.name,
                            vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
                            vodArea: dict["vod_area"] as? String,
                            vodDirector: dict["vod_director"] as? String,
                            vodActor: dict["vod_actor"] as? String,
                            vodContent: dict["vod_content"] as? String
                        )
                    }
                    results.append(contentsOf: items)
                    AppLogStore.shared.info(.spider, "[SpiderManager] 📂 原生[\(site.name)]: \(items.count)条")
                }
            } catch {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📂 ❌ 原生分类失败[\(site.name)]: \(error.localizedDescription)")
            }
        }

        // 3. 网盘 CMS 源分类内容
        let cloudSites = loadCloudSitesFromJSONConfig()
        for site in cloudSites where site.type == .cms {
            let api = "\(site.detailBase)/api.php/provide/vod"
            let urlStr = "\(api)?ac=list&t=\(categoryTypeId)&pg=\(page)\(filterQuery)"
            guard let url = URL(string: urlStr) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["list"] as? [[String: Any]] {
                    let items = list.compactMap { dict -> VodItem? in
                        guard let vodName = dict["vod_name"] as? String ?? dict["name"] as? String else { return nil }
                        let vodId = dict["vod_id"] as? String ?? dict["id"] as? String ?? UUID().uuidString
                        return VodItem(
                            vodId: vodId,
                            vodName: vodName,
                            vodPic: dict["vod_pic"] as? String ?? dict["pic"] as? String ?? "",
                            vodRemarks: dict["vod_remarks"] as? String ?? dict["remarks"] as? String ?? site.name,
                            vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
                            vodArea: dict["vod_area"] as? String,
                            vodDirector: dict["vod_director"] as? String,
                            vodActor: dict["vod_actor"] as? String,
                            vodContent: dict["vod_content"] as? String
                        )
                    }
                    results.append(contentsOf: items)
                    AppLogStore.shared.info(.spider, "[SpiderManager] 📂 网盘CMS[\(site.name)]: \(items.count)条")
                }
            } catch {
                AppLogStore.shared.info(.spider, "[SpiderManager] 📂 ❌ 网盘CMS分类失败[\(site.name)]: \(error.localizedDescription)")
            }
        }

        AppLogStore.shared.info(.spider, "[SpiderManager] 📂 分类完成: tid=\(categoryTypeId), 共\(results.count)条")
        return results
    }

    // MARK: - 筛选参数工具

    /// 将筛选参数转换为 URL 查询串（已含 & 前缀，空时返回 ""）
    private static func buildFilterQuery(_ filters: CategoryFilterParams?) -> String {
        guard let filters = filters else { return "" }
        var parts: [String] = []
        if let cls = filters.class, !cls.isEmpty, cls != "全部" {
            if let encoded = cls.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                parts.append("class=\(encoded)")
            }
        }
        if let area = filters.area, !area.isEmpty, area != "全部" {
            if let encoded = area.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                parts.append("area=\(encoded)")
            }
        }
        if let year = filters.year, !year.isEmpty, year != "全部" {
            if let encoded = year.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                parts.append("year=\(encoded)")
            }
        }
        if let sort = filters.sort, !sort.isEmpty, sort != "全部" {
            parts.append("sort=\(sort)")
        }
        return parts.isEmpty ? "" : "&" + parts.joined(separator: "&")
    }

    /// 自适应筛选维度
    struct AdaptiveFilterOptions {
        var `class`: [String] = []   // 类型/题材选项
        var area: [String] = []      // 地区选项
        var year: [String] = []      // 年份选项
        var sort: [String] = ["全部", "hits", "addtime", "score", "rand"] // 排序选项（固定）

        /// 是否有任何可用筛选维度
        var isEmpty: Bool {
            `class`.isEmpty && area.isEmpty && year.isEmpty
        }
    }

    /// 从一组 VodItem 中自适应提取可用的筛选选项（类型/地区/年份）
    /// - Parameter items: 视频列表
    /// - Returns: 去重并排序后的各维度选项（"全部"在首位）
    static func extractAdaptiveFilters(from items: [VodItem]) -> AdaptiveFilterOptions {
        var classSet = Set<String>()
        var areaSet = Set<String>()
        var yearSet = Set<String>()

        for item in items {
            // 地区
            if let area = item.vodArea, !area.isEmpty {
                // 多个地区用 / 或 , 分隔时拆分
                let parts = area.components(separatedBy: CharacterSet(charactersIn: "/,，、"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                parts.forEach { areaSet.insert($0) }
            }
            // 年份
            if let year = item.vodYear, !year.isEmpty {
                // 提取纯年份数字
                let digits = year.filter { $0.isNumber }
                if digits.count >= 4 {
                    let start = digits.startIndex
                    let end = digits.index(start, offsetBy: 4)
                    yearSet.insert(String(digits[start..<end]))
                }
            }
        }

        // 排序：年份降序，地区升序，类型升序
        let sortedYears = Array(yearSet).sorted(by: >)
        let sortedAreas = Array(areaSet).sorted()
        let sortedClasses = Array(classSet).sorted()

        // 都加上 "全部" 前缀
        var opts = AdaptiveFilterOptions()
        if !sortedClasses.isEmpty { opts.class = ["全部"] + sortedClasses }
        if !sortedAreas.isEmpty { opts.area = ["全部"] + sortedAreas }
        if !sortedYears.isEmpty { opts.year = ["全部"] + sortedYears }

        return opts
    }

    /// 获取单个源的分类 + 筛选内容（用于 SourceDiscoveryView 的单源发现页）
    /// - Parameters:
    ///   - source: 源配置
    ///   - categoryTypeId: 分类 ID
    ///   - page: 页码
    ///   - filters: 筛选参数
    /// - Returns: 视频列表（仅该源的数据）
    func fetchSingleSourceCategoryContent(source: SourceDisplayItem, categoryTypeId: String, page: Int = 1, filters: CategoryFilterParams? = nil) async -> [VodItem] {
        let filterQuery = Self.buildFilterQuery(filters)

        switch source.category {
        case .api, .cloudCMS, .zhanyuan:
            guard let api = source.api else { return [] }
            let baseAPI = api.hasSuffix("/") ? String(api.dropLast()) : api
            let urlStr = "\(baseAPI)?ac=list&t=\(categoryTypeId)&pg=\(page)\(filterQuery)"
            guard let url = URL(string: urlStr) else { return [] }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 10
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: req)

                guard let httpResp = response as? HTTPURLResponse,
                      (200...299).contains(httpResp.statusCode) else { return [] }

                let raw = try JSONDecoder().decode(CategoryContentResult.self, from: data)
                return raw.list ?? []
            } catch {
                print("[SpiderManager] singleSourceCategory[\(source.name)] 失败: \(error.localizedDescription)")
                return []
            }

        case .jsSpider:
            guard let key = source.engineKey, let engine = engines[key] else {
                print("[SpiderManager] jsSpiderCategory[\(source.name)] 引擎未找到: engineKey=\(source.engineKey ?? "nil")")
                return []
            }
            do {
                print("[SpiderManager] jsSpiderCategory[\(source.name)] 请求分类: tid=\(categoryTypeId), pg=\(page)")
                let result = try engine.callCategoryContent(tid: categoryTypeId, pg: page, extend: "{}")
                var list = result.list ?? []
                for i in 0..<list.count { list[i].engineKey = key }
                print("[SpiderManager] jsSpiderCategory[\(source.name)] 返回 \(list.count) 条数据")
                return list
            } catch {
                print("[SpiderManager] jsSpiderCategory[\(source.name)] 失败: \(error)")
                return []
            }

        case .cloudForum, .cloudSPA:
            return []
        }
    }

    /// 流式搜索 — 每个站点搜完立刻回调，不等全部完成
    func searchStream(keyword: String, onBatch: @escaping ([VodItem]) -> Void, onLog: ((String) -> Void)? = nil) async {
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let log = onLog ?? { print("[searchStream] \($0)") }
        log("====== 开始流式搜索: \(keyword) (\(Set(self.allSites.compactMap { $0.name }).count) 源) ======")

        // 写入搜索历史
        DatabaseManager.shared.addSearchHistory(keyword: keyword)

        // ========== 五路并发搜索（网盘 + 站源 + API切片 + JS蜘蛛 + Python蜘蛛 同时发起） ==========
        // 每一路独立通过 onBatch 实时回调，互不阻塞
        // Python 与 JS 完全并行: GIL 管理 I/O 并发，8秒超时兜底
        // 先捕获 MainActor 上的值，避免 TaskGroup 闭包内 await self 编译错误
        let spiderAllSites = self.allSites
        let fallbackEnabled = self.fallbackEnabled
        let fallbackSites = self.allFallbackSites
        let engines = self.engines

        // 预构建 API 站点列表（在 MainActor 上完成，避免闭包内调用 resolveSiteMode）
        struct Site { let name: String; let api: String }
        var apiSites: [Site] = []
        for s in spiderAllSites where s.api?.isEmpty == false {
            let mode = resolveSiteMode(site: s)
            if mode == .apiEndpoint || s.type == 0 || s.type == 1 {
                if let api = s.api { apiSites.append(Site(name: s.name, api: api)) }
            }
        }
        if fallbackEnabled {
            for fb in fallbackSites { apiSites.append(Site(name: fb.name, api: fb.api)) }
        }

        await withTaskGroup(of: Void.self) { group in

            // 0. 网盘站搜索
            group.addTask {
                await self.cloudSearch(keyword: keyword, onBatch: { items in
                    if !items.isEmpty {
                        log("☁️ 网盘 +\(items.count)条")
                        onBatch(items)
                    }
                }, onLog: onLog)
            }

            // 1. zhanyuan 站源搜索
            group.addTask {
                await ZhanyuanSearchService.searchAllZhanyuan(keyword: keyword, onBatch: { items in
                    if !items.isEmpty {
                        onBatch(items)
                    }
                }, onLog: { msg in
                    log("zhanyuan: \(msg)")
                })
            }

            // 2. API 站点 + 兜底源（切片资源）
            group.addTask {
                guard !apiSites.isEmpty else { return }

                await withTaskGroup(of: (name: String, items: [VodItem]?).self) { innerGroup in
                    var running = 0
                    let maxConcurrent = 60
                    for site in apiSites {
                        if running >= maxConcurrent {
                            if let r = await innerGroup.next() {
                                if let items = r.items, !items.isEmpty {
                                    log("✅ \(r.name) +\(items.count)条"); onBatch(items)
                                }
                                running -= 1
                            }
                        }
                        running += 1
                        innerGroup.addTask {
                            (name: site.name, items: await self.searchOneSite(name: site.name, api: site.api, keyword: encodedKW))
                        }
                    }
                    for await r in innerGroup {
                        if let items = r.items, !items.isEmpty {
                            log("✅ \(r.name) +\(items.count)条"); onBatch(items)
                        }
                    }
                }
            }

            // 3. JS/CMS 蜘蛛 — 并发 TaskGroup，限流 10（不再等待 Python）
            group.addTask {
                let siteNameMap = Dictionary(uniqueKeysWithValues: spiderAllSites.compactMap { site in
                    engines.keys.contains(site.key) ? (site.key, site.name) : nil
                })
                let engineEntries = Array(engines)
                guard !engineEntries.isEmpty else { return }

                // ★ Python 引擎已拆到通道4，这里只处理 JS/CMS 引擎
                let jsEntries = engineEntries.filter { !($1 is PythonSpiderEngine) }
                guard !jsEntries.isEmpty else { return }

                await withTaskGroup(of: (key: String, items: [VodItem]?, error: String?).self) { jsGroup in
                    var running = 0
                    let maxConcurrent = 10

                    for (key, engine) in jsEntries {
                        if running >= maxConcurrent {
                            if let r = await jsGroup.next() {
                                if let items = r.items, !items.isEmpty {
                                    var tagged = items
                                    let name = siteNameMap[r.key] ?? r.key
                                    for i in 0..<tagged.count {
                                        let original = tagged[i].vodRemarks ?? ""
                                        tagged[i].vodRemarks = original.hasPrefix("☁️") ? "☁️" + name : name
                                    }
                                    log("✅ QuickJS[\(r.key)] +\(tagged.count)条")
                                    onBatch(tagged)
                                } else if let err = r.error {
                                    log("❌ QuickJS[\(r.key)] \(err)")
                                }
                                running -= 1
                            }
                        }
                        running += 1
                        jsGroup.addTask {
                            do {
                                if let items = try engine.callSearchContent(keyword: keyword, pg: 1).list, !items.isEmpty {
                                    var taggedItems = items
                                    for i in 0..<taggedItems.count { taggedItems[i].engineKey = key }
                                    return (key: key, items: taggedItems, error: nil)
                                }
                                return (key: key, items: nil, error: nil)
                            } catch {
                                return (key: key, items: nil, error: error.localizedDescription)
                            }
                        }
                    }

                    for await r in jsGroup {
                        if let items = r.items, !items.isEmpty {
                            var tagged = items
                            let name = siteNameMap[r.key] ?? r.key
                            for i in 0..<tagged.count {
                                let original = tagged[i].vodRemarks ?? ""
                                tagged[i].vodRemarks = original.hasPrefix("☁️") ? "☁️" + name : name
                                tagged[i].engineKey = r.key
                            }
                            log("✅ QuickJS[\(r.key)] +\(tagged.count)条")
                            onBatch(tagged)
                        } else if let err = r.error {
                            log("❌ QuickJS[\(r.key)] \(err)")
                        }
                    }
                }
            }

            // 4. Python 蜘蛛 — 并发 TaskGroup，限流 10（与 JS 完全并行，GIL 管理 I/O 并发）
            //   PythonBridge.m 已增加 GIL 管理 (PyGILState_Ensure/Release + PyEval_SaveThread)
            //   每次调用创建独立 globals，不共享 __main__，避免 Spider 类互相覆盖
            //   I/O 期间 GIL 自动释放，多线程可并发执行网络请求
            //   每个蜘蛛 8 秒超时，慢脚本自动跳过
            group.addTask {
                let siteNameMap = Dictionary(uniqueKeysWithValues: spiderAllSites.compactMap { site in
                    engines.keys.contains(site.key) ? (site.key, site.name) : nil
                })
                let engineEntries = Array(engines)
                let pyEntries = engineEntries.filter { $1 is PythonSpiderEngine }
                guard !pyEntries.isEmpty else { return }

                await withTaskGroup(of: (key: String, items: [VodItem]?, error: String?).self) { pyGroup in
                    var running = 0
                    let maxConcurrent = 10

                    for (key, engine) in pyEntries {
                        if running >= maxConcurrent {
                            if let r = await pyGroup.next() {
                                if let items = r.items, !items.isEmpty {
                                    var tagged = items
                                    let name = siteNameMap[r.key] ?? r.key
                                    for i in 0..<tagged.count {
                                        tagged[i].vodRemarks = name
                                        tagged[i].engineKey = r.key
                                    }
                                    log("🐍 Python[\(r.key)] +\(tagged.count)条")
                                    onBatch(tagged)
                                } else if let err = r.error {
                                    log("🐍 Python[\(r.key)] \(err)")
                                }
                                running -= 1
                            }
                        }
                        running += 1
                        pyGroup.addTask {
                            guard let pyEngine = engine as? PythonSpiderEngine else {
                                return (key: key, items: nil, error: "引擎类型转换失败")
                            }
                            do {
                                let result = try await pyEngine.callSearchContentAsync(keyword: keyword, pg: 1)
                                if let items = result.list, !items.isEmpty {
                                    var taggedItems = items
                                    for i in 0..<taggedItems.count { taggedItems[i].engineKey = key }
                                    return (key: key, items: taggedItems, error: nil)
                                }
                                return (key: key, items: nil, error: nil)
                            } catch {
                                return (key: key, items: nil, error: error.localizedDescription)
                            }
                        }
                    }

                    for await r in pyGroup {
                        if let items = r.items, !items.isEmpty {
                            var tagged = items
                            let name = siteNameMap[r.key] ?? r.key
                            for i in 0..<tagged.count {
                                tagged[i].vodRemarks = name
                                tagged[i].engineKey = r.key
                            }
                            log("🐍 Python[\(r.key)] +\(tagged.count)条")
                            onBatch(tagged)
                        } else if let err = r.error {
                            log("🐍 Python[\(r.key)] \(err)")
                        }
                    }
                }
            }
        }
        log("====== Stream全部完成 ======")
    }

    /// 根据 URL 域名查找匹配的 zhanyuan 站点配置
    /// 优先从 SQLite 查找，为空时从内存回退
    private func findZhanyuanSiteForURL(_ url: String) async -> ZhanyuanSite? {
        guard let urlObj = URL(string: url) else { return nil }
        let host = urlObj.host ?? ""

        // 1. 从 SQLite 查找
        let dbSites = DatabaseManager.shared.queryActiveZhanyuanSites()
        for site in dbSites {
            if let siteUrl = URL(string: site.searchUrl),
               siteUrl.host == host {
                return site
            }
        }

        // 2. 从内存回退（@Published 属性需要主线程）
        let spiderSites = await MainActor.run { self.allSites }
        for s in spiderSites where s.type == 2 {
            guard let api = s.api, !api.isEmpty else { continue }
            if let siteUrl = URL(string: api), siteUrl.host == host {
                // 从 ext 字段构建 ZhanyuanSite
                let extJSON = s.ext ?? "{}"
                if let data = extJSON.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return ZhanyuanSite(
                        name: json["name"] as? String ?? s.name,
                        searchUrl: json["searchUrl"] as? String ?? api,
                        searchUA: json["searchUA"] as? String ?? "",
                        playUA: json["playUA"] as? String ?? "",
                        websearchurl: json["websearchurl"] as? String ?? "",
                        searchname: json["searchname"] as? String ?? "",
                        searchid: json["searchid"] as? String ?? "",
                        searchpic: json["searchpic"] as? String ?? "",
                        searchstarr: json["searchstarr"] as? String ?? "",
                        detaillist: json["detaillist"] as? String ?? "",
                        detailxl: json["detailxl"] as? String ?? "",
                        detailjs: json["detailjs"] as? String ?? "",
                        detailjsurl: json["detailjsurl"] as? String ?? "",
                        isActive: true,
                        updatedAt: Int64(Date().timeIntervalSince1970)
                    )
                }
                return ZhanyuanSite(name: s.name, searchUrl: api)
            }
        }

        return nil
    }

    /// 带超时的 GCD 异步执行包装器
    /// 避免 JS 引擎卡死（如 JS 代码死循环或 syncRequest 信号量永久阻塞）
    /// 导致 withCheckedContinuation 永久挂起、界面卡死
    private func withGCDTimeout<T>(
        timeout: TimeInterval = 30,
        qos: DispatchQoS = .userInitiated,
        operation: String = "",
        _ block: @escaping () -> T?
    ) async -> T? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var resumed = false
            let lock = NSLock()

            // 安全超时：超时后强制 resume(nil)，防止 continuation 永久挂起
            let timeoutWork = DispatchWorkItem {
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                if !already {
                    print("[SpiderManager] ⚠️ \(operation) 超时(\(Int(timeout))s)，强制返回 nil")
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            DispatchQueue.global(qos: qos.qosClass).async {
                let result = block()
                lock.lock()
                let already = resumed
                resumed = true
                lock.unlock()
                timeoutWork.cancel()
                if !already {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// 通过引擎获取详情，失败时回退到原生 API 详情
    func getDetail(ids: String, name: String? = nil, engineKey: String? = nil) async -> VodItem? {
        // 0. 如果 ids 是 HTTP URL，判断是 zhanyuan 站源还是网盘
        if ids.hasPrefix("http://") || ids.hasPrefix("https://") {
            // 0.1 检查是否匹配 zhanyuan 站点域名
            if let zhanyuanSite = await findZhanyuanSiteForURL(ids) {
                print("[SpiderManager] getDetail 检测到 zhanyuan 站源详情页: \(zhanyuanSite.name)")
                do {
                    let item = try await ZhanyuanSearchService.fetchDetail(detailUrl: ids, site: zhanyuanSite)
                    return item
                } catch {
                    print("[SpiderManager] ❌ zhanyuan 详情页解析失败: \(error.localizedDescription)")
                    // 继续尝试其他方式
                }
            }

            // 0.2 非 zhanyuan，走网盘解析
            print("[SpiderManager] getDetail 检测到详情页URL，走网盘解析: \(ids.prefix(80))")
            if let result = await resolveCloudPlay(from: ids) {
                // 把所有网盘链接编码到 vodPlayUrl 中
                if let linkData = try? JSONSerialization.data(withJSONObject: result.links.map { ["url": $0.url, "name": $0.name] }),
                   let linkJSON = String(data: linkData, encoding: .utf8) {
                    let item = VodItem(vodId: ids, vodName: result.siteName, vodPic: "",
                                       vodRemarks: "☁️网盘", vodPlayUrl: linkJSON)
                    return item
                }
            }
            print("[SpiderManager] ❌ 网盘详情页解析失败")
            return nil
        }
        // 0. 腾讯视频原生详情（不走 JS 引擎）
        if !ids.hasPrefix("http") {
            if let txItem = await TencentVideoNativeSpider.shared.detail(ids: ids) {
                return txItem
            }
        }
        let tencentKey = TencentVideoNativeSpider.siteKey
        
        // 1. engineKey 指定时，严格只用该引擎，不跨引擎回退
        if let engineKey = engineKey {
            if engineKey != tencentKey, let engine = engines[engineKey] {
                let idsCopy = ids
                // ★ 用 withGCDTimeout 替代 withCheckedContinuation，既保证 JS 引擎在独立 GCD
                // 线程执行（避免协作线程池死锁），又增加 30s 整体超时防止永久卡死
                let result: VodItem? = await withGCDTimeout(operation: "getDetail[\(engineKey)]") {
                    var itemResult: VodItem? = nil
                    do {
                        if var item = try engine.callDetailContent(ids: idsCopy).list?.first {
                            item.engineKey = engineKey
                            print("[SpiderManager] getDetail 精确匹配 [\(engineKey)]: \(item.vodName) playUrl=\(item.vodPlayUrl?.prefix(40) ?? "nil")")
                            itemResult = item
                        } else {
                            print("[SpiderManager] getDetail 精确匹配 [\(engineKey)] 返回空结果")
                        }
                    } catch {
                        print("[SpiderManager] getDetail 精确匹配 [\(engineKey)] 异常: \(error.localizedDescription)")
                    }
                    return itemResult
                }
                if let result { return result }
            }
            // engineKey 指定的引擎失败或不可用，不兜底到其他引擎，直接返回 nil
            print("[SpiderManager] getDetail [\(engineKey)] 不跨引擎回退")
            return nil
        }

        // 2. engineKey 未指定时，遍历所有引擎（跳过腾讯）
        // ★ 用 withGCDTimeout 替代 withCheckedContinuation，增加超时保护
        let idsCopy = ids
        let enginesSnapshot = engines
        let fallbackResult: VodItem? = await withGCDTimeout(operation: "getDetail[fallback]") {
            var itemResult: VodItem? = nil
            for (key, engine) in enginesSnapshot {
                if key == tencentKey { continue }
                do {
                    if var item = try engine.callDetailContent(ids: idsCopy).list?.first {
                        let hasPlayUrl = (item.vodPlayUrl ?? "").contains("$") || (item.vodPlayUrl ?? "").contains("http") || (item.vodPlayUrl ?? "").contains("/")
                        let hasPlayFrom = (item.vodPlayFrom ?? "").contains("$") || (item.vodPlayFrom ?? "").contains("$$$")
                        if hasPlayUrl || hasPlayFrom {
                            item.engineKey = key
                            print("[SpiderManager] getDetail 成功 [\(key)]: \(item.vodName) playUrl=\(item.vodPlayUrl?.prefix(40) ?? "nil")")
                            itemResult = item
                            break
                        }
                        print("[SpiderManager] getDetail [\(key)] 返回空播放地址，继续尝试: \(item.vodName)")
                    }
                } catch { continue }
            }
            return itemResult
        }
        if let fallbackResult { return fallbackResult }
        // 3. 引擎全部失败，回退到原生 API
        print("[SpiderManager] getDetail 引擎全部失败，回退到 nativeDetail")
        return await nativeDetail(ids: ids, name: name)
    }

    func getPlayerContent(vodId: String, flag: String = "play", url: String, engineKey: String? = nil) async -> PlayerContentResult? {
        let tencentKey = TencentVideoNativeSpider.siteKey
        
        // 1. engineKey 指定时，严格只用该引擎，不跨引擎回退
        if let engineKey = engineKey {
            if engineKey != tencentKey, let engine = engines[engineKey] {
                let vodIdCopy = vodId
                let flagCopy = flag
                let urlCopy = url
                // ★ 用 withGCDTimeout 替代 withCheckedContinuation，增加超时保护
                let result: PlayerContentResult? = await withGCDTimeout(operation: "getPlayerContent[\(engineKey)]") {
                    var pcResult: PlayerContentResult? = nil
                    do {
                        let result = try engine.callPlayerContent(vodId: vodIdCopy, flag: flagCopy, url: urlCopy)
                        let urlStr = result.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? result.url ?? ""
                        print("[SpiderManager] getPlayerContent 精确匹配 [\(engineKey)]: url=\(urlStr.prefix(60))")
                        pcResult = result
                    } catch {
                        print("[SpiderManager] getPlayerContent 精确匹配 [\(engineKey)] 异常: \(error.localizedDescription)")
                    }
                    return pcResult
                }
                if let result { return result }
            }
            // engineKey 指定的引擎失败或不可用，不兜底到其他引擎，直接返回 nil
            print("[SpiderManager] getPlayerContent [\(engineKey)] 不跨引擎回退")
            return nil
        }
        
        // 2. engineKey 未指定时，遍历所有引擎（跳过腾讯）
        // ★ 用 withGCDTimeout 替代 withCheckedContinuation，增加超时保护
        let enginesSnapshot = engines
        let vodIdCopy = vodId
        let flagCopy = flag
        let urlCopy = url
        return await withGCDTimeout(operation: "getPlayerContent[fallback]") {
            var pcResult: PlayerContentResult? = nil
            for (key, engine) in enginesSnapshot {
                if key == tencentKey { continue }
                do {
                    let result = try engine.callPlayerContent(vodId: vodIdCopy, flag: flagCopy, url: urlCopy)
                    let urlStr = result.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? result.url ?? ""
                    let hasUrl = !urlStr.isEmpty && (urlStr.contains("$") || urlStr.contains("http") || urlStr.contains("/"))
                    if hasUrl {
                        print("[SpiderManager] getPlayerContent 成功 [\(key)]: parse=\(result.parse ?? -1) url=\(urlStr.prefix(60))")
                        pcResult = result
                        break
                    }
                    print("[SpiderManager] getPlayerContent [\(key)] 返回空地址，继续尝试")
                } catch { continue }
            }
            return pcResult
        }
    }

    func getSavedSubscriptionURLs() -> [String] { subManager.configURLs }
    func saveSubscriptionURL(_ url: String) {
        subManager.configURLs.append(url)
        UserDefaults.standard.set(subManager.configURLs, forKey: "subscribed_config_urls")
        savedURLs = subManager.configURLs
    }
    func removeSubscriptionURL(_ url: String) {
        subManager.removeURL(url)
        savedURLs = subManager.configURLs

        // 只清除该订阅源的数据库记录，不影响其他订阅源
        let db = DatabaseManager.shared
        db.clearZhanyuanSites(dyurl: url)
        db.clearApiYuanSites(dyurl: url)
        db.clearSubscription(url: url)
        print("[SpiderManager] 已清除订阅源 \(url.prefix(60)) 的数据库记录")

        // 彻底清空 SpiderManager 的站点数据
        allSites = []
        loadedSiteCount = 0
        // 清除残留数据：重新加载剩下的订阅源
        Task { [self] in
            // 重新加载剩下的订阅源（如果有的话）
            await loadSitesFromSubscription()
        }
    }

    /// 原生搜索 — 直接 HTTP 调可用 API，不经过 QuickJS
    /// 先遍历订阅源中的 type=1/0 站点，再用硬编码采集站兜底
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword

        // ====== 搜索源 0: 遍历订阅源 API 模式站点（含 type=0/1 和 API 模式的 type=3） ======
        let subSites = subManager.allSites.filter { site in
            guard let api = site.api, !api.isEmpty else { return false }
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }

        // ====== 搜索源 1: 兜底采集 API（开关控制）======
        struct SearchSite { let name: String; let api: String }
        var mergedSites: [SearchSite] = []
        // 域名去重保持关闭（让所有站都参与搜索）

        for site in subSites {
            guard let api = site.api, !api.isEmpty else { continue }
            mergedSites.append(SearchSite(name: site.name, api: api))
        }
        // 兜底源：开关打开时补充（订阅源不足3个 或 直接补上）
        if fallbackEnabled {
            for fb in allFallbackSites {
                mergedSites.append(SearchSite(name: fb.name, api: fb.api))
            }
        }

        if mergedSites.isEmpty {
            print("[SpiderManager] nativeSearch 无可用站点")
            return []
        }

        print("[SpiderManager] nativeSearch 合并搜索站点 \(mergedSites.count) 个（订阅\(subSites.count) + 兜底）")

        // 分批并发搜索，每批10个，支持全部站点参与搜索
        let batchSize = 30
        let allSites = Array(mergedSites)
        for batchStart in stride(from: 0, to: allSites.count, by: batchSize) {
            let batch = Array(allSites[batchStart..<min(batchStart + batchSize, allSites.count)])
            await withTaskGroup(of: [VodItem]?.self) { group in
                for site in batch {
                    group.addTask {
                        await self.searchOneSite(name: site.name, api: site.api, keyword: encodedKW)
                    }
                }
                for await items in group {
                    if let items = items {
                        // 智能去重：按 vodName+画质 分组（已关闭，保留所有搜索结果）
                        // for item in items {
                        //     smartMerge(item: item, into: &allResults)
                        // }
                        allResults.append(contentsOf: items)
                    }
                }
            }
        }

        print("[SpiderManager] nativeSearch 完成: \(allResults.count) 条")
        return allResults
    }

    /// 搜索单个 API 站点
    private func searchOneSite(name: String, api: String, keyword: String) async -> [VodItem]? {
        // 构造搜索URL：兼容多种API格式
        let searchURL: String
        if api.hasSuffix("=") || api.hasSuffix("&") {
            // api 已含查询参数（如 apiyuan 的 searchurl），直接拼关键词
            searchURL = api + keyword
        } else if api.hasSuffix("?") {
            searchURL = api + "wd=" + keyword
        } else if api.contains("?") {
            searchURL = api + "&wd=" + keyword
        } else if api.hasSuffix("/search") || api.hasSuffix("/search.html") {
            // 搜索页路径，尝试 wd 参数
            searchURL = api + "?wd=" + keyword
        } else if api.contains("/api/v1/video/search") || api.contains("/appapi/searchList") {
            // 非标准 API 路径
            searchURL = api + "?keyword=" + keyword
        } else {
            // 默认苹果CMS格式
            searchURL = api + "?ac=videolist&wd=" + keyword
        }

        guard let url = URL(string: searchURL) else {
            print("[SpiderManager] nativeSearch \(name) URL无效: \(searchURL.prefix(80))")
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            let jsonObj = try JSONSerialization.jsonObject(with: data)

            var list: [[String: Any]]? = nil

            if let json = jsonObj as? [String: Any] {
                // Apple CMS 标准格式: { "list": [...] }
                if let l = json["list"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
                // 常见变体: { "data": [...] }
                else if let l = json["data"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
                // 常见变体: { "result": [...] }
                else if let l = json["result"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
                // 常见变体: { "results": [...] }
                else if let l = json["results"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
                // 常见变体: { "data": { "list": [...] } }
                else if let dataObj = json["data"] as? [String: Any],
                        let l = dataObj["list"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
                // 常见变体: { "data": { "data": [...] } }
                else if let dataObj = json["data"] as? [String: Any],
                        let l = dataObj["data"] as? [[String: Any]], !l.isEmpty {
                    list = l
                }
            } else if let arr = jsonObj as? [[String: Any]], !arr.isEmpty {
                // 直接返回数组
                list = arr
            }

            if let list = list {
                let items = list.map { Self.makeVodItem(from: $0, siteName: name) }
                print("[SpiderManager] nativeSearch \(name): \(items.count) 条")
                return items
            }
        } catch {
            print("[SpiderManager] nativeSearch \(name) 失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - 网盘资源专用搜索（从 video_sources.json 读取站点列表）
    /// 返回的 VodItem.vodId 存的是详情页完整 URL，播放时直接抓取解析
    /// 支持两种模式：
    ///   1. 带 onBatch 回调：每个站点出结果立即回调（用于 searchStream 优先通道）
    ///   2. 返回数组：全部完成后返回（兼容旧调用）
    ///
    /// 站点类型：
    ///   - cms:   标准AppleCMS站点，通用 /index.php/vod/search?wd= 搜索路径
    ///   - forum: 论坛程序（Xiuno BBS/NodeBB），搜索结果页含网盘链接
    ///   - spa:   单页Vue/React应用，需API接口

    /// 站点类型枚举
    enum CloudSiteType: String, Codable {
        case cms
        case forum
        case spa
        case wordpress
        case dedecms
        case binhd
    }

    struct CloudSiteConfig: Codable {
        let name: String
        let type: CloudSiteType
        let searchurl: String
        let detailBase: String
        var ua: String?
        var threadPattern: String?
        var threadURL: String?
        var apiSearch: String?
        var resultField: String?
        var titleField: String?
        var urlField: String?
        /// 自定义详情页链接正则（可选，仅 cms 类型生效，覆盖默认正则）
        var detailPattern: String?
        /// 额外网盘域名白名单（可选，追加到默认列表，所有类型生效）
        var extraPanHosts: [String]?
        /// 额外网盘域名→显示名称映射（可选，追加到默认列表，所有类型生效）
        var extraPanNames: [String: String]?
        /// 备用搜索 URL 列表（可选，仅 cms 类型生效，搜索时轮询尝试）
        var searchurls: [String]?
    }

    /// 云盘搜索引擎入口（按类型分发）
    func cloudSearch(keyword: String, onBatch: (([VodItem]) -> Void)? = nil, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        var results: [VodItem] = []
        let log = onLog ?? { print("[cloudSearch] \($0)") }
        log("====== cloudSearch: \(keyword) ======")

        let sites = loadCloudSitesFromJSONConfig()
        log("☁️ 加载 \(sites.count) 个网盘站")
        guard !sites.isEmpty else {
            log("⚠️ 当前无可用网盘站")
            return []
        }

        await withTaskGroup(of: [VodItem].self) { group in
            for site in sites {
                group.addTask {
                    await self.searchOneCloudSite2(keyword: keyword, site: site, onLog: log)
                }
            }
            for await items in group {
                if !items.isEmpty {
                    log("☁️ ✅ 获得 \(items.count) 条")
                    onBatch?(items)
                    results.append(contentsOf: items)
                }
            }
        }

        print("[SpiderManager] ====== cloudSearch 完成: \(results.count) 条 ======")
        return results
    }

    /// 按站点类型分发搜索
    private func searchOneCloudSite2(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        switch site.type {
        case .cms:
            return await searchOneCMSSite(keyword: keyword, site: site, onLog: onLog)
        case .forum:
            return await searchOneForumSite(keyword: keyword, site: site, onLog: onLog)
        case .spa:
            return await searchOneSpaSite(keyword: keyword, site: site, onLog: onLog)
        case .wordpress:
            return await searchOneWordPressSite(keyword: keyword, site: site, onLog: onLog)
        case .dedecms:
            return await searchOneDedeCMSSite(keyword: keyword, site: site, onLog: onLog)
        case .binhd:
            return await searchOneBinhdSite(keyword: keyword, site: site, onLog: onLog)
        }
    }

    /// 从 JSON 加载云盘站点配置
    private func loadCloudSitesFromJSONConfig() -> [CloudSiteConfig] {
        let fileManager = FileManager.default

        // 优先加载远程默认源缓存 cloud_sources.json
        if let data = RemoteSourceConfigManager.shared.cachedCloudSitesData() {
            do {
                let wrapper = try JSONDecoder().decode(CloudSitesWrapper.self, from: data)
                print("[SpiderManager] ✅ 从远程默认源缓存加载网盘源，共 \(wrapper.cloudSites.count) 个站点")
                return wrapper.cloudSites
            } catch {
                print("[SpiderManager] ⚠️ 远程网盘源缓存解析失败: \(error.localizedDescription)")
            }
        }

        // 兼容旧逻辑：继续支持用户手动放到 Documents 目录下的 video_sources.json
        if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let externalPath = documentsPath.appendingPathComponent("video_sources.json")
            if fileManager.fileExists(atPath: externalPath.path) {
                do {
                    let data = try Data(contentsOf: externalPath)
                    let wrapper = try JSONDecoder().decode(CloudSitesWrapper.self, from: data)
                    print("[SpiderManager] ✅ 从外部加载站点配置，共 \(wrapper.cloudSites.count) 个站点")
                    return wrapper.cloudSites
                } catch {
                    print("[SpiderManager] ⚠️ 外部JSON加载失败: \(error.localizedDescription)")
                }
            }
        }

        guard RemoteSourceConfigManager.shared.bundleSourcesEnabled else {
            print("[SpiderManager] Bundle 内置源已关闭，跳过 video_sources.json")
            return []
        }

        // 回退到 Bundle 资源
        guard let bundlePath = Bundle.main.path(forResource: "video_sources", ofType: "json") else {
            print("[SpiderManager] ❌ 找不到默认 video_sources.json 文件")
            return []
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
            let wrapper = try JSONDecoder().decode(CloudSitesWrapper.self, from: data)
            print("[SpiderManager] ✅ 从Bundle加载站点配置，共 \(wrapper.cloudSites.count) 个站点")
            return wrapper.cloudSites
        } catch {
            print("[SpiderManager] ❌ JSON解析失败: \(error.localizedDescription)")
            return []
        }
    }

    private struct CloudSitesWrapper: Codable {
        let cloudSites: [CloudSiteConfig]
    }

    // MARK: - CMS 型站点搜索

    /// PC 浏览器 UA（用于穿透 Cloudflare）
    let cloudPcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// 移动端 UA（用于未开启防护的站点）
    let cloudMobileUA = "Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    private func searchOneCMSSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        log("☁️ \(site.name) 请求中...")

        // 构建候选 URL 列表：主 URL 优先，后追加 searchurls 中的备用 URL
        var candidateURLs = [site.searchurl + encodedKW]
        if let backups = site.searchurls, !backups.isEmpty {
            for backupURL in backups {
                let fullBackup = backupURL + encodedKW
                if !candidateURLs.contains(fullBackup) {
                    candidateURLs.append(fullBackup)
                }
            }
        }

        // 轮询尝试每个 URL，第一个成功即返回
        for (index, fullURL) in candidateURLs.enumerated() {
            guard let url = URL(string: fullURL) else { continue }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 8
                req.setValue(site.ua == "pc" ? cloudPcUA : cloudMobileUA, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: req)

                if let httpResp = response as? HTTPURLResponse {
                    guard httpResp.statusCode == 200 else {
                        log("☁️ \(site.name) [线路\(index + 1)] HTTP \(httpResp.statusCode)，尝试下一条")
                        continue
                    }
                }

                guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { continue }
                let items = extractCMSSearchItems(from: html, site: site)
                if !items.isEmpty {
                    // 搜索成功，更新 detailBase 为当前可用域名
                    log("☁️ \(site.name) [线路\(index + 1)] 成功: \(items.count)条")
                    return items
                }
                // HTML 有内容但无搜索结果，继续尝试下一条（可能是反爬空页面）
                if index < candidateURLs.count - 1 {
                    log("☁️ \(site.name) [线路\(index + 1)] 无结果，尝试下一条")
                }
            } catch {
                if index < candidateURLs.count - 1 {
                    log("☁️ \(site.name) [线路\(index + 1)] 失败，尝试下一条")
                } else {
                    log("☁️ ❌ \(site.name) 所有线路均失败")
                }
            }
        }
        return []
    }

    /// 从 CMS 搜索结果 HTML 中提取条目
    private func extractCMSSearchItems(from html: String, site: CloudSiteConfig) -> [VodItem] {
        // 匹配常见的 CMS 详情页链接，捕获 innerHTML 而非仅文本
        // 若远程配置了 detailPattern 则使用自定义正则，否则使用默认正则
        let pattern: String
        if let custom = site.detailPattern, !custom.isEmpty {
            pattern = custom
        } else {
            pattern = #"<a[^>]*href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*"[^>]*>(.+?)</a>"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var items: [VodItem] = []
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let hrefRange = match.range(at: 1)
            let nameRange = match.range(at: 3)
            guard hrefRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let hRange = Range(hrefRange, in: html),
                  let nRange = Range(nameRange, in: html) else { continue }
            let detailPath = String(html[hRange])
            let innerHTML = String(html[nRange])

            // 去掉 HTML 标签，只保留文本
            var title = innerHTML.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let episodePatterns = ["更新到", "更新至", "连载至", "已完结", "更新中"]
            let looksLikeEpisode = episodePatterns.contains(where: { title.contains($0) })
            if looksLikeEpisode || title.count < 4 {
                var found = false
                // 优先从 <a> 标签的 title 属性获取
                let aTagPattern = #"<a[^>]*title="([^"]+)"#
                if let aRegex = try? NSRegularExpression(pattern: aTagPattern) {
                    // 统一在 innerHTML 中搜索 title 属性，避免 searchString 和 rangeInString 不一致导致崩溃
                    let searchTarget = innerHTML.contains("title=") ? innerHTML : innerHTML
                    let nsRange = NSRange(searchTarget.startIndex..., in: searchTarget)
                    if let aMatch = aRegex.firstMatch(in: searchTarget, range: nsRange),
                       let aRange = Range(aMatch.range(at: 1), in: searchTarget) {
                        let attrTitle = String(searchTarget[aRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if attrTitle.count > 2 {
                            title = attrTitle
                            found = true
                        }
                    }
                }
                if !found {
                    // 在链接前后 300 个字符内搜索标题
                    let searchStart = max(0, match.range.location - 300)
                    let searchEnd = min(match.range.location + 300, html.count)
                    if searchStart < searchEnd,
                       let sIdx = html.index(html.startIndex, offsetBy: searchStart, limitedBy: html.endIndex),
                       let eIdx = html.index(html.startIndex, offsetBy: searchEnd, limitedBy: html.endIndex) {
                        let ctx = String(html[sIdx..<eIdx])
                        let altPatterns = [
                            #"<img[^>]+alt="([^"]{2,80})""#,
                            #"<h[2-4][^>]*>([^<]{2,80})</h[2-4]>"#,
                            #"<span[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</span>"#,
                            #"<div[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</div>"#,
                            #"<a[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</a>"#,
                        ]
                        for ap in altPatterns {
                            if let ar = try? NSRegularExpression(pattern: ap, options: [.caseInsensitive]),
                               let am = ar.firstMatch(in: ctx, range: NSRange(ctx.startIndex..., in: ctx)),
                               let arr = Range(am.range(at: 1), in: ctx) {
                                let altText = String(ctx[arr]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if altText.count > 2 && !episodePatterns.contains(where: { altText.contains($0) }) {
                                    title = altText
                                    found = true
                                    break
                                }
                            }
                        }
                    }
                }
                // 最后兜底：把 "更新到第X集" 换成站点名，至少不是空白
                if !found && looksLikeEpisode {
                    let cleanTitle = title.replacingOccurrences(of: #"更新到第?\d+集"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"更新至第?\d+集"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanTitle.count > 2 {
                        title = cleanTitle
                    }
                }
            }

            if title.count < 2 || title.hasPrefix("首页") || title.hasPrefix("网址") || title.hasPrefix("APP") { continue }

            var pic = ""
            if let picRegex = try? NSRegularExpression(pattern: #"data-original="([^"]+)"#),
               let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let pRange = Range(picMatch.range(at: 1), in: html) {
                pic = String(html[pRange])
            }
            if pic.isEmpty,
               let picRegex = try? NSRegularExpression(pattern: #"<img[^>]*class="[^"]*lazy[^"]*"[^>]*data-src="([^"]+)"#),
               let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let pRange = Range(picMatch.range(at: 1), in: html) {
                pic = String(html[pRange])
            }

            let detailURL = site.detailBase + detailPath
            let item = VodItem(vodId: detailURL, vodName: title, vodPic: pic, vodRemarks: "☁️" + site.name)
            items.append(item)
        }
        // 去重
        var seen = Set<String>()
        return items.filter { seen.insert($0.vodId).inserted }
    }

    // MARK: - WordPress 型站点搜索

    private func searchOneWordPressSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        // WordPress 搜索 URL 格式: https://example.com/?s=关键词
        let fullURL: String
        if site.searchurl.contains("{kw}") {
            fullURL = site.searchurl.replacingOccurrences(of: "{kw}", with: encodedKW)
        } else {
            fullURL = site.searchurl + encodedKW
        }
        log("☁️ \(site.name)(WP) 请求中...")

        guard let url = URL(string: fullURL) else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(site.ua == "pc" ? cloudPcUA : cloudMobileUA, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResp = response as? HTTPURLResponse {
                guard httpResp.statusCode == 200 else {
                    log("☁️ \(site.name)(WP) HTTP \(httpResp.statusCode)")
                    return []
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return extractWordPressSearchItems(from: html, site: site)
        } catch {
            log("☁️ ❌ \(site.name)(WP) 失败")
            return []
        }
    }

    /// 从 WordPress 搜索结果中提取条目
    /// WordPress 文章链接格式: /12345.html 或 /2026/0522/12345.html
    /// 同时兼容完整URL格式: https://www.319312.com/12345.html
    private func extractWordPressSearchItems(from html: String, site: CloudSiteConfig) -> [VodItem] {
        // 匹配 WordPress 文章详情页链接，支持相对路径和完整URL两种格式
        // 相对路径: href="/12345.html" 或 href="/2026/05/22/12345.html"
        // 完整URL: href="https://www.example.com/12345.html"
        let pattern = #"<a[^>]*href="((?:https?://[^/]+)?/(?:[\d]{4}/[\d]{2}/[\d]{2}/)?(\d+)\.html)"[^>]*>(.+?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var items: [VodItem] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let hrefRange = match.range(at: 1)
            let nameRange = match.range(at: 3)
            guard hrefRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let hRange = Range(hrefRange, in: html),
                  let nRange = Range(nameRange, in: html) else { continue }
            let detailPath = String(html[hRange])
            let innerHTML = String(html[nRange])

            var title = innerHTML.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 跳过太短的标题（导航链接、页码等）
            if title.count < 4 { continue }
            if title.hasPrefix("首页") || title.hasPrefix("网址") || title.hasPrefix("APP") { continue }

            // 跳过非影视相关页面（通过 URL 路径判断）
            let linkLower = detailPath.lowercased()
            if linkLower.contains("/page/") || linkLower.contains("/wp-") || linkLower.contains("/author/") || linkLower.contains("/tag/") { continue }

            // 详情URL拼接：完整URL直接使用，相对路径拼接detailBase
            let detailURL = detailPath.hasPrefix("http") ? detailPath : site.detailBase + detailPath
            if seen.contains(detailURL) { continue }
            seen.insert(detailURL)

            // 提取缩略图：优先从当前匹配项附近查找
            var pic = ""
            // 先尝试从当前a标签内的img提取
            let imgPattern = #"<img[^>]+(?:data-original|data-src|src)="([^"]+)""#
            if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
                let searchStart = match.range.location
                let searchEnd = min(searchStart + 500, html.count)
                let searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
                if let imgMatch = imgRegex.firstMatch(in: html, range: searchRange),
                   let pRange = Range(imgMatch.range(at: 1), in: html) {
                    pic = String(html[pRange])
                }
            }
            // 兜底：从全页找第一张图
            if pic.isEmpty {
                if let picRegex = try? NSRegularExpression(pattern: #"<img[^>]+src="([^"]+)""#),
                   let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let pRange = Range(picMatch.range(at: 1), in: html) {
                    pic = String(html[pRange])
                }
            }

            items.append(VodItem(vodId: detailURL, vodName: title, vodPic: pic, vodRemarks: "☁️" + site.name))
        }
        return items
    }

    // MARK: - DedeCMS 型站点搜索

    private func searchOneDedeCMSSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let fullURL: String
        if site.searchurl.contains("{kw}") {
            fullURL = site.searchurl.replacingOccurrences(of: "{kw}", with: encodedKW)
        } else {
            fullURL = site.searchurl + encodedKW
        }
        log("☁️ \(site.name)(Dede) 请求中...")

        guard let url = URL(string: fullURL) else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(site.ua == "pc" ? cloudPcUA : cloudMobileUA, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResp = response as? HTTPURLResponse {
                guard httpResp.statusCode == 200 else {
                    log("☁️ \(site.name)(Dede) HTTP \(httpResp.statusCode)")
                    return []
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return extractDedeCMSSearchItems(from: html, site: site)
        } catch {
            log("☁️ ❌ \(site.name)(Dede) 失败")
            return []
        }
    }

    /// 从 DedeCMS 搜索结果中提取条目
    /// DedeCMS 详情页链接格式: /movie/2026/0522/12345.html 或 /dianshiju/2026/0416/12345.html
    /// 同时兼容月日合并格式: /zongyi/2022/0808/28365.html
    private func extractDedeCMSSearchItems(from html: String, site: CloudSiteConfig) -> [VodItem] {
        // 匹配 DedeCMS 详情页: href="/{分类}/{年}/{月日或月/日}/{aid}.html"
        // 日期支持两种格式: YYYY/MM/DD/ 和 YYYY/MMDD/
        let pattern = #"<a[^>]*href="(/(?:[a-z]+/)?\d{4}/(?:\d{2}/\d{2}/|\d{4}/)(\d+)\.html)"[^>]*>(.+?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var items: [VodItem] = []
        var seen = Set<String>()
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let hrefRange = match.range(at: 1)
            let nameRange = match.range(at: 3)
            guard hrefRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let hRange = Range(hrefRange, in: html),
                  let nRange = Range(nameRange, in: html) else { continue }
            let detailPath = String(html[hRange])
            let innerHTML = String(html[nRange])

            var title = innerHTML.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if title.count < 4 { continue }
            if title.hasPrefix("首页") || title.hasPrefix("网址") || title.hasPrefix("APP") { continue }

            let detailURL = site.detailBase + detailPath
            if seen.contains(detailURL) { continue }
            seen.insert(detailURL)

            // 提取缩略图：优先从当前匹配项附近查找
            var pic = ""
            let imgPattern = #"<img[^>]+(?:data-original|data-src|src)="([^"]+)""#
            if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
                let searchStart = match.range.location
                let searchEnd = min(searchStart + 500, html.count)
                let searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
                if let imgMatch = imgRegex.firstMatch(in: html, range: searchRange),
                   let pRange = Range(imgMatch.range(at: 1), in: html) {
                    pic = String(html[pRange])
                }
            }
            // 兜底：从全页找第一张图
            if pic.isEmpty {
                if let picRegex = try? NSRegularExpression(pattern: #"<img[^>]+src="([^"]+)""#),
                   let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let pRange = Range(picMatch.range(at: 1), in: html) {
                    pic = String(html[pRange])
                }
            }

            items.append(VodItem(vodId: detailURL, vodName: title, vodPic: pic, vodRemarks: "☁️" + site.name))
        }
        return items
    }

    // MARK: - 论坛型站点搜索

    private func searchOneForumSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let fullURL = site.searchurl + encodedKW
        log("☁️ \(site.name) 请求中...")

        guard let url = URL(string: fullURL) else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResp = response as? HTTPURLResponse {
                guard httpResp.statusCode == 200 else {
                    log("☁️ \(site.name) HTTP \(httpResp.statusCode)")
                    return []
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return [] }

            // 策略 A: 搜索结果页直接含网盘链接（最常见）
            let cloudLinks = parseCloudLinksFromHTML(html: html, siteName: site.name, extraPanHosts: site.extraPanHosts, extraPanNames: site.extraPanNames)
            if !cloudLinks.isEmpty {
                log("☁️ \(site.name)(论坛直链接): \(cloudLinks.count) 条")
                return cloudLinks
            }

            // 策略 B: 搜索结果只是主题列表，提取主题 URL 供后续点击详情解析
            if let threadPattern = site.threadPattern, let threadURL = site.threadURL {
                guard let regex = try? NSRegularExpression(pattern: threadPattern, options: []) else { return [] }
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                var items: [VodItem] = []
                for match in matches.prefix(10) {
                    let ranges = (0..<match.numberOfRanges).dropFirst()
                    var id = ""
                    for i in ranges {
                        if let r = Range(match.range(at: i), in: html) {
                            if !id.isEmpty { id += "-" }
                            id += String(html[r])
                        }
                    }
                    let resolved = threadURL.replacingOccurrences(of: "{id}", with: id)
                    let fullVodId = resolved.hasPrefix("http") ? resolved : site.detailBase + resolved
                    var title = site.name
                    let pos = match.range.location
                    let start = max(0, pos - 200)
                    let len = min(pos + 200, html.count) - start
                    if start >= 0, start + len <= html.count {
                        let ctx = String(html[html.index(html.startIndex, offsetBy: start)..<html.index(html.startIndex, offsetBy: start + len)])
                        if let t = ctx.range(of: #"title="([^"]+)""#, options: .regularExpression) {
                            title = String(ctx[t]).replacingOccurrences(of: #"title="([^"]+)""#, with: "$1", options: .regularExpression)
                        }
                    }
                    items.append(VodItem(vodId: fullVodId, vodName: title, vodPic: "", vodRemarks: site.name))
                }
                log("☁️ \(site.name)(论坛主题): \(items.count) 条")
                return items
            }

            // 策略 C: 全页扫描兜底
            let fallback = parseCloudLinksFromHTML(html: html, siteName: site.name, extraPanHosts: site.extraPanHosts, extraPanNames: site.extraPanNames)
            return fallback
        } catch {
            log("☁️ ❌ \(site.name) 失败")
            return []
        }
    }

    /// 从 HTML 中提取所有网盘链接（论坛/详情页通用）
    private func parseCloudLinksFromHTML(html: String, siteName: String, extraPanHosts: [String]? = nil, extraPanNames: [String: String]? = nil) -> [VodItem] {
        var panPatterns: [(pattern: String, driveName: String)] = [
            (#"(https?://115cdn\.com/s/[^\s\"<>'\\]*)"#, "115网盘"),
            (#"(https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s\"<>'\\]*)"#, "阿里云盘"),
            (#"(https?://pan\.quark\.cn/s/[^\s\"<>'\\]*)"#, "夸克网盘"),
            (#"(https?://pan\.baidu\.com/s/[^\s\"<>'\\]*)"#, "百度网盘"),
            (#"(https?://(?:drive|pan)\.uc\.cn/s/[^\s\"<>'\\]*)"#, "UC网盘"),
            (#"(https?://yun\.139\.com/[^\s\"<>'\\]*)"#, "天翼云盘"),
            (#"(https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+)"#, "123云盘"),
        ]
        // 追加远程配置的额外网盘域名
        if let extraHosts = extraPanHosts {
            for host in extraHosts {
                let escaped = NSRegularExpression.escapedPattern(for: host)
                let name = extraPanNames?.first(where: { host.contains($0.key) })?.value ?? "网盘链接"
                panPatterns.append(("(https?://\(escaped)[^\\s\"<>'\\\\]*)", name))
            }
        }
        var items: [VodItem] = []
        var seen = Set<String>()
        for (pattern, driveName) in panPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                if let r = Range(match.range(at: 1), in: html) {
                    let panURL = String(html[r])
                    guard seen.insert(panURL).inserted else { continue }

                    var name = "\(driveName)-\(siteName)"

                    if let htmlIdx = html.index(html.startIndex, offsetBy: match.range.location, limitedBy: html.endIndex) {
                        let beforeHTML = String(html[html.startIndex..<htmlIdx])
                        let titleRegex = try? NSRegularExpression(pattern: #"<title>(.+?)</title>"#, options: [.caseInsensitive])
                        if let titleMatch = titleRegex?.firstMatch(in: beforeHTML, range: NSRange(beforeHTML.startIndex..., in: beforeHTML)),
                           let tr = Range(titleMatch.range(at: 1), in: beforeHTML) {
                            let pageTitle = String(beforeHTML[tr]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if pageTitle.count > 2 && !pageTitle.contains("搜索") {
                                name = pageTitle
                            }
                        }
                    }

                    let searchRange = max(0, match.range.location - 800)
                    let searchLen = min(match.range.location + match.range.length + 200, html.count) - searchRange
                    if searchRange >= 0, searchRange + searchLen <= html.count,
                       let startIdx = html.index(html.startIndex, offsetBy: searchRange, limitedBy: html.endIndex),
                       let endIdx = html.index(startIdx, offsetBy: searchLen, limitedBy: html.endIndex) {
                        let ctx = String(html[startIdx..<endIdx])

                        let namePatterns = [
                            #"<a[^>]*title="([^"]+)"[^>]*>\s*(?:</a>)?"#,
                            #"<h[1-4][^>]*>([^<]+)</h[1-4]>"#,
                            #"alt="([^"]{2,40})""#,
                        ]
                        for np in namePatterns {
                            if let nr = try? NSRegularExpression(pattern: np, options: [.caseInsensitive]),
                               let nm = nr.firstMatch(in: ctx, range: NSRange(ctx.startIndex..., in: ctx)),
                               let nrr = Range(nm.range(at: 1), in: ctx) {
                                let candidate = String(ctx[nrr]).trimmingCharacters(in: .whitespacesAndNewlines)
                                if candidate.count > 2 && candidate.count < 80 &&
                                   !candidate.contains("pan.quark") && !candidate.contains("pan.baidu") &&
                                   !candidate.contains("aliyundrive") && !candidate.contains("alipan.com") &&
                                   candidate != siteName {
                                    name = candidate
                                    break
                                }
                            }
                        }
                    }
                    items.append(VodItem(vodId: panURL, vodName: name, vodPic: "", vodRemarks: siteName))
                }
            }
        }
        return items
    }

    // MARK: - SPA 型站点搜索

    private func searchOneSpaSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        log("☁️ \(site.name) 请求中...")

        guard let apiTemplate = site.apiSearch,
              let apiURL = URL(string: apiTemplate.replacingOccurrences(of: "{kw}", with: encodedKW)) else {
            return []
        }

        do {
            var req = URLRequest(url: apiURL)
            req.timeoutInterval = 8
            req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                log("☁️ \(site.name) HTTP \(httpResp.statusCode)")
                return []
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            var list: [[String: Any]] = []
            if let path = site.resultField {
                let keys = path.split(separator: ".")
                var current: Any = json
                for key in keys {
                    guard let d = current as? [String: Any], let n = d[String(key)] else { break }
                    current = n
                }
                if let arr = current as? [[String: Any]] {
                    list = arr
                } else if let dict = current as? [String: Any] {
                    // PanSou 格式: merged_by_type = { "quark": [...], "baidu": [...], ... }
                    // 扁平化所有网盘类型的数组
                    var flat: [[String: Any]] = []
                    for (_, value) in dict {
                        if let subArr = value as? [[String: Any]] {
                            flat.append(contentsOf: subArr)
                        }
                    }
                    list = flat
                }
            } else {
                if let arr = json["data"] as? [[String: Any]] { list = arr }
                else if let d = json["data"] as? [String: Any] { list = [d] }
            }

            let tField = site.titleField ?? "title"
            let uField = site.urlField ?? "url"
            var items: [VodItem] = []
            for entry in list.prefix(20) {
                guard let title = entry[tField] as? String,
                      let detailURL = entry[uField] as? String else { continue }
                let fullURL = detailURL.hasPrefix("http") ? detailURL : site.detailBase + detailURL
                items.append(VodItem(vodId: fullURL, vodName: title, vodPic: "", vodRemarks: site.name))
            }
            log("☁️ \(site.name)(SPA): \(items.count) 条")
            return items
        } catch {
            log("☁️ ❌ \(site.name) 失败: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - binhd 型站点搜索（HTML 页面解析 + 详情页复制链接 API）

    /// binhd.com（原奕搜资源/ysso.cc）搜索
    /// 网站已从 JSON API 迁移为 Django HTML 站，搜索结果为服务端渲染的 HTML 页面
    /// 部分资源支持匿名下载（无需登录），通过 POST /resources/{slug}/links/{id}/copy/ 获取网盘链接
    private func searchOneBinhdSite(keyword: String, site: CloudSiteConfig, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        let log = onLog ?? { _ in }
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        log("☁️ \(site.name) 请求中...")

        guard let url = URL(string: site.searchurl + encodedKW) else { return [] }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                log("☁️ \(site.name) HTTP \(httpResp.statusCode)")
                return []
            }

            guard let html = String(data: data, encoding: .utf8) else { return [] }
            return extractBinhdSearchItems(from: html, site: site)
        } catch {
            log("☁️ ❌ \(site.name) 失败: \(error.localizedDescription)")
            return []
        }
    }

    /// 从 binhd.com 搜索结果 HTML 中提取条目
    /// HTML 结构: <article class="resource-card"><h2><a href="/resources/{slug}/">标题</a></h2>...
    private func extractBinhdSearchItems(from html: String, site: CloudSiteConfig) -> [VodItem] {
        // 匹配资源卡片中的标题链接: <h2><a href="/resources/{slug}/">标题</a></h2>
        let pattern = #"<h2[^>]*>\s*<a[^>]*href="(/resources/[^"]+)"[^>]*>(.+?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

        var items: [VodItem] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let hrefRange = match.range(at: 1)
            let nameRange = match.range(at: 2)
            guard hrefRange.location != NSNotFound, nameRange.location != NSNotFound,
                  let hRange = Range(hrefRange, in: html),
                  let nRange = Range(nameRange, in: html) else { continue }

            let detailPath = String(html[hRange])
            // 去掉 HTML 标签（如 <mark class="search-highlight">）
            let title = String(html[nRange])
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let detailURL = detailPath.hasPrefix("http") ? detailPath : site.detailBase + detailPath
            if seen.contains(detailURL) || title.isEmpty { continue }
            seen.insert(detailURL)

            // 提取缩略图：从当前匹配项之前查找（封面图在标题上方）
            var pic = ""
            let imgPattern = #"<img[^>]+src="([^"]+)"[^>]*alt="[^"]*封面""#
            if let imgRegex = try? NSRegularExpression(pattern: imgPattern, options: [.caseInsensitive]) {
                // 封面图在 <h2> 标题之前，需要向前搜索
                let searchStart = max(0, match.range.location - 500)
                let searchEnd = min(match.range.location + 200, html.count)
                let searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
                if let imgMatch = imgRegex.firstMatch(in: html, range: searchRange),
                   let pRange = Range(imgMatch.range(at: 1), in: html) {
                    pic = String(html[pRange])
                }
            }

            items.append(VodItem(vodId: detailURL, vodName: title, vodPic: pic, vodRemarks: "☁️" + site.name))
        }

        return items
    }
    func resolveCloudPlay(from detailURL: String) async -> (links: [(url: String, name: String)], siteName: String)? {
        print("[SpiderManager] resolveCloudPlay: \(detailURL)")
        if let cached = cloudPlayCache[detailURL], cached.expiresAt > Date(), !cached.links.isEmpty {
            print("[SpiderManager] resolveCloudPlay 命中缓存: \(cached.links.count) 条")
            return (cached.links, cached.siteName)
        }

        // 根据详情页 URL 查找对应的站点配置，获取自定义网盘域名等
        let sites = loadCloudSitesFromJSONConfig()
        let matchedSite = sites.first { detailURL.hasPrefix($0.detailBase) }
        let extraHosts = matchedSite?.extraPanHosts
        let extraNames = matchedSite?.extraPanNames

        // 直通: URL 本身就是网盘链接（论坛搜索结果）
        if isCloudDriveLink(detailURL, extraHosts: extraHosts) {
            let driveName = cloudDriveName(for: detailURL, extraPanNames: extraNames)
            let result = (links: [(url: detailURL, name: driveName)], siteName: "云盘直链")
            cacheCloudPlay(result, for: detailURL)
            return result
        }

        // binhd.com 特殊处理：通过复制链接 API 获取网盘地址
        if detailURL.contains("binhd.com") {
            let result = await resolveBinhdCloudPlay(from: detailURL)
            if let result { cacheCloudPlay(result, for: detailURL) }
            return result
        }

        guard let url = URL(string: detailURL) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                print("[SpiderManager] resolveCloudPlay HTTP \(httpResp.statusCode)")
                return nil
            }
            guard let html = String(data: data, encoding: .utf8) else {
                if let gbkData = try? NSString(data: data, encoding: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) as String? {
                    let result = await parseCloudHTML(html: gbkData, extraPanHosts: extraHosts, extraPanNames: extraNames)
                    if let result { cacheCloudPlay(result, for: detailURL) }
                    return result
                }
                print("[SpiderManager] ❌ 编码错误")
                return nil
            }
            let result = await parseCloudHTML(html: html, extraPanHosts: extraHosts, extraPanNames: extraNames)
            if let result { cacheCloudPlay(result, for: detailURL) }
            return result
        } catch {
            print("[SpiderManager] resolveCloudPlay 失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// binhd.com 详情页解析：通过复制链接 API 获取网盘地址
    /// 流程：1. 获取详情页 HTML → 2. 提取非隐藏的下载卡片 → 3. POST copy API 获取真实链接
    private func resolveBinhdCloudPlay(from detailURL: String) async -> (links: [(url: String, name: String)], siteName: String)? {
        print("[SpiderManager] resolveBinhdCloudPlay: \(detailURL)")
        guard let url = URL(string: detailURL) else { return nil }

        // 1. 获取详情页 HTML（同时获取 CSRF cookie）
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html", forHTTPHeaderField: "Accept")

        var csrfToken = ""
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                print("[SpiderManager] resolveBinhdCloudPlay HTTP \(httpResp.statusCode)")
                return nil
            }

            // 从 Set-Cookie 提取 csrftoken
            if let httpResp = response as? HTTPURLResponse {
                let headerFields = httpResp.allHeaderFields as? [String: String] ?? [:]
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
                    if cookie.name == "csrftoken" {
                        csrfToken = cookie.value
                        break
                    }
                }
            }

            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // 提取站点名称
            var siteName = "云集"
            if let titleRegex = try? NSRegularExpression(pattern: #"<title>([^<]+)</title>"#),
               let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let fullTitle = String(html[r])
                siteName = fullTitle.replacingOccurrences(of: " - 云集.*$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if siteName.isEmpty { siteName = "云集" }
            }

            // 如果 CSRF token 未从 cookie 获取到，从 HTML 表单提取
            if csrfToken.isEmpty {
                if let tokenRegex = try? NSRegularExpression(pattern: #"csrfmiddlewaretoken[^>]*value="([^"]+)""#),
                   let m = tokenRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let r = Range(m.range(at: 1), in: html) {
                    csrfToken = String(html[r])
                }
            }

            // 2. 提取非隐藏的下载卡片中的复制链接 URL
            // 卡片结构：<article class="resource-download-card resource-download-card--xunlei">
            //   <span class="resource-download-card__provider">迅雷网盘</span>
            //   <button data-resource-copy-url="/resources/{slug}/links/{id}/copy/">一键复制</button>
            // 隐藏卡片有 --hidden 类且无 data-resource-copy-url
            let cardPattern = #"<article class="resource-download-card[^"]*">(.*?)</article>"#
            guard let cardRegex = try? NSRegularExpression(pattern: cardPattern, options: [.dotMatchesLineSeparators]) else { return nil }
            let cardMatches = cardRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            var links: [(url: String, name: String)] = []

            for cardMatch in cardMatches {
                guard let cardRange = Range(cardMatch.range, in: html) else { continue }
                let cardHTML = String(html[cardRange])

                // 跳过隐藏卡片（需要登录）
                if cardHTML.contains("resource-download-card--hidden") || cardHTML.contains("登录后可见") { continue }

                // 提取复制 URL
                guard let copyRegex = try? NSRegularExpression(pattern: #"data-resource-copy-url="([^"]+)""#),
                      let copyMatch = copyRegex.firstMatch(in: cardHTML, range: NSRange(cardHTML.startIndex..., in: cardHTML)),
                      let copyRange = Range(copyMatch.range(at: 1), in: cardHTML) else { continue }

                let copyPath = String(cardHTML[copyRange])
                let copyURL = copyPath.hasPrefix("http") ? copyPath : "https://binhd.com" + copyPath

                // 提取网盘类型名称
                var providerName = "网盘链接"
                if let provRegex = try? NSRegularExpression(pattern: #"resource-download-card__provider">([^<]+)<"#),
                   let provMatch = provRegex.firstMatch(in: cardHTML, range: NSRange(cardHTML.startIndex..., in: cardHTML)),
                   let provRange = Range(provMatch.range(at: 1), in: cardHTML) {
                    providerName = String(cardHTML[provRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }

                // 3. POST copy API 获取真实链接
                guard let copyApiURL = URL(string: copyURL) else { continue }
                var copyReq = URLRequest(url: copyApiURL)
                copyReq.httpMethod = "POST"
                copyReq.timeoutInterval = 10
                copyReq.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
                copyReq.setValue("application/json", forHTTPHeaderField: "Accept")
                copyReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                copyReq.setValue(detailURL, forHTTPHeaderField: "Referer")
                if !csrfToken.isEmpty {
                    copyReq.setValue(csrfToken, forHTTPHeaderField: "X-CSRFToken")
                }
                copyReq.setValue("csrftoken=\(csrfToken)", forHTTPHeaderField: "Cookie")

                do {
                    let (copyData, copyResp) = try await URLSession.shared.data(for: copyReq)
                    guard let httpResp = copyResp as? HTTPURLResponse, httpResp.statusCode == 200 else { continue }

                    if let json = try? JSONSerialization.jsonObject(with: copyData) as? [String: Any],
                       let copyText = json["copy_text"] as? String {
                        // 从 copy_text 中提取网盘链接
                        // 格式: "链接：https://pan.xunlei.com/s/XXXX?pwd=XXXX\n提取码：XXXX"
                        let panPatterns: [(String, String)] = [
                            (#"https?://pan\.quark\.cn/s/[^\s\"<>']+"#, "夸克网盘"),
                            (#"https?://pan\.baidu\.com/s/[^\s\"<>']+"#, "百度网盘"),
                            (#"https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s\"<>']+"#, "阿里云盘"),
                            (#"https?://pan\.xunlei\.com/s/[^\s\"<>']+"#, "迅雷网盘"),
                            (#"https?://115cdn\.com/s/[^\s\"<>']+"#, "115网盘"),
                            (#"https?://(?:drive|pan)\.uc\.cn/s/[^\s\"<>']+"#, "UC网盘"),
                            (#"https?://yun\.139\.com/[^\s\"<>']+"#, "天翼云盘"),
                            (#"https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+"#, "123云盘"),
                        ]

                        for (pattern, driveName) in panPatterns {
                            if let linkRegex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                               let linkMatch = linkRegex.firstMatch(in: copyText, range: NSRange(copyText.startIndex..., in: copyText)),
                               let linkRange = Range(linkMatch.range, in: copyText) {
                                let panLink = String(copyText[linkRange])
                                links.append((url: panLink, name: providerName.isEmpty ? driveName : providerName))
                                break
                            }
                        }
                    }
                } catch {
                    print("[SpiderManager] resolveBinhdCloudPlay copy 失败: \(error.localizedDescription)")
                }
            }

            if links.isEmpty {
                print("[SpiderManager] resolveBinhdCloudPlay 未找到可用的网盘链接（可能需要登录）")
                return nil
            }

            print("[SpiderManager] resolveBinhdCloudPlay 成功: \(links.count) 条链接")
            return (links: links, siteName: siteName)

        } catch {
            print("[SpiderManager] resolveBinhdCloudPlay 失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 判断 URL 是否是已知网盘链接
    private func isCloudDriveLink(_ url: String, extraHosts: [String]? = nil) -> Bool {
        let patterns = [
            "pan.quark.cn/s/", "115cdn.com/s/", "aliyundrive.com/s/", "alipan.com/s/",
            "pan.baidu.com/s/", "drive.uc.cn/s/", "pan.uc.cn/s/",
            "yun.139.com/", "www.123", ".com/s/"
        ]
        if patterns.contains(where: { url.contains($0) }) { return true }
        // 检查远程配置的额外网盘域名
        if let extra = extraHosts {
            return extra.contains(where: { url.contains($0) })
        }
        return false
    }

    /// 识别网盘类型名称
    private func cloudDriveName(for url: String, extraPanNames: [String: String]? = nil) -> String {
        if url.contains("pan.quark.cn") { return "夸克网盘" }
        if url.contains("115cdn.com") { return "115网盘" }
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return "阿里云盘" }
        if url.contains("pan.baidu.com") { return "百度网盘" }
        if url.contains("drive.uc.cn") || url.contains("pan.uc.cn") { return "UC网盘" }
        if url.contains("yun.139.com") { return "天翼云盘" }
        if url.contains("www.123") && url.contains("/s/") { return "123云盘" }
        // 检查远程配置的额外网盘域名→名称映射
        if let extra = extraPanNames {
            for (host, name) in extra {
                if url.contains(host) { return name }
            }
        }
        return "网盘链接"
    }

    private func cacheCloudPlay(_ result: (links: [(url: String, name: String)], siteName: String), for detailURL: String) {
        cloudPlayCache[detailURL] = (result.links, result.siteName, Date().addingTimeInterval(30 * 60))
        if cloudPlayCache.count > 100 {
            let now = Date()
            cloudPlayCache = cloudPlayCache.filter { $0.value.expiresAt > now }
        }
    }

    func clearCloudPlayCache() {
        cloudPlayCache.removeAll()
        spiderCloudPlayCache.removeAll()
    }

    // MARK: - JS 蜘蛛网盘源解析
    // 网盘蜘蛛源约定：vod_remarks 以 "☁️" 开头标识网盘资源，
    // detailContent 的 vod_play_url 返回 JSON 数组 [{"url":"网盘链接","name":"网盘名"}]
    // 本方法调用 JS detailContent 并解析 JSON 数组，与 resolveCloudPlay 并列，互不干扰

    private var spiderCloudPlayCache: [String: (links: [(url: String, name: String)], siteName: String, expiresAt: Date)] = [:]

    func resolveCloudPlayFromSpider(ids: String, engineKey: String) async -> (links: [(url: String, name: String)], siteName: String)? {
        let cacheKey = "\(engineKey):\(ids)"
        if let cached = spiderCloudPlayCache[cacheKey], cached.expiresAt > Date(), !cached.links.isEmpty {
            print("[SpiderManager] resolveCloudPlayFromSpider 命中缓存: \(cached.links.count) 条")
            return (cached.links, cached.siteName)
        }

        guard let engine = engines[engineKey] else {
            print("[SpiderManager] resolveCloudPlayFromSpider: 引擎未找到 engineKey=\(engineKey)")
            return nil
        }

        print("[SpiderManager] resolveCloudPlayFromSpider: ids=\(ids) engineKey=\(engineKey)")

        let idsCopy = ids
        let detailResult: VodItem? = await withGCDTimeout(operation: "spiderCloud[\(engineKey)]") {
            do {
                return try engine.callDetailContent(ids: idsCopy).list?.first
            } catch {
                print("[SpiderManager] resolveCloudPlayFromSpider JS调用异常: \(error.localizedDescription)")
                return nil
            }
        }

        guard let item = detailResult else {
            print("[SpiderManager] resolveCloudPlayFromSpider: JS detailContent 返回空")
            return nil
        }

        guard let playUrl = item.vodPlayUrl, !playUrl.isEmpty, playUrl.hasPrefix("[") else {
            print("[SpiderManager] resolveCloudPlayFromSpider: vod_play_url 不是 JSON 数组格式")
            return nil
        }

        guard let data = playUrl.data(using: .utf8),
              let linksArray = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            print("[SpiderManager] resolveCloudPlayFromSpider: JSON 解析失败")
            return nil
        }

        var cloudLinks: [(url: String, name: String)] = []
        for link in linksArray {
            guard let url = link["url"], !url.isEmpty else { continue }
            let name = link["name"] ?? "网盘资源"
            cloudLinks.append((url: url, name: name))
        }

        guard !cloudLinks.isEmpty else {
            print("[SpiderManager] resolveCloudPlayFromSpider: 解析后无有效链接")
            return nil
        }

        let siteName = item.vodRemarks?.replacingOccurrences(of: "☁️", with: "") ?? "网盘"
        spiderCloudPlayCache[cacheKey] = (cloudLinks, siteName, Date().addingTimeInterval(5 * 60))
        if spiderCloudPlayCache.count > 100 {
            let now = Date()
            spiderCloudPlayCache = spiderCloudPlayCache.filter { $0.value.expiresAt > now }
        }

        print("[SpiderManager] resolveCloudPlayFromSpider 成功: \(cloudLinks.count) 条链接, siteName=\(siteName)")
        return (cloudLinks, siteName)
    }

    private func parseCloudHTML(html: String, extraPanHosts: [String]? = nil, extraPanNames: [String: String]? = nil) async -> (links: [(url: String, name: String)], siteName: String)? {
        // 提取视频名称
        var videoName = ""
        if let titleRegex = try? NSRegularExpression(pattern: #"<h1[^>]*class="[^"]*page-title[^"]*"[^>]*>([^<]+)"#),
           let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            videoName = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if videoName.isEmpty,
           let titleRegex = try? NSRegularExpression(pattern: #"<title>([^<]+)"#),
           let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            videoName = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-.*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }

        // 提取所有网盘分享链接（去重），并识别网盘类型
        var panPatterns: [(pattern: String, driveName: String)] = [
            (#"(https?://115cdn\.com/s/[^\s\"<>']*)"#, "115网盘"),
            (#"(https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s\"<>']*)"#, "阿里云盘"),
            (#"(https?://pan\.quark\.cn/s/[^\s\"<>']*)"#, "夸克网盘"),
            (#"(https?://pan\.baidu\.com/s/[^\s\"<>']*)"#, "百度网盘"),
            (#"(https?://(?:drive|pan)\.uc\.cn/s/[^\s\"<>']*)"#, "UC网盘"),
            (#"(https?://yun\.139\.com/[^\s\"<>']*)"#, "天翼云盘"),
            (#"(https?://yun\.139\.com/share(?:web|wap)/#/[wm]/i[/?][^\s\"<>']*)"#, "天翼云盘分享"),
            (#"(https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+)"#, "123云盘"),
        ]
        // 追加远程配置的额外网盘域名
        if let extraHosts = extraPanHosts {
            for host in extraHosts {
                let escaped = NSRegularExpression.escapedPattern(for: host)
                let name = extraPanNames?.first(where: { host.contains($0.key) })?.value ?? "网盘链接"
                panPatterns.append(("(https?://\(escaped)[^\\s\"<>']*)", name))
            }
        }

        var allLinks: [(url: String, name: String)] = []
        var seenURLs = Set<String>()

        for (pattern, driveName) in panPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let r = Range(match.range(at: 1), in: html) {
                    let panURL = String(html[r])
                    if !seenURLs.contains(panURL) {
                        seenURLs.insert(panURL)
                        var desc = driveName
                        let pos = match.range(at: 1).location
                        let start = Int(max(0, Int(pos) - 60))
                        let len = min(Int(pos) + 80, html.count) - start
                        if start >= 0, start + len <= html.count {
                            let around = String(html[html.index(html.startIndex, offsetBy: start)..<html.index(html.startIndex, offsetBy: start + len)])
                            if let qualityRegex = try? NSRegularExpression(pattern: #"(4K|1080[Pp]|720[Pp]|蓝光|高清|国语|粤语|中字|原盘|REMUX|HDR|60帧|DV)"#),
                               let qMatch = qualityRegex.firstMatch(in: around, range: NSRange(around.startIndex..., in: around)),
                               let qRange = Range(qMatch.range(at: 1), in: around) {
                                desc = "\(String(around[qRange]))·\(driveName)"
                            }
                        }
                        allLinks.append((panURL, desc))
                    }
                }
            }
        }

        if allLinks.isEmpty {
            print("[SpiderManager] ❌ 未找到网盘链接")
            return nil
        }
        print("[SpiderManager] ✅ 找到 \(allLinks.count) 个网盘链接: \(allLinks.map { $0.name })")
        return (allLinks, videoName.isEmpty ? "网盘资源" : videoName)
    }

    /// 解析单个网盘分享链接为播放地址
    func resolvePanURL(_ panURL: String) async -> (url: String, headers: [String: String])? {
        guard let driveType = CloudDriveManager.detectDrive(from: panURL) else {
            print("[SpiderManager] ❌ resolvePanURL: 无法识别网盘类型: \(panURL.prefix(40))")
            return nil
        }
        print("[SpiderManager] 🔍 检测到网盘类型: \(driveType.displayName)")
        let tokens = CloudDriveManager.shared.tokens(for: driveType)
        guard let token = tokens.first else {
            print("[SpiderManager] ⚠️ 未配置 \(driveType.displayName) Token，请到设置中配置")
            return (panURL, [:])
        }
        print("[SpiderManager] ✅ 获取到 \(driveType.displayName) Token: \(token.name)")
        do {
            print("[SpiderManager] ⏳ 正在调用 \(driveType.displayName) API 解析播放地址...")
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: panURL)
            print("[SpiderManager] ✅ \(driveType.displayName) 解析成功! 播放地址: \(result.url.prefix(80))...")
            if !result.headers.isEmpty {
                print("[SpiderManager] 📋 请求头: \(result.headers.keys.joined(separator: ", "))")
            }
            return (result.url, result.headers)
        } catch let error as DriveError {
            print("[SpiderManager] ❌ \(driveType.displayName) 解析失败: \(error.localizedDescription)")
            if case .notImplemented = error {
                print("[SpiderManager] 💡 提示: Token 无效或已过期，请在设置中重新配置 \(driveType.displayName) Token")
            }
            return nil
        } catch {
            print("[SpiderManager] ❌ \(driveType.displayName) 解析异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 通过订阅源的 type=1 站点获取详情+播放地址
    /// 先用 ids 查，失败则用 name 搜索匹配
    func nativeDetail(ids: String, name: String? = nil) async -> VodItem? {
        let apiSites = subManager.apiSites
        // 【改造】扩展筛选条件：包含 API 模式的 type=3 站点
        let allApiSites = allSites.filter { site in
            guard let api = site.api, !api.isEmpty else { return false }
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }
        // 如果 apiSites 为空，降级用 allApiSites
        let detailSites = apiSites.isEmpty ? allApiSites : apiSites

        if detailSites.isEmpty {
            print("[SpiderManager] nativeDetail 失败: 无可用的 type=1 站点")
            print("[SpiderManager] 可用站点总数: \(allSites.count)")
            print("[SpiderManager] apiSites: \(apiSites.count)")
            return nil
        }

        print("[SpiderManager] nativeDetail: ids=\(ids), name=\(name ?? "nil"), 可用站点=\(detailSites.count)个")

        for site in detailSites {
            guard let siteApi = site.api, !siteApi.isEmpty else { continue }
            // 剥离查询参数，取纯基地址（兼容 apiyuan 的 ?ac=detail&wd= 格式）
            let baseUrl: String
            if let qIndex = siteApi.firstIndex(of: "?") {
                baseUrl = String(siteApi[..<qIndex])
            } else if siteApi.hasSuffix("/") {
                baseUrl = String(siteApi.dropLast())
            } else {
                baseUrl = siteApi
            }
            
            // 尝试多种API格式
            let apiFormats = [
                "\(baseUrl)?ac=videolist&ids=\(ids)",
                "\(baseUrl)?ac=detail&ids=\(ids)",
                "\(baseUrl)?ac=videolist&ids=\(ids)&pg=1"
            ]

            for format in apiFormats {
                if let url = URL(string: format) {
                    print("[SpiderManager] 尝试API格式: \(format)")
                    if let result = await fetchDetail(url: url, siteName: site.name) {
                        print("[SpiderManager] ✅ nativeDetail 成功: \(site.name)")
                        return result
                    }
                }
            }

            // ids 失败，用名称搜索
            if let n = name, !n.isEmpty,
               let encN = n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "\(baseUrl)?ac=detail&wd=\(encN)") {
                if let result = await fetchDetailFromSearchList(url: searchURL, siteName: site.name, targetName: n) {
                    print("[SpiderManager] ✅ nativeDetail 名称搜索成功: \(site.name)")
                    return result
                }
            }
        }
        print("[SpiderManager] ❌ nativeDetail 全部站点均失败")
        return nil
    }

// 解析器体系 - 将HTML播放页解析为视频直链
    func parsePlayUrl(from playPageUrl: String) async -> String? {
        // 🔧 修复: 自定义协议（如 xk://）不经过解析器，直接返回空
        // 避免 xk:// 地址被 extractDirectPlayURL/WKWebView 处理导致失败或卡死
        // 自定义协议应由上层调用 getPlayerContent 走 playerContent 解析
        let lowerUrl = playPageUrl.lowercased()
        let isStandardScheme = lowerUrl.hasPrefix("http://")
                          || lowerUrl.hasPrefix("https://")
                          || lowerUrl.hasPrefix("file://")
                          || lowerUrl.hasPrefix("rtmp://")
                          || lowerUrl.hasPrefix("rtsp://")
        if !isStandardScheme && !playPageUrl.isEmpty {
            print("[SpiderManager] parsePlayUrl 检测到自定义协议，跳过解析: \(playPageUrl.prefix(60))")
            return nil
        }

        // 0. 【新增】兼容 TVBox 特殊播放格式前缀
        var actualUrl = playPageUrl
        if playPageUrl.hasPrefix("parse://") || playPageUrl.hasPrefix("json://") {
            actualUrl = String(playPageUrl.dropFirst(8))
            print("[SpiderManager] 检测到 TVBox 前缀，解析后: \(actualUrl.prefix(80))")
        }

        // 1. 检查是否已经是直链
        if actualUrl.hasSuffix(".m3u8") || actualUrl.hasSuffix(".mp4") {
            return actualUrl
        }

        // 1.5 B站直链解析
        if actualUrl.contains("bilibili.com") || actualUrl.contains("b23.tv") {
            let bvid = extractBilibiliID(from: playPageUrl)
            if !bvid.isEmpty {
                let bUrl = "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&type=mp4&platform=html5"
                if let data = try? await URLSession.shared.data(from: URL(string: bUrl)!).0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let durl = json["data"] as? [String: Any] {
                    // 尝试提取 durl 或 stream 中的视频地址
                    if let durlList = durl["durl"] as? [[String: Any]], let first = durlList.first, let videoUrl = first["url"] as? String {
                        return videoUrl
                    }
                }
            }
        }

        print("[SpiderManager] 开始解析播放页：\(actualUrl.prefix(60))...")

        // 2. 尝试直接请求播放页提取 m3u8
        if let directUrl = await extractDirectPlayURL(from: actualUrl) {
            print("[SpiderManager] ✅ 从播放页直接提取成功：\(directUrl.prefix(80))...")
            return directUrl
        }

        // 3. WKWebView 客户端解析回退（最后手段）
        if let wkResult = await tryWKWebViewParse(originalURL: actualUrl) {
            return wkResult
        }

        print("[SpiderManager] ❌ 所有解析器均失败")
        return nil
    }

    // MARK: - WKWebView 客户端解析回退
    @MainActor
    private func tryWKWebViewParse(originalURL: String) async -> String? {
        // WKWebView 必须在主线程上创建和使用
        // 之前 Task.detached 在后台线程调用 WKWebView 导致 App 卡死
        return await withCheckedContinuation { continuation in
            var resumed = false
            
            // 安全超时：16秒后强制 resume（比 WKWebViewParser 内部15秒多1秒余量）
            // 防止因 WKWebView 内部回调未触发导致 continuation 永久挂起
            let safetyTimeout = DispatchWorkItem {
                guard !resumed else { return }
                resumed = true
                print("[SpiderManager] ⚠️ tryWKWebViewParse 安全超时触发，强制结束")
                continuation.resume(returning: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: safetyTimeout)
            
            WKWebViewParser.shared.parse(url: originalURL, parserType: .jsParser(jsURL: "https://jx.xmflv.com/?url=")) { result in
                safetyTimeout.cancel()
                guard !resumed else { return }
                resumed = true
                if let result = result, !result.isEmpty {
                    // 尝试从结果中提取视频地址
                    if let urlRange = result.range(of: "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*", options: .regularExpression) {
                        continuation.resume(returning: String(result[urlRange]))
                    } else if let urlRange = result.range(of: "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*", options: .regularExpression) {
                        continuation.resume(returning: String(result[urlRange]))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }


    // MARK: - B站直链辅助方法
    private func extractBilibiliID(from url: String) -> String {
        // BV号格式
        if let range = url.range(of: "BV[A-Za-z0-9]+") {
            return String(url[range])
        }
        // b23.tv 短链接需要重定向获取真实URL
        if url.contains("b23.tv") {
            // 返回空，让解析器处理
            return ""
        }
        // avid 格式
        if let range = url.range(of: "/video/av(\\d+)", options: .regularExpression) {
            let match = String(url[range])
            if let avRange = match.range(of: "\\d+", options: .regularExpression) {
                return String(match[avRange])
            }
        }
        return ""
    }

    private func tryParser(_ parserBase: String, url: String) async -> String? {
        let parseUrl = "\(parserBase)\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"

        guard let requestUrl = URL(string: parseUrl) else { return nil }

        do {
            var request = URLRequest(url: requestUrl)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)

            // 尝试从响应中提取 m3u8/mp4 链接
            if let responseStr = String(data: data, encoding: .utf8) {
                // 正则匹配视频链接
                let patterns = [
                    "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*",
                    "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*",
                    "\"url\":\\s*\"([^\"]+)\""
                ]

                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: responseStr, range: NSRange(responseStr.startIndex..., in: responseStr)) {

                        let result = (responseStr as NSString).substring(with: match.range(at: match.numberOfRanges - 1))

                        // 清理 JSON 格式的 URL
                        if result.hasPrefix("\"") && result.hasSuffix("\"") {
                            let cleaned = String(result.dropFirst().dropLast())
                            if cleaned.hasPrefix("http") {
                                return cleaned
                            }
                        } else if result.hasPrefix("http") {
                            return result
                        }
                    }
                }
            }
        } catch {
            print("[SpiderManager] 解析器请求失败：\(error.localizedDescription)")
        }

        return nil
    }
    
    /// 直接从播放页提取 m3u8/mp4链接
    private func extractDirectPlayURL(from playUrl: String) async -> String? {
        guard let url = URL(string: playUrl) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // 如果是 m3u8/mp4 直接返回
            if let mimeType = (response as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String {
                if mimeType.contains("application/vnd.apple.mpegurl") || mimeType.contains("video/mp4") {
                    return playUrl
                }
            }
            
            // 尝试从 HTML 中提取
            if let html = String(data: data, encoding: .utf8) {
                let patterns = [
                    "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*",
                    "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*",
                    "player\\.src\\(\\{\\s*src:\\s*['\"]([^'\"]+)['\"]",
                    "video\\.src\\(\\{\\s*src:\\s*['\"]([^'\"]+)['\"]",
                    "config *= *\\{[^}]*url:\\s*['\"]([^'\"]+)['\"]",
                    "\"playUrl\":\\s*\"([^\"]+)\"",
                    "data-play-url=\"([^\"]+)\""
                ]
                
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                        // 部分正则没有捕获组（如 m3u8/mp4 URL 匹配），range(at:1) 会越界崩溃
                        let range: Range<String.Index>?
                        if match.numberOfRanges > 1 {
                            range = Range(match.range(at: 1), in: html)
                        } else {
                            range = Range(match.range(at: 0), in: html)
                        }
                        if let r = range {
                            var result = String(html[r])
                            // 清理结果
                            if result.hasPrefix("\"") && result.hasSuffix("\"") {
                                result = String(result.dropFirst().dropLast())
                            }
                            if result.hasPrefix("http") {
                                print("[SpiderManager] 直接从 HTML 提取：\(result.prefix(80))")
                                return result
                            }
                            // 相对路径处理
                            if result.hasPrefix("//") {
                                result = "https:" + result
                                return result
                            }
                            if result.hasPrefix("/") && url.host != nil {
                                if let scheme = url.scheme {
                                    result = "\(scheme)://\(url.host ?? "")" + result
                                    return result
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("[SpiderManager] 直接提取失败：\(error.localizedDescription)")
        }

        return nil
    }

    // 从vodPlayUrl中提取第一集URL
    private func extractFirstPlayableUrl(from vodPlayUrl: String?) -> String? {
        guard let playUrl = vodPlayUrl, !playUrl.isEmpty else {
            return nil
        }

        // 格式：第1集$http://...#第2集$http://...
        let episodes = playUrl.components(separatedBy: "#")

        for episode in episodes {
            // 按 $ 分割，取最后一个（URL部分）
            let parts = episode.components(separatedBy: "$")
            if let urlPart = parts.last {
                // 提取 URL
                if let urlRange = urlPart.range(of: "http") {
                    var url = String(urlPart[urlRange.lowerBound...])

                    // 清理可能的尾部字符，但保留查询参数
                    let stopChars = ["#", "\n", "\r", " ", "$$", "$"]
                    for char in stopChars {
                        if let endRange = url.range(of: char) {
                            url = String(url[..<endRange.lowerBound])
                        }
                    }

                    // 验证是否为有效的视频URL
                    let isVideoUrl = url.contains(".m3u8") ||
                                    url.contains(".mp4") ||
                                    url.contains(".flv") ||
                                    url.contains(".ts") ||
                                    url.contains("/video/") ||
                                    url.contains("/play/") ||
                                    url.contains("m3u8") ||
                                    url.contains("mp4")

                    if isVideoUrl && !url.isEmpty {
                        return url.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // 如果没有#分隔符，直接检查是否包含http
        if playUrl.contains("http") {
            if let urlRange = playUrl.range(of: "http") {
                var url = String(playUrl[urlRange.lowerBound...])

                // 清理尾部
                let stopChars = ["#", "\n", "\r", " "]
                for char in stopChars {
                    if let endRange = url.range(of: char) {
                        url = String(url[..<endRange.lowerBound])
                    }
                }

                // 验证
                let isVideoUrl = url.contains(".m3u8") ||
                                url.contains(".mp4") ||
                                url.contains(".flv") ||
                                url.contains("m3u8") ||
                                url.contains("mp4")

                if isVideoUrl && !url.isEmpty {
                    return url.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return nil
    }

    nonisolated private func fetchDetail(url: URL, siteName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            print("[SpiderManager] fetchDetail 请求: \(url.absoluteString)")
            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResponse = response as? HTTPURLResponse {
                print("[SpiderManager] fetchDetail 响应状态: \(httpResponse.statusCode)")
                guard (200...299).contains(httpResponse.statusCode) else {
                    print("[SpiderManager] fetchDetail 非200状态码: \(httpResponse.statusCode)")
                    return nil
                }
            }

            if let rawStr = String(data: data, encoding: .utf8) {
                _ = String(rawStr.prefix(500))
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]],
               let first = list.first {
                // 打印完整字段名以便调试
                print("[SpiderManager] nativeDetail(ids) \(siteName) 第一条keys: \(first.keys.sorted())")

                // 打印关键字段的内容，用于调试
                print("[SpiderManager] === 关键字段内容 ===")
                for key in ["vod_id", "id", "vod_name", "name", "vod_pic", "pic", "vod_play_url", "play_url", "url", "vod_play_from", "play_from", "from"] {
                    if first[key] != nil {
                        let value = first[key] ?? "nil"
                        if let stringValue = value as? String {
                            print("[SpiderManager] \(key): '\(stringValue.prefix(50))...'")
                        } else {
                            print("[SpiderManager] \(key): \(value)")
                        }
                    }
                }
                print("[SpiderManager] === 字段内容结束 ===")

                let item = Self.makeVodItem(from: first, siteName: siteName)
                print("[SpiderManager] nativeDetail(ids) \(siteName): 解析结果:")
                print("[SpiderManager]   vodId: '\(item.vodId.prefix(20))...'")
                print("[SpiderManager]   vodName: '\(item.vodName)'")
                print("[SpiderManager]   vodPlayUrl: '\(item.vodPlayUrl?.prefix(50) ?? "nil")...'")
                print("[SpiderManager]   vodPlayFrom: '\(item.vodPlayFrom?.prefix(30) ?? "nil")...'")

                // 检查是否有播放地址
                if let playUrl = item.vodPlayUrl, !playUrl.isEmpty {
                    print("[SpiderManager] ✅ nativeDetail 找到播放地址")
                } else if let playFrom = item.vodPlayFrom, !playFrom.isEmpty,
                          let playUrlRaw = item.vodPlayUrl {
                    print("[SpiderManager] ✅ nativeDetail 找到 playFrom+playUrl 组合")
                } else {
                    print("[SpiderManager] ⚠️ nativeDetail 无播放地址")
                }

                return item
            }
        } catch {
            print("[SpiderManager] fetchDetail(ids) \(siteName) 失败: \(error.localizedDescription)")
        }
        return nil
    }

    nonisolated private func fetchDetailFromSearchList(url: URL, siteName: String, targetName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]] {
                // 按名称匹配
                for item in list {
                    let itemName = (item["vod_name"] as? String) ?? ""
                    if itemName.contains(targetName) || targetName.contains(itemName) {
                        let vod = Self.makeVodItem(from: item, siteName: siteName)
                        print("[SpiderManager] nativeDetail(name) 匹配成功: \(siteName)")
                        return vod
                    }
                }
                print("[SpiderManager] nativeDetail(name) \(siteName): 搜索到\(list.count)条但无名称匹配或无播放地址")
            }
        } catch {
            print("[SpiderManager] nativeDetail(name) \(siteName) 失败: \(error.localizedDescription)")
        }
        return nil
    }

    nonisolated private static func makeVodItem(from dict: [String: Any], siteName: String) -> VodItem {
        // 兼容多种字段名变体，包括各种拼写错误
        let vodId = String(describing: dict["vod_id"] ?? dict["id"] ?? dict["v_id"] ?? "")
        let vodName = (dict["vod_name"] as? String) ?? (dict["name"] as? String) ?? (dict["title"] as? String) ?? ""
        let vodPic = (dict["vod_pic"] as? String) ?? (dict["pic"] as? String) ?? (dict["img"] as? String) ?? ""
        let vodRemarks = siteName
        let vodYear = dict["vod_year"] as? String
        let vodDirector = dict["vod_director"] as? String
        let vodActor = dict["vod_actor"] as? String
        let vodContent = dict["vod_content"] as? String

        // 处理 vodPlayFrom - 兼容多种字段名
        var vodPlayFrom: String?
        let playFromKeys = ["vod_play_from", "play_from", "from", "vodFrom", "play_from_name", "vod_play_from_name"]
        for key in playFromKeys {
            if let from = dict[key] as? String, !from.isEmpty {
                vodPlayFrom = from
                break
            }
        }

        // 处理 vodPlayUrl - 兼容多种字段名，包括各种拼写错误
        var vodPlayUrl: String?
        let playUrlKeys = [
            "vod_play_url", "play_url", "url",
            "vodPlayUrl", "vodPrayUrt", "vodPlay Jri",  // 已知的拼写错误
            "vod_play_ur1", "vod_play_urt", "playurl",  // 其他可能的拼写错误
            "vod_play_urls", "urls", "play_urls", "video_url", "playUrl"
        ]

        for key in playUrlKeys {
            if let url = dict[key] as? String, !url.isEmpty {
                print("[SpiderManager] ✅ 使用字段名 '\(key)' 获取播放地址")
                vodPlayUrl = url
                break
            }
        }

        // 如果仍然没有找到播放地址，尝试模糊匹配
        if vodPlayUrl == nil {
            print("[SpiderManager] ⚠️ 标准字段名未找到播放地址，尝试模糊匹配...")
            for (key, value) in dict {
                if let stringValue = value as? String, !stringValue.isEmpty {
                    // 检查字段名是否包含 url 相关的关键词
                    let lowerKey = key.lowercased()
                    if lowerKey.contains("url") || lowerKey.contains("play") || lowerKey.contains("link") || lowerKey.contains("video") {
                        // 检查值是否看起来像是播放地址（包含 http 或 m3u8/mp4 关键字）
                        if stringValue.hasPrefix("http") || stringValue.contains("m3u8") || stringValue.contains("mp4") {
                            print("[SpiderManager] ✅ 模糊匹配找到字段 '\(key)': \(stringValue.prefix(50))...")
                            vodPlayUrl = stringValue
                            break
                        }
                    }
                } else if let arrayValue = value as? [String] {
                    // 处理数组类型的播放地址
                    if !arrayValue.isEmpty {
                        let firstUrl = arrayValue[0]
                        if firstUrl.hasPrefix("http") || firstUrl.contains("m3u8") || firstUrl.contains("mp4") {
                            print("[SpiderManager] ✅ 数组字段找到播放地址 '\(key)': \(firstUrl.prefix(50))...")
                            vodPlayUrl = firstUrl
                            break
                        }
                    }
                } else if let dictValue = value as? [String: Any] {
                    // 处理嵌套字典类型的播放地址
                    for (subKey, subValue) in dictValue {
                        if let subStringValue = subValue as? String {
                            let lowerSubKey = subKey.lowercased()
                            if (lowerSubKey.contains("url") || lowerSubKey.contains("play")) &&
                               (subStringValue.hasPrefix("http") || subStringValue.contains("m3u8") || subStringValue.contains("mp4")) {
                                print("[SpiderManager] ✅ 嵌套字段找到播放地址 '\(key).\(subKey)': \(subStringValue.prefix(50))...")
                                vodPlayUrl = subStringValue
                                break
                            }
                        }
                    }
                    if vodPlayUrl != nil {
                        break
                    }
                }
            }
        }

        // 特殊处理：如果 vodPlayFrom 存在但 vodPlayUrl 为空，尝试从所有字段中找到可能是播放地址的内容
        if vodPlayUrl == nil && vodPlayFrom != nil {
            print("[SpiderManager] ⚠️ vodPlayFrom 存在但 vodPlayUrl 为空，尝试从所有字段中提取...")
            for (key, value) in dict {
                if let stringValue = value as? String, !stringValue.isEmpty {
                    // 跳过已经检查过的字段
                    if key == "vod_id" || key == "id" || key == "vod_name" || key == "name" || key == "title" {
                        continue
                    }
                    // 检查是否包含视频特征
                    if stringValue.contains("://") || stringValue.contains(".m3u8") || stringValue.contains(".mp4") || stringValue.contains("#") {
                        print("[SpiderManager] ✅ 从字段 '\(key)' 提取可能的播放地址：\(stringValue.prefix(80))...")
                        vodPlayUrl = stringValue
                        break
                    }
                }
            }
        }

        // 如果仍然没有找到，打印所有可用字段名用于调试
        if vodPlayUrl == nil {
            print("[SpiderManager] ❌ 未找到播放地址字段")
            print("[SpiderManager] 可用字段名：\(dict.keys.sorted())")
            print("[SpiderManager] 所有字段值（前 100 字符）:")
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                if let stringValue = value as? String {
                    let displayValue = stringValue.count > 100 ? String(stringValue.prefix(100)) + "..." : stringValue
                    print("[SpiderManager]   \(key): '\(displayValue)'")
                } else {
                    print("[SpiderManager]   \(key): \(type(of: value)) = \(value)")
                }
            }
        }

        return VodItem(
            vodId: vodId,
            vodName: vodName,
            vodPic: vodPic,
            vodRemarks: vodRemarks,
            vodYear: vodYear,
            vodDirector: vodDirector,
            vodActor: vodActor,
            vodContent: vodContent,
            vodPlayFrom: vodPlayFrom,
            vodPlayUrl: vodPlayUrl
        )
    }

    // MARK: - 智能去重方法

    /// 智能合并搜索结果：按 vodName+画质 分组，合并来源站点名
    private func smartMerge(item: VodItem, into results: inout [VodItem]) {
        // 提取画质标记
        let quality = extractQuality(from: item.vodRemarks ?? "")
        // 生成去重key：名称 + 画质（如果画质不同则视为不同条目）
        let dedupKey = "\(item.vodName)_\(quality)"

        if let existIdx = results.firstIndex(where: { "\($0.vodName)_\(extractQuality(from: $0.vodRemarks ?? ""))" == dedupKey }) {
            // 合并来源
            var existing = results[existIdx]
            let existingRemarks = existing.vodRemarks ?? ""
            let newRemarks = item.vodRemarks ?? ""
            // 合并来源站点名（去重）
            var sources = Set<String>()
            for r in existingRemarks.components(separatedBy: ",") {
                let s = r.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sources.insert(s) }
            }
            for r in newRemarks.components(separatedBy: ",") {
                let s = r.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sources.insert(s) }
            }
            existing.vodRemarks = sources.joined(separator: ", ")
            // 保留更高画质的备注
            if qualityRank(newRemarks) > qualityRank(existingRemarks) {
                existing.vodRemarks = newRemarks
            }
            // 保留更高画质的封面（vodPic是let常量，不能修改，跳过）
            // if !item.vodPic.isEmpty && qualityRank(newRemarks) > qualityRank(existingRemarks) {
            //     existing.vodPic = item.vodPic
            // }
            results[existIdx] = existing
        } else {
            results.append(item)
        }
    }

    /// 从备注中提取画质标记
    private func extractQuality(from remarks: String) -> String {
        if remarks.contains("4K") { return "4K" }
        if remarks.contains("1080P") || remarks.contains("1080p") { return "1080P" }
        if remarks.contains("720P") || remarks.contains("720p") { return "720P" }
        if remarks.contains("蓝光") { return "蓝光" }
        if remarks.contains("高清") { return "高清" }
        return "其他"
    }

    /// 画质优先级排名（数值越高画质越好）
    private func qualityRank(_ remarks: String) -> Int {
        if remarks.contains("4K") { return 6 }
        if remarks.contains("1080P") || remarks.contains("1080p") { return 5 }
        if remarks.contains("蓝光") { return 4 }
        if remarks.contains("720P") || remarks.contains("720p") { return 3 }
        if remarks.contains("高清") { return 2 }
        return 1
    }

    // MARK: - 多源发现（方案B）

    /// 从 API 地址提取域名作为 Referer
    private func extractReferer(from api: String?) -> String? {
        guard let api = api, let url = URL(string: api), let host = url.host else { return nil }
        let scheme = url.scheme ?? "https"
        return "\(scheme)://\(host)/"
    }

    /// 获取所有可用源（网盘、API、JS蜘蛛、站源），统一为 SourceDisplayItem
    /// 结果会被缓存，allSites 变化时自动失效。调用方可安全地在主线程频繁调用。
    func fetchAllSourceDisplayItems() -> [SourceDisplayItem] {
        if let cached = _cachedSourceDisplayItems { return cached }

        var items: [SourceDisplayItem] = []

        // 1. 网盘源（video_sources.json）
        let cloudSites = loadCloudSitesFromJSONConfig()
        for site in cloudSites {
            let cat: SourceCategory
            switch site.type {
            case .cms: cat = .cloudCMS
            case .forum: cat = .cloudForum
            case .spa: cat = .cloudSPA
            case .wordpress: cat = .cloudCMS
            case .dedecms: cat = .cloudCMS
            case .binhd: cat = .cloudCMS
            }
            let api = site.type == .cms ? "\(site.detailBase)/api.php/provide/vod" : nil
            items.append(SourceDisplayItem(
                id: "cloud_\(site.name)",
                name: site.name,
                category: cat,
                supportsHome: cat.supportsHome,
                api: api,
                searchUrl: nil,
                engineKey: nil,
                referer: extractReferer(from: api),
                siteKey: site.name
            ))
        }

        // 2. API 源（allSites 中 type=0/1）
        let apiSites = allSites.filter { $0.type == 0 || $0.type == 1 }
        for site in apiSites {
            let key = site.key
            if items.contains(where: { $0.id == "api_\(key)" }) { continue }
            items.append(SourceDisplayItem(
                id: "api_\(key)",
                name: site.name,
                category: .api,
                supportsHome: true,
                api: site.api,
                searchUrl: nil,
                engineKey: nil,
                referer: extractReferer(from: site.api),
                siteKey: key
            ))
        }

        // 3. JS 蜘蛛
        for (key, _) in engines {
            if items.contains(where: { $0.id == "js_\(key)" }) { continue }
            let siteConfig = allSites.first(where: { $0.key == key })
            items.append(SourceDisplayItem(
                id: "js_\(key)",
                name: siteConfig?.name ?? key,
                category: .jsSpider,
                supportsHome: true,
                api: nil,
                searchUrl: nil,
                engineKey: key,
                referer: nil,
                siteKey: key
            ))
        }

        // 4. 站源（zhanyuan）
        let zhanyuanSites = DatabaseManager.shared.queryAllZhanyuanSites()
        for site in zhanyuanSites {
            let id = "zhanyuan_\(site.name)"
            if items.contains(where: { $0.id == id }) { continue }
            let baseURL = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let api = "\(baseURL)/api.php/provide/vod"
            items.append(SourceDisplayItem(
                id: id,
                name: site.name,
                category: .zhanyuan,
                supportsHome: true,
                api: api,
                searchUrl: site.searchUrl,
                engineKey: nil,
                referer: extractReferer(from: api),
                siteKey: site.name
            ))
        }

        // 按分类排序（网盘在前）
        items.sort { a, b in
            if a.category.sortOrder != b.category.sortOrder {
                return a.category.sortOrder < b.category.sortOrder
            }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }

        _cachedSourceDisplayItems = items
        return items
    }

    /// 主动清除源列表缓存（engines 变化时调用）
    func invalidateSourceDisplayCache() {
        _cachedSourceDisplayItems = nil
    }

    private nonisolated static func extractRefererForDisplay(from api: String?) -> String? {
        guard let api = api, let url = URL(string: api), let host = url.host else { return nil }
        let scheme = url.scheme ?? "https"
        return "\(scheme)://\(host)/"
    }

    private nonisolated static func loadCloudSitesForDisplayOffMain(remoteData: Data?, bundleSourcesEnabled: Bool) -> [CloudSiteConfig] {
        let decoder = JSONDecoder()
        let fileManager = FileManager.default

        if let remoteData = remoteData {
            do {
                let wrapper = try decoder.decode(CloudSitesWrapper.self, from: remoteData)
                print("[SpiderManager] ✅ 后台从远程默认源缓存加载网盘源，共 \(wrapper.cloudSites.count) 个站点")
                return wrapper.cloudSites
            } catch {
                print("[SpiderManager] ⚠️ 后台远程网盘源缓存解析失败: \(error.localizedDescription)")
            }
        }

        if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let externalPath = documentsPath.appendingPathComponent("video_sources.json")
            if fileManager.fileExists(atPath: externalPath.path) {
                do {
                    let data = try Data(contentsOf: externalPath)
                    let wrapper = try decoder.decode(CloudSitesWrapper.self, from: data)
                    print("[SpiderManager] ✅ 后台从外部加载站点配置，共 \(wrapper.cloudSites.count) 个站点")
                    return wrapper.cloudSites
                } catch {
                    print("[SpiderManager] ⚠️ 后台外部JSON加载失败: \(error.localizedDescription)")
                }
            }
        }

        guard bundleSourcesEnabled else {
            print("[SpiderManager] Bundle 内置源已关闭，后台跳过 video_sources.json")
            return []
        }

        guard let bundlePath = Bundle.main.path(forResource: "video_sources", ofType: "json") else {
            print("[SpiderManager] ❌ 后台找不到默认 video_sources.json 文件")
            return []
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: bundlePath))
            let wrapper = try decoder.decode(CloudSitesWrapper.self, from: data)
            print("[SpiderManager] ✅ 后台从Bundle加载站点配置，共 \(wrapper.cloudSites.count) 个站点")
            return wrapper.cloudSites
        } catch {
            print("[SpiderManager] ❌ 后台 JSON 解析失败: \(error.localizedDescription)")
            return []
        }
    }

    private nonisolated static func buildSourceDisplayItemsOffMain(
        cloudSites: [CloudSiteConfig],
        allSites: [SiteConfig],
        engineKeys: [String],
        zhanyuanSites: [ZhanyuanSite]
    ) -> [SourceDisplayItem] {
        var items: [SourceDisplayItem] = []

        for site in cloudSites {
            let cat: SourceCategory
            switch site.type {
            case .cms: cat = .cloudCMS
            case .forum: cat = .cloudForum
            case .spa: cat = .cloudSPA
            case .wordpress: cat = .cloudCMS
            case .dedecms: cat = .cloudCMS
            case .binhd: cat = .cloudCMS
            }
            let api = site.type == .cms ? "\(site.detailBase)/api.php/provide/vod" : nil
            items.append(SourceDisplayItem(
                id: "cloud_\(site.name)",
                name: site.name,
                category: cat,
                supportsHome: cat.supportsHome,
                api: api,
                searchUrl: nil,
                engineKey: nil,
                referer: extractRefererForDisplay(from: api),
                siteKey: site.name
            ))
        }

        let apiSites = allSites.filter { $0.type == 0 || $0.type == 1 }
        for site in apiSites {
            let key = site.key
            if items.contains(where: { $0.id == "api_\(key)" }) { continue }
            items.append(SourceDisplayItem(
                id: "api_\(key)",
                name: site.name,
                category: .api,
                supportsHome: true,
                api: site.api,
                searchUrl: nil,
                engineKey: nil,
                referer: extractRefererForDisplay(from: site.api),
                siteKey: key
            ))
        }

        for key in engineKeys {
            if items.contains(where: { $0.id == "js_\(key)" }) { continue }
            let siteConfig = allSites.first(where: { $0.key == key })
            items.append(SourceDisplayItem(
                id: "js_\(key)",
                name: siteConfig?.name ?? key,
                category: .jsSpider,
                supportsHome: true,
                api: nil,
                searchUrl: nil,
                engineKey: key,
                referer: nil,
                siteKey: key
            ))
        }

        for site in zhanyuanSites {
            let id = "zhanyuan_\(site.name)"
            if items.contains(where: { $0.id == id }) { continue }
            let baseURL = site.searchUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let api = "\(baseURL)/api.php/provide/vod"
            items.append(SourceDisplayItem(
                id: id,
                name: site.name,
                category: .zhanyuan,
                supportsHome: true,
                api: api,
                searchUrl: site.searchUrl,
                engineKey: nil,
                referer: extractRefererForDisplay(from: api),
                siteKey: site.name
            ))
        }

        items.sort { a, b in
            if a.category.sortOrder != b.category.sortOrder {
                return a.category.sortOrder < b.category.sortOrder
            }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }

        return items
    }

    /// 异步获取所有可用源，将文件 I/O 和数据库查询移出首屏渲染关键路径
    /// 避免主线程被 watchdog 杀掉（scene-update 10s 超时）
    func fetchAllSourceDisplayItemsAsync() async -> [SourceDisplayItem] {
        if let cached = _cachedSourceDisplayItems { return cached }

        let allSitesSnapshot = allSites
        let engineKeysSnapshot = Array(engines.keys)
        let bundleSourcesEnabled = UserDefaults.standard.object(forKey: RemoteSourceConfigKeys.bundleSourcesEnabled) as? Bool ?? false

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<[SourceDisplayItem], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let remoteCloudSitesData = RemoteSourceConfigManager.cachedCloudSitesDataForBackground()
                let cloudSites = Self.loadCloudSitesForDisplayOffMain(
                    remoteData: remoteCloudSitesData,
                    bundleSourcesEnabled: bundleSourcesEnabled
                )
                let zhanyuanSites = DatabaseManager.shared.queryAllZhanyuanSites()
                let items = Self.buildSourceDisplayItemsOffMain(
                    cloudSites: cloudSites,
                    allSites: allSitesSnapshot,
                    engineKeys: engineKeysSnapshot,
                    zhanyuanSites: zhanyuanSites
                )
                continuation.resume(returning: items)
            }
        }

        _cachedSourceDisplayItems = result
        return result
    }

    /// 获取单个源的首页数据
    func fetchHomeData(for source: SourceDisplayItem) async -> SourceHomeData? {
        switch source.category {
        case .cloudCMS, .api, .zhanyuan:
            return await fetchAPIHomeData(source: source)
        case .jsSpider:
            return await fetchJSSpiderHomeData(source: source)
        case .cloudForum, .cloudSPA:
            return nil  // 不支持首页，降级为搜索入口
        }
    }

    /// API 源 / CMS 网盘 / 站源的首页数据
    /// 优先尝试 ac=home（分类+推荐），失败后降级到 ac=list（列表），最后 HTML 兜底
    private func fetchAPIHomeData(source: SourceDisplayItem) async -> SourceHomeData? {
        guard let api = source.api else {
            return await fetchHTMLHomeFallback(source: source)
        }

        let baseURL: String
        if let qIndex = api.firstIndex(of: "?") {
            baseURL = String(api[..<qIndex])
        } else if api.hasSuffix("/") {
            baseURL = String(api.dropLast())
        } else {
            baseURL = api
        }

        // 尝试 ac=home（返回 class + list 分类和推荐）
        if let result = await tryFetchJSON(from: "\(baseURL)?ac=home") {
            if !result.list.isEmpty {
                return SourceHomeData(sourceName: source.name, categories: normalizeCategories(result.categories, list: result.list), recommended: result.list, sourceType: source.category)
            }
        }

        // ac=home 失败或返回空，降级到 ac=list（返回第一页列表，无分类）
        if let result = await tryFetchJSON(from: "\(baseURL)?ac=list&pg=1") {
            if !result.list.isEmpty {
                return SourceHomeData(sourceName: source.name, categories: normalizeCategories(result.categories, list: result.list), recommended: result.list, sourceType: source.category)
            }
        }

        // JSON API 全部失败 → HTML 降级
        return await fetchHTMLHomeFallback(source: source)
    }

    /// 尝试从 JSON API 获取数据，返回 (categories, list)
    private func tryFetchJSON(from urlStr: String) async -> (categories: [VodCategory], list: [VodItem])? {
        guard let url = URL(string: urlStr) else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else { return nil }

            let raw = try JSONDecoder().decode(SourceHomeRaw.self, from: data)
            return (categories: raw.class ?? [], list: raw.list ?? [])
        } catch {
            return nil
        }
    }

    private func normalizeCategories(_ categories: [VodCategory], list: [VodItem]) -> [VodCategory] {
        if categories.isEmpty, !list.isEmpty {
            return [VodCategory(typeId: "__all__", typeName: "全部")]
        }
        return categories
    }

    /// HTML 首页降级方案：抓取站点首页 HTML，解析视频条目
    /// 用于 JSON API 不可用的纯前端 CMS 站点
    private func fetchHTMLHomeFallback(source: SourceDisplayItem) async -> SourceHomeData? {
        // 从 source 中推导站点首页 URL
        let siteBase: String?
        switch source.category {
        case .cloudCMS:
            // cloudCMS 的 api 是 {detailBase}/api.php/provide/vod，首页是 {detailBase}
            if let api = source.api {
                // 去掉 /api.php/provide/vod 后缀
                let apiStr = api.hasSuffix("/") ? String(api.dropLast()) : api
                if let range = apiStr.range(of: "/api.php/provide/vod", options: .backwards) {
                    siteBase = String(apiStr[..<range.lowerBound])
                } else if let range = apiStr.range(of: "/index.php", options: .backwards) {
                    siteBase = String(apiStr[..<range.lowerBound])
                } else {
                    siteBase = apiStr
                }
            } else {
                siteBase = nil
            }
        case .api:
            // api 字段通常是 https://xxx.com/api.php/provide/vod，首页需要从域名提取
            if let api = source.api, let url = URL(string: api), let host = url.host {
                let scheme = url.scheme ?? "https"
                siteBase = "\(scheme)://\(host)"
            } else {
                siteBase = source.api
            }
        case .zhanyuan:
            siteBase = source.searchUrl
        default:
            siteBase = nil
        }

        guard let base = siteBase else { return nil }
        let homeURLStr = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: homeURLStr) else { return nil }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue(cloudPcUA, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let httpResp = response as? HTTPURLResponse,
                  (200...299).contains(httpResp.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                print("[SpiderManager] HTML降级[\(source.name)] HTTP \(code)")
                return nil
            }

            guard let html = String(data: data, encoding: .utf8), !html.isEmpty else { return nil }

            // 从 HTML 首页提取视频条目和分类
            let (videos, cats) = extractHTMLHomePage(from: html, siteBase: homeURLStr, sourceName: source.name)
            guard !videos.isEmpty else { return nil }

            print("[SpiderManager] HTML降级[\(source.name)] 成功: \(videos.count)条视频, \(cats.count)个分类")
            return SourceHomeData(
                sourceName: source.name,
                categories: cats,
                recommended: videos,
                sourceType: source.category
            )
        } catch {
            print("[SpiderManager] HTML降级[\(source.name)] 失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 从 CMS 站点首页 HTML 中提取视频列表和分类导航
    private func extractHTMLHomePage(from html: String, siteBase: String, sourceName: String) -> (videos: [VodItem], categories: [VodCategory]) {
        var videos: [VodItem] = []
        var categories: [VodCategory] = []
        var seenIDs = Set<String>()

        // 1. 提取分类导航：匹配各种 CMS 模板的分类链接
        let catPatterns = [
            // AppleCMS 标准：/index.php/vod/type/id/1.html
            #"href="(/index\.php/vod/type/id/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // AppleCMS 变体：/vodtype/1.html
            #"href="(/vodtype/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // AppleCMS 变体：/vodtype/1/ 结尾斜杠格式
            #"href="(/vodtype/(\d+)/?)"[^>]*>([^<]+)</a>"#,
            // 通用模板：/type/1.html
            #"href="(/type/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // AppleCMS 变体：/index.php/vod/show/id/1.html
            #"href="(/index\.php/vod/show/id/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：?m=vod-type-id-1.html
            #"href="(\?m=vod-type-id-(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/list/1.html
            #"href="(/list/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/category/1.html
            #"href="(/category/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/vod/type/1.html
            #"href="(/vod/type/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/vodshow/1.html
            #"href="(/vodshow/(\d+)\.html)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/vodshow/1/ 结尾斜杠格式
            #"href="(/vodshow/(\d+)/?)"[^>]*>([^<]+)</a>"#,
            // 非 AppleCMS：/vod/type/id/1 无 .html 后缀
            #"href="(/vod/type/id/(\d+))"[^>]*>([^<]+)</a>"#,
            // title 属性方式：href="/vodtype/1/" title="电影"
            #"href="(/vodtype/(\d+)/?)"[^>]*title="([^"]{1,10})""#,
            // title 属性方式：href="/vodshow/1/" title="电影"
            #"href="(/vodshow/(\d+)/?)"[^>]*title="([^"]{1,10})""#,
        ]
        for pattern in catPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard match.numberOfRanges >= 4 else { continue }
                guard let idRange = Range(match.range(at: 2), in: html),
                      let nameRange = Range(match.range(at: 3), in: html) else { continue }
                let typeId = String(html[idRange])
                let typeName = String(html[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                // 过滤导航项
                guard !typeName.isEmpty, typeName.count < 10,
                      !typeName.contains("首页"), !typeName.contains("地图"),
                      !typeName.contains("APP"), !typeName.contains("留言") else { continue }
                let cat = VodCategory(typeId: typeId, typeName: typeName)
                if !categories.contains(where: { $0.typeId == typeId }) {
                    categories.append(cat)
                }
            }
            if !categories.isEmpty { break }
        }

        // 2. 提取视频条目：匹配详情链接 + 图片 + 标题
        let videoPatterns = [
            // 标准模板：封面图 + 标题 + 链接（.html 后缀）
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*"[^>]*>.*?<img[^>]*data-original="([^"]*)"[^>]*>.*?</a>"#,
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*"[^>]*>.*?<img[^>]*data-src="([^"]*)"[^>]*>.*?</a>"#,
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*"[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*>.*?</a>"#,
            // 变体模板：无 .html 后缀（如 /voddetail/123/）
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)/?)[^"]*"[^>]*>.*?<img[^>]*data-original="([^"]*)"[^>]*>.*?</a>"#,
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)/?)[^"]*"[^>]*>.*?<img[^>]*data-src="([^"]*)"[^>]*>.*?</a>"#,
            #"<a\s+href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)/?)[^"]*"[^>]*>.*?<img[^>]*src="([^"]*)"[^>]*>.*?</a>"#,
        ]

        for pattern in videoPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                guard match.numberOfRanges >= 4 else { continue }
                guard let hrefRange = Range(match.range(at: 1), in: html),
                      let idRange = Range(match.range(at: 2), in: html),
                      let picRange = Range(match.range(at: 3), in: html) else { continue }
                let detailPath = String(html[hrefRange])
                let vodId = String(html[idRange])
                let pic = String(html[picRange])

                guard seenIDs.insert(vodId).inserted else { continue }

                // 从链接附近的 HTML 中提取标题
                let title = extractTitleNearLink(html: html, matchRange: match.range)

                let fullPic: String
                if pic.hasPrefix("http") {
                    fullPic = pic
                } else if pic.hasPrefix("//") {
                    fullPic = "https:" + pic
                } else {
                    fullPic = siteBase + (pic.hasPrefix("/") ? "" : "/") + pic
                }

                let detailURL = siteBase + detailPath
                let (vodYear, vodArea) = extractYearAndAreaNearLink(html: html, matchRange: match.range)
                let item = VodItem(
                    vodId: detailURL,
                    vodName: title,
                    vodPic: fullPic,
                    vodRemarks: "☁️" + sourceName,
                    vodYear: vodYear,
                    vodArea: vodArea
                )
                videos.append(item)
            }
            if !videos.isEmpty { break }
        }

        // 3. 如果上面没匹配到（某些模板结构不同），用更宽松的匹配
        if videos.isEmpty {
            let loosePatterns = [
                #"<a[^>]*href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)\.html)[^"]*""#,
                #"<a[^>]*href="((?:/index\.php/vod/detail/id/|/voddetail/|/detail/|/vod/)(\d+)/?)[^"]*""#,
            ]
            for loosePattern in loosePatterns {
            if let regex = try? NSRegularExpression(pattern: loosePattern, options: []) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for match in matches {
                    guard match.numberOfRanges >= 3 else { continue }
                    guard let hrefRange = Range(match.range(at: 1), in: html),
                          let idRange = Range(match.range(at: 2), in: html) else { continue }
                    let detailPath = String(html[hrefRange])
                    let vodId = String(html[idRange])

                    guard seenIDs.insert(vodId).inserted else { continue }
                    let title = extractTitleNearLink(html: html, matchRange: match.range)
                    let detailURL = siteBase + detailPath
                    let (vodYear, vodArea) = extractYearAndAreaNearLink(html: html, matchRange: match.range)

                    let item = VodItem(
                        vodId: detailURL,
                        vodName: title,
                        vodPic: "",
                        vodRemarks: "☁️" + sourceName,
                        vodYear: vodYear,
                        vodArea: vodArea
                    )
                    videos.append(item)
                }
            }
            if !videos.isEmpty { break }
            }
        }

        return (videos, categories)
    }

    /// 从 HTML 中提取标题文本（同源提取：标题与封面来自同一个 <a>...</a> 块）
    ///
    /// 修复说明：原实现在 matchRange ±500 字符窗口内用 firstMatch 取第一个 title/alt，
    /// 当相邻卡片间距小于 500 字符时窗口会跨越多张卡片，导致标题漂移到相邻卡片，
    /// 表现为封面图与资源标题不一致（尤其首页前部紧凑的推荐位区块）。
    ///
    /// 现改为：① 优先在当前块内提取（同源最可靠）；② 块内没有时只在块"之后"小范围查找
    /// （推荐位标题常在 <a> 外部的 <p class="title">），且不往前扩、截断到下一个详情链接前，
    /// 确保标题始终属于当前卡片。
    private func extractTitleNearLink(html: String, matchRange: NSRange) -> String {
        let blockStart = matchRange.location
        let blockEnd = matchRange.location + matchRange.length

        // 策略 1：当前 <a>...</a> 块内的 <a title> 与 <img alt>（同源，最可靠）
        if let bIdx = html.index(html.startIndex, offsetBy: blockStart, limitedBy: html.endIndex),
           let eIdx = html.index(html.startIndex, offsetBy: min(html.count, blockEnd), limitedBy: html.endIndex) {
            let block = String(html[bIdx..<eIdx])

            // <a title="...">
            let aTitlePattern = #"<a[^>]*title="([^"]{2,80})""#
            if let ar = try? NSRegularExpression(pattern: aTitlePattern, options: [.caseInsensitive]),
               let am = ar.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
               let aRange = Range(am.range(at: 1), in: block) {
                let t = String(block[aRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 2 { return t }
            }

            // <img alt="...">
            let imgAltPattern = #"<img[^>]+alt="([^"]{2,80})""#
            if let ar = try? NSRegularExpression(pattern: imgAltPattern, options: [.caseInsensitive]),
               let am = ar.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
               let aRange = Range(am.range(at: 1), in: block) {
                let t = String(block[aRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count > 2 && !t.contains("更新到") && !t.contains("更新至") { return t }
            }
        }

        // 策略 2：块内没有时，只在块"之后"小范围查找标题
        // 关键：不往前扩（往前扩会漂移到上一个卡片），并截断到下一个详情链接前
        let afterStart = blockEnd
        let afterEnd = min(html.count, afterStart + 300)
        if let sIdx = html.index(html.startIndex, offsetBy: afterStart, limitedBy: html.endIndex),
           let eIdx = html.index(html.startIndex, offsetBy: afterEnd, limitedBy: html.endIndex) {
            var after = String(html[sIdx..<eIdx])
            // 截断到下一个详情链接前，避免越过到下一卡片
            if let nextRange = after.range(of: #"/vod/detail/id/|/voddetail/|/detail/|/vod/"#, options: .regularExpression) {
                after = String(after[..<nextRange.lowerBound])
            }
            let afterPatterns = [
                #"<h[2-4][^>]*>([^<]{2,80})</h[2-4]>"#,
                #"<span[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</span>"#,
                #"<div[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</div>"#,
                #"<p[^>]*class="[^"]*title[^"]*"[^>]*>([^<]{2,80})</p>"#,
            ]
            for ap in afterPatterns {
                if let ar = try? NSRegularExpression(pattern: ap, options: [.caseInsensitive]),
                   let am = ar.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)),
                   let arr = Range(am.range(at: 1), in: after) {
                    let t = String(after[arr]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count > 2 && !t.contains("更新到") && !t.contains("更新至") { return t }
                }
            }
        }

        // 策略 3：链接标签 innerHTML（范围从块开始到块后 300，不含块前）
        let innerPattern = #"<a[^>]*href="[^"]*"([^>]*)>([^<]{2,80})</a>"#
        if let ir = try? NSRegularExpression(pattern: innerPattern, options: [.dotMatchesLineSeparators]) {
            let tightStart = blockStart
            let tightEnd = min(html.count, blockEnd + 300)
            if let tsIdx = html.index(html.startIndex, offsetBy: tightStart, limitedBy: html.endIndex),
               let teIdx = html.index(html.startIndex, offsetBy: tightEnd, limitedBy: html.endIndex) {
                let tight = String(html[tsIdx..<teIdx])
                if let tm = ir.firstMatch(in: tight, range: NSRange(tight.startIndex..., in: tight)),
                   let tmRange = Range(tm.range(at: 2), in: tight) {
                    var t = String(tight[tmRange]).replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count < 4 || t.contains("更新到") || t.contains("更新至") {
                        t = ""
                    }
                    if t.count > 2 { return t }
                }
            }
        }

        return "未知标题"
    }

    /// 从 HTML 中提取年份和地区（同源提取：只在当前块及块之后小范围查找，不往前扩）
    /// 修复说明：原实现 searchStart = matchRange.location - 300，往前扩会漂移到上一个卡片的年份信息。
    private func extractYearAndAreaNearLink(html: String, matchRange: NSRange) -> (year: String?, area: String?) {
        // 不往前扩：从当前块开始，到块后 300 字符（年份/地区信息通常在标题附近）
        let searchStart = matchRange.location
        let searchEnd = min(html.count, matchRange.location + matchRange.length + 300)
        guard let sIdx = html.index(html.startIndex, offsetBy: searchStart, limitedBy: html.endIndex),
              let eIdx = html.index(html.startIndex, offsetBy: searchEnd, limitedBy: html.endIndex) else { return (nil, nil) }
        let ctx = String(html[sIdx..<eIdx])

        var year: String?
        var area: String?

        // 匹配 "年份 / 地区 / 类型" 或 "年份-地区" 格式
        let infoPatterns = [
            #"(\d{4})\s*/\s*([^<>\s/]{2,8})\s*/"#,   // "2024 / 大陆 /"
            #"(\d{4})\s*-\s*([^<>\s/-]{2,8})"#,        // "2024-大陆"
        ]
        for pattern in infoPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: ctx, range: NSRange(ctx.startIndex..., in: ctx)),
               let yrRange = Range(match.range(at: 1), in: ctx),
               let arRange = Range(match.range(at: 2), in: ctx) {
                year = String(ctx[yrRange])
                let rawArea = String(ctx[arRange]).trimmingCharacters(in: .whitespaces)
                // 过滤掉明显是类型的词（如"动作"、"喜剧"等）
                let typeWords = ["动作", "喜剧", "爱情", "科幻", "恐怖", "悬疑", "剧情", "动画", "奇幻", "冒险", "战争", "犯罪", "纪录", "古装", "历史", "武侠", "家庭", "伦理", "军事", "谍战", "穿越", "青春", "偶像", "惊悚", "同性", "灾难", "音乐", "歌舞", "传记", "运动", "短片", "微电影", "福利", "伦理片"]
                if !typeWords.contains(rawArea) && rawArea.count <= 8 {
                    area = rawArea
                }
                break
            }
        }

        // 只匹配年份（如果没有匹配到完整格式）
        if year == nil {
            let yearOnlyPattern = #"\b(20\d{2})\b"#
            if let regex = try? NSRegularExpression(pattern: yearOnlyPattern, options: []),
               let match = regex.firstMatch(in: ctx, range: NSRange(ctx.startIndex..., in: ctx)),
               let yrRange = Range(match.range(at: 1), in: ctx) {
                year = String(ctx[yrRange])
            }
        }

        return (year, area)
    }

    /// JS 蜘蛛的 home
    private func fetchJSSpiderHomeData(source: SourceDisplayItem) async -> SourceHomeData? {
        guard let key = source.engineKey, let engine = engines[key] else { return nil }

        do {
            let result = try engine.callHomeContent()
            let categories = result.class ?? []
            var list = result.list ?? []
            for i in 0..<list.count { list[i].engineKey = key }

            // 允许 list 为空：分类列表仍然可用，用户可切换分类浏览
            return SourceHomeData(
                sourceName: source.name,
                categories: categories,
                recommended: list,
                sourceType: .jsSpider
            )
        } catch {
            print("[SpiderManager] fetchJSSpiderHome[\(source.name)] 失败: \(error.localizedDescription)")
            return nil
        }
    }
}

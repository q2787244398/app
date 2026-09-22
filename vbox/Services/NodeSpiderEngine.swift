import Foundation

// MARK: - A1 接缝：Node 常驻系统蜘蛛引擎（形态 A'' 接线）
//
// P2-03 实现（开发方案 v1.17 阶段 2）。
//
// 协议对齐（bundle kstore_index.js 内置 spiders，统一挂载 /spider/{key}/{type}）：
//   - POST /spider/{nodeKey}/3/home         → {class:[], list:[...]}（HomeContentResult）
//   - POST /spider/{nodeKey}/3/category     body {tid, pg, extend}
//   - POST /spider/{nodeKey}/3/detail       body {id, ids}（bundle 统一读 body.id，见下）
//   - POST /spider/{nodeKey}/3/search       body {wd, pg}
//   - POST /spider/{nodeKey}/3/player       body {id, ids, flag, url}
//   （参数与 bundle 蜘蛛协议对位，议题 18.6 已代码实证 ✅）
//
// key 映射：vbox 站点 key（nodejs_xxx / csp_xxx）→ Node 系统内蜘蛛 key（xxx），
// 规则 = 去掉 nodejs_ 或 csp_ 前缀（议题 13.10 形态 ③ 定稿）。
//
// 铁律：
//   1. 本引擎只桥接 Node 托管蜘蛛（key 前缀 nodejs_ / 标记 group:"node" 的站点）；
//   2. 非 Node 站点（百度/夸克/UC/阿里等原生源、普通 JS/Python 蜘蛛）零改动；
//   3. Node 未就绪 / 桥接失败时抛出明确错误并输出错误日志，不静默兜底，便于排查。

final class NodeSpiderEngine: SpiderEngineProtocol {

    var onLog: ((String) -> Void)?

    /// Node 蜘蛛始终"就绪"—— 实际可用性由 NodeRuntimeManager.isSystemReady 决定。
    /// 桥接方法内部会再次校验，未就绪时抛出明确错误。
    var isSpiderReady: Bool { NodeRuntimeManager.shared.isSystemReady }

    /// vbox 站点 key（含 nodejs_/csp_ 前缀）
    private let siteKey: String
    /// Node 系统内蜘蛛 key（去掉前缀）
    private let nodeKey: String

    private let session: URLSession

    init(siteKey: String) {
        self.siteKey = siteKey
        // key 映射：nodejs_xxx / csp_xxx → xxx，再经订阅源 key → bundle spider key 归一化
        self.nodeKey = Self.normalizeNodeKey(siteKey)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    // MARK: - 订阅源 key → Node bundle spider key 归一化
    //
    // 阶段2实测：订阅源蜘蛛 key（AiNewMuOu / SportAiKaFei / 玩偶 …）与 Node bundle
    // （kstore_index.js）内注册的 spider key（muou / sportaikafei / wogg …）不一致，
    // 直接按原 key 桥接 → /spider/{key}/3/* 命中 404。
    // 规则：1) 先去 nodejs_/csp_ 前缀；2) 显式映射表命中；3) 小写兜底；4) 原样透传。

    /// 订阅源 key → bundle 注册 key（来自 node-spider-key-map.json，84/96 可映射）
    static let bundleKeyMap: [String: String] = [
        "Douban": "douban", "Doubanaaaa": "gengxin", "Wexconfig": "baseset", "MyPan": "mypan",
        "玩偶": "wogg", "AiNewGuanYing": "guanying", "AiQwMkv": "qwmkv", "AiNewPianKu": "pianku",
        "AiNewHuBan": "huban", "AiNewMuOu": "muou", "AiNewDuoDuo": "duoduo", "AiNewJuTou": "jutou",
        "AiNewLibvio": "libvio", "原盘": "zhinan4k", "蜗牛": "woniu4k", "AiPan1Me": "pan123ziyuan",
        "AiNewYiDong4K": "yidong4k", "WexHanXiaoQuan": "hanxiaoquan", "WexAiGuaZi": "guazi",
        "WexAiDuBoKu": "wexDuBoKu", "WexAiYueYue": "wexYueYue", "WexAiWenCai": "wencai",
        "WexFengYe4K": "wexfengye4k", "AppV7 | 大师兄": "appv7dashixiong", "AppV7 | 粉猪追剧": "appv7fenzhu",
        "AppV7 | 咸鱼": "appv7xianyu", "AppV7 | 追剧达人": "appv7zhuijudaren", "AppV7 | 小柚子": "appv7xiaoyouzi",
        "AppV7 | 小柠檬": "appv7xiaoningmeng", "AppV7 | 蒙太奇": "appv7mengtaiqi",
        "AppV7 | 零零七影视": "appv7linglingqi", "AppV7 | 小柿子": "appv7xiaoshizi",
        "AppV7 | 小黄人": "appv7xiaohuangren", "WexAiYiYs": "yiyingshi", "WexAiReBo": "rebo",
        "WexAiBoBo": "bobo", "WexAiIkanBot": "ikanbot", "LiveAiHuYa": "huya", "LiveAiDouYu": "douyu",
        "LiveAiBiLi": "bililive", "ManJuAiHongGuo": "manjuhongguo", "ManJuAiHuoLong": "manjuhuolong",
        "ManJuAiQiMao": "manjuqimao", "ManJuAiXiFan": "manjuxifan", "ManJuAiHeMa": "hema",
        "DuanJuAiHaoKan": "baiduduanju", "DuanJuAiQiMiao": "duanjuqimiao", "DuanJuAiXingYa": "duanjuxingya",
        "DuanJuAiWeiGuan": "duanjuweiguan", "AnimeXiFan": "animexifan", "AnimeCiYuanCheng": "animeciyuancheng",
        "AnimeAiMoDu": "animemodu", "BookHongGuo": "bookhongguo", "BookHeMa": "bookhema",
        "BookAiShiJie": "bookaishijie", "BookAiYueTing": "bookaiyueting", "ChildrenAiBaoBao": "childrenaibaobao",
        "ChildrenAiBeiWa": "childrenaibeiwa", "ChildrenAiTuTu": "childrenaitutu", "MusicAiQingTing": "musicaiqingting",
        "MusicAiIKtv": "musicaikg", "MusicAiKuWoa": "musicaikuwoa", "MusicAi163": "musicai163",
        "MusicAiKuWo": "musicaikuwo", "MusicAiLunHui": "musicailunhui", "SportAiFeiQiu": "sportaifeiqiu",
        "SportAiGuaZi": "sportaiguazi", "SportAiKanQiuTong": "sportaikanqiutong", "SportAiKanqiu": "sportaikanqiu",
        "SportAiKaFei": "sportaikafei", "SportAiWwe": "sportaiwwe", "FakeAi115Share": "fake115share",
        "biliys": "biliys", "bilibili": "bilibili", "bilixiqu": "bilixiqu", "biliych": "biliych",
        "少儿教育": "少儿教育", "小学课堂": "小学课堂", "初中课堂": "初中课堂", "高中教育": "高中教育",
        "SoAiHaiYin": "soaihaiyin", "SoAiPanSoo": "soaipansoo", "SoAiQuPanShe": "soaiqupanshe",
        "SoKaKa": "sokaka",
    ]

    /// 归一化：去前缀 → 映射表 → 小写兜底 → 原样
    static func normalizeNodeKey(_ key: String) -> String {
        var stripped = key
        for prefix in ["nodejs_", "csp_"] where stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
            break
        }
        if let mapped = bundleKeyMap[stripped] { return mapped }
        let lowered = stripped.lowercased()
        if lowered != stripped { return lowered }
        return stripped
    }

    // MARK: - 空操作 —— Node 引擎不需要在本地加载 JS

    func loadScript(_ script: String) throws {
        onLog?("⚠️ [NodeSpiderEngine] 忽略 loadScript（Node 蜘蛛不在本地执行 JS）")
    }

    func loadLibrary(_ script: String) throws {
        onLog?("⚠️ [NodeSpiderEngine] 忽略 loadLibrary（Node 蜘蛛不在本地执行 JS）")
    }

    func loadScriptFromURL(_ urlString: String) async throws {
        onLog?("⚠️ [NodeSpiderEngine] 忽略 loadScriptFromURL（Node 蜘蛛不在本地执行 JS）")
    }

    func registerSpider() throws {}

    // MARK: - 五个协议方法 → 桥接 Node 常驻系统

    func callHomeContent() throws -> HomeContentResult {
        try perform("home", params: nil)
    }

    func callCategoryContent(tid: String, pg: Int, extend: String) throws -> CategoryContentResult {
        try perform("category", params: ["tid": tid, "pg": pg, "extend": extend])
    }

    func callDetailContent(ids: String) throws -> DetailContentResult {
        // bundle 蜘蛛 detail 统一读 body.id（kstore_index.js 258 处 body?.id / body.id，
        // 0 处读 ids）；同时携带 ids 兼容未来读取多数的实现。
        try perform("detail", params: ["id": ids, "ids": ids])
    }

    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult {
        try perform("search", params: ["wd": keyword, "pg": pg])
    }

    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        // 同上：bundle play 读 body.id（Od: String(w.body?.id)，AppV7: String(c.id)）
        try perform("player", params: ["id": vodId, "ids": vodId, "flag": flag, "url": url])
    }

    // MARK: - 桥接实现（同步等待，35s 超时兜底）

    private func perform<T: Decodable>(_ action: String, params: [String: Any]?) throws -> T {
        // 🔧 修复: Node 未就绪时先限时等待，而不是立即抛错。
        // App 启动时 Node 常驻系统初始化需要数秒（部署文件→启动引擎→ack→HTTP 探活），
        // 此前首页/分类并发加载 97 个引擎时几乎全部命中未就绪 → 分类数据大面积缺失。
        // 后台线程轮询等待（最多 20s）；主线程不等待，避免阻塞 UI。
        if !NodeRuntimeManager.shared.isSystemReady {
            if Thread.isMainThread {
                let msg = "Node 常驻系统未就绪，无法桥接蜘蛛 \(siteKey) (action=\(action))"
                onLog?("❌ \(msg)")
                AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
                throw NodeSpiderError.systemNotReady
            }
            let waitDeadline = Date().addingTimeInterval(20)
            while !NodeRuntimeManager.shared.isSystemReady && Date() < waitDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if !NodeRuntimeManager.shared.isSystemReady {
                let msg = "Node 常驻系统等待 20s 仍未就绪，无法桥接蜘蛛 \(siteKey) (action=\(action))"
                onLog?("❌ \(msg)")
                AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
                throw NodeSpiderError.systemNotReady
            }
        }

        let base = NodeRuntimeManager.shared.baseURL
        // 中文源 key（少儿教育/小学课堂/初中课堂/高中教育）必须百分号编码，
        // 否则 URL(string:) 对非 ASCII 返回 nil → 桥接恒失败（HTTP 400/无效 URL）
        let path = "/spider/\(nodeKey)/3/\(action)"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "\(base)\(encodedPath)") else {
            let msg = "桥接蜘蛛 \(siteKey) 生成无效 URL: \(base)\(path)"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge("无效 URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vbox/1.0", forHTTPHeaderField: "User-Agent")
        // Node 侧要求合法 JSON body：无参数时发 {}，杜绝空 body 触发 HTTP 400
        let body: Data
        if let params = params {
            body = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        } else {
            body = Data("{}".utf8)
        }
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                resultError = error
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                resultError = NodeSpiderError.bridge("HTTP \(http.statusCode)")
            } else {
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()

        // 35s 超时兜底，防回调丢失死锁（议题 18 K2 / S2-6）
        let waitResult = semaphore.wait(timeout: .now() + 35)
        if waitResult == .timedOut {
            task.cancel()
            let msg = "桥接蜘蛛 \(siteKey) \(action) 超时（35s）"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge("请求超时")
        }

        if let resultError = resultError {
            let msg = "桥接蜘蛛 \(siteKey) \(action) 失败: \(resultError.localizedDescription)"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge(resultError.localizedDescription)
        }

        guard let data = resultData, !data.isEmpty else {
            let msg = "桥接蜘蛛 \(siteKey) \(action) 返回空数据"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge("返回空数据")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let msg = "桥接蜘蛛 \(siteKey) \(action) 响应解码失败: \(error.localizedDescription)"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge("响应解码失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - 错误类型

enum NodeSpiderError: LocalizedError {
    /// Node 常驻系统未就绪
    case systemNotReady
    /// 桥接失败（网络 / 超时 / 解码）
    case bridge(String)

    var errorDescription: String? {
        switch self {
        case .systemNotReady:
            return "Node 常驻系统未就绪，请稍后重试"
        case .bridge(let message):
            return "Node 蜘蛛桥接失败: \(message)"
        }
    }
}

// MARK: - B1/B3/C1/C2 预留：LXBridgeEngineError

enum LXBridgeError: LocalizedError {
    case lxNotReady
    case bridge(String)
    var errorDescription: String? {
        switch self {
        case .lxNotReady: return "lx 音乐源暂不可用"
        case .bridge(let m): return "lx 桥接失败: \(m)"
        }
    }
}

// MARK: - lx-music 桥接引擎（P1-A1）────────────────────────────
//
// 复用 Node 常驻进程内的独立 lx HTTP 服务（NodeRuntimeManager.lxPort=58083），
// 为 lx-music 协议插件（刀源 / 念心）提供搜索 / 直链解析 / 歌词能力。
// 关键纪律：
//   - 只桥接 engineType == .nodeLX 的源（key 见 lxKeyMap）；
//   - 视频 / 网盘 / kstore 音乐源零接触；
//   - lx 不可用（isLXReady=false）时抛出 lxNotReady，由 UI 温和提示，不影响其他源。

final class LXBridgeEngine: SpiderEngineProtocol {

    var onLog: ((String) -> Void)?

    var isSpiderReady: Bool { NodeRuntimeManager.shared.isLXReady }

    /// vbox 站点 key（nodejs_musicaidaxe / nodejs_musicainianxin …）
    private let siteKey: String
    /// lx 插件 key（对应插件文件名，如 daxe / nianxin，经 lx-bridge 路由）
    let pluginKey: String
    /// 每个插件声明的平台源能力（source -> {name, actions, qualitys,...}），list 时拉取
    private var sourcesMeta: [String: [String: Any]] = [:]

    /// 已知 lx 音乐源 key → 插件 key 白名单（P1-A2：白名单式识别，防误判）
    static let lxKeyMap: [String: String] = [
        "nodejs_musicaidaxe": "daxe",
        "nodejs_musicainianxin": "nianxin",
    ]

    init(siteKey: String) {
        self.siteKey = siteKey
        self.pluginKey = Self.lxKeyMap[siteKey]
            ?? Self.deriveKey(siteKey)
    }

    /// 兜底推导：去前缀后保留（念心 = nodejs_musicainianxin → nianxin）
    private static func deriveKey(_ k: String) -> String {
        var s = k
        for p in ["nodejs_musicaid", "nodejs_musicai", "csp_", "nodejs_"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        return s.isEmpty ? k : s
    }

    private var base: String { NodeRuntimeManager.shared.lxBaseURL }

    // MARK: - 协议方法（lx 无首页/详情，一律空返回；不进入视频搜索）

    func loadScript(_ script: String) throws {
        onLog?("⚠️ [LXBridgeEngine] 忽略 loadScript（lx 插件由 Node 运行时托管）")
    }
    func loadLibrary(_ script: String) throws {
        onLog?("⚠️ [LXBridgeEngine] 忽略 loadLibrary（lx 插件由 Node 运行时托管）")
    }
    func loadScriptFromURL(_ urlString: String) async throws {
        onLog?("⚠️ [LXBridgeEngine] 忽略 loadScriptFromURL")
    }
    func registerSpider() throws {}

    func callHomeContent() throws -> HomeContentResult { HomeContentResult(class: nil, list: nil) }
    func callCategoryContent(tid: String, pg: Int, extend: String) throws -> CategoryContentResult {
        CategoryContentResult(page: 1, pagecount: 1, limit: nil, total: nil, list: nil)
    }
    func callDetailContent(ids: String) throws -> DetailContentResult { DetailContentResult(list: nil) }
    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult {
        // 关键隔离（P1-A5）：lx 的 search 不进入视频搜索返回集。
        SearchContentResult(page: pg, pagecount: 1, list: nil)
    }
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        PlayerContentResult(parse: 0, playUrl: nil, url: nil, header: nil)
    }

    // MARK: - 桥接 HTTP（JSONSerialization 解析，规避 Codable-[String:Any] 不成立问题）

    /// 调用桥插件的指定 action，返回 `(完整响应字典, result 原始值)`。
    /// result 保持原始 JSON 类型（String / [[String:Any]] / [String:Any]），由调用方按需解析。
    private func bridgeCall(_ action: String, _ body: [String: Any]?) async throws -> ([String: Any], Any?) {
        guard NodeRuntimeManager.shared.isLXReady else { throw LXBridgeError.lxNotReady }
        guard let url = URL(string: "\(base)/lx/\(pluginKey)/\(action)") else {
            throw LXBridgeError.bridge("无效 URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = action == "search" ? 14 : 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body = body {
            request.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw LXBridgeError.bridge("HTTP \(http.statusCode)")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            throw LXBridgeError.bridge("响应非 JSON")
        }
        return (obj, obj["result"])
    }

    /// 校验响应门面：ok==false 时抛错；loading 视为 lx 尚未就绪。
    @discardableResult
    private func ensureOk(_ obj: [String: Any]) throws -> Bool {
        if let ok = obj["ok"] as? Bool, ok {
            return true
        }
        if (obj["loading"] as? Bool) ?? false {
            throw LXBridgeError.lxNotReady
        }
        let err = obj["error"] as? String ?? "未知错误"
        throw LXBridgeError.bridge(err)
    }

    /// 拉取插件元数据并缓存
    func refreshMetadata() async {
        guard let (obj, _) = try? await bridgeCall("list", nil),
              let plugin = obj["plugin"] as? [String: Any],
              let sources = plugin["sources"] as? [String: Any] else { return }
        self.sourcesMeta = sources
    }

    /// 插件声明支持的平台（如 wy/tx/kw/kg/mg）
    var supportedSources: [String] {
        sourcesMeta.isEmpty ? Array(Self.defaultSources) : Array(sourcesMeta.keys)
    }
    private static let defaultSources = ["wy", "tx", "kw", "kg", "mg"]

    /// 指定平台的可用音质
    func availQualities(for source: String) -> [String] {
        guard let meta = sourcesMeta[source] as? [String: Any],
              let qs = meta["qualitys"] as? [String], !qs.isEmpty else { return ["128k", "320k"] }
        return qs
    }

    // MARK: - 搜索（P1-A5 音乐搜索用；元数据映射 B3）

    /// 对单个平台执行 lx search，返回转换为 VodItem 的歌曲列表。
    /// 念心等不提供 search 的平台返回空数组（优雅降级）。
    func searchSongs(keyword: String, source: String, page: Int = 1) async throws -> [VodItem] {
        guard let (obj, result) = try? await bridgeCall("search", ["name": keyword, "page": page, "source": source]) else {
            throw LXBridgeError.bridge("search 连接失败")
        }
        try ensureOk(obj)
        guard let list = result as? [[String: Any]] else { return [] }
        var items: [VodItem] = []
        for song in list {
            items.append(Self.vodItem(from: song, source: source, pluginKey: pluginKey))
        }
        return items
    }

    private static func vodItem(from song: [String: Any], source: String, pluginKey: String) -> VodItem {
        let id = String(song["id"] as? String ?? song["songmid"] as? String ?? song["hash"] as? String ?? "")
        let name = song["name"] as? String ?? ""
        let singer = song["singer"] as? String ?? ""
        let picture = (song["picture"] as? String) ?? ""
        let pic = picture.isEmpty ? song["pic"] as? String ?? "" : picture
        var remarks = source
        if !singer.isEmpty { remarks = "\(source)\t\(singer)" }
        // P2-B2/B3：时长 interval("mm:ss")→秒、专辑 albumName、可发音质 qualitys 一并注入 VodItem
        let duration = parseInterval(song, key: "interval")
        let album = (song["albumName"] as? String) ?? (song["album"] as? String)
        let qs = (song["qualitys"] as? [String]) ?? (song["quality"] as? [String]) ?? []
        return VodItem(vodId: id, vodName: name, vodPic: pic,
                       vodRemarks: remarks, vodYear: nil, vodArea: nil,
                       vodDirector: nil, vodActor: nil, vodContent: nil,
                       vodPlayFrom: pluginKey, vodPlayUrl: nil, customHeaders: nil,
                       engineKey: pluginKey,
                       metaDuration: duration, albumName: album, availQualities: qs)
    }

    /// 解析 lx interval 时长（"MM:SS"/"HH:MM:SS"）为秒；无效返回 nil。
    private static func parseInterval(_ d: [String: Any], key: String) -> Int? {
        guard let raw = d[key] as? String, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty else { return nil }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] } // HH:MM:SS
        if parts.count == 2 { return parts[0] * 60 + parts[1] }                    // MM:SS
        return parts.reduce(0, +)
    }

    // MARK: - 直链解析（B1 多平台并发竞速回退）

    /// 对插件支持的所有平台并发请求 musicUrl，取首个成功返回非空直链。
    /// 念心仅 musicUrl 类型，天然契合此路径。
    func resolvePlayURL(id: String, quality: String?, preferSources: [String]? = nil) async throws -> String {
        guard NodeRuntimeManager.shared.isLXReady else { throw LXBridgeError.lxNotReady }
        let sources = preferSources ?? supportedSources
        guard !sources.isEmpty else { throw LXBridgeError.bridge("该源无可播放平台") }
        let q = quality ?? "320k"

        // B1：同 Source 并发出 4 路，整体 8s 上限，单请求 6s 超时
        let overallDeadline = Date().addingTimeInterval(8)
        var index = 0
        while true {
            var swiftConformant = true
            let remaining = sources.dropFirst(index).prefix(4)
            let results = await withTaskGroup(of: (String, Bool, String?).self) { group -> [(String, Bool, String?)] in
                guard swiftConformant else { return [] }
                for src in remaining {
                    let s = src
                    group.addTask {
                        do {
                            let r = try await self.tryResolve(s: s, id: id, q: q)
                            return (s, true, r)
                        } catch {
                            return (s, false, nil)
                        }
                    }
                }
                var out: [(String, Bool, String?)] = []
                for await g in group { out.append(g) }
                return out
            }
            for (_, ok, url) in results where ok && url.flatMap({ !$0.isEmpty }) == true {
                if let u = url { return u }
            }
            index += 4
            if index >= sources.count || Date() > overallDeadline { break }
        }
        throw LXBridgeError.bridge("所有平台均解析失败")
    }

    private func tryResolve(s: String, id: String, q: String) async throws -> String {
        let (obj, result) = try await bridgeCall("musicUrl", ["source": s, "id": id, "quality": q])
        try ensureOk(obj)
        if let str = result as? String, !str.isEmpty { return str }
        if let dict = result as? [String: Any] {
            if let url = dict["url"] as? String, !url.isEmpty { return url }
            if let playUrl = dict["playUrl"] as? String, !playUrl.isEmpty { return playUrl }
        }
        throw LXBridgeError.bridge("空直链")
    }

    // MARK: - 歌词（C2，仅完整型插件提供）

    func fetchLyric(id: String, source: String) async throws -> String {
        let (obj, result) = try await bridgeCall("lyric", ["source": source, "id": id])
        try ensureOk(obj)
        if let str = result as? String, !str.isEmpty { return str }
        if let dict = result as? [String: Any] {
            if let lrc = dict["lrc"] as? String, !lrc.isEmpty { return lrc }
            if let lyric = dict["lyric"] as? String, !lyric.isEmpty { return lyric }
            if let arr = result as? [Any], let first = arr.first as? [String: Any] {
                if let lrc = first["lrc"] as? String, !lrc.isEmpty { return lrc }
            }
        }
        throw LXBridgeError.bridge("无歌词")
    }

    /// P3-C2：跨平台取首个非空歌词（并发竞速未记录具体胜出平台，故逐一尝试）。
    /// 完整型插件（刀源）有 lyric；念心无 concurrency 逐源尝试后返回空，UI 借此隐藏歌词区。
    func fetchLyricForSong(id: String, preferSources: [String]? = nil) async -> String {
        let sources = preferSources ?? supportedSources
        for src in sources {
            if let lrc = try? await fetchLyric(id: id, source: src), !lrc.isEmpty {
                return lrc
            }
        }
        return ""
    }
}



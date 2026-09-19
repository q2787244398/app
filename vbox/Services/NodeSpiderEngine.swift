import Foundation

// MARK: - A1 接缝：Node 常驻系统蜘蛛引擎（形态 A'' 接线）
//
// P2-03 实现（开发方案 v1.17 阶段 2）。
//
// 协议对齐（bundle kstore_index.js 内置 spiders，统一挂载 /spider/{key}/{type}）：
//   - POST /spider/{nodeKey}/3/home         → {class:[], list:[...]}（HomeContentResult）
//   - POST /spider/{nodeKey}/3/category     body {tid, pg, extend}
//   - POST /spider/{nodeKey}/3/detail       body {ids}
//   - POST /spider/{nodeKey}/3/search       body {wd, pg}
//   - POST /spider/{nodeKey}/3/player       body {ids, flag, url}
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
        // key 映射：nodejs_xxx / csp_xxx → xxx
        var key = siteKey
        for prefix in ["nodejs_", "csp_"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
            break
        }
        self.nodeKey = key
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
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
        try perform("detail", params: ["ids": ids])
    }

    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult {
        try perform("search", params: ["wd": keyword, "pg": pg])
    }

    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult {
        try perform("player", params: ["ids": vodId, "flag": flag, "url": url])
    }

    // MARK: - 桥接实现（同步等待，35s 超时兜底）

    private func perform<T: Decodable>(_ action: String, params: [String: Any]?) throws -> T {
        guard NodeRuntimeManager.shared.isSystemReady else {
            let msg = "Node 常驻系统未就绪，无法桥接蜘蛛 \(siteKey) (action=\(action))"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.systemNotReady
        }

        let base = NodeRuntimeManager.shared.baseURL
        guard let url = URL(string: "\(base)/spider/\(nodeKey)/3/\(action)") else {
            let msg = "桥接蜘蛛 \(siteKey) 生成无效 URL: \(base)/spider/\(nodeKey)/3/\(action)"
            onLog?("❌ \(msg)")
            AppLogStore.shared.error(.spider, "[NodeSpiderEngine] \(msg)")
            throw NodeSpiderError.bridge("无效 URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vbox/1.0", forHTTPHeaderField: "User-Agent")
        if let params = params {
            request.httpBody = try? JSONSerialization.data(withJSONObject: params)
        }

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

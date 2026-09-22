import Foundation

/// 蜘蛛引擎统一协议 — 让 JSSpiderEngine 和 QJSSpiderEngine 可以互换使用
protocol SpiderEngineProtocol: AnyObject {
    var onLog: ((String) -> Void)? { get set }

    /// 加载 JS 脚本
    func loadScript(_ script: String) throws

    /// 加载引擎库（不检查 spider 注册）
    func loadLibrary(_ script: String) throws

    /// 从远程 URL 加载脚本
    func loadScriptFromURL(_ urlString: String) async throws

    /// 检查蜘蛛是否已注册
    var isSpiderReady: Bool { get }

    /// 注册蜘蛛
    func registerSpider() throws

    /// 调用首页
    func callHomeContent() throws -> HomeContentResult

    /// 调用搜索
    func callSearchContent(keyword: String, pg: Int) throws -> SearchContentResult

    /// 调用分类
    func callCategoryContent(tid: String, pg: Int, extend: String) throws -> CategoryContentResult

    /// 调用详情
    func callDetailContent(ids: String) throws -> DetailContentResult

    /// 调用播放解析
    func callPlayerContent(vodId: String, flag: String, url: String) throws -> PlayerContentResult
}

// MARK: - 引擎类型标识
enum SpiderEngineType: String, CaseIterable {
    case javaScriptCore = "JavaScriptCore"
    case quickJS = "QuickJS"
    /// Node 常驻系统引擎（形态 A'' 接线，P2-03）—— 不加载本地 JS，桥接 127.0.0.1 Node 进程
    case node = "Node"
    /// lx-music 桥接引擎（P1-A1）—— 复用 Node 常驻进程的独立 lx 端口，桥接 lx-music 协议插件
    case nodeLX = "NodeLX"

    var displayName: String {
        switch self {
        case .javaScriptCore: return "JSC (Apple)"
        case .quickJS: return "QuickJS"
        case .node: return "Node"
        case .nodeLX: return "Node-LX"
        }
    }
}

// MARK: - JSSpiderEngine 遵循协议
extension JSSpiderEngine: SpiderEngineProtocol {}

// MARK: - QJSSpiderEngine 遵循协议
extension QJSSpiderEngine: SpiderEngineProtocol {
    /// QJS 的 isSpiderReady 是方法，协议要求是属性，需要包装
    var isSpiderReady: Bool {
        // QJSSpiderEngine 的 registerSpider() 返回 Bool，这里直接检测
        let result = evaluateJS("typeof globalThis.__JS_SPIDER__")
        return (result == "object" || result == "\"object\"" || result?.contains("object") == true)
    }

    /// 让 QJS 的 registerSpider() 符合协议（抛出异常而非返回 Bool）
    func registerSpider() throws {
        let success = registerSpiderBool()
        if !success {
            throw QJSError(message: "QuickJS 蜘蛛注册失败: 未找到 __JS_SPIDER__")
        }
    }

    /// 加载库（QJS 直接 evaluateJS 即可）
    func loadLibrary(_ script: String) throws {
        let result = evaluateJS(script)
        if let result = result, !result.isEmpty {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Error") || trimmed.hasPrefix("TypeError") || trimmed.hasPrefix("ReferenceError") || trimmed.hasPrefix("SyntaxError") {
                throw QJSError(message: "加载库失败: \(trimmed)")
            }
        }
    }

    /// 从远程 URL 加载
    func loadScriptFromURL(_ urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw QJSError(message: "无效的URL: \(urlString)")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let script = String(data: data, encoding: .utf8) else {
            throw QJSError(message: "无法解码脚本: \(urlString)")
        }
        try loadScript(script)
    }

    // 重命名原来的 registerSpider() 为内部方法
    private func registerSpiderBool() -> Bool {
        let result = evaluateJS("typeof globalThis.__JS_SPIDER__")
        let founded = (result == "object" || result == "\"object\"" || result?.contains("object") == true)
        if founded {
            onLog?("✅ QuickJS 蜘蛛注册成功")
        } else {
            onLog?("❌ QuickJS 蜘蛛注册失败: __JS_SPIDER__ 类型=\(result ?? "nil")")
        }
        return founded
    }

    private func decodeResult<T: Codable>(_ script: String) throws -> T {
        guard let result = evaluateJS(script) else {
            throw QJSError(message: "JS 返回 nil")
        }
        guard let data = result.data(using: .utf8) else {
            throw QJSError(message: "结果编码无效")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

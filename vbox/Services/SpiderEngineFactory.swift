import Foundation

/// JS 引擎工厂 — 负责在后台线程创建和预热蜘蛛引擎
/// 不接触 UI，不访问 MainActor 状态
final class SpiderEngineFactory {

    /// 缓存公共 JS 库内容，避免每次重复读文件
    private static let libraryCache = SpiderEngineLibraryCache()

    /// 创建并预热引擎。调用方应保证此方法在后台线程执行。
    static func buildEngine(
        jsCode: String,
        extCode: String?,
        engineType: SpiderEngineType,
        key: String
    ) throws -> SpiderEngineProtocol {

        let engine: SpiderEngineProtocol
        switch engineType {
        case .javaScriptCore:
            engine = JSSpiderEngine()
        case .quickJS:
            engine = QJSSpiderEngine()
        case .node:
            // 形态 A''：Node 引擎不加载本地 JS，直接桥接 127.0.0.1 Node 进程
            engine = NodeSpiderEngine(siteKey: key)
        }

        // 先在后台设置一个基础日志回调（只打印，不碰 UI）
        engine.onLog = { msg in
            print("[SpiderEngine|\(key)|\(engineType.displayName)] \(msg)")
        }

        // Node 引擎无需注入蜘蛛库 / 执行脚本，直接返回
        guard engineType != .node else {
            return engine
        }

        // 注入库 + 执行脚本（全部在后台线程）
        try injectLibraries(engine: engine)
        try engine.loadScript(jsCode)

        if !engine.isSpiderReady {
            try engine.registerSpider()
        }

        // 如果有 ext，也在后台注入
        if let ext = extCode, !ext.isEmpty {
            try engine.loadScript(ext)
        }

        return engine
    }

    // MARK: - Private

    /// 注入公共库（后台读取文件，避免主线程 IO）
    private static func injectLibraries(engine: SpiderEngineProtocol) throws {
        // 0. 浏览器兼容 polyfill（atob/btoa - QuickJS/JSC 没有这些）
        try engine.loadLibrary("""
        if (typeof atob === 'undefined') {
            atob = function(base64) {
                var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
                var result = '';
                var buffer = 0, bits = 0;
                for (var i = 0; i < base64.length; i++) {
                    var c = chars.indexOf(base64[i]);
                    if (c === -1) continue;
                    buffer = (buffer << 6) | c;
                    bits += 6;
                    if (bits >= 8) {
                        bits -= 8;
                        result += String.fromCharCode((buffer >> bits) & 0xFF);
                    }
                }
                return result;
            };
        }
        """)

        // 1. net.js — 同步/异步 HTTP 请求封装
        try engine.loadLibrary("""
        let req = (url, options) => http(url, Object.assign({ async: false }, options));
        """)

        // 2. 加载 cheerio (HTML 解析器)
        if let cheerio = cachedLibrary(named: "cheerio.min", type: "js") {
            try engine.loadLibrary(cheerio)
            print("[SpiderEngineFactory] ✅ cheerio 已注入")
        }

        // 3. 加载 utils.js (TVBox 标准工具库)
        if let utils = cachedLibrary(named: "utils", type: "js", subdirectory: "js/lib") {
            try engine.loadLibrary(utils)
            print("[SpiderEngineFactory] ✅ utils.js 已注入")
        }

        // 4. 加载 similarity.js (相似度匹配库)
        if let sim = cachedLibrary(named: "similarity", type: "js", subdirectory: "js/lib") {
            try engine.loadLibrary(sim)
            print("[SpiderEngineFactory] ✅ similarity.js 已注入")
        }

        // 5. 模板引擎
        if let tmpl = cachedLibrary(named: "模板", type: "js") {
            try engine.loadLibrary(tmpl)
            print("[SpiderEngineFactory] ✅ 模板引擎已注入")
        }

        // 6. zhanyuan 蜘蛛引擎 (HTML 站源)
        if let zhan = cachedLibrary(named: "zhanyuan_spider", type: "js") {
            try engine.loadLibrary(zhan)
            print("[SpiderEngineFactory] ✅ zhanyuan 蜘蛛引擎已注入")
        }

        print("[SpiderEngineFactory] ✅ JS 库注入完成")
    }

    private static func cachedLibrary(named name: String, type: String, subdirectory: String? = nil) -> String? {
        let key = "\(subdirectory ?? "")/\(name).\(type)"
        return libraryCache.value(forKey: key) {
            guard let path = Bundle.main.path(forResource: name, ofType: type, inDirectory: subdirectory) else { return nil }
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
    }
}

/// 线程安全的公共 JS 库缓存。
private final class SpiderEngineLibraryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func value(forKey key: String, loader: () -> String?) -> String? {
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let loaded = loader() else { return nil }

        lock.lock()
        storage[key] = loaded
        lock.unlock()
        return loaded
    }
}

import Foundation

/// 站点加载诊断结果
struct SiteDiagnosticResult: Identifiable {
    let id = UUID()
    let siteKey: String
    let siteName: String
    let type: Int
    let api: String?
    let searchable: Int?
    let status: SiteStatus
    let errorMessage: String?
    let engineLoaded: Bool
    let canSearch: Bool
    let engineType: SpiderEngineType?  // 实际加载成功的引擎类型
    let jscCompatible: Bool            // 是否兼容 JSC
    let qjsCompatible: Bool            // 是否兼容 QuickJS
}

enum SiteStatus: String, CaseIterable {
    case loaded = "已加载"
    case engineReady = "引擎就绪"
    case apiOnly = "仅API"
    case noApi = "无API地址"
    case downloadFailed = "下载失败"
    case invalidContent = "内容无效"
    case registerFailed = "注册失败"
    case unknown = "未知"
    case skipped = "已跳过"
    case jscOnly = "仅JSC兼容"
    case qjsOnly = "仅QJS兼容"

    var icon: String {
        switch self {
        case .loaded, .engineReady: return "✅"
        case .apiOnly: return "📡"
        case .noApi: return "❌"
        case .downloadFailed: return "🌐"
        case .invalidContent: return "📄"
        case .registerFailed: return "🔧"
        case .unknown: return "❓"
        case .skipped: return "⏭️"
        case .jscOnly: return "🍎"
        case .qjsOnly: return "⚡"
        }
    }
}

/// 站点诊断管理器 — 帮助用户了解每个接口的状态
@MainActor
class SiteDiagnosticsManager: ObservableObject {
    static let shared = SiteDiagnosticsManager()

    @Published var results: [SiteDiagnosticResult] = []
    @Published var isDiagnosing = false
    @Published var summary: DiagnosticSummary?

    struct DiagnosticSummary {
        let total: Int
        let engineReady: Int
        let apiOnly: Int
        let failed: Int
        let skipped: Int
        let searchableCount: Int
        let jscCount: Int
        let qjsCount: Int
    }

    private init() {}

    /// 对 SpiderManager 中的所有站点进行诊断
    func diagnose(spiderManager: SpiderManager) async {
        isDiagnosing = true
        defer { isDiagnosing = false }

        var diagnostics: [SiteDiagnosticResult] = []
        let sites = spiderManager.allSites

        for site in sites {
            let result = await diagnoseSite(site, spiderManager: spiderManager)
            diagnostics.append(result)
        }

        results = diagnostics

        let engineReady = diagnostics.filter { $0.status == .engineReady }.count
        let apiOnly = diagnostics.filter { $0.status == .apiOnly }.count
        let failed = diagnostics.filter { [.downloadFailed, .invalidContent, .registerFailed, .noApi].contains($0.status) }.count
        let skipped = diagnostics.filter { $0.status == .skipped }.count
        let searchable = diagnostics.filter { $0.canSearch }.count
        let jscCount = diagnostics.filter { $0.engineType == .javaScriptCore }.count
        let qjsCount = diagnostics.filter { $0.engineType == .quickJS }.count

        summary = DiagnosticSummary(
            total: diagnostics.count,
            engineReady: engineReady,
            apiOnly: apiOnly,
            failed: failed,
            skipped: skipped,
            searchableCount: searchable,
            jscCount: jscCount,
            qjsCount: qjsCount
        )
    }

    private func diagnoseSite(_ site: SiteConfig, spiderManager: SpiderManager) async -> SiteDiagnosticResult {
        let key = site.key.isEmpty ? site.name : site.key
        let hasEngine = spiderManager.hasEngine(forKey: key)
        let actualEngineType = spiderManager.engineType(forKey: key)

        // 判断搜索能力
        var canSearch = false
        var status: SiteStatus = .unknown
        var errorMsg: String? = nil
        var jscCompatible = false
        var qjsCompatible = false

        switch site.type {
        case 0, 1:
            // API 采集站
            if let api = site.api, !api.isEmpty, api.hasPrefix("http") {
                canSearch = true
                status = .apiOnly
            } else {
                status = .noApi
                errorMsg = "API地址为空或无效"
            }

        case 2:
            // zhanyuan 站源
            if hasEngine {
                canSearch = true
                status = .engineReady
            } else {
                status = .registerFailed
                errorMsg = "zhanyuan 引擎未成功加载（缺少 cheerio/zhanyuan_spider.js 库文件）"
            }

        case 3:
            // JS 蜘蛛 — 诊断双引擎兼容性
            if hasEngine {
                canSearch = true
                status = .engineReady
                // 已有引擎加载成功，标记对应引擎兼容
                if actualEngineType == .javaScriptCore {
                    jscCompatible = true
                } else if actualEngineType == .quickJS {
                    qjsCompatible = true
                }
            } else if let api = site.api, !api.isEmpty {
                if api.hasPrefix("http://") || api.hasPrefix("https://") {
                    // 尝试下载并测试双引擎兼容性
                    do {
                        var req = URLRequest(url: URL(string: api)!)
                        req.timeoutInterval = 10
                        let (data, response) = try await URLSession.shared.data(for: req)
                        let httpResp = response as? HTTPURLResponse

                        if httpResp?.statusCode != 200 {
                            status = .downloadFailed
                            errorMsg = "HTTP \(httpResp?.statusCode ?? 0)，无法下载 JS 脚本"
                        } else if let jsCode = String(data: data, encoding: .utf8) {
                            if jsCode.count < 200 {
                                status = .invalidContent
                                errorMsg = "JS 代码太短(\(jsCode.count)字符)，可能不是有效蜘蛛脚本"
                            } else if !jsCode.contains("function ") && !jsCode.contains("spider") {
                                status = .invalidContent
                                errorMsg = "内容不包含 function/spider 关键字，可能不是 JS 脚本（可能是 jar 包或 HTML）"
                            } else {
                                // 测试 JSC 兼容性
                                let jscTest = await testEngineCompatibility(jsCode: jsCode, engineType: .javaScriptCore)
                                // 测试 QuickJS 兼容性
                                let qjsTest = await testEngineCompatibility(jsCode: jsCode, engineType: .quickJS)

                                jscCompatible = jscTest.success
                                qjsCompatible = qjsTest.success

                                if jscCompatible && qjsCompatible {
                                    status = .registerFailed
                                    errorMsg = "JSC 和 QuickJS 都能解析该脚本，但运行时注册失败（可能缺少依赖库如 cheerio/模板.js）"
                                } else if jscCompatible {
                                    status = .jscOnly
                                    errorMsg = "仅 JSC 兼容，QuickJS 失败: \(qjsTest.error ?? "未知错误")"
                                } else if qjsCompatible {
                                    status = .qjsOnly
                                    errorMsg = "仅 QuickJS 兼容，JSC 失败: \(jscTest.error ?? "未知错误")"
                                } else {
                                    status = .registerFailed
                                    errorMsg = "JSC 失败: \(jscTest.error ?? "未知") | QuickJS 失败: \(qjsTest.error ?? "未知")"
                                }
                            }
                        } else {
                            status = .invalidContent
                            errorMsg = "无法解码响应内容为字符串"
                        }
                    } catch {
                        status = .downloadFailed
                        errorMsg = "下载失败: \(error.localizedDescription)"
                    }
                } else {
                    status = .noApi
                    errorMsg = "api 不是 http/https URL: \(api)"
                }
            } else {
                status = .noApi
                errorMsg = "api 字段为空"
            }

        default:
            status = .unknown
            errorMsg = "未知类型 type=\(site.type)"
        }

        // 如果站点明确标记了 searchable=0，则覆盖搜索能力
        if site.searchable == 0 {
            canSearch = false
            errorMsg = (errorMsg ?? "") + " [searchable=0，已禁用搜索]"
        }

        return SiteDiagnosticResult(
            siteKey: key,
            siteName: site.name,
            type: site.type,
            api: site.api,
            searchable: site.searchable,
            status: status,
            errorMessage: errorMsg,
            engineLoaded: hasEngine,
            canSearch: canSearch,
            engineType: actualEngineType,
            jscCompatible: jscCompatible,
            qjsCompatible: qjsCompatible
        )
    }

    /// 测试指定引擎对 JS 代码的兼容性
    private func testEngineCompatibility(jsCode: String, engineType: SpiderEngineType) async -> (success: Bool, error: String?) {
        do {
            let engine: SpiderEngineProtocol
            switch engineType {
            case .javaScriptCore:
                engine = JSSpiderEngine()
            case .quickJS:
                engine = QJSSpiderEngine()
            case .node, .nodeLX:
                // Node / NodeLX 引擎不做本地 JS 兼容性测试
                return (success: true, error: nil)
            }

            // 只测试语法解析，不注入完整库（避免依赖问题干扰）
            try engine.loadScript(jsCode)

            // 检查是否有 __JS_SPIDER__ 或 spider 相关导出
            let hasSpider = jsCode.contains("__JS_SPIDER__") || jsCode.contains("function spider") || jsCode.contains("var spider")
            if hasSpider {
                return (success: true, error: nil)
            } else {
                return (success: false, error: "脚本缺少 __JS_SPIDER__ 导出")
            }
        } catch {
            return (success: false, error: error.localizedDescription)
        }
    }
}

import Foundation
import CommonCrypto

// MARK: - A1 接缝：Node 常驻系统分享解析服务层
//
// P1-08/09/15 实现。
//
// 协议对齐（bundle kstore_index.js push spider，meta type=4，已内置注册无需改 bundle）：
//   挂载前缀（Ph0 注册）：/spider/push/4 与 /spider/push 均可用，这里使用带 type 的规范路径。
//   - POST /spider/push/4/detail   body {"id": ["<分享链接>"]}
//         → {list:[{vod_id, vod_name, vod_play_from, vod_play_url, ...}]}
//         vod_play_url = "文件名$<base64id>#文件名$<base64id>"（tle 转义 + rle 编码；
//         多播放组以 $$$ 分隔，取第一组主播放源）
//   - POST /spider/push/4/play     body {"id": "<base64id>"}
//         → {parse:0, url, header:{...}, format}
//   - GET  /spider/push/4/proxy/...（bundle 内部转发；play 返回相对路径时补全 base）
//
// 铁律：
//   1. 本服务只处理 Node 托管盘（光鸭/蜗牛，以及 Node 就绪时的新增盘回退优先）；
//   2. 百度/夸克/UC/阿里原生链路零改动；
//   3. Node 未就绪时返回明确错误，提示用户检查 Node 状态。

// MARK: - 数据结构

/// push spider detail 返回的单条可播放条目（vod_play_url 中 $ 分隔的一项）
struct NodePanEntry {
    /// base64 编码的 {providerId, shareId, fileId, name, playToken, mode}
    let playID: String
    /// 展示文件名（rle 解码后的 name）
    let name: String
}

/// 分享链接解析结果
struct NodePanShareResult {
    let title: String
    let entries: [NodePanEntry]
}

/// play 返回的播放信息
struct NodePanPlayResult {
    let url: String
    let headers: [String: String]
    let format: String?
}

// MARK: - 服务

final class NodePanResolver {

    static let shared = NodePanResolver()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    // MARK: 对外接口

    /// 解析分享链接 → 可播放条目列表
    /// 对应 bundle: panAdapter.detail → panService.resolve（Bj.resolve + resolveShare）
    func resolveShare(_ url: String) async throws -> NodePanShareResult {
        let base = NodeRuntimeManager.shared.baseURL
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        guard !clean.isEmpty else {
            throw NodePanError.invalidShareURL
        }

        let payload: [String: Any] = ["id": [clean]]
        let data = try await postJSON(base + "/spider/push/4/detail", body: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodePanError.nodeRejected("解析响应 JSON 失败")
        }
        // 失败时 bundle 返回 {list:[], msg:"..."}
        if let msg = root["msg"] as? String, !msg.isEmpty, (root["list"] as? [Any])?.isEmpty != false {
            throw NodePanError.nodeRejected(msg)
        }
        guard let list = root["list"] as? [[String: Any]], let vod = list.first else {
            throw NodePanError.nodeRejected("未解析到可播放网盘资源")
        }

        let title = (vod["vod_name"] as? String) ?? "网盘资源"
        let playURL = (vod["vod_play_url"] as? String) ?? ""
        let entries = Self.parsePlayURL(playURL)
        guard !entries.isEmpty else {
            throw NodePanError.nodeRejected("分享内未找到可播放视频")
        }
        return NodePanShareResult(title: title, entries: entries)
    }

    /// 用 playID 换取播放地址（直链或 bundle /proxy 代理地址 + header）
    func resolvePlay(playID: String) async throws -> NodePanPlayResult {
        let base = NodeRuntimeManager.shared.baseURL
        guard !playID.isEmpty else {
            throw NodePanError.nodeRejected("播放参数无效")
        }
        let payload: [String: Any] = ["id": playID]
        let data = try await postJSON(base + "/spider/push/4/play", body: payload)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NodePanError.nodeRejected("播放响应 JSON 失败")
        }
        guard var url = root["url"] as? String, !url.isEmpty else {
            let msg = root["msg"] as? String ?? root["error"] as? String ?? "播放地址为空"
            throw NodePanError.nodeRejected(msg)
        }
        // bundle 内部代理可能返回相对路径（/spider/push/4/proxy/...），补全 base 后再交给播放器
        if url.hasPrefix("/") {
            url = base + url
        }
        let headers = (root["header"] as? [String: Any])?
            .reduce(into: [String: String]()) { $0[String($1.key)] = String(describing: $1.value) } ?? [:]
        let format = root["format"] as? String
        return NodePanPlayResult(url: url, headers: headers, format: format)
    }

    // MARK: 内部实现

    /// 解析 vod_play_url："名$id#名$id"（bundle tle 转义 + rle base64 编码）
    /// 多播放组（如 原画$$$极速）以 $$$ 分隔，仅取第一组主播放源。
    private static func parsePlayURL(_ raw: String) -> [NodePanEntry] {
        guard !raw.isEmpty else { return [] }
        let primary = raw.components(separatedBy: "$$$").first ?? raw
        let segments = primary.components(separatedBy: "#")
        var entries: [NodePanEntry] = []
        for seg in segments {
            let parts = seg.components(separatedBy: "$")
            guard parts.count >= 2 else { continue }
            let playID = parts.last ?? ""
            guard !playID.isEmpty else { continue }
            let name = decodeName(from: playID) ?? parts.first ?? "视频"
            entries.append(NodePanEntry(playID: playID, name: name))
        }
        return entries
    }

    /// rle base64 JSON {providerId,shareId,fileId,name,...} → name
    private static func decodeName(from playID: String) -> String? {
        guard let data = Data(base64Encoded: playID),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else {
            return nil
        }
        return name
    }

    private func postJSON(_ urlString: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NodePanError.nodeRejected("无效 URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("vbox/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NodePanError.nodeUnavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 502 || http.statusCode == 503 || http.statusCode == 404 {
                throw NodePanError.nodeUnavailable
            }
            // bundle handler 抛错时由 Fastify 返回 500 + {message}（如
            // 「非高会需要配置 UC TV Token」/「还没有配置 UC Cookie」），
            // 这里读出真实原因，避免只剩「HTTP 500」无法定位。
            let detail = Self.extractErrorMessage(from: data)
            throw NodePanError.nodeRejected(detail.isEmpty ? "HTTP \(http.statusCode)" : "\(detail)（HTTP \(http.statusCode)）")
        }
        return data
    }

    /// 从错误响应体中提取可读信息（Fastify 默认 {statusCode,error,message}；
    /// bundle 自定义分支为 {code,msg}）；均取不到时退化为截断的原始文本
    private static func extractErrorMessage(from data: Data) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["message", "msg", "error", "errMsg"] {
                if let text = obj[key] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        let raw = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(raw.prefix(200))
    }
}

// MARK: - 错误

enum NodePanError: LocalizedError {
    /// Node 常驻系统未就绪 / 连接失败
    case nodeUnavailable
    /// 分享链接格式无法识别
    case invalidShareURL
    /// Node 侧返回的业务错误
    case nodeRejected(String)

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable:
            return "Node 常驻系统未就绪，请稍后重试"
        case .invalidShareURL:
            return "无法识别的分享链接"
        case .nodeRejected(let message):
            return message
        }
    }
}

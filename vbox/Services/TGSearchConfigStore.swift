import Foundation

// MARK: - TG搜索配置存储
/// 管理 TG搜索蜘蛛的代理地址和自定义频道
/// 参照 WelfareProxyStore 的独立 Store 单例模式
class TGSearchConfigStore: ObservableObject {
    static let shared = TGSearchConfigStore()

    // MARK: - UserDefaults Keys
    private let proxyURLKey = "tg_search_proxy_url_v1"
    private let channelsKey = "tg_search_channels_v1"
    private let channelModeKey = "tg_search_channel_mode_v1"

    // MARK: - 频道模型
    struct TGChannel: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String        // 显示名称，如 "UC夸克资源"
        var channelId: String   // Telegram 频道 ID，如 "ucquark"
    }

    // MARK: - 频道来源模式
    enum ChannelMode: String, CaseIterable, Codable {
        case `default` = "default"   // 仅远程默认频道
        case custom = "custom"       // 仅自定义频道
        case all = "all"             // 全部合并（远程默认 + 自定义）

        var displayName: String {
            switch self {
            case .default: return "远程默认"
            case .custom: return "仅自定义"
            case .all: return "全部合并"
            }
        }
    }

    /// 加载完成前禁止 didSet 触发 save()，避免 load() 中的属性赋值
    /// 用空数据覆盖已有的持久化数据（这是升级后自定义频道丢失的根因）
    private var isLoaded = false

    // MARK: - Published 属性
    @Published var proxyURL: String = "" {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }

    @Published var channels: [TGChannel] = [] {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }

    @Published var channelMode: ChannelMode = .default {
        didSet {
            guard isLoaded else { return }
            save()
        }
    }

    // MARK: - 预置常用频道（快捷添加用）
    static let presetChannels: [TGChannel] = [
        TGChannel(name: "UC夸克资源", channelId: "ucquark"),
        TGChannel(name: "夸克分享", channelId: "quarkshare"),
        TGChannel(name: "阿里分享", channelId: "shareAliyun"),
        TGChannel(name: "豆儿盘", channelId: "douerpan"),
        // 【新增 2026-09-20】常用网盘/影视 TG 频道（阿里频道 shareAliyun 已存在，跳过；123云盘按需移除）
        TGChannel(name: "4K影视频道", channelId: "Aliyun_4K_Movies"),
        TGChannel(name: "百度频道", channelId: "BaiduCloudDisk"),
        TGChannel(name: "移动云盘", channelId: "yunpan139"),
        TGChannel(name: "天翼云盘", channelId: "yunpan189"),
        TGChannel(name: "UC云盘", channelId: "yunpanuc"),
        TGChannel(name: "迅雷云盘", channelId: "yunpanxunlei")
    ]

    // MARK: - Init
    init() {
        load()
        isLoaded = true
    }

    // MARK: - 代理地址有效性
    var hasValidProxy: Bool {
        let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.hasPrefix("http")
    }

    // MARK: - 频道管理
    func addChannel(name: String, channelId: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        let displayName = trimmedName.isEmpty ? trimmedId : trimmedName
        channels.append(TGChannel(name: displayName, channelId: trimmedId))
    }

    func removeChannels(at offsets: IndexSet) {
        channels.remove(atOffsets: offsets)
    }

    func moveChannel(from source: IndexSet, to destination: Int) {
        channels.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - 生成配置 JS
    /// 生成注入到蜘蛛脚本前的配置 JS 代码
    /// 蜘蛛脚本通过全局变量 __TG_CONFIG__ 读取配置
    func generateConfigJS() -> String {
        var config: [String: Any] = [:]

        let trimmedProxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProxy.isEmpty {
            config["proxyUrl"] = trimmedProxy
        } else {
            config["proxyUrl"] = ""
        }

        config["channelMode"] = channelMode.rawValue

        let channelArray = channels.map { ch -> [String: String] in
            return ["name": ch.name, "id": ch.channelId]
        }
        config["channels"] = channelArray

        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }

        return "var __TG_CONFIG__ = \(json);"
    }

    // MARK: - 持久化
    private func load() {
        let defaults = UserDefaults.standard
        proxyURL = defaults.string(forKey: proxyURLKey) ?? ""

        if let modeRaw = defaults.string(forKey: channelModeKey),
           let mode = ChannelMode(rawValue: modeRaw) {
            channelMode = mode
        }

        if let data = defaults.data(forKey: channelsKey),
           let savedChannels = try? JSONDecoder().decode([TGChannel].self, from: data) {
            channels = savedChannels
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(proxyURL, forKey: proxyURLKey)
        defaults.set(channelMode.rawValue, forKey: channelModeKey)
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: channelsKey)
        }
    }
}

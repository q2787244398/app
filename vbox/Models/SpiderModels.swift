import SwiftUI

// MARK: - AnyCodable: 兼容 String / 对象 / 数组 多种类型
struct AnyCodable: Codable {
    var value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict.mapValues { $0.value } }
        else if let array = try? container.decode([AnyCodable].self) { value = array.map { $0.value } }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let s = value as? String { try container.encode(s) }
        else if let i = value as? Int { try container.encode(i) }
        else { try container.encode("") }
    }
}

// MARK: - 站点配置
struct SiteConfig: Codable {
    let key: String
    let name: String
    let type: Int
    let api: String?
    let searchable: Int?
    let quickSearch: Int?
    let filterable: Int?
    let ext: String?
    let playerType: Int?
    let jar: String?
    let changeable: Int?
    let playStrategy: String?
    // P2-00 扩展（议题 18 K1）：Node 源识别与播放标识
    /// 播放模式标识：normal / pan / hybrid（议题 15 定稿；Node 源随 manifest 下发）
    let playMode: String?
    /// 网盘宿主列表（playMode=pan 时用于播放分发，如 ["quark","ali"]）
    let panHosts: [String]?
    /// 站点分组标记：group == "node" 表示 Node 常驻系统托管源（node 识别辅助标记）
    let group: String?

    // P1-A6（远程上架）：lx-music 桥接插件属性，随远程清单下发。api 为空、由 bridge 引擎按 pluginPath 托管。
    /// 引擎类型标记：lxMusic（走 LXBridgeEngine）、node、空（普通 JS/Python）。
    let engineType: String?
    /// lx 插件脚本相对仓库路径（如 sources/lx/daxe.js），用于远程下载
    let pluginPath: String?
    /// 插件版本（与插件 @version 对齐，用于远程更新比对）
    let version: String?
    /// 插件脚本 MD5（完整性校验）
    let md5: String?

    init(key: String, name: String, type: Int, api: String? = nil,
         searchable: Int? = nil, quickSearch: Int? = nil, filterable: Int? = nil,
         ext: String? = nil, playerType: Int? = nil, jar: String? = nil,
         changeable: Int? = nil, playStrategy: String? = nil,
         playMode: String? = nil, panHosts: [String]? = nil, group: String? = nil,
         engineType: String? = nil, pluginPath: String? = nil,
         version: String? = nil, md5: String? = nil) {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
        self.quickSearch = quickSearch
        self.filterable = filterable
        self.ext = ext
        self.playerType = playerType
        self.jar = jar
        self.changeable = changeable
        self.playStrategy = playStrategy
        self.playMode = playMode
        self.panHosts = panHosts
        self.group = group
        self.engineType = engineType
        self.pluginPath = pluginPath
        self.version = version
        self.md5 = md5
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        name = try container.decode(String.self, forKey: .name)
        // type 兼容整数和字符串
        if let typeInt = try? container.decode(Int.self, forKey: .type) {
            type = typeInt
        } else if let typeStr = try? container.decode(String.self, forKey: .type) {
            type = Int(typeStr) ?? 0
        } else {
            type = 0
        }
        api = try? container.decode(String.self, forKey: .api)
        searchable = try? container.decode(Int.self, forKey: .searchable)
        quickSearch = try? container.decode(Int.self, forKey: .quickSearch)
        filterable = try? container.decode(Int.self, forKey: .filterable)
        jar = try? container.decode(String.self, forKey: .jar)
        playerType = try? container.decode(Int.self, forKey: .playerType)
        changeable = try? container.decode(Int.self, forKey: .changeable)
        playStrategy = try? container.decode(String.self, forKey: .playStrategy)
        playMode = try? container.decode(String.self, forKey: .playMode)
        panHosts = try? container.decode([String].self, forKey: .panHosts)
        group = try? container.decode(String.self, forKey: .group)
        engineType = try? container.decode(String.self, forKey: .engineType)
        pluginPath = try? container.decode(String.self, forKey: .pluginPath)
        version = try? container.decode(String.self, forKey: .version)
        md5 = try? container.decode(String.self, forKey: .md5)

        // ext：兼容字符串和对象
        if let extStr = try? container.decode(String.self, forKey: .ext) {
            ext = extStr
        } else if let extObj = try? container.decode([String: AnyCodable].self, forKey: .ext) {
            ext = extObj.compactMap { $0.value as? String }.first
        } else if let extArr = try? container.decode([String].self, forKey: .ext) {
            ext = extArr.first
        } else {
            ext = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case key, name, type, api, searchable, quickSearch, filterable
        case ext, playerType, jar, changeable, playStrategy
        case playMode, panHosts, group
        case engineType, pluginPath, version, md5
    }
}

struct SubscribeConfig: Codable {
    let sites: [SiteConfig]
    let spider: String?
    let wallpaper: String?
    let lives: [LiveConfig]?
    let flags: [String]?
    let banned: [String]?
    // 解析器配置
    let parses: [ParseConfig]?

    enum CodingKeys: String, CodingKey {
        case sites, spider, wallpaper, lives, flags, banned, parses
    }
}

struct ParseConfig: Codable {
    let name: String
    let url: String
    let type: Int?  // 0=未知，1=JSON API，2=Web 解析器

    init(name: String, url: String, type: Int? = nil) {
        self.name = name
        self.url = url
        self.type = type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        type = try? container.decode(Int.self, forKey: .type)
    }

    enum CodingKeys: String, CodingKey {
        case name, url, type
    }
}

struct LiveConfig: Codable {
    let name: String?
    let urls: [String]?
}

// MARK: - 视频数据模型
struct VodCategory: Codable, Identifiable, Equatable {
    var id: String { typeId }
    let typeId: String
    let typeName: String
    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
    }
}

struct VodItem: Codable, Identifiable {
    var id: String { vodId }
    let vodId: String
    let vodName: String
    let vodPic: String
    var vodRemarks: String?
    let vodYear: String?
    let vodArea: String?
    let vodDirector: String?
    let vodActor: String?
    let vodContent: String?
    let vodPlayFrom: String?
    var vodPlayUrl: String?
    let customHeaders: [String: String]?
    /// 追踪数据来源引擎的 key，用于精确匹配详情和播放地址
    var engineKey: String?
    /// P2-B2/B3：lx 插件返回的元数据（可选，视频/网盘/普通音乐源留空，不影响既有解码）
    var metaDuration: Int?        // 时长（秒，由 lx interval 格式化串解析）
    var albumName: String?        // 专辑名
    var availQualities: [String]  // 可选音质档位（读插件 qualitys 声明）
    /// P1-A7：lx 歌曲所属平台 key（wy/tx/kw/kg/mg/qs）。搜索时记录该首歌来自哪个平台，
    /// 播放时据此只对该平台发起 musicUrl（聚合源竞速必须定位到正确平台，否则同名 id 全部失败）。
    var musicPlatform: String?
    /// P1-A7：lx 搜索返回的原始 song 字典 JSON（含 hash/songmid/name/singer/albumName 等字段）。
    /// 许多插件（念心）直接读 musicInfo 里的平台专有字段（hash/songmid），必须原样带回播放。
    var lxMusicInfo: String?

    init(vodId: String, vodName: String, vodPic: String, vodRemarks: String? = nil,
         vodYear: String? = nil, vodArea: String? = nil, vodDirector: String? = nil,
         vodActor: String? = nil, vodContent: String? = nil, vodPlayFrom: String? = nil,
         vodPlayUrl: String? = nil, customHeaders: [String: String]? = nil, engineKey: String? = nil,
         metaDuration: Int? = nil, albumName: String? = nil, availQualities: [String] = [],
         musicPlatform: String? = nil, lxMusicInfo: String? = nil) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodDirector = vodDirector
        self.vodActor = vodActor
        self.vodContent = vodContent
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
        self.customHeaders = customHeaders
        self.engineKey = engineKey
        self.metaDuration = metaDuration
        self.albumName = albumName
        self.availQualities = availQualities
        self.musicPlatform = musicPlatform
        self.lxMusicInfo = lxMusicInfo
    }

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodDirector = "vod_director"
        case vodActor = "vod_actor"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
        case customHeaders
        case engineKey
        case metaDuration, albumName, availQualities, musicPlatform, lxMusicInfo
    }

    /// 显式解码：新增元数据字段全部 decodeIfPresent/默认回退，
    /// 保证不含新字段的旧 JSON（视频/网盘/远程源）仍可安全解码，不破坏既有链路。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vodId = try c.decode(String.self, forKey: .vodId)
        vodName = try c.decode(String.self, forKey: .vodName)
        vodPic = try c.decode(String.self, forKey: .vodPic)
        vodRemarks = try c.decodeIfPresent(String.self, forKey: .vodRemarks)
        vodYear = try c.decodeIfPresent(String.self, forKey: .vodYear)
        vodArea = try c.decodeIfPresent(String.self, forKey: .vodArea)
        vodDirector = try c.decodeIfPresent(String.self, forKey: .vodDirector)
        vodActor = try c.decodeIfPresent(String.self, forKey: .vodActor)
        vodContent = try c.decodeIfPresent(String.self, forKey: .vodContent)
        vodPlayFrom = try c.decodeIfPresent(String.self, forKey: .vodPlayFrom)
        vodPlayUrl = try c.decodeIfPresent(String.self, forKey: .vodPlayUrl)
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders)
        engineKey = try c.decodeIfPresent(String.self, forKey: .engineKey)
        metaDuration = try c.decodeIfPresent(Int.self, forKey: .metaDuration)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        availQualities = try c.decodeIfPresent([String].self, forKey: .availQualities) ?? []
        musicPlatform = try c.decodeIfPresent(String.self, forKey: .musicPlatform)
        lxMusicInfo = try c.decodeIfPresent(String.self, forKey: .lxMusicInfo)
    }
}

struct HomeContentResult: Codable {
    let `class`: [VodCategory]?
    let list: [VodItem]?
}

struct CategoryContentResult: Codable {
    let page: Int?
    let pagecount: Int?
    let limit: Int?
    let total: Int?
    let list: [VodItem]?
}

struct DetailContentResult: Codable {
    let list: [VodItem]?
}

struct SearchContentResult: Codable {
    let page: Int?
    let pagecount: Int?
    let list: [VodItem]?
}

struct PlayerContentResult: Codable {
    let parse: Int?
    let playUrl: String?
    let url: String?
    let header: [String: String]?
}


// MARK: - Color Hex 扩展
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - UIApplication 扩展
extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

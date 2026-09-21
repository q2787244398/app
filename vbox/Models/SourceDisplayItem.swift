import Foundation

// MARK: - 源分类

enum SourceCategory: String, Codable, CaseIterable {
    case cloudCMS    // 网盘 CMS 型（支持 ac=home）
    case cloudForum  // 网盘论坛型（只支持搜索）
    case cloudSPA    // 网盘单页型（只支持搜索）
    case api         // API 源（ibox + 订阅 + 兜底）
    case jsSpider    // JS 蜘蛛
    case zhanyuan    // 站源（Apple CMS）
    case music       // 音乐源（NodeJS 音乐蜘蛛引擎）

    var displayName: String {
        switch self {
        case .cloudCMS:   return "网盘"
        case .cloudForum: return "论坛"
        case .cloudSPA:   return "网盘"
        case .api:        return "API"
        case .jsSpider:   return "JS"
        case .zhanyuan:   return "站源"
        case .music:      return "音乐"
        }
    }

    var supportsHome: Bool {
        switch self {
        case .cloudCMS, .api, .jsSpider, .zhanyuan, .music: return true
        case .cloudForum, .cloudSPA: return false
        }
    }

    /// 排序权重（越小越靠前）
    var sortOrder: Int {
        switch self {
        case .cloudCMS:   return 0
        case .cloudSPA:   return 1
        case .cloudForum: return 2
        case .api:        return 3
        case .jsSpider:   return 4
        case .zhanyuan:   return 5
        case .music:      return 6
        }
    }
}

// MARK: - 统一源展示模型

struct SourceDisplayItem: Identifiable, Hashable {
    let id: String
    let name: String
    let category: SourceCategory
    let supportsHome: Bool
    let api: String?           // API 基地址（ac=home 用）
    let searchUrl: String?     // 站源搜索 URL
    let engineKey: String?     // JS 蜘蛛引擎 key
    let referer: String?       // 封面图 Referer（从 api 提取域名）
    let siteKey: String        // 原始 key

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SourceDisplayItem, rhs: SourceDisplayItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 多源首页数据

struct SourceHomeData {
    let sourceName: String
    let categories: [VodCategory]
    let recommended: [VodItem]
    let sourceType: SourceCategory
}

// MARK: - 源首页请求结果（AppleCMS ac=home 格式）

struct SourceHomeRaw: Codable {
    let `class`: [VodCategory]?
    let list: [VodItem]?
}
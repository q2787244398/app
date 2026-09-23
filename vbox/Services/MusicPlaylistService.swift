import Foundation
import SwiftUI

// MARK: - MusicPlatformType

enum MusicPlatformType: String, CaseIterable, Codable, Hashable {
    case netease = "wy"
    case qq = "tx"
    case kugou = "kg"
    case kuwo = "kw"
    case migu = "mg"

    var displayName: String {
        switch self {
        case .netease: return "网易云"
        case .qq: return "QQ音乐"
        case .kugou: return "酷狗"
        case .kuwo: return "酷我"
        case .migu: return "咪咕"
        }
    }

    var accentColor: Color {
        switch self {
        case .netease: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .qq: return Color(red: 0.11, green: 0.56, blue: 1.00)
        case .kugou: return Color(red: 0.05, green: 0.75, blue: 0.40)
        case .kuwo: return Color(red: 1.00, green: 0.55, blue: 0.10)
        case .migu: return Color(red: 0.50, green: 0.25, blue: 0.85)
        }
    }
}

// MARK: - Models

struct PlaylistCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let platform: MusicPlatformType
}

struct PlaylistItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let coverURL: String
    let playCount: String?
    let songCount: Int?
    let creator: String?
    let platform: MusicPlatformType
    let rawId: String
}

struct PlaylistSong: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let artist: String
    let album: String?
    let duration: Int?
    let coverURL: String?
    let platform: String
    let rawInfo: String?
}

struct PlaylistDetail: Codable {
    let id: String
    let name: String
    let coverURL: String
    let creator: String?
    let description: String?
    let songCount: Int
    let songs: [PlaylistSong]
    let platform: MusicPlatformType
}

struct RankingItem: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let coverURL: String?
    let updateFreq: String?
    let platform: MusicPlatformType
    let rawId: String
}

// MARK: - MusicPlaylistService

@MainActor
final class MusicPlaylistService {

    static let shared = MusicPlaylistService()
    private init() {}

    // MARK: - Constants

    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/605.1.15"

    // MARK: - HTTP Helpers

    private func httpGet(url: URL, headers: [String: String] = [:]) async -> Any? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            return nil
        }
    }

    private func httpPost(url: URL, body: String, headers: [String: String] = [:]) async -> Any? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
        } catch {
            return nil
        }
    }

    // MARK: - JSON Helpers

    private func safeString(_ dict: [String: Any], _ key: String) -> String? {
        if let s = dict[key] as? String { return s }
        if let i = dict[key] as? Int { return String(i) }
        if let d = dict[key] as? Double { return String(Int(d)) }
        if let n = dict[key] as? NSNumber { return n.stringValue }
        return nil
    }

    private func safeInt(_ dict: [String: Any], _ key: String) -> Int? {
        if let i = dict[key] as? Int { return i }
        if let d = dict[key] as? Double { return Int(d) }
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String {
            if let v = Int(s) { return v }
            if let v = Double(s) { return Int(v) }
        }
        return nil
    }

    private func safeDouble(_ dict: [String: Any], _ key: String) -> Double? {
        if let d = dict[key] as? Double { return d }
        if let i = dict[key] as? Int { return Double(i) }
        if let n = dict[key] as? NSNumber { return n.doubleValue }
        if let s = dict[key] as? String, let v = Double(s) { return v }
        return nil
    }

    private func safeDict(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        return dict[key] as? [String: Any]
    }

    private func safeArray(_ dict: [String: Any], _ key: String) -> [Any]? {
        return dict[key] as? [Any]
    }

    private func safeStringFromDictArray(_ array: [Any]?, key: String) -> String {
        guard let array = array else { return "" }
        let names = array.compactMap { item -> String? in
            guard let d = item as? [String: Any] else { return nil }
            return safeString(d, key)
        }
        return names.joined(separator: ", ")
    }

    private func toJsonString(_ obj: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func firstNonNil(_ values: String?...) -> String? {
        for v in values {
            if let v = v, !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - Utility Helpers

    private func formatPlayCount(_ count: Int?) -> String? {
        guard let count = count, count > 0 else { return nil }
        if count >= 100_000_000 {
            return String(format: "%.1f亿", Double(count) / 100_000_000)
        } else if count >= 10_000 {
            return "\(count / 10_000)万"
        } else {
            return String(count)
        }
    }

    private func normalizeDuration(_ value: Int?) -> Int? {
        guard let v = value, v > 0 else { return nil }
        if v > 10_000 {
            return v / 1000
        }
        return v
    }

    private func ensureHTTPSPrefix(_ url: String?) -> String? {
        guard var u = url, !u.isEmpty else { return nil }
        if u.hasPrefix("//") {
            u = "https:" + u
        }
        return u
    }

    private func buildURL(base: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = queryItems
        return components.url
    }

    private func buildURLWithEncodedJSON(base: String, paramName: String, json: [String: Any]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        components.queryItems = [URLQueryItem(name: paramName, value: jsonString)]
        return components.url
    }

    private func formEncode(_ params: [String: String]) -> String {
        return params.map { (key, value) -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    // MARK: - Public API Methods

    func getPlaylistCategories(platform: MusicPlatformType) async -> [PlaylistCategory] {
        switch platform {
        case .netease: return await neteaseCategories()
        case .qq: return await qqCategories()
        case .kugou: return await kugouCategories()
        case .kuwo: return await kuwoCategories()
        case .migu: return await miguCategories()
        }
    }

    func getPlaylists(platform: MusicPlatformType, category: String?, page: Int) async -> [PlaylistItem] {
        switch platform {
        case .netease: return await neteasePlaylists(category: category, page: page)
        case .qq: return await qqPlaylists(category: category, page: page)
        case .kugou: return await kugouPlaylists(category: category, page: page)
        case .kuwo: return await kuwoPlaylists(category: category, page: page)
        case .migu: return await miguPlaylists(category: category, page: page)
        }
    }

    func getPlaylistDetail(platform: MusicPlatformType, id: String) async -> PlaylistDetail? {
        switch platform {
        case .netease: return await neteasePlaylistDetail(id: id)
        case .qq: return await qqPlaylistDetail(id: id)
        case .kugou: return await kugouPlaylistDetail(id: id)
        case .kuwo: return await kuwoPlaylistDetail(id: id)
        case .migu: return await miguPlaylistDetail(id: id)
        }
    }

    func getRankings(platform: MusicPlatformType) async -> [RankingItem] {
        switch platform {
        case .netease: return await neteaseRankings()
        case .qq: return await qqRankings()
        case .kugou: return await kugouRankings()
        case .kuwo: return await kuwoRankings()
        case .migu: return await miguRankings()
        }
    }

    func getRankingDetail(platform: MusicPlatformType, id: String) async -> PlaylistDetail? {
        switch platform {
        case .netease: return await neteasePlaylistDetail(id: id)
        case .qq: return await qqPlaylistDetail(id: id)
        case .kugou: return await kugouRankingDetail(id: id)
        case .kuwo: return await kuwoRankingDetail(id: id)
        case .migu: return await miguPlaylistDetail(id: id)
        }
    }

    func searchPlaylists(platform: MusicPlatformType, keyword: String, page: Int) async -> [PlaylistItem] {
        switch platform {
        case .netease: return await neteaseSearchPlaylists(keyword: keyword, page: page)
        case .qq: return await qqSearchPlaylists(keyword: keyword, page: page)
        case .kugou: return await kugouSearchPlaylists(keyword: keyword, page: page)
        case .kuwo: return await kuwoSearchPlaylists(keyword: keyword, page: page)
        case .migu: return await miguSearchPlaylists(keyword: keyword, page: page)
        }
    }

    // MARK: - NetEase (网易云)

    private func neteaseHeaders() -> [String: String] {
        return ["Referer": "https://music.163.com"]
    }

    private func neteaseCategories() async -> [PlaylistCategory] {
        guard let url = URL(string: "https://music.163.com/api/playlist/catalogue") else { return [] }
        guard let result = await httpGet(url: url, headers: neteaseHeaders()) as? [String: Any] else { return [] }

        var categories: [PlaylistCategory] = []
        categories.append(PlaylistCategory(id: "全部", name: "全部", platform: .netease))

        if let sub = safeArray(result, "sub") {
            for item in sub {
                guard let dict = item as? [String: Any] else { continue }
                guard let name = safeString(dict, "name"), !name.isEmpty else { continue }
                categories.append(PlaylistCategory(id: name, name: name, platform: .netease))
            }
        }

        return categories
    }

    private func neteasePlaylists(category: String?, page: Int) async -> [PlaylistItem] {
        let cat = category ?? "全部"
        let offset = page * 35
        guard let url = buildURL(
            base: "https://music.163.com/api/playlist/list",
            queryItems: [
                URLQueryItem(name: "cat", value: cat),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: "35"),
                URLQueryItem(name: "order", value: "hot")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: neteaseHeaders()) as? [String: Any] else { return [] }
        guard let playlists = safeArray(result, "playlists") else { return [] }

        var items: [PlaylistItem] = []
        for playlist in playlists {
            guard let dict = playlist as? [String: Any] else { continue }
            guard let id = safeInt(dict, "id") else { continue }
            let name = safeString(dict, "name") ?? ""
            let coverURL = safeString(dict, "coverImgUrl") ?? ""
            let playCount = formatPlayCount(safeInt(dict, "playCount"))
            let songCount = safeInt(dict, "trackCount")
            let creator = safeDict(dict, "creator").flatMap { safeString($0, "nickname") }

            items.append(PlaylistItem(
                id: "wy_\(id)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .netease,
                rawId: String(id)
            ))
        }
        return items
    }

    private func neteasePlaylistDetail(id: String) async -> PlaylistDetail? {
        guard let url = URL(string: "https://music.163.com/api/v3/playlist/detail") else { return nil }
        let body = formEncode(["id": id, "n": "1000", "s": "8"])
        guard let result = await httpPost(url: url, body: body, headers: neteaseHeaders()) as? [String: Any] else { return nil }
        guard let playlist = safeDict(result, "playlist") else { return nil }

        let name = safeString(playlist, "name") ?? ""
        let coverURL = safeString(playlist, "coverImgUrl") ?? ""
        let creator = safeDict(playlist, "creator").flatMap { safeString($0, "nickname") }
        let description = safeString(playlist, "description")
        let songCount = safeInt(playlist, "trackCount") ?? 0

        var songs: [PlaylistSong] = []
        if let tracks = safeArray(playlist, "tracks") {
            for track in tracks {
                guard let dict = track as? [String: Any] else { continue }
                guard let songId = safeInt(dict, "id") else { continue }
                let songName = safeString(dict, "name") ?? ""
                let artist = safeStringFromDictArray(safeArray(dict, "ar"), key: "name")
                let album = safeDict(dict, "al").flatMap { safeString($0, "name") }
                let duration = normalizeDuration(safeInt(dict, "dt"))
                let coverURL = safeDict(dict, "al").flatMap { safeString($0, "picUrl") }
                let rawInfo = toJsonString(dict)

                songs.append(PlaylistSong(
                    id: "wy_\(songId)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: coverURL,
                    platform: "wy",
                    rawInfo: rawInfo
                ))
            }
        }

        return PlaylistDetail(
            id: "wy_\(id)",
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount,
            songs: songs,
            platform: .netease
        )
    }

    private func neteaseRankings() async -> [RankingItem] {
        guard let url = URL(string: "https://music.163.com/api/toplist/detail") else { return [] }
        guard let result = await httpGet(url: url, headers: neteaseHeaders()) as? [String: Any] else { return [] }
        guard let list = safeArray(result, "list") else { return [] }

        var items: [RankingItem] = []
        for entry in list {
            guard let dict = entry as? [String: Any] else { continue }
            guard let id = safeInt(dict, "id") else { continue }
            let name = safeString(dict, "name") ?? ""
            let coverURL = safeString(dict, "coverImgUrl")
            let updateFreq = safeString(dict, "updateFrequency")

            items.append(RankingItem(
                id: "wy_\(id)",
                name: name,
                coverURL: coverURL,
                updateFreq: updateFreq,
                platform: .netease,
                rawId: String(id)
            ))
        }
        return items
    }

    private func neteaseSearchPlaylists(keyword: String, page: Int) async -> [PlaylistItem] {
        guard let url = URL(string: "https://music.163.com/api/cloudsearch/pc") else { return [] }
        let offset = page * 30
        let body = formEncode([
            "s": keyword,
            "type": "1000",
            "limit": "30",
            "offset": String(offset)
        ])
        guard let result = await httpPost(url: url, body: body, headers: neteaseHeaders()) as? [String: Any] else { return [] }
        guard let searchResult = safeDict(result, "result") else { return [] }
        guard let playlists = safeArray(searchResult, "playlists") else { return [] }

        var items: [PlaylistItem] = []
        for playlist in playlists {
            guard let dict = playlist as? [String: Any] else { continue }
            guard let id = safeInt(dict, "id") else { continue }
            let name = safeString(dict, "name") ?? ""
            let coverURL = safeString(dict, "coverImgUrl") ?? ""
            let playCount = formatPlayCount(safeInt(dict, "playCount"))
            let songCount = safeInt(dict, "trackCount")
            let creator = safeDict(dict, "creator").flatMap { safeString($0, "nickname") }

            items.append(PlaylistItem(
                id: "wy_\(id)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .netease,
                rawId: String(id)
            ))
        }
        return items
    }

    // MARK: - QQ Music (QQ音乐)

    private func qqHeaders() -> [String: String] {
        return ["Referer": "https://y.qq.com/"]
    }

    private func qqCategories() async -> [PlaylistCategory] {
        let requestBody: [String: Any] = [
            "comm": ["uin": 0, "format": "json", "ct": 24, "cv": 0],
            "req": [
                "module": "playlist.PlayListCategoryServer",
                "method": "get_category_content",
                "param": [
                    "callerId": "0",
                    "callerType": "0",
                    "categoryType": "1000000000",
                    "size": "30"
                ]
            ]
        ]

        guard let url = buildURLWithEncodedJSON(
            base: "https://u.y.qq.com/cgi-bin/musicu.fcg",
            paramName: "data",
            json: requestBody
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: qqHeaders()) as? [String: Any] else { return [] }
        guard let req = safeDict(result, "req") else { return [] }
        guard let data = safeDict(req, "data") else { return [] }

        var categories: [PlaylistCategory] = []
        categories.append(PlaylistCategory(id: "", name: "全部", platform: .qq))

        var categoryList: [[String: Any]] = []
        if let category = safeDict(data, "category"),
           let cl = safeArray(category, "categoryList") {
            for item in cl {
                if let dict = item as? [String: Any] {
                    categoryList.append(dict)
                }
            }
        } else if let cl = safeArray(data, "categoryList") {
            for item in cl {
                if let dict = item as? [String: Any] {
                    categoryList.append(dict)
                }
            }
        }

        for group in categoryList {
            if let vClass = group["vClass"] as? [Any] {
                for tag in vClass {
                    guard let tagDict = tag as? [String: Any] else { continue }
                    let id = safeString(tagDict, "id") ?? ""
                    let name = safeString(tagDict, "tagName") ?? ""
                    if !name.isEmpty {
                        categories.append(PlaylistCategory(id: id, name: name, platform: .qq))
                    }
                }
            }
        }

        return categories
    }

    private func qqPlaylists(category: String?, page: Int) async -> [PlaylistItem] {
        var param: [String: Any] = [
            "callerId": "0",
            "size": "30",
            "page": page - 1 < 0 ? 0 : page - 1,
            "type": 0
        ]
        if let cat = category, !cat.isEmpty {
            param["type"] = 1
            param["tagId"] = cat
        }

        let requestBody: [String: Any] = [
            "comm": ["uin": 0, "format": "json", "ct": 24, "cv": 0],
            "req": [
                "module": "playlist.PlayListPlazaServer",
                "method": "get_playlist_by_tag",
                "param": param
            ]
        ]

        guard let url = buildURLWithEncodedJSON(
            base: "https://u.y.qq.com/cgi-bin/musicu.fcg",
            paramName: "data",
            json: requestBody
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: qqHeaders()) as? [String: Any] else { return [] }
        guard let req = safeDict(result, "req") else { return [] }
        guard let data = safeDict(req, "data") else { return [] }

        let playlistArray: [Any]?
        if let arr = safeArray(data, "playlistList") {
            playlistArray = arr
        } else if let arr = safeArray(data, "v_playlist") {
            playlistArray = arr
        } else if let arr = safeArray(data, "list") {
            playlistArray = arr
        } else {
            playlistArray = nil
        }

        guard let playlists = playlistArray else { return [] }

        var items: [PlaylistItem] = []
        for playlist in playlists {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "dirId"),
                safeString(dict, "tid"),
                safeString(dict, "disstid"),
                safeInt(dict, "dirId").map { String($0) },
                safeInt(dict, "tid").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }

            let name = firstNonNil(
                safeString(dict, "dirName"),
                safeString(dict, "dcName"),
                safeString(dict, "title"),
                safeString(dict, "dissname")
            ) ?? ""
            let coverURL = firstNonNil(
                safeString(dict, "picUrl"),
                safeString(dict, "picurl"),
                safeString(dict, "imgurl"),
                safeString(dict, "logo")
            ) ?? ""
            let playCount = formatPlayCount(
                safeInt(dict, "listenNum") ?? safeInt(dict, "listennum") ?? safeInt(dict, "playCount")
            )
            let songCount = safeInt(dict, "songNum") ?? safeInt(dict, "songnum")
            let creator = safeDict(dict, "creator").flatMap { safeString($0, "name") }

            items.append(PlaylistItem(
                id: "tx_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .qq,
                rawId: rawId
            ))
        }
        return items
    }

    private func qqPlaylistDetail(id: String) async -> PlaylistDetail? {
        guard let url = buildURL(
            base: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg",
            queryItems: [
                URLQueryItem(name: "type", value: "1"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "utf8", value: "1"),
                URLQueryItem(name: "onlysong", value: "0"),
                URLQueryItem(name: "new_format", value: "1"),
                URLQueryItem(name: "disstid", value: id),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "inCharset", value: "utf8"),
                URLQueryItem(name: "outCharset", value: "utf-8")
            ]
        ) else { return nil }

        guard let result = await httpGet(url: url, headers: qqHeaders()) as? [String: Any] else { return nil }
        guard let cdlist = safeArray(result, "cdlist") else { return nil }
        guard let firstCD = cdlist.first as? [String: Any] else { return nil }

        let name = firstNonNil(
            safeString(firstCD, "dissname"),
            safeString(firstCD, "dirName"),
            safeString(firstCD, "title")
        ) ?? ""
        let coverURL = firstNonNil(
            safeString(firstCD, "logo"),
            safeString(firstCD, "picUrl"),
            safeString(firstCD, "imgurl")
        ) ?? ""
        let creator = firstNonNil(
            safeString(firstCD, "nickname"),
            safeDict(firstCD, "creator").flatMap { safeString($0, "name") }
        )
        let description = firstNonNil(
            safeString(firstCD, "desc"),
            safeString(firstCD, "introduction"),
            safeString(firstCD, "comment")
        )
        let songCount = safeInt(firstCD, "total_song_num") ?? safeInt(firstCD, "songnum") ?? 0

        var songs: [PlaylistSong] = []
        if let songlist = safeArray(firstCD, "songlist") {
            for song in songlist {
                guard let dict = song as? [String: Any] else { continue }
                guard let songMid = safeString(dict, "songmid") else { continue }
                let songName = safeString(dict, "songname") ?? safeString(dict, "name") ?? ""
                let artist = safeStringFromDictArray(safeArray(dict, "singer"), key: "name")
                let album = safeString(dict, "albumname") ?? safeString(dict, "albumName")
                let duration = safeInt(dict, "interval")
                let albumMid = safeString(dict, "albummid") ?? ""
                let picUrl = firstNonNil(
                    safeString(dict, "picAlbum"),
                    safeString(dict, "picurl"),
                    safeString(dict, "pic")
                ) ?? (albumMid.isEmpty ? nil : "https://y.gtimg.cn/music/photo_new/T002R300x300M000\(albumMid).jpg")
                let rawInfo = toJsonString(dict)

                songs.append(PlaylistSong(
                    id: "tx_\(songMid)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: picUrl,
                    platform: "tx",
                    rawInfo: rawInfo
                ))
            }
        }

        return PlaylistDetail(
            id: "tx_\(id)",
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount,
            songs: songs,
            platform: .qq
        )
    }

    private func qqRankings() async -> [RankingItem] {
        guard let url = buildURL(
            base: "https://c.y.qq.com/v8/fcg-bin/fcg_myqq_toplist.fcg",
            queryItems: [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "inCharset", value: "utf-8"),
                URLQueryItem(name: "outCharset", value: "utf-8"),
                URLQueryItem(name: "notice", value: "0"),
                URLQueryItem(name: "platform", value: "h5"),
                URLQueryItem(name: "needNewCode", value: "1")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: qqHeaders()) as? [String: Any] else { return [] }

        var topList: [Any] = []
        if let data = safeDict(result, "data"), let arr = safeArray(data, "topList") {
            topList = arr
        } else if let arr = safeArray(result, "topList") {
            topList = arr
        }

        var items: [RankingItem] = []
        for entry in topList {
            guard let dict = entry as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "id"),
                safeString(dict, "topId"),
                safeInt(dict, "id").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = firstNonNil(
                safeString(dict, "topTitle"),
                safeString(dict, "title"),
                safeString(dict, "topName")
            ) ?? ""
            let coverURL = firstNonNil(
                safeString(dict, "picUrl"),
                safeString(dict, "picurl"),
                safeString(dict, "frontPicUrl"),
                safeString(dict, "albumPic")
            )
            let updateFreq = firstNonNil(
                safeString(dict, "updateTime"),
                safeString(dict, "updateFreq"),
                safeString(dict, "frequency")
            )

            items.append(RankingItem(
                id: "tx_\(rawId)",
                name: name,
                coverURL: coverURL,
                updateFreq: updateFreq,
                platform: .qq,
                rawId: rawId
            ))
        }
        return items
    }

    private func qqSearchPlaylists(keyword: String, page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "http://c.y.qq.com/soso/fcgi-bin/client_music_search_songlist",
            queryItems: [
                URLQueryItem(name: "page_no", value: String(page)),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "query", value: keyword),
                URLQueryItem(name: "remoteplace", value: "txt.yqq.playlist"),
                URLQueryItem(name: "inCharset", value: "utf8"),
                URLQueryItem(name: "outCharset", value: "utf-8")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: qqHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var searchList: [Any] = []
        if let listObj = safeDict(data, "list"), let arr = safeArray(listObj, "list") {
            searchList = arr
        } else if let arr = safeArray(data, "list") {
            searchList = arr
        }

        var items: [PlaylistItem] = []
        for playlist in searchList {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "dissid"),
                safeString(dict, "disstid"),
                safeString(dict, "id")
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = firstNonNil(
                safeString(dict, "dissname"),
                safeString(dict, "dcName"),
                safeString(dict, "title")
            ) ?? ""
            let coverURL = firstNonNil(
                safeString(dict, "imgurl"),
                safeString(dict, "picUrl"),
                safeString(dict, "picurl"),
                safeString(dict, "logo")
            ) ?? ""
            let playCount = formatPlayCount(
                safeInt(dict, "listennum") ?? safeInt(dict, "listenNum") ?? safeInt(dict, "playCount")
            )
            let songCount = safeInt(dict, "songnum") ?? safeInt(dict, "songNum")
            let creator = safeDict(dict, "creator").flatMap { safeString($0, "name") }

            items.append(PlaylistItem(
                id: "tx_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .qq,
                rawId: rawId
            ))
        }
        return items
    }

    // MARK: - KuGou (酷狗)

    private func kugouHeaders() -> [String: String] {
        return [:]
    }

    private func kugouCategories() async -> [PlaylistCategory] {
        // 动态自适应：从酷狗标签树接口实时拉取，不再写死分类。
        var categories: [PlaylistCategory] = []
        categories.append(PlaylistCategory(id: "", name: "推荐", platform: .kugou))

        guard let url = buildURL(
            base: "http://mobilecdnbj.kugou.com/api/v3/tag/list",
            queryItems: [
                URLQueryItem(name: "plat", value: "0"),
                URLQueryItem(name: "version", value: "9108")
            ]
        ) else { return categories }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { return categories }
        guard let data = safeDict(result, "data") else { return categories }
        guard let info = safeArray(data, "info") else { return categories }

        // 一级分类：取每个标签分类的 id 与名称（对应歌单 tag 接口的 tagid）
        var seen = Set<String>()
        for group in info {
            guard let dict = group as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "special_tag_id"),
                safeInt(dict, "special_tag_id").map { String($0) },
                safeString(dict, "id"),
                safeInt(dict, "id").map { String($0) }
            ) ?? ""
            let name = firstNonNil(safeString(dict, "name")) ?? ""
            if name.isEmpty || rawId.isEmpty { continue }
            // 跳过纯运营位（如“排行榜”“专属定制”等无歌单分类标签）
            if seen.contains(rawId) { continue }
            seen.insert(rawId)
            categories.append(PlaylistCategory(id: rawId, name: name, platform: .kugou))
        }

        return categories
    }

    private func kugouPlaylists(category: String?, page: Int) async -> [PlaylistItem] {
        if let cat = category, !cat.isEmpty {
            return await kugouPlaylistsByTag(tagId: cat, page: page)
        } else {
            return await kugouRecommendedPlaylists(page: page)
        }
    }

    private func kugouRecommendedPlaylists(page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "http://mobilecdnbj.kugou.com/api/v5/special/recommend",
            queryItems: [
                URLQueryItem(name: "version", value: "9108"),
                URLQueryItem(name: "plat", value: "0"),
                URLQueryItem(name: "showtype", value: "2"),
                URLQueryItem(name: "apiver", value: "6"),
                URLQueryItem(name: "area_code", value: "1"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pagesize", value: "30")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }
        guard let list = safeArray(data, "info") else { return [] }

        return parseKuGouPlaylistItems(list)
    }

    private func kugouPlaylistsByTag(tagId: String, page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "http://mobilecdnbj.kugou.com/api/v5/special/tag",
            queryItems: [
                URLQueryItem(name: "version", value: "9108"),
                URLQueryItem(name: "plat", value: "0"),
                URLQueryItem(name: "showtype", value: "2"),
                URLQueryItem(name: "apiver", value: "6"),
                URLQueryItem(name: "area_code", value: "1"),
                URLQueryItem(name: "tagid", value: tagId),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pagesize", value: "30")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }
        guard let list = safeArray(data, "info") else { return [] }

        return parseKuGouPlaylistItems(list)
    }

    private func parseKuGouPlaylistItems(_ list: [Any]) -> [PlaylistItem] {
        var items: [PlaylistItem] = []
        for playlist in list {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "specialid"),
                safeInt(dict, "specialid").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = firstNonNil(
                safeString(dict, "specialname"),
                safeString(dict, "name")
            ) ?? ""
            var coverURL = firstNonNil(
                safeString(dict, "imgurl"),
                safeString(dict, "picurl"),
                safeString(dict, "logo")
            ) ?? ""
            coverURL = ensureHTTPSPrefix(coverURL) ?? coverURL
            let playCount = formatPlayCount(
                safeInt(dict, "playcount") ?? safeInt(dict, "listennum")
            )
            let songCount = safeInt(dict, "songcount") ?? safeInt(dict, "songnum")
            let creator = firstNonNil(
                safeString(dict, "nickname"),
                safeString(dict, "username"),
                safeString(dict, "creator")
            )

            items.append(PlaylistItem(
                id: "kg_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .kugou,
                rawId: rawId
            ))
        }
        return items
    }

    private func kugouPlaylistDetail(id: String) async -> PlaylistDetail? {
        async let infoResult = kugouPlaylistInfo(id: id)
        async let songsResult = kugouPlaylistSongs(id: id)

        let info = await infoResult
        let songs = await songsResult

        return PlaylistDetail(
            id: "kg_\(id)",
            name: info.name,
            coverURL: info.coverURL,
            creator: info.creator,
            description: info.description,
            songCount: info.songCount,
            songs: songs,
            platform: .kugou
        )
    }

    private struct KuGouPlaylistInfo {
        let name: String
        let coverURL: String
        let creator: String?
        let description: String?
        let songCount: Int
    }

    private func kugouPlaylistInfo(id: String) async -> KuGouPlaylistInfo {
        guard let url = buildURL(
            base: "https://mobiles.kugou.com/api/v5/special/info_v2",
            queryItems: [
                URLQueryItem(name: "specialid", value: id),
                URLQueryItem(name: "with_common_getter", value: "1"),
                URLQueryItem(name: "appid", value: "1005"),
                URLQueryItem(name: "clientver", value: "0"),
                URLQueryItem(name: "format", value: "1"),
                URLQueryItem(name: "srcappid", value: "2919")
            ]
        ) else {
            return KuGouPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else {
            return KuGouPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }
        guard let data = safeDict(result, "data") else {
            return KuGouPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }

        let name = safeString(data, "specialname") ?? ""
        var coverURL = safeString(data, "imgurl") ?? ""
        coverURL = ensureHTTPSPrefix(coverURL) ?? coverURL
        let creator = firstNonNil(
            safeString(data, "nickname"),
            safeString(data, "username")
        )
        let description = firstNonNil(
            safeString(data, "intro"),
            safeString(data, "description")
        )
        let songCount = safeInt(data, "songcount") ?? 0

        return KuGouPlaylistInfo(
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount
        )
    }

    private func kugouPlaylistSongs(id: String) async -> [PlaylistSong] {
        var allSongs: [PlaylistSong] = []
        var page = 1

        while page <= 50 {
            guard let url = buildURL(
                base: "https://mobiles.kugou.com/api/v5/special/song_v2",
                queryItems: [
                    URLQueryItem(name: "specialid", value: id),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "pagesize", value: "30"),
                    URLQueryItem(name: "appid", value: "1005"),
                    URLQueryItem(name: "clientver", value: "0"),
                    URLQueryItem(name: "format", value: "1"),
                    URLQueryItem(name: "srcappid", value: "2919")
                ]
            ) else { break }

            guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { break }
            guard let data = safeDict(result, "data") else { break }
            guard let list = safeArray(data, "info") else { break }
            if list.isEmpty { break }

            for song in list {
                guard let dict = song as? [String: Any] else { continue }
                guard let hash = safeString(dict, "hash") else { continue }
                let songName = firstNonNil(
                    safeString(dict, "songname"),
                    safeString(dict, "filename"),
                    safeString(dict, "name")
                ) ?? ""
                let artist = firstNonNil(
                    safeString(dict, "singername"),
                    safeString(dict, "artist")
                ) ?? ""
                let album = firstNonNil(
                    safeString(dict, "album_name"),
                    safeString(dict, "albumname"),
                    safeString(dict, "album")
                )
                let duration = safeInt(dict, "duration")
                var coverURL = firstNonNil(
                    safeString(dict, "album_img"),
                    safeString(dict, "imgurl")
                )
                coverURL = ensureHTTPSPrefix(coverURL) ?? coverURL
                let rawInfo = toJsonString(dict)

                allSongs.append(PlaylistSong(
                    id: "kg_\(hash)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: coverURL,
                    platform: "kg",
                    rawInfo: rawInfo
                ))
            }

            if list.count < 30 { break }
            page += 1
        }

        return allSongs
    }

    private func kugouRankings() async -> [RankingItem] {
        guard let url = buildURL(
            base: "http://mobilecdnbj.kugou.com/api/v5/rank/list",
            queryItems: [
                URLQueryItem(name: "version", value: "9108"),
                URLQueryItem(name: "plat", value: "0"),
                URLQueryItem(name: "showtype", value: "2"),
                URLQueryItem(name: "parentid", value: "0"),
                URLQueryItem(name: "apiver", value: "6"),
                URLQueryItem(name: "area_code", value: "1"),
                URLQueryItem(name: "withsong", value: "1")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }
        guard let list = safeArray(data, "list") else { return [] }

        var items: [RankingItem] = []
        for entry in list {
            guard let dict = entry as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "rankid"),
                safeInt(dict, "rankid").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = safeString(dict, "rankname") ?? ""
            var coverURL = safeString(dict, "imgurl")
            coverURL = ensureHTTPSPrefix(coverURL)
            let updateFreq = safeString(dict, "update_frequency")

            items.append(RankingItem(
                id: "kg_\(rawId)",
                name: name,
                coverURL: coverURL,
                updateFreq: updateFreq,
                platform: .kugou,
                rawId: rawId
            ))
        }
        return items
    }

    private func kugouRankingDetail(id: String) async -> PlaylistDetail? {
        async let rankingsResult = kugouRankings()
        async let songsResult = kugouRankingSongs(rankId: id, page: 1)

        let rankings = await rankingsResult
        let songs = await songsResult

        let ranking = rankings.first { $0.rawId == id }
        let name = ranking?.name ?? ""
        let coverURL = ranking?.coverURL ?? ""

        return PlaylistDetail(
            id: "kg_\(id)",
            name: name,
            coverURL: coverURL,
            creator: nil,
            description: nil,
            songCount: songs.count,
            songs: songs,
            platform: .kugou
        )
    }

    private func kugouRankingSongs(rankId: String, page: Int) async -> [PlaylistSong] {
        var allSongs: [PlaylistSong] = []
        var currentPage = page

        while currentPage <= 10 {
            guard let url = buildURL(
                base: "http://mobilecdnbj.kugou.com/api/v3/rank/song",
                queryItems: [
                    URLQueryItem(name: "version", value: "9108"),
                    URLQueryItem(name: "ranktype", value: "1"),
                    URLQueryItem(name: "plat", value: "0"),
                    URLQueryItem(name: "pagesize", value: "30"),
                    URLQueryItem(name: "area_code", value: "1"),
                    URLQueryItem(name: "page", value: String(currentPage)),
                    URLQueryItem(name: "with_res_tag", value: "0"),
                    URLQueryItem(name: "rankid", value: rankId),
                    URLQueryItem(name: "show_portrait_mv", value: "1")
                ]
            ) else { break }

            guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { break }
            guard let data = safeDict(result, "data") else { break }
            guard let list = safeArray(data, "info") else { break }
            if list.isEmpty { break }

            for song in list {
                guard let dict = song as? [String: Any] else { continue }
                guard let hash = safeString(dict, "hash") else { continue }
                let songName = firstNonNil(
                    safeString(dict, "songname"),
                    safeString(dict, "filename")
                ) ?? ""
                let artist = firstNonNil(
                    safeString(dict, "singername"),
                    safeString(dict, "artist")
                ) ?? ""
                let album = firstNonNil(
                    safeString(dict, "album_name"),
                    safeString(dict, "albumname")
                )
                let duration = safeInt(dict, "duration")
                var coverURL = firstNonNil(
                    safeString(dict, "album_img"),
                    safeString(dict, "imgurl")
                )
                coverURL = ensureHTTPSPrefix(coverURL) ?? coverURL
                let rawInfo = toJsonString(dict)

                allSongs.append(PlaylistSong(
                    id: "kg_\(hash)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: coverURL,
                    platform: "kg",
                    rawInfo: rawInfo
                ))
            }

            if list.count < 30 { break }
            currentPage += 1
        }

        return allSongs
    }

    private func kugouSearchPlaylists(keyword: String, page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "http://msearchretry.kugou.com/api/v3/search/special",
            queryItems: [
                URLQueryItem(name: "keyword", value: keyword),
                URLQueryItem(name: "showtype", value: "10"),
                URLQueryItem(name: "filter", value: "0"),
                URLQueryItem(name: "version", value: "7910"),
                URLQueryItem(name: "sver", value: "2"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pagesize", value: "20")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: kugouHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }
        guard let list = safeArray(data, "lists") else { return [] }

        var items: [PlaylistItem] = []
        for playlist in list {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "specialid"),
                safeInt(dict, "specialid").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = safeString(dict, "specialname") ?? ""
            var coverURL = safeString(dict, "imgurl") ?? ""
            coverURL = ensureHTTPSPrefix(coverURL) ?? coverURL
            let playCount = formatPlayCount(safeInt(dict, "playcount"))
            let songCount = safeInt(dict, "songcount")
            let creator = firstNonNil(
                safeString(dict, "username"),
                safeString(dict, "nickname")
            )

            items.append(PlaylistItem(
                id: "kg_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .kugou,
                rawId: rawId
            ))
        }
        return items
    }

    // MARK: - KuWo (酷我)

    private func kuwoHeaders() -> [String: String] {
        return ["Referer": "http://www.kuwo.cn/"]
    }

    private func kuwoCategories() async -> [PlaylistCategory] {
        guard let url = buildURL(
            base: "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagList",
            queryItems: [
                URLQueryItem(name: "cmd", value: "rcm_keyword_playlist"),
                URLQueryItem(name: "user", value: "0"),
                URLQueryItem(name: "prod", value: "kwplayer_pc_9.0.5.0"),
                URLQueryItem(name: "vipver", value: "9.0.5.0"),
                URLQueryItem(name: "source", value: "kwplayer_pc_9.0.5.0"),
                URLQueryItem(name: "loginUid", value: "0"),
                URLQueryItem(name: "loginSid", value: "0"),
                URLQueryItem(name: "appUid", value: "76039576")
            ]
        ) else {
            return [PlaylistCategory(id: "", name: "推荐", platform: .kuwo)]
        }

        guard let result = await httpGet(url: url, headers: kuwoHeaders()) as? [String: Any] else {
            return [PlaylistCategory(id: "", name: "推荐", platform: .kuwo)]
        }

        var categories: [PlaylistCategory] = []
        categories.append(PlaylistCategory(id: "", name: "推荐", platform: .kuwo))

        if let data = safeArray(result, "data") {
            for group in data {
                guard let groupDict = group as? [String: Any] else { continue }
                if let tags = groupDict["tags"] as? [Any] {
                    for tag in tags {
                        guard let tagDict = tag as? [String: Any] else { continue }
                        let id = firstNonNil(
                            safeString(tagDict, "id"),
                            safeInt(tagDict, "id").map { String($0) }
                        ) ?? ""
                        let name = safeString(tagDict, "name") ?? ""
                        if !name.isEmpty {
                            categories.append(PlaylistCategory(id: id, name: name, platform: .kuwo))
                        }
                    }
                }
            }
        }

        return categories
    }

    private func kuwoPlaylists(category: String?, page: Int) async -> [PlaylistItem] {
        let base: String
        var queryItems: [URLQueryItem]

        if let cat = category, !cat.isEmpty {
            base = "http://wapi.kuwo.cn/api/pc/classify/playlist/getTagPlayList"
            queryItems = [
                URLQueryItem(name: "loginUid", value: "0"),
                URLQueryItem(name: "loginSid", value: "0"),
                URLQueryItem(name: "appUid", value: "76039576"),
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "rn", value: "30"),
                URLQueryItem(name: "id", value: cat)
            ]
        } else {
            base = "http://wapi.kuwo.cn/api/pc/classify/playlist/getRcmPlayList"
            queryItems = [
                URLQueryItem(name: "loginUid", value: "0"),
                URLQueryItem(name: "loginSid", value: "0"),
                URLQueryItem(name: "appUid", value: "76039576"),
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "rn", value: "30")
            ]
        }

        guard let url = buildURL(base: base, queryItems: queryItems) else { return [] }
        guard let result = await httpGet(url: url, headers: kuwoHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }
        guard let list = safeArray(data, "list") else { return [] }

        var items: [PlaylistItem] = []
        for playlist in list {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "id"),
                safeInt(dict, "id").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = safeString(dict, "name") ?? ""
            let coverURL = safeString(dict, "img") ?? ""
            let playCount = formatPlayCount(safeInt(dict, "playCount"))
            let songCount = safeInt(dict, "total") ?? safeInt(dict, "songnum")
            let creator = firstNonNil(
                safeString(dict, "userName"),
                safeString(dict, "uname"),
                safeString(dict, "creator")
            )

            items.append(PlaylistItem(
                id: "kw_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .kuwo,
                rawId: rawId
            ))
        }
        return items
    }

    private func kuwoPlaylistDetail(id: String) async -> PlaylistDetail? {
        guard let url = buildURL(
            base: "http://nplserver.kuwo.cn/pl.svc",
            queryItems: [
                URLQueryItem(name: "op", value: "getlistinfo"),
                URLQueryItem(name: "pid", value: id),
                URLQueryItem(name: "encode", value: "utf8"),
                URLQueryItem(name: "keyset", value: "pl2012"),
                URLQueryItem(name: "identity", value: "kuwo"),
                URLQueryItem(name: "pcmp4", value: "1"),
                URLQueryItem(name: "vipver", value: "MUSIC_9.0.5.0_W1"),
                URLQueryItem(name: "newver", value: "1"),
                URLQueryItem(name: "pn", value: "1"),
                URLQueryItem(name: "rn", value: "100")
            ]
        ) else { return nil }

        guard let result = await httpGet(url: url, headers: kuwoHeaders()) as? [String: Any] else { return nil }

        let name = safeString(result, "name") ?? ""
        let coverURL = safeString(result, "pic") ?? ""
        let creator = firstNonNil(
            safeString(result, "uname"),
            safeString(result, "userName"),
            safeString(result, "creator")
        )
        let description = firstNonNil(
            safeString(result, "info"),
            safeString(result, "description")
        )
        let songCount = safeInt(result, "total") ?? 0

        var songs: [PlaylistSong] = []
        if let list = safeArray(result, "list") {
            for song in list {
                guard let dict = song as? [String: Any] else { continue }
                let songId = firstNonNil(
                    safeString(dict, "rid"),
                    safeString(dict, "id"),
                    safeInt(dict, "rid").map { String($0) },
                    safeInt(dict, "id").map { String($0) }
                ) ?? ""
                if songId.isEmpty { continue }
                let songName = safeString(dict, "name") ?? safeString(dict, "songName") ?? ""
                let artist = firstNonNil(
                    safeString(dict, "artist"),
                    safeString(dict, "singer")
                ) ?? ""
                let album = firstNonNil(
                    safeString(dict, "album"),
                    safeString(dict, "albumName")
                )
                let duration = safeInt(dict, "duration")
                let coverURL = safeString(dict, "pic")
                let rawInfo = toJsonString(dict)

                songs.append(PlaylistSong(
                    id: "kw_\(songId)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: coverURL,
                    platform: "kw",
                    rawInfo: rawInfo
                ))
            }
        }

        return PlaylistDetail(
            id: "kw_\(id)",
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount,
            songs: songs,
            platform: .kuwo
        )
    }

    private func kuwoRankings() async -> [RankingItem] {
        let hardcoded: [(String, String, String)] = [
            ("93", "酷我飙升榜", "每日更新"),
            ("16", "酷我热歌榜", "每日更新"),
            ("158", "酷我新歌榜", "每日更新"),
            ("17", "酷我华语榜", "每周更新"),
            ("18", "酷我欧美榜", "每周更新"),
            ("19", "酷我日韩榜", "每周更新"),
            ("26440106", "抖音热歌榜", "每日更新"),
            ("265", "网络红歌榜", "每日更新"),
            ("272", "国风榜", "每周更新"),
            ("273", "怀旧金曲榜", "每周更新"),
        ]

        return hardcoded.map { rawId, name, freq in
            RankingItem(
                id: "kw_\(rawId)",
                name: name,
                coverURL: nil,
                updateFreq: freq,
                platform: .kuwo,
                rawId: rawId
            )
        }
    }

    private func kuwoRankingDetail(id: String) async -> PlaylistDetail? {
        guard let url = buildURL(
            base: "http://kbangserver.kuwo.cn/ksong.s",
            queryItems: [
                URLQueryItem(name: "from", value: "pc"),
                URLQueryItem(name: "fmt", value: "json"),
                URLQueryItem(name: "pn", value: "1"),
                URLQueryItem(name: "rn", value: "30"),
                URLQueryItem(name: "type", value: "bang"),
                URLQueryItem(name: "data", value: "content"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "show_copyright_off", value: "0"),
                URLQueryItem(name: "pcmp4", value: "1"),
                URLQueryItem(name: "isbang", value: "1")
            ]
        ) else { return nil }

        guard let result = await httpGet(url: url, headers: kuwoHeaders()) as? [String: Any] else { return nil }

        let name = firstNonNil(
            safeString(result, "name"),
            safeString(result, "bangName"),
            safeString(result, "title")
        ) ?? ""
        let coverURL = firstNonNil(
            safeString(result, "pic"),
            safeString(result, "img"),
            safeString(result, "cover")
        ) ?? ""
        let creator: String? = nil
        let description: String? = nil
        let songCount = safeInt(result, "total") ?? 0

        var songs: [PlaylistSong] = []
        if let list = safeArray(result, "list") ?? safeArray(result, "musiclist") ?? safeArray(result, "songs") {
            for song in list {
                guard let dict = song as? [String: Any] else { continue }
                let songId = firstNonNil(
                    safeString(dict, "rid"),
                    safeString(dict, "id"),
                    safeInt(dict, "rid").map { String($0) },
                    safeInt(dict, "id").map { String($0) }
                ) ?? ""
                if songId.isEmpty { continue }
                let songName = safeString(dict, "name") ?? safeString(dict, "songName") ?? ""
                let artist = firstNonNil(
                    safeString(dict, "artist"),
                    safeString(dict, "singer")
                ) ?? ""
                let album = firstNonNil(
                    safeString(dict, "album"),
                    safeString(dict, "albumName")
                )
                let duration = safeInt(dict, "duration")
                let coverURL = safeString(dict, "pic")
                let rawInfo = toJsonString(dict)

                songs.append(PlaylistSong(
                    id: "kw_\(songId)",
                    name: songName,
                    artist: artist,
                    album: album,
                    duration: duration,
                    coverURL: coverURL,
                    platform: "kw",
                    rawInfo: rawInfo
                ))
            }
        }

        return PlaylistDetail(
            id: "kw_\(id)",
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount,
            songs: songs,
            platform: .kuwo
        )
    }

    private func kuwoSearchPlaylists(keyword: String, page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "http://search.kuwo.cn/r.s",
            queryItems: [
                URLQueryItem(name: "all", value: keyword),
                URLQueryItem(name: "rformat", value: "json"),
                URLQueryItem(name: "encoding", value: "utf8"),
                URLQueryItem(name: "ver", value: "mbox"),
                URLQueryItem(name: "vipver", value: "MUSIC_8.7.7.0_BCS37"),
                URLQueryItem(name: "plat", value: "pc"),
                URLQueryItem(name: "devid", value: "28156413"),
                URLQueryItem(name: "ft", value: "playlist"),
                URLQueryItem(name: "pay", value: "0"),
                URLQueryItem(name: "needliveshow", value: "0"),
                URLQueryItem(name: "pn", value: String(page)),
                URLQueryItem(name: "rn", value: "20")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: kuwoHeaders()) as? [String: Any] else { return [] }
        guard let list = safeArray(result, "abslist") else { return [] }

        var items: [PlaylistItem] = []
        for playlist in list {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "specialid"),
                safeInt(dict, "specialid").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = firstNonNil(
                safeString(dict, "specialname"),
                safeString(dict, "name")
            ) ?? ""
            let coverURL = safeString(dict, "img") ?? ""
            let playCount = formatPlayCount(safeInt(dict, "playcnt"))
            let songCount = safeInt(dict, "songnum")
            let creator = firstNonNil(
                safeString(dict, "username"),
                safeString(dict, "creator")
            )

            items.append(PlaylistItem(
                id: "kw_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .kuwo,
                rawId: rawId
            ))
        }
        return items
    }

    // MARK: - Migu (咪咕)

    private func miguHeaders() -> [String: String] {
        return ["Referer": "https://music.migu.cn/"]
    }

    private func miguCategories() async -> [PlaylistCategory] {
        guard let url = buildURL(
            base: "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square/v1.0",
            queryItems: [URLQueryItem(name: "templateVersion", value: "1")]
        ) else {
            return [PlaylistCategory(id: "", name: "推荐", platform: .migu)]
        }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else {
            return [PlaylistCategory(id: "", name: "推荐", platform: .migu)]
        }

        var categories: [PlaylistCategory] = []
        categories.append(PlaylistCategory(id: "", name: "推荐", platform: .migu))

        if let data = safeDict(result, "data") {
            if let tagList = safeArray(data, "tagList") {
                for tag in tagList {
                    guard let tagDict = tag as? [String: Any] else { continue }
                    let id = firstNonNil(
                        safeString(tagDict, "tagId"),
                        safeInt(tagDict, "tagId").map { String($0) }
                    ) ?? ""
                    let name = firstNonNil(
                        safeString(tagDict, "tagName"),
                        safeString(tagDict, "name")
                    ) ?? ""
                    if !name.isEmpty {
                        categories.append(PlaylistCategory(id: id, name: name, platform: .migu))
                    }
                }
            }

            if categories.count <= 1, let contentItemList = safeArray(data, "contentItemList") {
                for item in contentItemList {
                    guard let itemDict = item as? [String: Any] else { continue }
                    let itemType = safeString(itemDict, "itemType") ?? ""
                    if itemType.lowercased().contains("tag") {
                        if let contentList = safeArray(itemDict, "contentList") {
                            for content in contentList {
                                guard let contentDict = content as? [String: Any] else { continue }
                                let id = firstNonNil(
                                    safeString(contentDict, "tagId"),
                                    safeString(contentDict, "id")
                                ) ?? ""
                                let name = firstNonNil(
                                    safeString(contentDict, "tagName"),
                                    safeString(contentDict, "name")
                                ) ?? ""
                                if !name.isEmpty {
                                    categories.append(PlaylistCategory(id: id, name: name, platform: .migu))
                                }
                            }
                        }
                    }
                }
            }
        }

        return categories
    }

    private func miguPlaylists(category: String?, page: Int) async -> [PlaylistItem] {
        if let cat = category, !cat.isEmpty {
            return await miguPlaylistsByTag(tagId: cat, page: page)
        } else {
            return await miguPlaylistSquare(page: page)
        }
    }

    private func miguPlaylistSquare(page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square/v1.0",
            queryItems: [
                URLQueryItem(name: "templateVersion", value: "1"),
                URLQueryItem(name: "pageNo", value: String(page))
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var items: [PlaylistItem] = []
        if let contentItemList = safeArray(data, "contentItemList") {
            for item in contentItemList {
                guard let itemDict = item as? [String: Any] else { continue }
                let itemType = safeString(itemDict, "itemType") ?? ""
                if itemType.lowercased().contains("playlist") || itemType.isEmpty {
                    if let contentList = safeArray(itemDict, "contentList") {
                        for content in contentList {
                            guard let contentDict = content as? [String: Any] else { continue }
                            if let parsed = parseMiguPlaylistItem(contentDict) {
                                items.append(parsed)
                            }
                        }
                    }
                }
            }
        }

        return items
    }

    private func miguPlaylistsByTag(tagId: String, page: Int) async -> [PlaylistItem] {
        guard let url = buildURL(
            base: "https://app.c.nf.migu.cn/pc/v1.0/template/musiclistplaza-listbytag/release",
            queryItems: [
                URLQueryItem(name: "tagId", value: tagId),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "count", value: "20")
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var items: [PlaylistItem] = []
        if let contentItemList = safeArray(data, "contentItemList") {
            for item in contentItemList {
                guard let itemDict = item as? [String: Any] else { continue }
                if let contentList = safeArray(itemDict, "contentList") {
                    for content in contentList {
                        guard let contentDict = content as? [String: Any] else { continue }
                        if let parsed = parseMiguPlaylistItem(contentDict) {
                            items.append(parsed)
                        }
                    }
                }
            }
        } else if let list = safeArray(data, "list") ?? safeArray(data, "playlistList") {
            for content in list {
                guard let contentDict = content as? [String: Any] else { continue }
                if let parsed = parseMiguPlaylistItem(contentDict) {
                    items.append(parsed)
                }
            }
        }

        return items
    }

    private func parseMiguPlaylistItem(_ dict: [String: Any]) -> PlaylistItem? {
        let rawId = firstNonNil(
            safeString(dict, "contentId"),
            safeString(dict, "playlistId"),
            safeString(dict, "id"),
            safeInt(dict, "contentId").map { String($0) },
            safeInt(dict, "playlistId").map { String($0) }
        ) ?? ""
        if rawId.isEmpty { return nil }

        let name = firstNonNil(
            safeString(dict, "contentName"),
            safeString(dict, "playlistName"),
            safeString(dict, "name"),
            safeString(dict, "title")
        ) ?? ""
        let coverURL = firstNonNil(
            safeString(dict, "imageUrl"),
            safeString(dict, "coverUrl"),
            safeString(dict, "picUrl"),
            safeString(dict, "img")
        ) ?? ""
        let playCount = formatPlayCount(
            safeInt(dict, "playCount") ?? safeInt(dict, "listennum") ?? safeInt(dict, "playNum")
        )
        let songCount = safeInt(dict, "songCount") ?? safeInt(dict, "songnum")
        let creator = firstNonNil(
            safeString(dict, "createUserName"),
            safeString(dict, "creator"),
            safeString(dict, "nickname")
        )

        return PlaylistItem(
            id: "mg_\(rawId)",
            name: name,
            coverURL: coverURL,
            playCount: playCount,
            songCount: songCount,
            creator: creator,
            platform: .migu,
            rawId: rawId
        )
    }

    private func miguPlaylistDetail(id: String) async -> PlaylistDetail? {
        async let infoResult = miguPlaylistInfo(id: id)
        async let songsResult = miguPlaylistSongs(id: id)

        let info = await infoResult
        let songs = await songsResult

        return PlaylistDetail(
            id: "mg_\(id)",
            name: info.name,
            coverURL: info.coverURL,
            creator: info.creator,
            description: info.description,
            songCount: info.songCount > 0 ? info.songCount : songs.count,
            songs: songs,
            platform: .migu
        )
    }

    private struct MiguPlaylistInfo {
        let name: String
        let coverURL: String
        let creator: String?
        let description: String?
        let songCount: Int
    }

    private func miguPlaylistInfo(id: String) async -> MiguPlaylistInfo {
        guard let url = buildURL(
            base: "https://c.musicapp.migu.cn/MIGUM3.0/resource/playlist/v2.0",
            queryItems: [URLQueryItem(name: "playlistId", value: id)]
        ) else {
            return MiguPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else {
            return MiguPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }
        guard let data = safeDict(result, "data") else {
            return MiguPlaylistInfo(name: "", coverURL: "", creator: nil, description: nil, songCount: 0)
        }

        var playlist: [String: Any] = data
        if let nested = safeDict(data, "playlist") {
            playlist = nested
        }

        let name = firstNonNil(
            safeString(playlist, "playlistName"),
            safeString(playlist, "contentName"),
            safeString(playlist, "name")
        ) ?? ""
        let coverURL = firstNonNil(
            safeString(playlist, "imageUrl"),
            safeString(playlist, "coverUrl"),
            safeString(playlist, "picUrl"),
            safeString(playlist, "img")
        ) ?? ""
        let creator = firstNonNil(
            safeString(playlist, "createUserName"),
            safeString(playlist, "creator"),
            safeString(playlist, "nickname")
        )
        let description = firstNonNil(
            safeString(playlist, "playlistDescribe"),
            safeString(playlist, "description"),
            safeString(playlist, "intro")
        )
        let songCount = safeInt(playlist, "contentCountTotal")
            ?? safeInt(playlist, "songCount")
            ?? safeInt(playlist, "songnum")
            ?? 0

        return MiguPlaylistInfo(
            name: name,
            coverURL: coverURL,
            creator: creator,
            description: description,
            songCount: songCount
        )
    }

    private func miguPlaylistSongs(id: String) async -> [PlaylistSong] {
        guard let url = buildURL(
            base: "https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0",
            queryItems: [URLQueryItem(name: "playlistId", value: id)]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var songArray: [Any] = []
        if let arr = safeArray(data, "songList") {
            songArray = arr
        } else if let arr = safeArray(data, "list") {
            songArray = arr
        } else if let contentItemList = safeArray(data, "contentItemList") {
            for item in contentItemList {
                if let itemDict = item as? [String: Any],
                   let contentList = safeArray(itemDict, "contentList") {
                    songArray.append(contentsOf: contentList)
                }
            }
        }

        var songs: [PlaylistSong] = []
        for song in songArray {
            guard let dict = song as? [String: Any] else { continue }
            let songId = firstNonNil(
                safeString(dict, "songId"),
                safeString(dict, "contentId"),
                safeString(dict, "id"),
                safeInt(dict, "songId").map { String($0) },
                safeInt(dict, "contentId").map { String($0) }
            ) ?? ""
            if songId.isEmpty { continue }
            let songName = firstNonNil(
                safeString(dict, "songName"),
                safeString(dict, "contentName"),
                safeString(dict, "name")
            ) ?? ""
            let artist = firstNonNil(
                safeString(dict, "singerName"),
                safeString(dict, "singer"),
                safeString(dict, "artist")
            ) ?? ""
            let album = firstNonNil(
                safeString(dict, "albumName"),
                safeString(dict, "album")
            )
            let duration = normalizeDuration(
                safeInt(dict, "duration") ?? safeInt(dict, "length")
            )
            let coverURL = firstNonNil(
                safeString(dict, "coverUrl"),
                safeString(dict, "imageUrl"),
                safeString(dict, "picUrl")
            )
            let rawInfo = toJsonString(dict)

            songs.append(PlaylistSong(
                id: "mg_\(songId)",
                name: songName,
                artist: artist,
                album: album,
                duration: duration,
                coverURL: coverURL,
                platform: "mg",
                rawInfo: rawInfo
            ))
        }

        return songs
    }

    private func miguRankings() async -> [RankingItem] {
        guard let url = URL(string: "https://app.c.nf.migu.cn/pc/bmw/rank/rank-index/v1.0") else { return [] }
        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var items: [RankingItem] = []

        if let contentItemList = safeArray(data, "contentItemList") {
            for item in contentItemList {
                guard let itemDict = item as? [String: Any] else { continue }
                if let contentList = safeArray(itemDict, "contentList") {
                    for content in contentList {
                        guard let contentDict = content as? [String: Any] else { continue }
                        let rawId = firstNonNil(
                            safeString(contentDict, "contentId"),
                            safeString(contentDict, "rankId"),
                            safeString(contentDict, "id"),
                            safeInt(contentDict, "contentId").map { String($0) }
                        ) ?? ""
                        if rawId.isEmpty { continue }
                        let name = firstNonNil(
                            safeString(contentDict, "contentName"),
                            safeString(contentDict, "rankName"),
                            safeString(contentDict, "name")
                        ) ?? ""
                        let coverURL = firstNonNil(
                            safeString(contentDict, "imageUrl"),
                            safeString(contentDict, "coverUrl"),
                            safeString(contentDict, "picUrl")
                        )
                        let updateFreq = firstNonNil(
                            safeString(contentDict, "updateFreq"),
                            safeString(contentDict, "updateFrequency")
                        )

                        items.append(RankingItem(
                            id: "mg_\(rawId)",
                            name: name,
                            coverURL: coverURL,
                            updateFreq: updateFreq,
                            platform: .migu,
                            rawId: rawId
                        ))
                    }
                }
            }
        }

        if items.isEmpty {
            if let rankList = safeArray(data, "rankList") {
                for entry in rankList {
                    guard let dict = entry as? [String: Any] else { continue }
                    let rawId = firstNonNil(
                        safeString(dict, "rankId"),
                        safeString(dict, "contentId"),
                        safeString(dict, "id"),
                        safeInt(dict, "rankId").map { String($0) }
                    ) ?? ""
                    if rawId.isEmpty { continue }
                    let name = firstNonNil(
                        safeString(dict, "rankName"),
                        safeString(dict, "contentName"),
                        safeString(dict, "name")
                    ) ?? ""
                    let coverURL = firstNonNil(
                        safeString(dict, "imageUrl"),
                        safeString(dict, "coverUrl"),
                        safeString(dict, "picUrl")
                    )
                    let updateFreq = firstNonNil(
                        safeString(dict, "updateFreq"),
                        safeString(dict, "updateFrequency")
                    )

                    items.append(RankingItem(
                        id: "mg_\(rawId)",
                        name: name,
                        coverURL: coverURL,
                        updateFreq: updateFreq,
                        platform: .migu,
                        rawId: rawId
                    ))
                }
            }
        }

        return items
    }

    private func miguSearchPlaylists(keyword: String, page: Int) async -> [PlaylistItem] {
        let searchSwitch = #"{"song":0,"album":0,"singer":0,"tagSong":0,"mvSong":0,"bestShow":0,"songlist":1,"lyricSong":0}"#
        guard let url = buildURL(
            base: "https://jadeite.migu.cn/music_search/v3/search/searchAll",
            queryItems: [
                URLQueryItem(name: "isCorrect", value: "0"),
                URLQueryItem(name: "isCopyright", value: "1"),
                URLQueryItem(name: "pageSize", value: "20"),
                URLQueryItem(name: "searchSwitch", value: searchSwitch),
                URLQueryItem(name: "text", value: keyword),
                URLQueryItem(name: "pageNo", value: String(page))
            ]
        ) else { return [] }

        guard let result = await httpGet(url: url, headers: miguHeaders()) as? [String: Any] else { return [] }
        guard let data = safeDict(result, "data") else { return [] }

        var searchList: [Any] = []
        if let playListResult = safeDict(data, "playListResult"),
           let arr = safeArray(playListResult, "playListList") {
            searchList = arr
        } else if let arr = safeArray(data, "playListList") {
            searchList = arr
        } else if let arr = safeArray(data, "list") {
            searchList = arr
        }

        var items: [PlaylistItem] = []
        for playlist in searchList {
            guard let dict = playlist as? [String: Any] else { continue }
            let rawId = firstNonNil(
                safeString(dict, "playlistId"),
                safeString(dict, "contentId"),
                safeString(dict, "id"),
                safeInt(dict, "playlistId").map { String($0) }
            ) ?? ""
            if rawId.isEmpty { continue }
            let name = firstNonNil(
                safeString(dict, "playlistName"),
                safeString(dict, "contentName"),
                safeString(dict, "name")
            ) ?? ""
            let coverURL = firstNonNil(
                safeString(dict, "imageUrl"),
                safeString(dict, "coverUrl"),
                safeString(dict, "picUrl")
            ) ?? ""
            let playCount = formatPlayCount(
                safeInt(dict, "playCount") ?? safeInt(dict, "playNum") ?? safeInt(dict, "listennum")
            )
            let songCount = safeInt(dict, "songCount") ?? safeInt(dict, "songnum")
            let creator = firstNonNil(
                safeString(dict, "createUserName"),
                safeString(dict, "creator")
            )

            items.append(PlaylistItem(
                id: "mg_\(rawId)",
                name: name,
                coverURL: coverURL,
                playCount: playCount,
                songCount: songCount,
                creator: creator,
                platform: .migu,
                rawId: rawId
            ))
        }
        return items
    }
}

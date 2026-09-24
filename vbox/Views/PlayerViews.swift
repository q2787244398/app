import SwiftUI
import AVKit
import AVFoundation

private struct CloudPanLink: Identifiable, Hashable {
    let id: String
    let url: String
    let name: String
    let driveType: CloudDriveManager.DriveType?
    let driveName: String
}

private struct DetailEpisodePopupItem: Identifiable, Hashable {
    let id: String
    let title: String
    let fullTitle: String
}

private enum DriveExpandState {
    case loading
    case loaded([CloudPanLink])
    case failed(String)
    case empty
}

// MARK: - 视频详情视图 (新版：演职人员 + 修复闪跳)
/// 播放器启动数据 - 包装 VodItem 和详情页已解析好的集数列表
/// 避免播放器重复解析 vodPlayUrl 导致选源不一致和 UI 卡死
struct PlayerLaunchData: Identifiable {
    let id = UUID()
    let video: VodItem
    let episodes: [(name: String, url: String)]?
}

struct VideoDetailView: View {
    let video: VodItem
    let searchKeyword: String?
    let isFromSourceDiscovery: Bool

    init(video: VodItem, searchKeyword: String? = nil, isFromSourceDiscovery: Bool = false) {
        self.video = video
        self.searchKeyword = searchKeyword
        self.isFromSourceDiscovery = isFromSourceDiscovery
    }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloudDriveSortManager = CloudDriveSortManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    // 下载管理悬浮弹窗
    @State private var showDownloadPopup: Bool = false

    // 播放器
    @State private var playerLaunchData: PlayerLaunchData?
    @State private var selectedPanVideo: VodItem?

    // 网盘
    @State private var isLoadingPan = false
    @State private var selectedCloudDrive: String? = nil  // 选中的网盘类型
    @State private var driveExpandStates: [String: DriveExpandState] = [:]  // 每个网盘的展开状态
    @State private var rawCloudLinks: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)] = []  // 排序后的原始链接

    // 剧集排序
    @State private var episodesReversed = false

    // 详情数据（加载完成后不再变化，避免闪跳）
    @State private var detailVideo: VodItem?
    @State private var isLoadingDetail = false
    @State private var hasLoadedDetail = false

    // 播放源（使用 @State 缓存，避免计算属性频繁变化）
    @State private var allSources: [(name: String, items: [(name: String, url: String)])] = []
    @State private var selectedSourceIndex = 0

    // 演职人员
    @State private var actors: [DoubanCelebrity] = []
    @State private var directors: [DoubanCelebrity] = []
    @State private var writers: [DoubanCelebrity] = []
    @State private var isLoadingCredits = false

    // TMDB 大封面图 / logo
    @State private var tmdbBackdropURL: String? = nil
    @State private var tmdbPosterURL: String? = nil
    @State private var tmdbLogoURL: String? = nil
    @State private var tmdbMediaType: String = "movie"
    @State private var isLoadingTMDB = false

    // 豆瓣大封面图（TMDB 关闭或 TMDB 失败时使用）
    @State private var doubanBackdropURL: String? = nil

    // 演职人员分类
    @State private var selectedCastTab = "全部"

    // 底栏选集弹窗
    @State private var showEpisodeSheet = false
    @State private var showExpandedEpisodePopup = false

    // 收藏
    @State private var isFavorite = false
    @State private var favoriteId: Int? = nil
    @State private var showDownloadTip = false

    private var isCloudVideo: Bool { video.vodRemarks?.hasPrefix("☁️") == true }
    private var displayVideo: VodItem { detailVideo ?? video }
    private var searchName: String { searchKeyword ?? video.vodName }

    private var fallbackBackground: some View {
        LinearGradient(
            colors: [
                Color(hex: "3D4A5C"),
                Color(hex: "2A323E"),
                Color(hex: "121418")
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // 网盘链接按类型分组（基于展开状态）
    private var cloudDriveGroups: [(drive: String, links: [CloudPanLink])] {
        // rawCloudLinks 已按排序顺序存储，提取去重的网盘名即可
        var seen = Set<String>()
        var orderedDrives: [String] = []
        for link in rawCloudLinks {
            if !seen.contains(link.driveName) {
                seen.insert(link.driveName)
                orderedDrives.append(link.driveName)
            }
        }
        return orderedDrives.map { driveName in
            if case .loaded(let expanded) = driveExpandStates[driveName] {
                return (driveName, expanded)
            }
            // loading/failed/empty/nil 时用原始链接占位（UI层会根据 driveExpandStates 显示对应状态）
            let fallback = rawCloudLinks
                .filter { $0.driveName == driveName }
                .enumerated()
                .map { idx, link in
                    makeCloudPanLink(url: link.url, name: link.name, driveType: link.driveType, driveName: link.driveName, index: idx)
                }
            return (driveName, fallback)
        }
    }

    private func driveNameFromLink(_ name: String) -> String {
        if name.contains("115") { return "115网盘" }
        if name.contains("阿里") { return "阿里云盘" }
        if name.contains("夸克") { return "夸克网盘" }
        if name.contains("百度") { return "百度网盘" }
        if name.contains("UC") { return "UC网盘" }
        if name.contains("天翼") { return "天翼云盘" }
        if name.contains("123") { return "123云盘" }
        return "其他网盘"
    }

    private func cloudDriveSortIndex(for group: (key: String, value: [CloudPanLink])) -> Int {
        if let type = group.value.first?.driveType,
           let index = cloudDriveSortManager.displayOrder.firstIndex(of: type) {
            return index
        }
        return cloudDriveSortManager.orderIndex(forDriveName: group.key)
    }

    private var currentCloudDriveGroup: (drive: String, links: [CloudPanLink])? {
        cloudDriveGroups.first(where: { $0.drive == selectedCloudDrive }) ?? cloudDriveGroups.first
    }

    private var currentCloudEpisodeLinks: [CloudPanLink] {
        guard let links = currentCloudDriveGroup?.links else { return [] }
        return episodesReversed ? Array(links.reversed()) : links
    }

    private var expandedEpisodeTitle: String {
        if isCloudVideo {
            return "\(currentCloudDriveGroup?.drive ?? "网盘资源") 剧集列表"
        }
        if !allSources.isEmpty {
            let idx = selectedSourceIndex < allSources.count ? selectedSourceIndex : 0
            if idx < allSources.count {
                return "\(allSources[idx].name) 剧集列表"
            }
        }
        return "剧集列表"
    }

    private var expandedEpisodeItems: [DetailEpisodePopupItem] {
        if isCloudVideo {
            let driveName = selectedCloudDrive ?? cloudDriveGroups.first?.drive ?? ""
            let links: [CloudPanLink]
            if case .loaded(let loaded) = driveExpandStates[driveName] {
                links = loaded
            } else {
                links = currentCloudDriveGroup?.links ?? []
            }
            let displayLinks = episodesReversed ? links.reversed().map { $0 } : links
            return displayLinks.enumerated().map { idx, link in
                let title = cloudEpisodeTitle(for: link, index: idx)
                return DetailEpisodePopupItem(id: link.id, title: title, fullTitle: link.name)
            }
        }
        return computeEpisodes().enumerated().map { idx, episode in
            DetailEpisodePopupItem(id: "\(idx)|\(episode.name)|\(episode.url)", title: episode.name, fullTitle: episode.name)
        }
    }

    private func handleExpandedEpisodeSelect(index: Int) {
        if isCloudVideo {
            let driveName = selectedCloudDrive ?? cloudDriveGroups.first?.drive ?? ""
            let links: [CloudPanLink]
            if case .loaded(let loaded) = driveExpandStates[driveName] {
                links = episodesReversed ? loaded.reversed().map { $0 } : loaded
            } else {
                links = currentCloudEpisodeLinks
            }
            guard index < links.count else { return }
            showExpandedEpisodePopup = false
            playPanLink(links[index])
        } else {
            let eps = computeEpisodes()
            guard index < eps.count else { return }
            showExpandedEpisodePopup = false
            handleEpisodeSelect(eps[index])
        }
    }

    private func computeEpisodes() -> [(name: String, url: String)] {
        if isCloudVideo {
            if let selectedDrive = selectedCloudDrive,
               case .loaded(let links) = driveExpandStates[selectedDrive] {
                let orderedLinks = episodesReversed ? links.reversed().map { $0 } : links
                return orderedLinks.map { (name: $0.name, url: $0.url) }
            }
            // 降级：用当前组的 links
            let links = currentCloudDriveGroup?.links ?? []
            let orderedLinks = episodesReversed ? links.reversed().map { $0 } : links
            return orderedLinks.map { (name: $0.name, url: $0.url) }
        }
        guard !allSources.isEmpty else { return [] }
        let idx = selectedSourceIndex < allSources.count ? selectedSourceIndex : 0
        guard idx < allSources.count else { return [] }
        let eps = allSources[idx].items
        return episodesReversed ? Array(eps.reversed()) : eps
    }

    // MARK: - 初始化播放源（只执行一次，避免闪跳）
    private func initializeSources() {
        let sources = parseAllSources(from: displayVideo.vodPlayUrl, playFrom: displayVideo.vodPlayFrom)
        allSources = sources
        selectedSourceIndex = 0
    }

    // MARK: - 加载真实详情（仅补充元数据，不覆盖已有剧集）
    private func loadRealDetailIfNeeded() {
        guard !hasLoadedDetail, !isLoadingDetail else { return }
        isLoadingDetail = true
        Task {
            let detail = await SpiderManager.shared.getDetail(ids: video.vodId, name: video.vodName, engineKey: video.engineKey)
            await MainActor.run {
                hasLoadedDetail = true
                if let detail {
                    detailVideo = detail
                    // 仅当搜索结果没有带回剧集（allSources 为空）时，才从详情接口填充
                    // 搜索结果已带剧集时直接用，不再二次刷新，避免切片资源被错误站点的数据覆盖
                    if allSources.isEmpty {
                        let newSources = parseAllSources(from: detail.vodPlayUrl, playFrom: detail.vodPlayFrom)
                        if !newSources.isEmpty {
                            allSources = newSources
                            selectedSourceIndex = 0
                        }
                    }
                }
                isLoadingDetail = false
            }
        }
    }

    // MARK: - 加载豆瓣数据（大封面图 + 演职人员）
    private func loadDoubanData() {
        guard !isLoadingCredits else { return }
        isLoadingCredits = true
        Task {
            let result = await DoubanService.shared.fetchCredits(for: searchName)

            var backdropURL: String? = nil
            if let subjectId = result.subjectId {
                backdropURL = await DoubanService.shared.fetchWallpaperURL(subjectId: subjectId)
            }

            await MainActor.run {
                // 仅当当前没有任何演职人员时才写入（避免 TMDB 已获取到的数据被覆盖）
                if actors.isEmpty && directors.isEmpty && writers.isEmpty {
                    actors = result.actors
                    directors = result.directors
                    writers = result.writers
                }
                // 仅当没有 TMDB 大封面时才写入豆瓣封面
                if tmdbPosterURL == nil && tmdbBackdropURL == nil {
                    doubanBackdropURL = backdropURL
                }
                isLoadingCredits = false
            }
        }
    }

    // MARK: - 加载 TMDB 数据（logo、海报、演员）
    private func loadTMDBData() {
        guard settings.enableTMDB, !isLoadingTMDB else { return }
        TMDBService.shared.updateProxy(baseURL: settings.tmdbProxyURL)
        TMDBService.shared.updateToken(useToken: settings.tmdbUseToken, token: settings.tmdbProxyToken)
        isLoadingTMDB = true
        Task {
            guard let searchResult = await TMDBService.shared.searchMovie(name: searchName, year: video.vodYear) else {
                await MainActor.run { isLoadingTMDB = false }
                loadDoubanData()
                return
            }

            let id = searchResult.id
            let mediaType = searchResult.mediaType
            await MainActor.run { tmdbMediaType = mediaType }

            async let imagesTask = TMDBService.shared.fetchImages(id: id, mediaType: mediaType)
            async let creditsTask = TMDBService.shared.fetchCredits(id: id, mediaType: mediaType)

            let images = await imagesTask
            let credits = await creditsTask

            await MainActor.run {
                // logo 优先 w500 走代理
                if let logoPath = images?.bestLogo?.w500URL {
                    tmdbLogoURL = TMDBService.shared.proxiedImageURL(logoPath, size: "w500")
                }
                // 背景 poster 用 original 走代理
                if let posterPath = images?.bestPoster?.originalURL {
                    tmdbPosterURL = TMDBService.shared.proxiedImageURL(posterPath, size: "original")
                }
                // backdrop 备用
                if let backdropPath = images?.bestBackdrop?.originalURL {
                    tmdbBackdropURL = TMDBService.shared.proxiedImageURL(backdropPath, size: "original")
                }

                // 演职人员：TMDB 有则替换豆瓣
                if let credits, !credits.actors.isEmpty {
                    actors = credits.actors
                    directors = credits.directors
                    writers = credits.writers
                }

                isLoadingTMDB = false

                // 如果 TMDB 没找到大封面图或演职人员，触发豆瓣兜底
                let hasTMDBBackdrop = tmdbPosterURL != nil || tmdbBackdropURL != nil
                let hasTMDBCredits = !actors.isEmpty || !directors.isEmpty || !writers.isEmpty
                if !hasTMDBBackdrop || !hasTMDBCredits {
                    loadDoubanData()
                }
            }
        }
    }

    // MARK: - 网盘
    private func loadPanLinks() {
        guard rawCloudLinks.isEmpty, !isLoadingPan else { return }
        isLoadingPan = true
        Task {
            // 路由分发：
            // 路径A — 云源：vodId 是 HTTP URL → resolveCloudPlay（现有逻辑，不变）
            // 路径B — JS蜘蛛网盘源：vodId 非 URL 但有 engineKey → resolveCloudPlayFromSpider（新增）
            let result: (links: [(url: String, name: String)], siteName: String)?
            if video.vodId.hasPrefix("http") {
                result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId)
            } else if let engineKey = video.engineKey {
                result = await SpiderManager.shared.resolveCloudPlayFromSpider(ids: video.vodId, engineKey: engineKey)
            } else {
                result = nil
            }

            if let result {
                // 1. 预处理：识别每个链接的网盘类型，按排序优先级排列
                let parsed = result.links.enumerated().map { index, link in
                    let dt = CloudDriveManager.detectDrive(from: link.url)
                    let name = dt?.displayName ?? driveNameFromLink(link.name)
                    return (url: link.url, name: link.name, driveType: dt, driveName: name)
                }
                // 2. 夸克网盘拆成三条线路：夸克网盘(原画直链) + 备用夸克(普画转码) + 夸克Node(Node 独立路链)
                var splitLinks: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)] = []
                for link in parsed {
                    splitLinks.append(link)
                    if link.driveType == .quark {
                        splitLinks.append((url: link.url, name: link.name, driveType: link.driveType, driveName: "备用夸克"))
                        // 夸克Node：原夸克链接 + #vbox_nd=1 标记 → 详情/取链/播放全走 Node（A1 接缝）
                        let nodeURL = appendQuarkNodeMark(to: link.url)
                        splitLinks.append((url: nodeURL, name: link.name, driveType: .quarkNode, driveName: "夸克Node"))
                    }
                }
                // 3. 按排序顺序排列 rawCloudLinks
                let sorted = sortRawCloudLinks(splitLinks)

                await MainActor.run {
                    rawCloudLinks = sorted
                    // 设置所有网盘为 loading 状态
                    var seen = Set<String>()
                    for link in sorted {
                        if !seen.contains(link.driveName) {
                            seen.insert(link.driveName)
                            driveExpandStates[link.driveName] = .loading
                        }
                    }
                }

                // 2. 按网盘分组，保持排序顺序
                let grouped = groupRawLinks(sorted)

                // 3. 第一个网盘同步等待
                if let first = grouped.first {
                    let expanded = await expandSingleDrive(driveName: first.drive, links: first.links)
                    await MainActor.run {
                        driveExpandStates[first.drive] = expanded
                        isLoadingPan = false
                        if selectedCloudDrive == nil {
                            selectedCloudDrive = first.drive
                        }
                    }

                    // 4. 后续网盘依次后台预加载
                    for group in grouped.dropFirst() {
                        let expanded = await expandSingleDrive(driveName: group.drive, links: group.links)
                        await MainActor.run {
                            driveExpandStates[group.drive] = expanded
                        }
                    }
                } else {
                    await MainActor.run { isLoadingPan = false }
                }
            } else {
                await MainActor.run { isLoadingPan = false }
            }
        }
    }
    
    /// 按排序优先级对原始链接排序
    private func sortRawCloudLinks(_ links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)]) -> [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)] {
        return links.sorted { lhs, rhs in
            let leftIndex = sortIndex(forDriveType: lhs.driveType, driveName: lhs.driveName)
            let rightIndex = sortIndex(forDriveType: rhs.driveType, driveName: rhs.driveName)
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return lhs.driveName < rhs.driveName
        }
    }
    
    /// 获取网盘排序索引
    private func sortIndex(forDriveType dt: CloudDriveManager.DriveType?, driveName: String) -> Int {
        // "备用夸克" 紧跟在 "夸克网盘" 后面
        if driveName == "备用夸克" {
            let quarkBase = cloudDriveSortManager.displayOrder.firstIndex(of: .quark) ?? 0
            return quarkBase + 1
        }
        // "夸克Node" 紧跟在 "备用夸克" 后面
        if driveName == "夸克Node" {
            let quarkBase = cloudDriveSortManager.displayOrder.firstIndex(of: .quark) ?? 0
            return quarkBase + 2
        }
        if let dt, let idx = cloudDriveSortManager.displayOrder.firstIndex(of: dt) {
            return idx
        }
        return cloudDriveSortManager.orderIndex(forDriveName: driveName)
    }
    
    /// 将原始链接按网盘名分组，保持排序顺序
    private func groupRawLinks(_ links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)]) -> [(drive: String, links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)])] {
        var seen = Set<String>()
        var groups: [(drive: String, links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)])] = []
        for link in links {
            if !seen.contains(link.driveName) {
                seen.insert(link.driveName)
                groups.append((drive: link.driveName, links: []))
            }
            groups[groups.count - 1].links.append(link)
        }
        return groups
    }
    
    /// 展开单个网盘的文件列表
    private func expandSingleDrive(driveName: String, links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)]) async -> DriveExpandState {
        guard let driveType = links.first?.driveType else {
            let fallback = links.enumerated().map { idx, link in
                makeCloudPanLink(url: link.url, name: link.name, driveType: link.driveType, driveName: link.driveName, index: idx)
            }
            return .loaded(fallback)
        }
        
        switch driveType {
        case .one15, .pan123, .pan139, .pan189, .xunlei, .guangya, .woniu4k, .quarkNode:
            // Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛/夸克Node）：
            // 文件列表走 A1 接缝（Node 常驻系统），失败直接报错，无原生兜底。
            // 必须排在原生分支之前，确保命中 Node 链路。
            return await expandNodeDrive(driveName: driveName, links: links, driveType: driveType)

        case .quark:
            guard let token = CloudDriveManager.shared.tokens(for: .quark).first else {
                return .failed("未配置夸克网盘账号")
            }
            // 判断线路偏好："备用夸克"走普画转码，"夸克网盘"走原画直链（默认）
            let routePref: String? = driveName == "备用夸克" ? "transcode" : "original"
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.quarkGetFileList(shareURL: link.url, cookie: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        var params: [String: String] = ["vbox_fid": file.fid]
                        if let route = routePref {
                            params["vbox_route"] = route
                        }
                        return makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: params),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("夸克网盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)
            
        case .baidu:
            guard let pair = CloudDriveManager.shared.baiduTokenPair() else {
                return .failed("未配置百度网盘账号")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.baiduGetFileList(shareURL: link.url, bduss: pair.web.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fsid": file.fsId]),
                            name: file.name,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("百度网盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)
            
        case .uc:
            guard let token = CloudDriveManager.shared.tokens(for: .uc).first else {
                return .failed("未配置UC网盘账号")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.ucGetFileList(shareURL: link.url, cookie: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fid": file.fid, "vbox_token": file.shareFidToken]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("UC网盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .ali:
            // 阿里云盘：递归获取分享链接内所有视频文件，展开为多集
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.aliGetAllPlayableFiles(shareURL: link.url)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fid": file.fileId]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("阿里云盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .xunlei:
            // 迅雷云盘：递归获取分享链接内所有视频文件，展开为多集
            guard let token = CloudDriveManager.shared.tokens(for: .xunlei).first else {
                return .failed("未配置迅雷云盘 Cookie")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.xunleiGetFileList(shareURL: link.url, cookie: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fid": file.fileId]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("迅雷云盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .one15:
            // 115网盘：递归获取分享链接内所有视频文件，展开为多集
            guard let token = CloudDriveManager.shared.tokens(for: .one15).first else {
                return .failed("未配置115网盘 Cookie/CID")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.one15GetAllPlayableFiles(shareURL: link.url, cid: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_pickcode": file.pickCode]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("115网盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .pan123:
            // 123云盘：递归获取分享链接内所有视频文件，展开为多集
            guard let token = CloudDriveManager.shared.tokens(for: .pan123).first else {
                return .failed("未配置123云盘 Cookie")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.pan123GetAllFiles(shareURL: link.url, token: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fileId": file.fileId, "vbox_etag": file.eTag]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("123云盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .pan139:
            // 139云盘：递归获取分享链接内所有视频文件，展开为多集
            guard let token = CloudDriveManager.shared.tokens(for: .pan139).first else {
                return .failed("未配置139云盘 Cookie")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.pan139GetAllFiles(shareURL: link.url, cookie: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_contentId": file.contentId, "vbox_catalogId": file.catalogId]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("139云盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        case .pan189:
            // 天翼云盘：递归获取分享链接内所有视频文件，展开为多集
            guard let token = CloudDriveManager.shared.tokens(for: .pan189).first else {
                return .failed("未配置天翼云盘 Cookie")
            }
            var allExpanded: [CloudPanLink] = []
            for (linkIndex, link) in links.enumerated() {
                do {
                    let files = try await CloudDriveManager.shared.pan189GetAllFiles(shareURL: link.url, cookie: token.value)
                    let items = files.enumerated().map { fileIndex, file in
                        makeCloudPanLink(
                            url: appendVboxFragment(to: link.url, params: ["vbox_fileId": file.fileId]),
                            name: file.fileName,
                            driveType: driveType,
                            driveName: driveName,
                            index: allExpanded.count + fileIndex
                        )
                    }
                    allExpanded.append(contentsOf: items)
                } catch {
                    if allExpanded.isEmpty && linkIndex == links.count - 1 {
                        return .failed("天翼云盘资源加载失败：\(error.localizedDescription)")
                    }
                }
            }
            return allExpanded.isEmpty ? .empty : .loaded(allExpanded)

        default:
            let fallback = links.enumerated().map { idx, link in
                makeCloudPanLink(url: link.url, name: link.name, driveType: link.driveType, driveName: link.driveName, index: idx)
            }
            return .loaded(fallback)
        }
    }

    /// 展开 Node 托管网盘的文件列表（集数）：A1 接缝 /spider/push/4/detail
    /// 失败直接报错，不降级原生路链（百度/夸克/阿里/UC 原生链路不受影响）
    private func expandNodeDrive(driveName: String, links: [(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String)], driveType: CloudDriveManager.DriveType) async -> DriveExpandState {
        var allExpanded: [CloudPanLink] = []
        for link in links {
            do {
                let share = try await CloudDriveManager.shared.resolveNodeShare(link.url, driveType: driveType)
                let items = share.entries.enumerated().map { fileIndex, entry in
                    makeCloudPanLink(
                        url: appendVboxFragment(to: link.url, params: ["vbox_node": entry.playID]),
                        name: entry.name,
                        driveType: driveType,
                        driveName: driveName,
                        index: allExpanded.count + fileIndex
                    )
                }
                allExpanded.append(contentsOf: items)
            } catch {
                // 无兜底：失败直接报错，便于排查
                return .failed("\(driveType.displayName)资源加载失败：\(error.localizedDescription)")
            }
        }
        return allExpanded.isEmpty ? .empty : .loaded(allExpanded)
    }

    private func makeCloudPanLink(url: String, name: String, driveType: CloudDriveManager.DriveType?, driveName: String, index: Int) -> CloudPanLink {
        CloudPanLink(id: "\(driveName)|\(index)|\(name)|\(url)", url: url, name: name, driveType: driveType, driveName: driveName)
    }

    private func appendVboxFragment(to url: String, params: [String: String]) -> String {
        let payload = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return url.contains("#") ? "\(url)&\(payload)" : "\(url)#\(payload)"
    }

    /// 给夸克链接追加 Node 夸克路链标记（#vbox_nd=1），已带则不重复追加。
    /// 与既有 #vbox_node=<playID>（详情页指定剧集）可共存：#vbox_nd=1&vbox_node=xxx
    private func appendQuarkNodeMark(to url: String) -> String {
        if url.contains("#vbox_nd=1") { return url }
        if url.contains("#") { return url.replacingOccurrences(of: "#", with: "#vbox_nd=1&", options: [], range: url.range(of: "#")) }
        return url + "#vbox_nd=1"
    }

    private func playPanLink(_ link: CloudPanLink) {
        selectedPanVideo = VodItem(vodId: link.url, vodName: "\(video.vodName) - \(link.name)",
                                    vodPic: video.vodPic, vodRemarks: "☁️网盘", vodPlayUrl: link.url)
    }

    // MARK: - 播放
    private func handlePlay() {
        if isCloudVideo {
            // 尝试用已展开的第一个网盘的第一集播放
            if let firstDrive = cloudDriveGroups.first,
               case .loaded(let links) = driveExpandStates[firstDrive.drive],
               let firstLink = links.first {
                playPanLink(firstLink)
            } else if !isLoadingPan && rawCloudLinks.isEmpty {
                // 没有数据也没在加载，重新触发加载
                loadPanLinks()
            }
        } else {
            // 传递详情页已解析好的集数列表，避免播放器重复解析导致选源不一致和卡死
            let eps = allSources.isEmpty ? [] : allSources[min(selectedSourceIndex, allSources.count - 1)].items
            playerLaunchData = PlayerLaunchData(video: video, episodes: eps.isEmpty ? nil : eps)
        }
    }

    // MARK: - 分享
    private func handleShare() {
        let text = "\(displayVideo.vodName)\n\(displayVideo.vodContent ?? "")"
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    // MARK: - 收藏
    private func checkFavorite() {
        let sourceName = allSources.first?.name ?? ""
        if let favId = DatabaseManager.shared.isFavorite2(detailurl: video.vodId, laiyuan: sourceName) {
            isFavorite = true
            favoriteId = favId
        } else {
            isFavorite = false
            favoriteId = nil
        }
    }

    private func toggleFavorite() {
        if isFavorite, let favId = favoriteId {
            DatabaseManager.shared.removeFavorite(id: favId)
            isFavorite = false
            favoriteId = nil
        } else {
            let sourceName = allSources.first?.name ?? ""
            let record = FavoriteRecord(
                name: displayVideo.vodName,
                laiyuan: sourceName,
                imgurl: displayVideo.vodPic ?? "",
                detailurl: video.vodId,
                detailua: "",
                xianlu: 0,
                jishu: 0,
                addedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addFavorite(record)
            isFavorite = true
            // 重新查询获取 id
            if let favId = DatabaseManager.shared.isFavorite2(detailurl: video.vodId, laiyuan: sourceName) {
                favoriteId = favId
            }
        }
    }

    // MARK: - 下载
    private func handleDownload() {
        let eps = computeEpisodes()
        guard !eps.isEmpty else {
            showDownloadTip = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
            return
        }
        let episode = eps[0]
        let sourceName = allSources.first?.name ?? ""
        let record = DownloadRecord(
            name: "\(displayVideo.vodName) \(episode.name)",
            laiyuan: sourceName,
            imgurl: displayVideo.vodPic ?? "",
            detailurl: video.vodId,
            playurl: episode.url,
            jishu: 1,
            progress: 0,
            status: "pending",
            addedAt: Int64(Date().timeIntervalSince1970)
        )
        DatabaseManager.shared.addDownload(record)
        showDownloadTip = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
    }

    // MARK: - 批量下载（从剧集弹窗选择后触发）
    private func handleBatchDownload(indices: [Int]) {
        let eps = computeEpisodes()
        guard !eps.isEmpty, !indices.isEmpty else { return }

        // 判断资源类型：网盘资源标记为 cloud，其他标记为 normal
        let sourceType = isCloudVideo ? "cloud" : "normal"
        let sourceName = allSources.first?.name ?? ""
        let engineKey = displayVideo.engineKey

        for index in indices {
            guard index < eps.count else { continue }
            let episode = eps[index]

            let record = DownloadRecord(
                name: "\(displayVideo.vodName) \(episode.name)",
                laiyuan: sourceName,
                imgurl: displayVideo.vodPic ?? "",
                detailurl: video.vodId,
                playurl: episode.url,
                jishu: index + 1,
                progress: 0,
                status: "pending",
                addedAt: Int64(Date().timeIntervalSince1970),
                sourceType: sourceType,
                engineKey: engineKey,
                vodId: video.vodId
            )
            DownloadManager.shared.enqueueDownload(record: record)
        }

        showDownloadTip = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
    }

    // MARK: - 选集
    private func handleEpisodeSelect(_ episode: (name: String, url: String)) {
        // 传递完整 vodPlayUrl 和详情页已解析好的集数列表。
        // 播放器优先使用 preParsedEpisodes 填充 episodeItems，跳过 parseNormalEpisodes，
        // 彻底消除二次解析导致的选源不一致和 UI 卡死问题。
        // vodName 含集名（如"云秀行 第13集"），播放器据此自动定位到选中集。
        let eps = allSources.isEmpty ? [] : allSources[min(selectedSourceIndex, allSources.count - 1)].items
        playerLaunchData = PlayerLaunchData(
            video: VodItem(
                vodId: displayVideo.vodId,
                vodName: "\(displayVideo.vodName) \(episode.name)",
                vodPic: displayVideo.vodPic,
                vodRemarks: episode.name,
                vodYear: displayVideo.vodYear,
                vodArea: displayVideo.vodArea,
                vodDirector: displayVideo.vodDirector,
                vodActor: displayVideo.vodActor,
                vodContent: displayVideo.vodContent,
                vodPlayFrom: displayVideo.vodPlayFrom,
                vodPlayUrl: displayVideo.vodPlayUrl,
                engineKey: displayVideo.engineKey
            ),
            episodes: eps.isEmpty ? nil : eps
        )
    }

    // MARK: - 解析播放源
    private func parseAllSources(from raw: String?, playFrom: String?) -> [(name: String, items: [(name: String, url: String)])] {
        guard let raw, !raw.isEmpty else { return [] }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                  let links = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
                  !links.isEmpty else { return [] }
            var epsList: [(name: String, url: String)] = []
            for (idx, link) in links.enumerated() {
                guard let url = link["url"], !url.isEmpty else { continue }
                let name = link["name"] ?? "网盘资源\(idx + 1)"
                epsList.append((name: name, url: url))
            }
            guard !epsList.isEmpty else { return [] }
            return [("网盘资源", epsList)]
        }

        let urlGroups = raw.components(separatedBy: "$$$")
        let nameGroups = playFrom?.components(separatedBy: "$$$") ?? []

        var sources: [(name: String, items: [(name: String, url: String)])] = []
        for (idx, group) in urlGroups.enumerated() {
            let eps = parseGroupEpisodes(group)
            guard !eps.isEmpty else { continue }
            let sourceName = (idx < nameGroups.count && !nameGroups[idx].isEmpty) ? nameGroups[idx] : "线路\(idx + 1)"
            sources.append((name: sourceName, items: eps))
        }
        sources.sort { a, b in
            let aIsM3u8 = a.name.lowercased().contains("m3u8")
            let bIsM3u8 = b.name.lowercased().contains("m3u8")
            let aIsYun = a.name.lowercased().contains("yun")
            let bIsYun = b.name.lowercased().contains("yun")
            if aIsM3u8 && !bIsM3u8 { return true }
            if !aIsM3u8 && bIsM3u8 { return false }
            if aIsYun && !bIsYun { return false }
            if !aIsYun && bIsYun { return true }
            return false
        }
        return sources
    }

    private func parseGroupEpisodes(_ group: String) -> [(name: String, url: String)] {
        group.components(separatedBy: "#").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pieces = trimmed.components(separatedBy: "$")
            if pieces.count >= 2 {
                return (name: pieces[0].isEmpty ? "播放" : pieces[0], url: pieces[1])
            }
            if trimmed.hasPrefix("http") || trimmed.contains("pan.baidu.com") {
                return (name: "播放", url: trimmed)
            }
            return nil
        }
    }

    private func driveColor(_ name: String) -> Color {
        if name.contains("115") { return .orange }
        if name.contains("阿里") { return .blue }
        if name.contains("夸克") { return .purple }
        if name.contains("百度") { return .green }
        if name.contains("UC") { return .red }
        return .gray
    }

    // MARK: - Body
    var body: some View {
        ZStack(alignment: .bottom) {
            // 背景层：铺满全屏（包括安全区）
            GeometryReader { fullGeometry in
                backgroundLayer(geometry: fullGeometry)
            }
            .ignoresSafeArea()

            // 内容层：只在安全区内
            GeometryReader { safeGeometry in
                contentLayer(geometry: safeGeometry)
            }

            // 下载胶囊通知 — 底部显示，不影响详情页交互
            DownloadCapsuleNotification()
                .allowsHitTesting(false)
                .zIndex(50)

            // 悬浮下载按键（详情页专用）
            if !showDownloadPopup && !downloadManager.isFloatingButtonManuallyHidden {
                FloatingVideoDownloadButton(onTap: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showDownloadPopup = true
                    }
                })
                .zIndex(15)
            }

            // 下载管理悬浮弹窗
            if showDownloadPopup {
                DownloadManagementPopup(isPresented: $showDownloadPopup)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(20)
            }

            if showExpandedEpisodePopup {
                EpisodeExpandPopup(
                    title: expandedEpisodeTitle,
                    items: expandedEpisodeItems,
                    isReversed: $episodesReversed,
                    onSelect: { index in
                        handleExpandedEpisodeSelect(index: index)
                    },
                    onClose: {
                        showExpandedEpisodePopup = false
                    },
                    onDownload: { indices in
                        handleBatchDownload(indices: indices)
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(20)
            }
        }
        // 播放器
        .fullScreenCover(item: $playerLaunchData) { data in
            VideoPlayerViewV2(video: data.video, preParsedEpisodes: data.episodes)
        }
        .fullScreenCover(item: $selectedPanVideo) { panVideo in VideoPlayerViewV2(video: panVideo) }
        // 选集弹窗（半屏）
        .sheet(isPresented: $showEpisodeSheet) {
            EpisodeSheetView(
                sources: allSources,
                selectedSourceIndex: $selectedSourceIndex,
                onSelect: { episode in
                    handleEpisodeSelect(episode)
                    showEpisodeSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            initializeSources()
            if isCloudVideo { loadPanLinks() }
            loadRealDetailIfNeeded()
            if settings.enableTMDB {
                loadTMDBData()
            } else {
                loadDoubanData()
            }
            checkFavorite()
            if isFromSourceDiscovery {
                settings.isTabBarHidden = true
            }
        }
        .onDisappear {
            // 底栏由 HomeView.onChange(of: selectedSource) 统一控制
            // 当用户从 VideoDetailView 返回 SourceDiscoveryView 时，底栏保持隐藏
            // 当用户从 SourceDiscoveryView 返回首页时，onDismiss 中的 withAnimation 统一恢复底栏
        }
        .onReceive(cloudDriveSortManager.$order) { _ in
            guard isCloudVideo, !rawCloudLinks.isEmpty else { return }
            // 重新排序 rawCloudLinks
            let sorted = sortRawCloudLinks(rawCloudLinks)
            rawCloudLinks = sorted
            // 保留已展开的数据，只是重新排列
            selectedCloudDrive = cloudDriveGroups.first?.drive
        }
        .edgeSwipeBack { dismiss() }
        .navigationBarHidden(isFromSourceDiscovery)
        .navigationBarBackButtonHidden(isFromSourceDiscovery)
        .toolbar(isFromSourceDiscovery ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(isFromSourceDiscovery ? .hidden : .visible, for: .navigationBar)
    }

    // MARK: - 背景层
    private func backgroundLayer(geometry: GeometryProxy) -> some View {
        Group {
            if let poster = tmdbPosterURL ?? tmdbBackdropURL ?? doubanBackdropURL,
               let url = DoubanImageProxyServer.shared.resolvedURL(for: poster) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .overlay(bottomDimmingOverlay(height: geometry.size.height * 0.55))
                    default:
                        fallbackBackground
                    }
                }
            } else {
                fallbackBackground
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .ignoresSafeArea()
    }

    private func bottomDimmingOverlay(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.black.opacity(0.10), location: 0.35),
                    .init(color: Color.black.opacity(0.35), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
        }
    }

    // MARK: - 内容滚动层
    private func contentLayer(geometry: GeometryProxy) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // 顶部透明区域，露出背景封面图
                Color.clear
                    .frame(height: geometry.size.height * 0.30)

                // 内容区（完全透明，透出底层封面图）
                VStack(spacing: 20) {
                    // logo / 片名 / 类型（紧挨内容区顶部）
                    VStack(spacing: 12) {
                        HeroTitleView(
                            name: displayVideo.vodName,
                            logoURL: tmdbLogoURL
                        )
                        .frame(maxHeight: 70)

                        Text(displayVideo.vodName)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            Text("剧情")
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .foregroundColor(.white.opacity(0.9))

                            if let year = displayVideo.vodYear, !year.isEmpty {
                                Text(year)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                        }
                    }

                    playButton
                    castSection
                    synopsisSection
                    panSection
                    if !isCloudVideo {
                        episodeSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: - 立即播放按钮
    private var playButton: some View {
        Button(action: handlePlay) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("立即播放")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.black)
            .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
            .padding(.vertical, 14)
            .background(Color(hex: "93C5FD"))
            .cornerRadius(28)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 演职人员分类展示
    private var castSection: some View {
        Group {
            if !actors.isEmpty || !directors.isEmpty || !writers.isEmpty || isLoadingCredits {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(["全部", "演员", "导演", "编剧"], id: \.self) { tab in
                            let available: Bool = {
                                switch tab {
                                case "全部": return !actors.isEmpty || !directors.isEmpty || !writers.isEmpty
                                case "演员": return !actors.isEmpty
                                case "导演": return !directors.isEmpty
                                case "编剧": return !writers.isEmpty
                                default: return false
                                }
                            }()
                            if available {
                                Button(action: { selectedCastTab = tab }) {
                                    Text(tab)
                                        .font(.system(size: 14, weight: selectedCastTab == tab ? .semibold : .medium))
                                        .foregroundColor(selectedCastTab == tab ? .white : .white.opacity(0.6))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(selectedCastTab == tab ? Color.white.opacity(0.2) : Color.clear)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    let currentPeople: [DoubanCelebrity] = {
                        switch selectedCastTab {
                        case "全部": return actors + directors + writers
                        case "导演": return directors
                        case "编剧": return writers
                        default: return actors
                        }
                    }()

                    if !currentPeople.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(currentPeople, id: \.id) { person in
                                    CastPersonCard(person: person)
                                }
                            }
                        }
                    } else {
                        Text("暂无\(selectedCastTab)信息")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    // MARK: - 剧情简介
    private var synopsisSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("剧情简介")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 24))
                        .foregroundColor(isFavorite ? Color(hex: "E11D48") : .white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
            Text(displayVideo.vodContent ?? "暂无简介")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 网盘资源
    @ViewBuilder
    private var panSection: some View {
        if isCloudVideo && (!rawCloudLinks.isEmpty || isLoadingPan) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "cloud.fill").font(.system(size: 14)).foregroundColor(.blue)
                    if isLoadingPan && rawCloudLinks.isEmpty {
                        Text("正在加载网盘资源...").font(.system(size: 14)).foregroundColor(.gray)
                        Spacer(); ProgressView().scaleEffect(0.8)
                    } else if rawCloudLinks.isEmpty {
                        Text("未找到网盘链接").font(.system(size: 14)).foregroundColor(.gray)
                    } else {
                        Text("网盘源 (\(cloudDriveGroups.count) 个)").font(.system(size: 14, weight: .semibold)).foregroundColor(.blue)
                    }
                    Spacer()
                }
                if !rawCloudLinks.isEmpty, !cloudDriveGroups.isEmpty {
                    // 网盘 tab 栏
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(cloudDriveGroups, id: \.drive) { group in
                                let state = driveExpandStates[group.drive]
                                let countText: String = {
                                    if case .loaded(let links) = state { return "\(links.count)" }
                                    if case .loading = state { return "..." }
                                    return "-"
                                }()
                                Button(action: {
                                    selectedCloudDrive = group.drive
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: driveIcon(group.drive))
                                            .font(.system(size: 13))
                                        Text(group.drive)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(countText)
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                    .foregroundColor(selectedCloudDrive == group.drive ? .white : .white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedCloudDrive == group.drive ? Color(hex: "E11D48") : Color.white.opacity(0.12))
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    // 当前选中网盘的剧集列表
                    if let selectedDrive = selectedCloudDrive,
                       cloudDriveGroups.contains(where: { $0.drive == selectedDrive }) {
                        driveEpisodeSection(for: selectedDrive)
                    } else if let firstDrive = cloudDriveGroups.first?.drive {
                        driveEpisodeSection(for: firstDrive)
                    }
                }
            }.padding(.vertical, 8)
        }
    }
    
    /// 单个网盘的剧集列表区域（支持 loading/loaded/failed/empty 状态）
    @ViewBuilder
    private func driveEpisodeSection(for driveName: String) -> some View {
        let state = driveExpandStates[driveName]
        
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("正在加载 \(driveName) 剧集列表...")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.vertical, 16)
            
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(2)
            }
            .padding(.vertical, 12)
            
        case .empty:
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                Text("\(driveName) 暂无视频文件")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.vertical, 12)
            
        case .loaded(let links):
            if !links.isEmpty {
                let orderedLinks = episodesReversed ? links.reversed().map { $0 } : links
                HStack {
                    Text("\(driveName) 剧集列表")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { episodesReversed.toggle() }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14))
                            .foregroundColor(episodesReversed ? Color(hex: "E11D48") : .white.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                    Text("共 \(links.count) 集")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    Button(action: {
                        showExpandedEpisodePopup = true
                    }) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 56), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(Array(orderedLinks.enumerated()), id: \.element.id) { idx, link in
                            Button(action: { playPanLink(link) }) {
                                Text(cloudEpisodeTitle(for: link, index: idx))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .frame(minWidth: 48)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.12))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
                .padding(.top, 4)
            }
            
        case nil:
            EmptyView()
        }
    }

    private func driveIcon(_ drive: String) -> String {
        if drive.contains("115") { return "link.icloud" }
        if drive.contains("阿里") { return "icloud" }
        if drive.contains("夸克") { return "link.circle" }
        if drive.contains("百度") { return "link" }
        return "link.circle.fill"
    }

    private func cloudEpisodeTitle(for link: CloudPanLink, index: Int) -> String {
        let drive = link.driveName
        let cleanedName = link.name
            .replacingOccurrences(of: drive, with: "")
            .replacingOccurrences(of: "网盘", with: "")
            .replacingOccurrences(of: "云盘", with: "")
            .replacingOccurrences(of: "·", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedName.isEmpty ? "第\(index + 1)集" : cleanedName
    }

    // MARK: - 剧集列表（独立滚动 + 排序）
    private var episodeSection: some View {
        let eps = computeEpisodes()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if isCloudVideo, let drive = selectedCloudDrive {
                    Text("\(drive) 资源")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Text("剧集列表")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer()

                // 排序按钮（纯图标无背景）
                if !eps.isEmpty {
                    Button(action: { episodesReversed.toggle() }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14))
                            .foregroundColor(episodesReversed ? Color(hex: "E11D48") : .white.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                if isLoadingDetail {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text(eps.isEmpty ? "暂无集数" : "共 \(eps.count) 集")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    if !eps.isEmpty {
                        Button(action: {
                            showExpandedEpisodePopup = true
                        }) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            if !isCloudVideo && allSources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(allSources.enumerated()), id: \.offset) { idx, source in
                            Button(action: { selectedSourceIndex = idx }) {
                                Text(source.name)
                                    .font(.system(size: 12, weight: idx == selectedSourceIndex ? .semibold : .medium))
                                    .foregroundColor(idx == selectedSourceIndex ? .white : .white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(idx == selectedSourceIndex ? Color(hex: "E11D48") : Color.white.opacity(0.12))
                                    )
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }

            // 独立滚动区域：剧集网格
            if !eps.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 56), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(Array(eps.enumerated()), id: \.offset) { idx, episode in
                            Button(action: { handleEpisodeSelect(episode) }) {
                                Text(episode.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(minWidth: 48)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.white.opacity(0.12))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 300)
            }
        }.padding(.top, 8)
    }

    // MARK: - 底部胶囊悬浮操作栏（与首页 GlassBottomTabBar 保持一致）
    private var bottomBarLayer: some View {
        HStack(spacing: 2) {
            BottomBarButton(icon: "play.fill", title: "播放", iconColor: bottomBarActiveColor, titleColor: bottomBarInactiveColor) { handlePlay() }
            BottomBarButton(icon: "list.bullet", title: "选集", iconColor: bottomBarActiveColor, titleColor: bottomBarInactiveColor) { showEpisodeSheet = true }
            BottomBarButton(icon: "square.and.arrow.down", title: "下载", iconColor: bottomBarActiveColor, titleColor: bottomBarInactiveColor) { handleDownload() }
            BottomBarButton(icon: "square.and.arrow.up", title: "分享", iconColor: bottomBarActiveColor, titleColor: bottomBarInactiveColor) { handleShare() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .background(Capsule().fill(bottomBarBaseColor))
                .overlay(
                    Capsule()
                        .stroke(bottomBarStrokeColor, lineWidth: 1)
                )
        )
        .clipShape(Capsule())
        .padding(.horizontal, 36)
        .padding(.bottom, 8)
    }

    private var bottomBarBaseColor: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.34) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemBackground).opacity(0.62) }
        return Color(uiColor: .systemBackground).opacity(0.86)
    }

    private var bottomBarStrokeColor: Color {
        settings.usesVisualSkin ? Color.white.opacity(0.28) : Color.gray.opacity(0.2)
    }

    private var bottomBarActiveColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color.blue
    }

    private var bottomBarInactiveColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.72) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondaryLabel) }
        return Color.gray
    }

    // MARK: - 下载提示
    @ViewBuilder
    private var downloadTipLayer: some View {
        if showDownloadTip {
            VStack {
                Spacer()
                Text(computeEpisodes().isEmpty ? "暂无播放源，无法下载" : "已添加到下载列表")
                    .font(.system(size: 14))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .foregroundColor(.white)
                    .padding(.bottom, 100)
            }
            .transition(.opacity)
            .animation(.easeInOut, value: showDownloadTip)
        }
    }
}

// MARK: - 大标题视图（TMDB logo 优先，马善政毛笔楷体兜底）
struct HeroTitleView: View {
    let name: String
    let logoURL: String?

    var body: some View {
        if let logoURL = logoURL,
           let url = URL(string: logoURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 70)
                default:
                    fallbackTitle
                }
            }
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(name)
            .font(.custom("Ma Shan Zheng", size: 48))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
    }
}

// MARK: - 剧集展开弹窗
private struct EpisodeExpandPopup: View {
    let title: String
    let items: [DetailEpisodePopupItem]
    @Binding var isReversed: Bool
    let onSelect: (Int) -> Void
    let onClose: () -> Void
    let onDownload: ([Int]) -> Void

    @State private var isDownloadMode = false
    @State private var selectedIndices: Set<Int> = []

    private var useTwoColumns: Bool {
        guard !items.isEmpty else { return false }
        let longCount = items.filter { $0.title.count > 8 || $0.fullTitle.count > 12 }.count
        return Double(longCount) / Double(items.count) > 0.3
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: useTwoColumns ? 2 : 4)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(isDownloadMode
                                 ? "已选 \(selectedIndices.count) 集"
                                 : "共 \(items.count) 集")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: { isReversed.toggle() }) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 14))
                                .foregroundColor(isReversed ? Color(hex: "E11D48") : .secondary)
                        }
                        .buttonStyle(.plain)

                        // 下载按钮：三态（未激活 → 选择中 → 待确认打勾）
                        Button(action: {
                            if isDownloadMode && !selectedIndices.isEmpty {
                                // 打勾状态 → 提交下载
                                let sorted = selectedIndices.sorted()
                                onDownload(sorted)
                                onClose()
                            } else {
                                isDownloadMode.toggle()
                                if !isDownloadMode { selectedIndices.removeAll() }
                            }
                        }) {
                            Image(systemName: isDownloadMode
                                  ? "checkmark.circle.fill"
                                  : "arrow.down.circle")
                                .font(.system(size: 15))
                                .foregroundColor(isDownloadMode
                                                 ? (selectedIndices.isEmpty ? .secondary : .blue)
                                                 : .secondary)
                        }
                        .buttonStyle(.plain)

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                Button(action: {
                                    if isDownloadMode {
                                        if selectedIndices.contains(index) {
                                            selectedIndices.remove(index)
                                        } else {
                                            selectedIndices.insert(index)
                                        }
                                    } else {
                                        onSelect(index)
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        Text(item.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(useTwoColumns ? 2 : 1)
                                        if isDownloadMode {
                                            Image(systemName: selectedIndices.contains(index)
                                                  ? "checkmark.circle.fill"
                                                  : "circle")
                                                .font(.system(size: 12))
                                        }
                                    }
                                    .foregroundColor(isDownloadMode && selectedIndices.contains(index)
                                                     ? .blue : .primary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: useTwoColumns ? 46 : 36)
                                    .padding(.horizontal, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isDownloadMode && selectedIndices.contains(index)
                                                  ? Color.blue.opacity(0.15)
                                                  : Color(uiColor: .secondarySystemBackground))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .frame(width: min(geometry.size.width - 32, 380))
                .frame(height: min(max(geometry.size.height * 0.58, 360), geometry.size.height * 0.72))
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 10)
                )
            }
        }
    }
}

// MARK: - 演职人员卡片
struct CastPersonCard: View {
    let person: DoubanCelebrity

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: person.avatarURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(person.name)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 60)

            if let role = person.character ?? person.roles?.first {
                Text(role)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
    }
}

// MARK: - 底部栏按钮（胶囊底栏样式）
struct BottomBarButton: View {
    let icon: String
    let title: String
    let iconColor: Color
    let titleColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(titleColor)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 选集弹窗
struct EpisodeSheetView: View {
    let sources: [(name: String, items: [(name: String, url: String)])]
    @Binding var selectedSourceIndex: Int
    let onSelect: ((name: String, url: String)) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 线路切换
                if sources.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(sources.enumerated()), id: \.offset) { idx, source in
                                Button(action: { selectedSourceIndex = idx }) {
                                    Text(source.name)
                                        .font(.system(size: 13, weight: idx == selectedSourceIndex ? .semibold : .medium))
                                        .foregroundColor(idx == selectedSourceIndex ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(idx == selectedSourceIndex ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemGroupedBackground))
                                        )
                                }.buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    Divider().padding(.horizontal, 16)
                }

                // 集数列表
                ScrollView {
                    let currentEpisodes = selectedSourceIndex < sources.count ? sources[selectedSourceIndex].items : []
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Array(currentEpisodes.enumerated()), id: \.offset) { _, episode in
                            Button(action: { onSelect(episode) }) {
                                Text(episode.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 演职人员区块
struct CreditsSection: View {
    let actors: [DoubanCelebrity]
    let directors: [DoubanCelebrity]
    let writers: [DoubanCelebrity]
    let isLoading: Bool
    @State private var selectedTab = 0
    private let tabs = ["全部", "主演", "导演", "编剧"]

    private var displayList: [DoubanCelebrity] {
        switch selectedTab {
        case 1: return actors
        case 2: return directors
        case 3: return writers
        default: return actors + directors + writers
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演职人员").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)

            // Tab 切换
            HStack(spacing: 16) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                    Button(action: { selectedTab = idx }) {
                        Text(tab)
                            .font(.system(size: 14, weight: selectedTab == idx ? .semibold : .medium))
                            .foregroundColor(selectedTab == idx ? Color(hex: "E11D48") : .gray)
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }

            if isLoading && displayList.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if displayList.isEmpty {
                Text("暂无演职人员信息")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(displayList) { person in
                            VStack(spacing: 6) {
                                // 演员封面图 - 小长方形圆角样式
                                if let url = DoubanImageProxyServer.shared.resolvedURL(for: person.avatarURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        case .failure, .empty:
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.gray.opacity(0.25))
                                                .overlay(
                                                    Image(systemName: "person.fill")
                                                        .font(.system(size: 24))
                                                        .foregroundColor(.gray.opacity(0.6))
                                                )
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                    .frame(width: 76, height: 100)
                                    .cornerRadius(6)
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.gray.opacity(0.25))
                                        .frame(width: 76, height: 100)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 24))
                                                .foregroundColor(.gray.opacity(0.6))
                                        )
                                }

                                Text(person.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: 76)

                                if !person.roleText.isEmpty {
                                    Text(person.roleText)
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                        .frame(width: 76)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - 辅助组件
struct TagLabel: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7))
                .clipShape(Capsule())
        }
    }
}

struct ActionButton: View {
    let icon: String; let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .top, endPoint: .bottom))
                Text(title).font(.system(size: 12)).foregroundColor(.primary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(PlainButtonStyle())
    }
}

struct EpisodeGridView: View {
    @State private var selectedEpisode = 1
    let episodes: [(name: String, url: String)]
    let onSelect: ((name: String, url: String)) -> Void
    var body: some View {
        if episodes.isEmpty {
            Text("当前资源暂未解析到真实剧集列表")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(episodes.enumerated()), id: \.offset) { idx, episode in
                    let ep = idx + 1
                    Button(action: {
                        selectedEpisode = ep
                        onSelect(episode)
                    }) {
                        Text(episode.name).font(.system(size: 13, weight: ep == selectedEpisode ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(ep == selectedEpisode ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(ep == selectedEpisode ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8))
                            )
                    }.buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
}

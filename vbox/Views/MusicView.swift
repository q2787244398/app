import SwiftUI
import AVFoundation

// MARK: - 网络音乐浏览页

struct MusicView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = AppSettings()
    @StateObject private var viewModel = MusicViewModel()
    @State private var selectedSource: SourceDisplayItem?
    @State private var selectedCategory: VodCategory?
    @State private var searchText: String = ""
    @State private var showSearch: Bool = false

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 源切换器
                musicSourceBar

                Divider()

                if showSearch {
                    MusicSearchView(
                        searchText: $searchText,
                        onSearch: { Task { await viewModel.search(keyword: searchText) } },
                        onClear: { showSearch = false; searchText = ""; viewModel.clearSearch() },
                        results: viewModel.searchResults,
                        isLoading: viewModel.isSearching,
                        onPlay: { item in playItem(item) },
                        accentColor: accentColor
                    )
                } else if selectedSource == nil && viewModel.musicSources.isEmpty {
                    emptyState
                } else {
                    // 分类标签 + 歌曲列表
                    if !viewModel.categories.isEmpty {
                        categoryBar
                    }
                    songList
                }
            }
            .navigationTitle("网络音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showSearch.toggle()
                        if !showSearch { searchText = ""; viewModel.clearSearch() }
                    }) {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .navigationViewStyle(.stack)
        // 在网络音乐页底部同样悬浮音乐条，便于跨页连续控制
        .overlay(alignment: .bottom) {
            MiniPlayerBar()
        }
        .task {
            await viewModel.loadSources()
            if let first = viewModel.musicSources.first {
                selectedSource = first
                await viewModel.loadHome(source: first)
            }
        }
        .onChange(of: selectedSource) { newSource in
            guard let source = newSource else { return }
            selectedCategory = nil
            Task { await viewModel.loadHome(source: source) }
        }
        .onChange(of: selectedCategory) { newCat in
            guard let source = selectedSource else { return }
            let tid = newCat?.typeId ?? ""
            Task { await viewModel.loadCategory(source: source, tid: tid, page: 1) }
        }
    }

    // MARK: - 源切换器

    private var musicSourceBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.musicSources, id: \.id) { source in
                    let isSelected = selectedSource?.id == source.id
                    Button(action: { selectedSource = source }) {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                                .font(.system(size: 12))
                            Text(source.name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? accentColor.opacity(0.15) : Color(.systemGray6))
                        .foregroundColor(isSelected ? accentColor : .primary)
                        .cornerRadius(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 分类标签栏

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.categories, id: \.typeId) { cat in
                    let isSelected = (selectedCategory?.typeId == cat.typeId) ||
                        (selectedCategory == nil && cat.typeId == viewModel.categories.first?.typeId)
                    Button(action: { selectedCategory = cat }) {
                        Text(cat.typeName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? accentColor.opacity(0.12) : Color.clear)
                            .foregroundColor(isSelected ? accentColor : .secondary)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 歌曲列表

    private var songList: some View {
        Group {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(accentColor)
                    Text("加载中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.songs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("暂无音乐内容")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(viewModel.songs, id: \.vodId) { song in
                            MusicRowView(song: song, accentColor: accentColor) {
                                playItem(song)
                            }
                        }
                        if viewModel.hasMore && !viewModel.songs.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .tint(accentColor)
                                Text("加载更多...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .onAppear {
                                Task { await viewModel.loadMore() }
                            }
                        }
                    } header: {
                        if !viewModel.songs.isEmpty {
                            HStack {
                                Text("共 \(viewModel.songs.count) 首")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: { playAll() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 11))
                                        Text("播放全部")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundColor(accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.4))
            Text("未发现音乐源")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            Text("请先在订阅源中添加音乐类站点")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 播放

    private func playItem(_ item: VodItem) {
        guard let source = selectedSource ?? viewModel.musicSources.first(where: { $0.engineKey == item.engineKey }) else { return }
        Task { await viewModel.playSong(song: item, source: source) }
    }

    /// 播放全部（加入队列）
    private func playAll() {
        guard let source = selectedSource else { return }
        Task {
            var items: [MusicQueueItem] = []
            for song in viewModel.songs {
                let (playUrl, _) = await SpiderManager.shared.fetchMusicPlayUrl(
                    source: source, vodId: song.vodId
                )
                if let url = playUrl, !url.isEmpty {
                    items.append(MusicQueueItem(
                        from: song,
                        sourceName: source.name,
                        engineKey: source.engineKey ?? "",
                        playURL: url
                    ))
                }
            }
            if !items.isEmpty {
                AudioPlayerManager.shared.playQueue(items)
            }
        }
    }
}

// MARK: - 歌曲行

struct MusicRowView: View {
    let song: VodItem
    let accentColor: Color
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                // 封面图
                if let url = URL(string: song.vodPic) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ZStack {
                            Rectangle().fill(Color(.systemGray5))
                            Image(systemName: "music.note")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 50, height: 50)
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(song.vodName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let remarks = song.vodRemarks, !remarks.isEmpty {
                        Text(remarks)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // P2-B2：时长展示（仅 song.metaDuration 存在时显示，无该元数据不显示，不影响 vodRemarks 歌手/来源）
                if let d = song.metaDuration, d > 0 {
                    Text(Self.formatDuration(d))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 8)
                }

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    /// 秒 → mm:ss（超过 1 小时 → h:mm:ss）
    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 音乐搜索页

struct MusicSearchView: View {
    @Binding var searchText: String
    let onSearch: () -> Void
    let onClear: () -> Void
    let results: [VodItem]
    let isLoading: Bool
    let onPlay: (VodItem) -> Void
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                TextField("搜索歌曲、歌手...", text: $searchText)
                    .font(.system(size: 14))
                    .submitLabel(.search)
                    .onSubmit { onSearch() }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // 搜索结果
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(accentColor)
                    Text("跨源搜索中...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.mic")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(searchText.isEmpty ? "输入关键词搜索音乐" : "未找到相关音乐")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(results, id: \.vodId) { song in
                        MusicRowView(song: song, accentColor: accentColor) {
                            onPlay(song)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MusicViewModel: ObservableObject {
    @Published var musicSources: [SourceDisplayItem] = []
    @Published var categories: [VodCategory] = []
    @Published var songs: [VodItem] = []
    @Published var searchResults: [VodItem] = []
    @Published var isLoading: Bool = false
    @Published var isSearching: Bool = false
    @Published var hasMore: Bool = false

    private var currentPage: Int = 1
    private var currentSource: SourceDisplayItem?
    private var currentTid: String = ""
    private var isSearchMode: Bool = false

    // MARK: - 加载源列表

    func loadSources() async {
        musicSources = SpiderManager.shared.getMusicSources()
    }

    // MARK: - 加载首页

    func loadHome(source: SourceDisplayItem) async {
        currentSource = source
        currentPage = 1
        isSearchMode = false
        isLoading = true
        songs = []

        let home = await SpiderManager.shared.fetchHomeData(for: source)
        isLoading = false

        if let home = home {
            categories = home.categories
            songs = home.recommended
            hasMore = !home.recommended.isEmpty
        } else {
            categories = []
            songs = []
            hasMore = false
        }
    }

    // MARK: - 加载分类内容

    func loadCategory(source: SourceDisplayItem, tid: String, page: Int) async {
        currentSource = source
        currentTid = tid
        currentPage = page
        isSearchMode = false

        if page == 1 {
            isLoading = true
            songs = []
        }

        let items = await SpiderManager.shared.fetchSingleSourceCategoryContent(
            source: source,
            categoryTypeId: tid,
            page: page
        )

        if page == 1 {
            songs = items
            isLoading = false
        } else {
            songs.append(contentsOf: items)
        }
        hasMore = items.count >= 20
    }

    // MARK: - 加载更多

    func loadMore() async {
        guard hasMore, !isLoading, let source = currentSource else { return }
        currentPage += 1

        if isSearchMode {
            // 暂不支持分页搜索
            hasMore = false
        } else if currentTid.isEmpty {
            // 首页推荐不分页
            hasMore = false
        } else {
            await loadCategory(source: source, tid: currentTid, page: currentPage)
        }
    }

    // MARK: - 搜索

    func search(keyword: String) async {
        guard !keyword.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isSearching = true
        searchResults = []
        isSearchMode = true

        await SpiderManager.shared.searchAllMusicSources(keyword: keyword) { [weak self] batch in
            Task { @MainActor in
                self?.searchResults.append(contentsOf: batch)
            }
        }

        isSearching = false
    }

    func clearSearch() {
        searchResults = []
        isSearchMode = false
    }

    // MARK: - 播放

    func playSong(song: VodItem, source: SourceDisplayItem) async {
        let (playUrl, playFrom) = await SpiderManager.shared.fetchMusicPlayUrl(
            source: source,
            vodId: song.vodId
        )

        // 能直接取到播放地址。榜单/歌单源（如酷听/网易云等）的 spider 会把歌单内
        // 所有歌曲以 "歌曲1$url1#歌曲2$url2…" 拼进一个 vod_play_url，这里解析后
        // 若不止一首则整批入队，使正在播放页的播放列表显示该歌单的全部歌曲。
        if let url = playUrl, !url.isEmpty {
            let playItems = parsePlayUrl(url, playFrom: playFrom)
            if playItems.count > 1 {
                // 多首 → 按歌单一次性入队，播放第一条
                let queue = playItems.map { item in
                    MusicQueueItem(
                        name: item.name,
                        artist: song.vodName,   // 歌单名作为归类显示
                        coverURL: song.vodPic,
                        playURL: item.url,
                        sourceName: source.name,
                        engineKey: source.engineKey ?? ""
                    )
                }
                print("[MusicView] '\(song.vodName)' 展开为歌单, 共 \(queue.count) 首")
                AudioPlayerManager.shared.playQueue(queue)
            } else if let firstItem = playItems.first {
                // 单首 → 普通歌曲
                let queueItem = MusicQueueItem(
                    from: song,
                    sourceName: source.name,
                    engineKey: source.engineKey ?? "",
                    playURL: firstItem.url
                )
                AudioPlayerManager.shared.play(item: queueItem)
            }
            return
        }

        // 取不到直接播放地址 → 该节点很可能是"歌单/榜单"等聚合条目。
        // 用其 vodId 作为分类 id，拉取其下的歌曲列表后整批入队播放，
        // 这样正在播放页的播放队列会显示该歌单/榜单下的所有歌曲。
        print("[MusicView] 无直接播放地址, 将 '\(song.vodName)' 作为歌单/榜单展开: tid=\(song.vodId)")
        let subSongs = await SpiderManager.shared.fetchSingleSourceCategoryContent(
            source: source,
            categoryTypeId: song.vodId,
            page: 1
        )
        guard !subSongs.isEmpty else {
            print("[MusicView] 展开失败(未返回子歌曲): \(song.vodName)")
            return
        }

        var queue: [MusicQueueItem] = []
        for sub in subSongs {
            let (subUrl, subFrom) = await SpiderManager.shared.fetchMusicPlayUrl(
                source: source, vodId: sub.vodId
            )
            if let u = subUrl, !u.isEmpty, let first = parsePlayUrl(u, playFrom: subFrom).first {
                queue.append(MusicQueueItem(
                    from: sub,
                    sourceName: source.name,
                    engineKey: source.engineKey ?? "",
                    playURL: first.url
                ))
            }
        }
        if !queue.isEmpty {
            AudioPlayerManager.shared.playQueue(queue)
        }
    }

    // MARK: - 解析播放地址

    private struct PlayItem {
        let name: String
        let url: String
    }

    private func parsePlayUrl(_ playUrl: String, playFrom: String?) -> [PlayItem] {
        var items: [PlayItem] = []

        // 格式: 线路1$url1#线路2$url2 或单个 url
        let segments = playUrl.components(separatedBy: "#")
        let fromNames = playFrom?.components(separatedBy: "$$$") ?? []

        for (index, segment) in segments.enumerated() {
            let parts = segment.components(separatedBy: "$")
            if parts.count >= 2 {
                items.append(PlayItem(name: parts[0], url: parts[1]))
            } else if !segment.isEmpty {
                let name = index < fromNames.count ? fromNames[index] : "默认线路"
                items.append(PlayItem(name: name, url: segment))
            }
        }

        return items
    }
}

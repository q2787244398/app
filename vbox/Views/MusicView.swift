import SwiftUI
import AVFoundation

// MARK: - 网络音乐浏览页

struct MusicView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
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

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(accentColor.opacity(0.8))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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

        guard let url = playUrl, !url.isEmpty else {
            print("[MusicView] 无法获取播放地址: \(song.vodName)")
            return
        }

        // 播放地址可能包含多线路，格式: 线路1$url1#线路2$url2
        let playItems = parsePlayUrl(url, playFrom: playFrom)
        if let firstItem = playItems.first {
            let queueItem = MusicQueueItem(
                from: song,
                sourceName: source.name,
                engineKey: source.engineKey ?? "",
                playURL: firstItem.url
            )
            AudioPlayerManager.shared.play(item: queueItem)
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

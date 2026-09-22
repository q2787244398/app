import SwiftUI
import AVFoundation

// MARK: - 内容类型 / 搜索类型 枚举

/// 内容区 Tab：歌单广场 / 排行榜
enum MusicTab: String, CaseIterable, Hashable {
    case playlist   // 歌单广场
    case ranking    // 排行榜

    var title: String {
        switch self {
        case .playlist: return "歌单广场"
        case .ranking:  return "排行榜"
        }
    }
}

/// 搜索区 Tab：搜歌曲 / 搜歌单
enum SearchTab: String, CaseIterable, Hashable {
    case songs      // 搜歌曲
    case playlists  // 搜歌单

    var title: String {
        switch self {
        case .songs:     return "搜歌曲"
        case .playlists: return "搜歌单"
        }
    }
}

// MARK: - 网络音乐浏览页（歌单广场 + 排行榜）

struct MusicView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = AppSettings()
    @StateObject private var viewModel = MusicViewModel()

    @FocusState private var searchFieldFocused: Bool

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 播放源切换器（决定播放后端：哪个 lx 插件 / csp 引擎解析播放地址）
                sourceSwitcher
                Divider().opacity(0.6)

                if viewModel.searchMode {
                    searchOverlay
                } else {
                    // 平台选择（决定歌单 / 榜单的内容来源平台）
                    platformSelector
                    Divider().opacity(0.4)
                    // 内容类型切换：歌单广场 / 排行榜
                    contentTypeTabs
                    // 歌单广场模式：分类标签栏
                    if viewModel.selectedTab == .playlist {
                        tagFilterBar
                    }
                    contentArea
                }
            }
            .background(Color(.systemGroupedBackground).opacity(0.35))
            .navigationTitle("网络音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左：关闭
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(accentColor)
                    }
                }
                // 右：搜索（切换搜索模式）
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        UIApplication.shared.endEditing()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.searchMode.toggle()
                        }
                        if !viewModel.searchMode { viewModel.exitSearch() }
                    }) {
                        Image(systemName: viewModel.searchMode ? "xmark" : "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(accentColor)
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .navigationViewStyle(.stack)
        // 底部悬浮播放条，便于跨页连续控制
        .overlay(alignment: .bottom) {
            MiniPlayerBar()
        }
        .task {
            await viewModel.loadSources()
            await viewModel.loadCategories()
            await viewModel.loadPlaylists(page: 1)
            // 排行榜数据懒加载：首次切到“排行榜”Tab 时再拉取，避免 isLoading 在
            // 歌单广场模式下造成“加载歌单中…”的误显（selectTab 内部已处理空态拉取）
        }
        .onChange(of: viewModel.searchMode) { isOn in
            searchFieldFocused = isOn
        }
    }

    // MARK: - 播放源切换器

    private var sourceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.musicSources, id: \.id) { source in
                    let isSelected = viewModel.selectedSource?.id == source.id
                    Button(action: { viewModel.selectedSource = source }) {
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
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? accentColor.opacity(0.4) : .clear, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
                if viewModel.musicSources.isEmpty {
                    Text("未发现音乐源，将使用默认解析")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 平台选择（网易云 / QQ音乐 / 酷狗 / 酷我 / 咪咕）

    private var platformSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(MusicPlatformType.allCases, id: \.self) { p in
                    let isSelected = viewModel.selectedPlatform == p
                    Button {
                        Task { await viewModel.selectPlatform(p) }
                    } label: {
                        VStack(spacing: 5) {
                            Text(p.displayName)
                                .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                                .foregroundColor(isSelected ? p.accentColor : .secondary)
                            Capsule()
                                .fill(isSelected ? p.accentColor : Color.clear)
                                .frame(width: 22, height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    // MARK: - 内容类型 Tab（分段）

    private var contentTypeTabs: some View {
        HStack(spacing: 8) {
            ForEach(MusicTab.allCases, id: \.self) { tab in
                let isSelected = viewModel.selectedTab == tab
                Button {
                    Task { await viewModel.selectTab(tab) }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(isSelected ? accentColor.opacity(0.15) : Color(.systemGray6))
                        .foregroundColor(isSelected ? accentColor : .primary)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 分类标签栏（仅歌单广场模式）

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // “全部”按钮（selectedCategory == nil）
                let allSelected = viewModel.selectedCategory == nil
                Button {
                    Task { await viewModel.selectCategory(nil) }
                } label: {
                    Text("全部")
                        .font(.system(size: 12, weight: allSelected ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(allSelected ? accentColor.opacity(0.16) : Color(.systemGray6))
                        .foregroundColor(allSelected ? accentColor : .primary)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                // 分类标签（过滤掉 API 自带的“全部”，避免重复）
                ForEach(viewModel.categories.filter { $0.name != "全部" }, id: \.id) { cat in
                    let isSelected = viewModel.selectedCategory == cat.id
                    Button {
                        Task { await viewModel.selectCategory(cat.id) }
                    } label: {
                        Text(cat.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? accentColor.opacity(0.16) : Color(.systemGray6))
                            .foregroundColor(isSelected ? accentColor : .primary)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.selectedTab == .playlist {
            playlistGrid
        } else {
            rankingList
        }
    }

    // MARK: - 歌单广场：2 列网格

    private var playlistGrid: some View {
        Group {
            if viewModel.isLoading && viewModel.playlists.isEmpty {
                loadingView(text: "加载歌单中...")
            } else if viewModel.playlists.isEmpty {
                emptyView(systemImage: "square.stack", text: "暂无歌单")
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ], spacing: 14) {
                        ForEach(viewModel.playlists, id: \.id) { pl in
                            NavigationLink(destination:
                                PlaylistDetailView(
                                    platform: pl.platform,
                                    playlistId: pl.rawId,
                                    isRanking: false,
                                    viewModel: viewModel,
                                    accentColor: accentColor
                                )
                            ) {
                                PlaylistCard(playlist: pl, accentColor: accentColor)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                // 滚动接近底部时分页加载
                                if let idx = viewModel.playlists.firstIndex(where: { $0.id == pl.id }),
                                   idx >= viewModel.playlists.count - 4 {
                                    Task { await viewModel.loadMorePlaylists() }
                                }
                            }
                        }
                        // 分页加载指示
                        if viewModel.isLoading && !viewModel.playlists.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView().tint(accentColor)
                                Text("加载更多...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .gridCellColumns(2)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
                .refreshable {
                    await viewModel.loadPlaylists(page: 1)
                }
            }
        }
    }

    // MARK: - 排行榜：纵向列表

    private var rankingList: some View {
        Group {
            if viewModel.isLoading && viewModel.rankings.isEmpty {
                loadingView(text: "加载榜单中...")
            } else if viewModel.rankings.isEmpty {
                emptyView(systemImage: "chart.bar", text: "暂无排行榜")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.rankings, id: \.id) { rk in
                            NavigationLink(destination:
                                PlaylistDetailView(
                                    platform: rk.platform,
                                    playlistId: rk.rawId,
                                    isRanking: true,
                                    viewModel: viewModel,
                                    accentColor: accentColor
                                )
                            ) {
                                RankingRow(ranking: rk, accentColor: accentColor)
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 84)
                        }
                    }
                    .padding(.bottom, 96)
                }
                .refreshable {
                    await viewModel.loadRankings()
                }
            }
        }
    }

    // MARK: - 搜索浮层

    private var searchOverlay: some View {
        VStack(spacing: 0) {
            // 搜索栏 + 取消
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    TextField(
                        viewModel.searchTab == .songs ? "搜索歌曲、歌手..." : "搜索歌单...",
                        text: $viewModel.searchText
                    )
                    .font(.system(size: 14))
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .focused($searchFieldFocused)
                    if !viewModel.searchText.isEmpty {
                        Button(action: { viewModel.searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.systemGray6))
                .cornerRadius(10)

                Button("取消") {
                    UIApplication.shared.endEditing()
                    withAnimation(.easeInOut(duration: 0.2)) { viewModel.searchMode = false }
                    viewModel.exitSearch()
                }
                .font(.system(size: 14))
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // 搜索类型 Tab：搜歌曲 / 搜歌单
            HStack(spacing: 0) {
                ForEach(SearchTab.allCases, id: \.self) { tab in
                    let isSelected = viewModel.searchTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { viewModel.searchTab = tab }
                    } label: {
                        VStack(spacing: 4) {
                            Text(tab.title)
                                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? accentColor : .secondary)
                            Capsule()
                                .fill(isSelected ? accentColor : Color.clear)
                                .frame(width: 20, height: 3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            searchContent
        }
        // 400ms 防抖：关键词或搜索类型变化即重启任务
        .task(id: "\(viewModel.searchText)_\(viewModel.searchTab.rawValue)") {
            let kw = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kw.isEmpty else {
                viewModel.clearSearchResults()
                return
            }
            // 防抖：等待 400ms，期间若输入再次变化则当前任务被取消
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines) == kw else { return }
            if viewModel.searchTab == .songs {
                await viewModel.searchSongs(keyword: kw)
            } else {
                await viewModel.searchPlaylists(keyword: kw)
            }
        }
    }

    // MARK: - 搜索内容（热搜 / 歌曲结果 / 歌单结果）

    @ViewBuilder
    private var searchContent: some View {
        let kw = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty {
            hotKeywordsView
        } else if viewModel.searchTab == .songs {
            songSearchResults
        } else {
            playlistSearchResults
        }
    }

    private var hotKeywordsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("热门搜索")
                        .font(.system(size: 15, weight: .bold))
                    Text("点选即搜")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)], spacing: 10) {
                    ForEach(MusicViewModel.hotKeywords, id: \.self) { kw in
                        Button(action: { viewModel.searchText = kw }) {
                            Text(kw)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color(.systemGray6))
                                .foregroundColor(.primary)
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }

    private var songSearchResults: some View {
        Group {
            if viewModel.isSearching && viewModel.searchResults.isEmpty {
                loadingView(text: "跨源搜索中...")
            } else if viewModel.searchResults.isEmpty {
                emptyView(systemImage: "music.mic", text: "未找到相关歌曲")
            } else {
                List {
                    ForEach(viewModel.searchResults, id: \.vodId) { song in
                        MusicRowView(song: song, accentColor: accentColor) {
                            playSearchSong(song)
                        }
                    }
                    if viewModel.isSearching {
                        HStack {
                            Spacer()
                            ProgressView().tint(accentColor)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var playlistSearchResults: some View {
        Group {
            if viewModel.isSearching && viewModel.playlistSearchResults.isEmpty {
                loadingView(text: "搜索歌单中...")
            } else if viewModel.playlistSearchResults.isEmpty {
                emptyView(systemImage: "square.stack", text: "未找到相关歌单")
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ], spacing: 14) {
                        ForEach(viewModel.playlistSearchResults, id: \.id) { pl in
                            NavigationLink(destination:
                                PlaylistDetailView(
                                    platform: pl.platform,
                                    playlistId: pl.rawId,
                                    isRanking: false,
                                    viewModel: viewModel,
                                    accentColor: accentColor
                                )
                            ) {
                                PlaylistCard(playlist: pl, accentColor: accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 96)
                }
            }
        }
    }

    // MARK: - 通用加载 / 空态

    private func loadingView(text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(accentColor)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyView(systemImage: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.5))
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜索歌曲播放

    /// 跨源搜索结果（VodItem）的播放：用选中源（或歌曲归属源）解析播放地址后播放
    private func playSearchSong(_ item: VodItem) {
        guard let source = viewModel.selectedSource
            ?? viewModel.musicSources.first(where: { $0.engineKey == item.engineKey }) else { return }
        Task {
            let (playUrl, _) = await SpiderManager.shared.fetchMusicPlayUrl(source: source, song: item)
            guard let url = playUrl, !url.isEmpty else { return }
            let queueItem = MusicQueueItem(
                from: item,
                sourceName: source.name,
                engineKey: source.engineKey ?? "",
                playURL: url
            )
            AudioPlayerManager.shared.play(item: queueItem)
        }
    }
}

// MARK: - 歌单卡片

struct PlaylistCard: View {
    let playlist: PlaylistItem
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverImage

            Text(playlist.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                if let play = playlist.playCount, !play.isEmpty {
                    Image(systemName: "play.circle")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(play)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if let sc = playlist.songCount, sc > 0 {
                    Text("·\(sc)首")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var coverImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray5))
            if let url = URL(string: playlist.coverURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().tint(.secondary)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholderIcon
                    @unknown default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(height: 142)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .clipped()
    }

    private var placeholderIcon: some View {
        Image(systemName: "music.note")
            .font(.system(size: 24))
            .foregroundColor(.secondary)
    }
}

// MARK: - 排行榜行

struct RankingRow: View {
    let ranking: RankingItem
    let accentColor: Color

    var body: some View {
        HStack(spacing: 12) {
            coverImage

            VStack(alignment: .leading, spacing: 4) {
                Text(ranking.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let freq = ranking.updateFreq, !freq.isEmpty {
                    Text(freq)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text(ranking.platform.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var coverImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
            if let cover = ranking.coverURL, !cover.isEmpty, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Image(systemName: "chart.bar")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholderIcon
                    @unknown default:
                        placeholderIcon
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .clipped()
    }

    private var placeholderIcon: some View {
        Image(systemName: "chart.bar")
            .font(.system(size: 20))
            .foregroundColor(.secondary)
    }
}

// MARK: - 歌单 / 排行榜详情页

struct PlaylistDetailView: View {
    let platform: MusicPlatformType
    let playlistId: String
    let isRanking: Bool
    @ObservedObject var viewModel: MusicViewModel
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var detail: PlaylistDetail?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ZStack {
            if isLoading && detail == nil {
                loadingState("加载中...")
            } else if let detail = detail {
                contentView(detail)
            } else if let err = loadError {
                errorState(err)
            } else {
                Color.clear
            }
        }
        .navigationTitle(isRanking ? "排行榜" : "歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if detail != nil {
                    Button(action: { playAll() }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                            .foregroundColor(accentColor)
                    }
                }
            }
        }
        .task {
            if detail == nil { await loadDetail() }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func contentView(_ detail: PlaylistDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerView(detail)
                playAllBar(detail)
                if detail.songs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("暂无歌曲")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(detail.songs, id: \.id) { song in
                            PlaylistSongRowView(song: song, platform: platform, accentColor: accentColor) {
                                Task { await viewModel.playPlaylistSong(song) }
                            }
                            Divider().padding(.leading, 68)
                        }
                    }
                }
            }
            .padding(.bottom, 96)
        }
    }

    private func headerView(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                if let url = URL(string: detail.coverURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().tint(accentColor)
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if let creator = detail.creator, !creator.isEmpty {
                    Text(creator)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text("\(detail.songCount) 首")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let desc = detail.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func playAllBar(_ detail: PlaylistDetail) -> some View {
        Button(action: { playAll() }) {
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                Text("播放全部")
                    .font(.system(size: 14, weight: .medium))
                if !detail.songs.isEmpty {
                    Text("(\(detail.songs.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .foregroundColor(accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态视图

    private func loadingState(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(accentColor)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Button("重试") { Task { await loadDetail() } }
                .font(.system(size: 14))
                .foregroundColor(accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: 30))
            .foregroundColor(.secondary)
    }

    // MARK: - 加载 / 播放

    private func loadDetail() async {
        isLoading = true
        loadError = nil
        let result: PlaylistDetail?
        if isRanking {
            result = await MusicPlaylistService.shared.getRankingDetail(platform: platform, id: playlistId)
        } else {
            result = await MusicPlaylistService.shared.getPlaylistDetail(platform: platform, id: playlistId)
        }
        isLoading = false
        if let r = result {
            detail = r
        } else {
            loadError = "加载失败，请重试"
        }
    }

    private func playAll() {
        guard let detail = detail else { return }
        Task { await viewModel.playPlaylistDetail(detail) }
    }
}

// MARK: - 歌单歌曲行

struct PlaylistSongRowView: View {
    let song: PlaylistSong
    let platform: MusicPlatformType
    let accentColor: Color
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                coverImage

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if !song.artist.isEmpty {
                            Text(song.artist)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let album = song.album, !album.isEmpty {
                            Text(" - \(album)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                // 平台来源 tag
                Text(platform.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(platform.accentColor.opacity(0.85))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                if let d = song.duration, d > 0 {
                    Text(Self.formatDuration(d))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(accentColor.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private var coverImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))
            if let cover = song.coverURL, !cover.isEmpty, let url = URL(string: cover) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .clipped()
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: 16))
            .foregroundColor(.secondary)
    }

    /// 秒 → mm:ss（超过 1 小时 → h:mm:ss）
    static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - 歌曲行（跨源搜索结果，VodItem）

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

                // lx 聚合源：歌曲来源平台 tag（从 vodRemarks 首段平台 key 映射中文名）
                if let tag = platformTag {
                    Text(tag)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tagBG)
                        .foregroundColor(tagFG)
                        .cornerRadius(5)
                        .padding(.trailing, 6)
                }

                // 时长展示（仅 song.metaDuration 存在时显示）
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

    /// 歌曲来源平台 tag：lx 聚合源的 vodRemarks 形如 "平台key\t歌手名"，取出首段映射中文名；
    /// 非 lx / 非已知平台返回 nil（不显示 tag，不影响其它源）。
    private var platformTag: String? {
        guard let rem = song.vodRemarks,
              let first = rem.split(separator: "\t", maxSplits: 1).first,
              !first.isEmpty else { return nil }
        return LXBridgeEngine.platformDisplayNames[String(first)]
    }

    private var tagFG: Color { Color.white }
    private var tagBG: Color {
        guard let tag = platformTag else { return Color.blue }
        switch tag {
        case "网易云": return Color(red: 0.84, green: 0.20, blue: 0.29)   // 网易红
        case "腾讯QQ": return Color(red: 0.20, green: 0.60, blue: 1.00)  // 腾讯蓝
        case "酷狗": return Color(red: 0.16, green: 0.72, blue: 0.49)    // 酷狗绿
        case "酷我": return Color(red: 0.96, green: 0.55, blue: 0.24)     // 酷我橙
        default: return Color(hex: "7C3AED")
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MusicViewModel: ObservableObject {
    // 源 / 平台 / 内容类型
    @Published var musicSources: [SourceDisplayItem] = []
    @Published var selectedSource: SourceDisplayItem?
    @Published var selectedPlatform: MusicPlatformType = .netease
    @Published var selectedTab: MusicTab = .playlist

    // 歌单广场
    @Published var categories: [PlaylistCategory] = []
    @Published var selectedCategory: String? = nil      // nil = 全部
    @Published var playlists: [PlaylistItem] = []
    @Published var rankings: [RankingItem] = []
    @Published var isLoading: Bool = false

    // 搜索
    @Published var searchMode: Bool = false
    @Published var searchText: String = ""
    @Published var searchTab: SearchTab = .songs
    @Published var searchResults: [VodItem] = []
    @Published var playlistSearchResults: [PlaylistItem] = []
    @Published var isSearching: Bool = false

    // 分页
    @Published var currentPlaylistPage: Int = 1
    @Published var hasMorePlaylists: Bool = true

    /// 内置热搜关键词（搜索栏空态兜底，点选即搜）
    static let hotKeywords: [String] = [
        "晴天", "稻香", "孤勇者", "罗刹海市",
        "晚风心里吹", "我记得", "起风了", "体面",
        "七里香", "告白气球", "浮夸", "海阔天空"
    ]

    // MARK: - 加载源列表（决定播放后端）

    func loadSources() async {
        musicSources = SpiderManager.shared.getMusicSources()
        if selectedSource == nil { selectedSource = musicSources.first }
    }

    // MARK: - 平台 / 内容类型 / 分类 切换

    /// 切换平台 → 重载分类 + 歌单 / 榜单
    func selectPlatform(_ p: MusicPlatformType) async {
        guard selectedPlatform != p else { return }
        selectedPlatform = p
        selectedCategory = nil
        await loadCategories()
        if selectedTab == .playlist {
            await loadPlaylists(page: 1)
        } else {
            await loadRankings()
        }
    }

    /// 切换内容类型 → 重载对应数据（空时才拉取，避免重复请求）
    func selectTab(_ tab: MusicTab) async {
        selectedTab = tab
        if tab == .playlist {
            if playlists.isEmpty { await loadPlaylists(page: 1) }
        } else {
            if rankings.isEmpty { await loadRankings() }
        }
    }

    /// 切换分类 → 重载歌单第 1 页
    func selectCategory(_ id: String?) async {
        selectedCategory = id
        await loadPlaylists(page: 1)
    }

    // MARK: - 加载分类

    func loadCategories() async {
        categories = await MusicPlaylistService.shared.getPlaylistCategories(platform: selectedPlatform)
    }

    // MARK: - 加载歌单（支持分页）

    func loadPlaylists(page: Int) async {
        let isFirst = page <= 1
        if isFirst {
            isLoading = true
            playlists = []
            currentPlaylistPage = 1
            hasMorePlaylists = true
        } else {
            guard hasMorePlaylists, !isLoading else { return }
            isLoading = true
        }

        let items = await MusicPlaylistService.shared.getPlaylists(
            platform: selectedPlatform,
            category: selectedCategory,
            page: max(page, 1)
        )

        if isFirst {
            playlists = items
        } else {
            playlists.append(contentsOf: items)
        }
        currentPlaylistPage = max(page, 1)
        hasMorePlaylists = !items.isEmpty && items.count >= 15
        isLoading = false
    }

    /// 滚动到底部分页加载
    func loadMorePlaylists() async {
        guard hasMorePlaylists, !isLoading else { return }
        await loadPlaylists(page: currentPlaylistPage + 1)
    }

    // MARK: - 加载排行榜

    func loadRankings() async {
        isLoading = true
        rankings = await MusicPlaylistService.shared.getRankings(platform: selectedPlatform)
        isLoading = false
    }

    // MARK: - 搜索：搜歌曲（跨源，VodItem）

    func searchSongs(keyword: String) async {
        isSearching = true
        searchResults = []
        await SpiderManager.shared.searchAllMusicSources(keyword: keyword) { [weak self] batch in
            Task { @MainActor in
                self?.searchResults.append(contentsOf: batch)
            }
        }
        isSearching = false
    }

    // MARK: - 搜索：搜歌单（当前选中平台）

    func searchPlaylists(keyword: String) async {
        isSearching = true
        playlistSearchResults = []
        let items = await MusicPlaylistService.shared.searchPlaylists(
            platform: selectedPlatform,
            keyword: keyword,
            page: 1
        )
        playlistSearchResults = items
        isSearching = false
    }

    /// 清空搜索结果（关键词为空时调用）
    func clearSearchResults() {
        searchResults = []
        playlistSearchResults = []
        isSearching = false
    }

    /// 退出搜索模式：清空输入与结果
    func exitSearch() {
        searchText = ""
        clearSearchResults()
    }

    // MARK: - 播放：歌单内单曲

    /// 将 PlaylistSong 转为 VodItem，用选中源解析播放地址后播放
    func playPlaylistSong(_ song: PlaylistSong) async {
        guard let source = selectedSource else { return }

        var vodItem = VodItem(
            vodId: song.id,
            vodName: song.name,
            vodPic: song.coverURL ?? "",
            engineKey: source.engineKey,
            musicPlatform: song.platform,
            lxMusicInfo: song.rawInfo
        )

        let (playUrl, _) = await SpiderManager.shared.fetchMusicPlayUrl(source: source, song: vodItem)
        guard let url = playUrl, !url.isEmpty else {
            print("[MusicView] 解析播放地址失败: \(song.name)")
            return
        }

        let queueItem = MusicQueueItem(
            from: vodItem,
            sourceName: source.name,
            engineKey: source.engineKey ?? "",
            playURL: url
        )
        AudioPlayerManager.shared.play(item: queueItem)
    }

    // MARK: - 播放：歌单全部歌曲

    /// 解析歌单内全部歌曲并整批入队播放；首首解析成功即开播，余下继续解析并追加队列
    func playPlaylistDetail(_ detail: PlaylistDetail) async {
        guard let source = selectedSource, !detail.songs.isEmpty else { return }

        var started = false
        for song in detail.songs {
            let vodItem = VodItem(
                vodId: song.id,
                vodName: song.name,
                vodPic: song.coverURL ?? "",
                engineKey: source.engineKey,
                musicPlatform: song.platform,
                lxMusicInfo: song.rawInfo
            )

            let (playUrl, _) = await SpiderManager.shared.fetchMusicPlayUrl(source: source, song: vodItem)
            guard let url = playUrl, !url.isEmpty else { continue }

            let item = MusicQueueItem(
                from: vodItem,
                sourceName: source.name,
                engineKey: source.engineKey ?? "",
                playURL: url
            )

            if !started {
                // 首首解析成功 → 立即开播（play 会将其加入队列并设为当前）
                started = true
                AudioPlayerManager.shared.play(item: item)
            } else {
                // 后续解析成功的歌曲追加进播放队列
                AudioPlayerManager.shared.queue.append(item)
            }
        }

        // 兜底：若全部解析失败则无操作；否则已开播或已入队
        if !started {
            print("[MusicView] 歌单全部歌曲解析失败: \(detail.name)")
        }
    }
}

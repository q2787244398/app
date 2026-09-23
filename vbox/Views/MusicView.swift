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
                } else if !viewModel.isSelectedSourceAggregator {
                    // 非聚合（普通音乐源）：无平台标签，展示该源自身首页/分类/歌曲
                    sourceHomeContent
                } else {
                    // 平台选择（决定歌单 / 榜单的内容来源平台，仅聚合源展示）
                    platformSelector
                    Divider().opacity(0.4)
                    // 内容类型切换：歌单广场 / 排行榜
                    contentTypeTabs
                    // 歌单广场模式：分类标签栏（仅当该源/平台真的有分类标签时显示；
                    // 无标签直接展示接口数据，避免空标签栏造成“不变化”的错觉）
                    if viewModel.selectedTab == .playlist && !viewModel.categories.isEmpty {
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
                // 右：活动日志
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        viewModel.showActivityLog.toggle()
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(accentColor)
                            if viewModel.activityLog.contains(where: { $0.level == .error }) {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 4, y: -4)
                            }
                        }
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
            if viewModel.isSelectedSourceAggregator {
                await viewModel.loadCategories()
                await viewModel.loadPlaylists(page: 1)
            } else {
                await viewModel.loadSourceHome()
            }
            // 排行榜数据懒加载：首次切到“排行榜”Tab 时再拉取，避免 isLoading 在
            // 歌单广场模式下造成“加载歌单中…”的误显（selectTab 内部已处理空态拉取）
        }
        .onChange(of: viewModel.searchMode) { isOn in
            searchFieldFocused = isOn
        }
        .sheet(isPresented: $viewModel.showActivityLog) {
            ActivityLogPanel(viewModel: viewModel, accentColor: accentColor)
        }
    }

    // MARK: - 播放源切换器

    private var sourceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.musicSources, id: \.id) { source in
                    let isSelected = viewModel.selectedSource?.id == source.id
                    Button(action: { Task { await viewModel.selectSource(source) } }) {
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

    // MARK: - 非聚合音乐源首页内容（源自身分类 + 歌曲）

    /// 普通音乐源（非刀/念心聚合源）：无平台标签，直接展示该源自身接口数据。
    /// 含源分类栏 + 推荐歌曲列表，点歌即用所选源并发解析播放。
    private var sourceHomeContent: some View {
        VStack(spacing: 0) {
            if viewModel.sourceHomeLoading && viewModel.sourceHome == nil {
                loadingView(text: "加载源首页...")
            } else if let home = viewModel.sourceHome {
                // 分类栏（若该源返回分类标签；无则整栏隐藏，不造成“不变化”错觉）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(home.categories, id: \.id) { cat in
                            let isSelected = viewModel.selectedCategory == cat.id
                            Button {
                                Task { await viewModel.selectSourceCategory(cat, for: home) }
                            } label: {
                                Text(cat.typeName)
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
                Divider().opacity(0.4)

                if home.recommended.isEmpty {
                    emptyView(systemImage: "music.mic", text: "该源暂无推荐歌曲，可点右上角搜索")
                } else {
                    List {
                        ForEach(home.recommended) { song in
                            MusicRowView(song: song, accentColor: accentColor) {
                                playSearchSong(song)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                emptyView(systemImage: "music.mic", text: "该源暂无首页数据，可点右上角搜索")
            }
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
                VStack(spacing: 0) {
                    if viewModel.isResolvingSingleSong {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在解析播放地址…").font(.system(size: 12))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    } else if let notice = viewModel.singleSongNotice {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                            Text(notice).font(.system(size: 12)).lineLimit(2)
                            Spacer()
                            Button {
                                viewModel.singleSongNotice = nil
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(.red)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
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

    /// 跨源搜索结果（VodItem）的播放：并发竞速所有音乐源，首个命中即播（对标歌一刀）。
    private func playSearchSong(_ item: VodItem) {
        guard !viewModel.musicSources.isEmpty else {
            viewModel.log(.error, "无可播放源", "《\(item.vodName)》未找到匹配的音乐源")
            viewModel.singleSongNotice = "未找到匹配的音乐源，请先在顶部选择源"
            return
        }
        Task { @MainActor in
            viewModel.log(.start, "并发解析搜索歌曲", "《\(item.vodName)》，候选源 \(viewModel.musicSources.count) 个，归属平台 \(item.musicPlatform ?? "-")")
            viewModel.isResolvingSingleSong = true
            viewModel.singleSongNotice = nil
            defer { viewModel.isResolvingSingleSong = false }

            // 快照源列表到局部值，避免在任务组子任务里触碰 @MainActor 的 viewModel（并发安全）
            let sources = viewModel.musicSources
            let result: (index: Int, item: MusicQueueItem)? = await withTaskGroup(
                of: (Int, MusicQueueItem?)?.self
            ) { group in
                for (i, source) in sources.enumerated() {
                    group.addTask {
                        var vod = item
                        vod.engineKey = source.engineKey
                        let r = await SpiderManager.shared.fetchMusicPlayUrl(source: source, song: vod)
                        guard let url = r.playUrl, !url.isEmpty else { return nil }
                        let qi = MusicQueueItem(
                            from: vod,
                            sourceName: source.name,
                            engineKey: source.engineKey ?? "",
                            playURL: url
                        )
                        return (i, qi)
                    }
                }
                var winner: (Int, MusicQueueItem)? = nil
                for await res in group {
                    if let res = res, let item = res.item {
                        winner = (res.index, item)
                        group.cancelAll()
                        break
                    }
                }
                return winner
            }
            if let winner = result {
                let source = sources[winner.index]
                viewModel.log(.success, "解析成功并播放", "《\(item.vodName)》[\(source.name)] \(winner.item.playURL.prefix(60))…")
                AudioPlayerManager.shared.play(item: winner.item)
                return
            }
            viewModel.log(.error, "搜索歌曲解析失败", "《\(item.vodName)》所有源均未返回播放地址（平台 \(item.musicPlatform ?? "-")）")
            viewModel.singleSongNotice = "解析《\(item.vodName)》失败：所有源未返回地址"
        }
    }
}

// MARK: - 活动日志面板

/// 网络音乐整体步骤/响应日志：展示每一次操作的开始、成功、失败、详情。
struct ActivityLogPanel: View {
    @ObservedObject var viewModel: MusicViewModel
    let accentColor: Color

    /// 导出日志文件（写入临时目录后弹系统分享）
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    @State private var exportNotice: String?

    private func exportLogFile() {
        let lines = viewModel.activityLog.map { entry in
            "[\(entry.time)] [\(entry.level.icon)] \(entry.title)\(entry.detail.isEmpty ? "" : " — \(entry.detail)")"
        }
        let content = "网络音乐操作日志\n导出于：\(Self.exportFormatter.string(from: Date()))\n共 \(lines.count) 条\n\n" + lines.joined(separator: "\n")
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("music_operations_log.txt")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            exportedFileURL = url
            showShareSheet = true
            exportNotice = "日志已导出（\(lines.count) 条）"
        } catch {
            exportNotice = "导出失败：\(error.localizedDescription)"
        }
    }

    private static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 6) {
                        if viewModel.activityLog.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .font(.system(size: 32))
                                    .foregroundColor(.secondary)
                                Text("暂无日志")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 80)
                        } else {
                            ForEach(viewModel.activityLog) { entry in
                                LogRow(entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .onChange(of: viewModel.activityLog.count) { _ in
                    withAnimation { proxy.scrollTo(viewModel.activityLog.last?.id, anchor: .bottom) }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("操作日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { viewModel.showActivityLog = false }
                        .foregroundColor(accentColor)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            exportLogFile()
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14))
                        }
                        .foregroundColor(accentColor)
                        .disabled(viewModel.activityLog.isEmpty)

                        Button("清空") { viewModel.activityLog = [] }
                            .foregroundColor(.secondary)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = exportNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray5).opacity(0.95))
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                        .padding(.bottom, 16)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                withAnimation { exportNotice = nil }
                            }
                        }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = exportedFileURL {
                    ShareSheet(items: [url])
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 系统分享（导出日志）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LogRow: View {
    let entry: MusicViewModel.LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.level.icon)
                .font(.system(size: 14))
                .foregroundColor(entry.level.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.system(size: 11))
                        .foregroundColor(entry.level.color.opacity(0.85))
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
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
                // #2：整单“播放全部”并发解析进度反馈
                if viewModel.isResolvingPlaylist {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if viewModel.playlistResolveProgress > 0 {
                            Text("正在解析歌曲地址 \(viewModel.playlistResolveProgress)/\(max(detail.songCount, 1))…")
                                .font(.system(size: 11))
                        } else {
                            Text("正在解析首播地址…")
                                .font(.system(size: 11))
                        }
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                }
                // #4：固定源播放跨平台歌单提示，引导切到聚合源
                if !viewModel.isSelectedSourceAggregator {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text("当前播放源为固定源，跨平台歌单可能无法解析，建议切换刀源/念心")
                            .font(.system(size: 11))
                            .lineLimit(2)
                        Spacer()
                    }
                    .foregroundColor(.orange)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    .padding(.horizontal, 16)
                }
                // 单曲点击播放反馈：解析中 loading / 失败提示（在详情页内直接可见）
                if viewModel.isResolvingSingleSong {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在解析播放地址…").font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                } else if let notice = viewModel.singleSongNotice {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                        Text(notice)
                            .font(.system(size: 11))
                            .lineLimit(2)
                        Spacer()
                    }
                    .foregroundColor(.red)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
                    .padding(.horizontal, 16)
                    .onTapGesture { viewModel.singleSongNotice = nil }
                }
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

    // 非聚合（普通音乐源）首页：无平台标签时展示源自身首页/分类数据
    @Published var sourceHome: SourceHomeData? = nil
    @Published var sourceHomeLoading: Bool = false

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

    // 整单“播放全部”解析进度（#2：并发预解析时展示，避免无反馈）
    @Published var isResolvingPlaylist: Bool = false
    @Published var playlistResolveProgress: Int = 0
    // 单曲点击播放：解析中 loading + 失败提示（在歌单详情页内直接可见，避免“点了没反应”）
    @Published var isResolvingSingleSong: Bool = false
    @Published var singleSongNotice: String? = nil

    // MARK: - 活动日志（整个网络音乐逐步响应 / 错误 / 步骤过程）

    /// 日志等级
    enum LogLevel: Equatable {
        case start, success, info, error
        var color: Color {
            switch self {
            case .start:   return .blue
            case .success: return .green
            case .info:    return .secondary
            case .error:   return .red
            }
        }
        var icon: String {
            switch self {
            case .start:   return "circle.dotted"
            case .success: return "checkmark.circle"
            case .info:    return "info.circle"
            case .error:   return "xmark.circle"
            }
        }
    }

    /// 单条步骤记录
    struct LogEntry: Identifiable {
        let id = UUID()
        let time: String
        let level: LogLevel
        let title: String
        let detail: String
    }

    @Published var activityLog: [LogEntry] = []
    @Published var showActivityLog: Bool = false
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 记录一条步骤；自动追加并保留最近 60 条。
    /// 同时桥接到全局调试日志 AppLogStore（.music 分类），便于在“开发调试”日志里统一追溯。
    func log(_ level: LogLevel, _ title: String, _ detail: String = "") {
        let entry = LogEntry(
            time: Self.logFormatter.string(from: Date()),
            level: level,
            title: title,
            detail: detail
        )
        activityLog.append(entry)
        if activityLog.count > 60 {
            activityLog.removeFirst(activityLog.count - 60)
        }

        // 桥接到 AppLogStore：音乐模块日志进全局调试日志
        let message = detail.isEmpty ? title : "\(title) — \(detail)"
        switch level {
        case .start, .info:
            AppLogInfo(.music, message)
        case .success:
            AppLogInfo(.music, message)
        case .error:
            AppLogError(.music, message)
        }
    }

    /// 当前播放源是否 lx 聚合源（决定跨平台歌单播放可用性 / 提示）
    var isSelectedSourceAggregator: Bool {
        let key = selectedSource?.engineKey ?? ""
        return !key.isEmpty && LXBridgeEngine.lxKeyMap[key] != nil
    }

    /// 内置热搜关键词（搜索栏空态兜底，点选即搜）
    static let hotKeywords: [String] = [
        "晴天", "稻香", "孤勇者", "罗刹海市",
        "晚风心里吹", "我记得", "起风了", "体面",
        "七里香", "告白气球", "浮夸", "海阔天空"
    ]

    // MARK: - 加载源列表（决定播放后端）

    func loadSources() async {
        log(.start, "加载音乐源列表")
        musicSources = SpiderManager.shared.getMusicSources()
        if selectedSource == nil { selectedSource = musicSources.first }
        if musicSources.isEmpty {
            log(.error, "未发现音乐源", "将使用默认解析")
        } else {
            log(.success, "音乐源加载完成", "共 \(musicSources.count) 个：\(musicSources.map { $0.name }.joined(separator: "、"))")
            log(.info, "当前源", selectedSource?.name ?? "nil")
        }
    }

    /// 切换播放源 → 记录日志并按源类型刷新内容：
    /// - 聚合源（刀/念心）：展示各平台标签 + 平台接口歌单/榜单
    /// - 普通音乐源：无平台标签，展示该源自身首页/分类数据
    func selectSource(_ source: SourceDisplayItem) async {
        guard selectedSource?.id != source.id else {
            log(.info, "已处于源 [\(source.name)]", "无需切换")
            return
        }
        selectedSource = source
        log(.start, "切换播放源", source.name)
        log(.success, "已切换", "当前源 [\(source.name)]，引擎Key \(source.engineKey ?? "nil")")
        if isSelectedSourceAggregator {
            // 聚合源：平台标签行 + 平台接口内容
            log(.info, "源类型", "聚合源（支持跨平台），加载平台数据")
            await loadCategories()
            if selectedTab == .playlist {
                await loadPlaylists(page: 1)
            } else {
                await loadRankings()
            }
        } else {
            // 普通源：加载该源自身首页/分类
            log(.info, "源类型", "普通音乐源（无平台标签），加载源自身首页数据")
            await loadSourceHome()
        }
    }

    /// 切到普通源某个分类：加载该分类下的歌曲（复用聚合源搜索词/该引擎分类接口）
    func selectSourceCategory(_ cat: VodCategory, for home: SourceHomeData) async {
        guard selectedCategory != cat.id else { return }
        selectedCategory = cat.id
        log(.start, "切换源分类", "[\(home.sourceName)] \(cat.typeName)")
        sourceHomeLoading = true
        let source = selectedSource
        defer { sourceHomeLoading = false }

        // 普通音乐源分类：优先用该引擎的 category 接口；失败则回退用分类名做关键词搜索
        var songs: [VodItem] = []
        if let src = source, let key = src.engineKey,
           let engine = SpiderManager.shared.getEngine(forKey: key) {
            if let csp = engine as? NodeSpiderEngine, csp.isSpiderReady {
                let result = try? csp.callCategoryContent(tid: cat.typeId, pg: 1, extend: cat.typeName)
                if let list = result?.list, !list.isEmpty {
                    songs = list
                }
            }
        }
        if songs.isEmpty {
            songs = await SpiderManager.shared.searchInMusicSource(
                source: source ?? homeRecommendedSource(home),
                keyword: cat.typeName, pg: 1)
        }
        if let current = sourceHome, !songs.isEmpty {
            // SourceHomeData 的 recommended 是 let，需重建新实例
            sourceHome = SourceHomeData(
                sourceName: current.sourceName,
                categories: current.categories,
                recommended: songs,
                sourceType: current.sourceType
            )
        }
        log(songs.isEmpty ? .error : .success, "源分类加载", "[\(home.sourceName)/\(cat.typeName)] 返回 \(songs.count) 条")
    }

    /// 源首页数据未带 source 时，用该源自身的 engineKey 构造一个展示条目用于分类回退
    private func homeRecommendedSource(_ home: SourceHomeData) -> SourceDisplayItem {
        selectedSource ?? musicSources.first ?? SourceDisplayItem(
            id: "music_fallback", name: home.sourceName, category: .music,
            supportsHome: true, api: nil, searchUrl: nil, engineKey: nil,
            referer: nil, siteKey: home.sourceName)
    }

    /// 加载普通音乐源的首页数据（分类 + 推荐歌曲）
    func loadSourceHome() async {
        guard let source = selectedSource else { return }
        sourceHomeLoading = true
        sourceHome = nil
        defer { sourceHomeLoading = false }
        let data = await SpiderManager.shared.fetchHomeData(for: source)
        sourceHome = data
        if let d = data {
            log(.success, "源首页加载完成", "[\(source.name)] 分类 \(d.categories.count) 个，推荐歌曲 \(d.recommended.count) 条")
        } else {
            log(.error, "源首页加载失败", "[\(source.name)] 未返回首页/分类数据，可尝试搜索")
        }
    }

    // MARK: - 平台 / 内容类型 / 分类 切换

    /// 切换平台 → 重载分类 + 歌单 / 榜单
    func selectPlatform(_ p: MusicPlatformType) async {
        guard selectedPlatform != p else { return }
        log(.start, "切换平台", "\(selectedPlatform.displayName) → \(p.displayName)")
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
        log(.start, "加载分类标签", "平台 \(selectedPlatform.displayName)（\(selectedPlatform.rawValue)）")
        categories = await MusicPlaylistService.shared.getPlaylistCategories(platform: selectedPlatform)
        // 过滤掉接口自带的“全部”做统计（不影响展示）
        let real = categories.filter { $0.name != "全部" }
        log(.success, "分类加载完成", "共 \(categories.count) 个标签：\(real.prefix(8).map { $0.name }.joined(separator: "、"))\(real.count > 8 ? "…" : "")")
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
            log(.info, "歌单加载", "平台=\(selectedPlatform.displayName) 分类=\(selectedCategory ?? "全部") page=\(max(page,1))")
            if items.isEmpty {
                log(.error, "歌单为空", "当前平台/分类未返回任何歌单（平台接口可能收紧或分类无内容）")
            } else {
                log(.success, "歌单加载完成", "第\(max(page,1))页返回 \(items.count) 个")
            }
        }

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
        log(.start, "加载排行榜", "平台 \(selectedPlatform.displayName)")
        isLoading = true
        rankings = await MusicPlaylistService.shared.getRankings(platform: selectedPlatform)
        if rankings.isEmpty {
            log(.error, "排行榜为空", "平台接口未返回榜单数据")
        } else {
            log(.success, "排行榜加载完成", "共 \(rankings.count) 个榜单")
        }
        isLoading = false
    }

    // MARK: - 搜索：搜歌曲（跨源，VodItem）

    func searchSongs(keyword: String) async {
        log(.start, "搜索歌曲", "关键词「\(keyword)」，跨全部音乐源")
        isSearching = true
        searchResults = []
        var total = 0
        await SpiderManager.shared.searchAllMusicSources(keyword: keyword) { [weak self] batch in
            Task { @MainActor in
                self?.searchResults.append(contentsOf: batch)
            }
            total += batch.count
        }
        isSearching = false
        if total == 0 {
            log(.error, "搜索无结果", "「\(keyword)」在所有源均未找到")
        } else {
            log(.success, "搜索完成", "共返回 \(total) 条（跨源合并）")
        }
    }

    // MARK: - 搜索：搜歌单（当前选中平台）

    func searchPlaylists(keyword: String) async {
        log(.start, "搜索歌单", "关键词「\(keyword)」，平台 \(selectedPlatform.displayName)")
        isSearching = true
        playlistSearchResults = []
        let items = await MusicPlaylistService.shared.searchPlaylists(
            platform: selectedPlatform,
            keyword: keyword,
            page: 1
        )
        playlistSearchResults = items
        isSearching = false
        if items.isEmpty {
            log(.error, "歌单搜索无结果", "平台 \(selectedPlatform.displayName) 未返回")
        } else {
            log(.success, "歌单搜索完成", "共 \(items.count) 条")
        }
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

    /// 并发竞速解析播放地址（对标歌一刀）：同时打所有候选源，首个命中即取消其余。
    private func resolvePlayFor(_ song: PlaylistSong) async -> MusicQueueItem? {
        let candidates = resolutionCandidates(for: song)
        log(.start, "并发解析播放地址", "《\(song.name)》，候选源 \(candidates.count) 个")
        if candidates.isEmpty {
            log(.error, "无候选播放源", "请先在顶部选择刀源/念心等音乐源")
            return nil
        }
        let result: (index: Int, item: MusicQueueItem)? = await withTaskGroup(
            of: (Int, MusicQueueItem?)?.self
        ) { group in
            for (i, source) in candidates.enumerated() {
                group.addTask {
                    var vodItem = VodItem(
                        vodId: song.id,
                        vodName: song.name,
                        vodPic: song.coverURL ?? "",
                        engineKey: source.engineKey,
                        musicPlatform: song.platform,
                        lxMusicInfo: song.rawInfo
                    )
                    let r = await SpiderManager.shared.fetchMusicPlayUrl(source: source, song: vodItem)
                    guard let url = r.playUrl, !url.isEmpty else { return nil }
                    let item = MusicQueueItem(
                        from: vodItem,
                        sourceName: source.name,
                        engineKey: source.engineKey ?? "",
                        playURL: url
                    )
                    return (i, item)
                }
            }
            var winner: (Int, MusicQueueItem)? = nil
            for await res in group {
                if let res = res, let item = res.item {
                    winner = (res.index, item)
                    group.cancelAll()
                    break
                }
            }
            return winner
        }
        if let winner = result {
            let source = candidates[winner.index]
            log(.success, "解析成功", "[\(source.name)] 首个返回播放地址 \(winner.item.playURL.prefix(60))…")
            return winner.item
        }
        log(.error, "全部候选源均失败", "《\(song.name)》无法解析播放地址")
        return nil
    }

    /// 依歌曲归属平台排列候选播放源：并发竞速取首个命中。
    /// 所有音乐源均可参与（聚合源吃跨平台 id；固定源仅认自身平台），
    /// 选中源排在前面以提升命中偏好，最终由并发解析 App 首个可用即播。
    private func resolutionCandidates(for song: PlaylistSong) -> [SourceDisplayItem] {
        var ordered: [SourceDisplayItem] = []
        // 1) 选中源最优先
        if let sel = selectedSource, !ordered.contains(where: { $0.id == sel.id }) {
            ordered.append(sel)
        }
        // 2) 聚合源（刀/念心）次之——吃跨平台 id，可兜住大多歌曲
        let selID = selectedSource?.id
        let aggs = musicSources.filter {
            $0.id != selID && LXBridgeEngine.lxKeyMap[$0.engineKey ?? ""] != nil
        }
        ordered.append(contentsOf: aggs)
        // 3) 其余音乐源兜底（非聚合源仅认自身平台，命中率低但无害）
        for s in musicSources where !ordered.contains(where: { $0.id == s.id }) {
            ordered.append(s)
        }
        return ordered
    }

    /// 播放歌单内单曲（含跨平台回退）
    func playPlaylistSong(_ song: PlaylistSong) async {
        guard song.id != "noSource" else { return }
        isResolvingSingleSong = true
        singleSongNotice = nil
        defer {
            isResolvingSingleSong = false
        }
        let item = await resolvePlayFor(song)
        guard let item = item else {
            AudioPlayerManager.shared.playbackNotice = "未能解析播放地址，请切换到刀源/念心"
            singleSongNotice = "未能解析播放地址，请切换到刀源/念心源再试"
            return
        }
        log(.success, "开始播放", "《\(song.name)》via \(item.sourceName)")
        AudioPlayerManager.shared.play(item: item)
    }

    // MARK: - 播放：歌单全部歌曲

    /// 并发预解析整单（#2）：先并发解析前 4 首尽快开播，其余分批并发追加，全程给进度反馈
    func playPlaylistDetail(_ detail: PlaylistDetail) async {
        guard !detail.songs.isEmpty else { return }
        let total = detail.songs.count
        isResolvingPlaylist = true
        playlistResolveProgress = 0
        defer {
            isResolvingPlaylist = false
            playlistResolveProgress = 0
        }

        // 阶段一：并发解析前 4 首，尽快出声
        let headCount = min(4, total)
        let head = Array(detail.songs.prefix(headCount))
        let headDict = await resolveBatch(head)
        let headResolved = head.indices.compactMap { headDict[$0] ?? nil }

        if let first = headResolved.first {
            AudioPlayerManager.shared.play(item: first)
        }
        for extra in headResolved.dropFirst() { AudioPlayerManager.shared.addToQueue(extra) }
        playlistResolveProgress = headCount

        if headResolved.isEmpty {
            AudioPlayerManager.shared.playbackNotice = "未能解析播放地址，请切换到刀源/念心"
        }

        // 阶段二：剩余并发解析，分批追加并刷新进度
        guard headCount < total else { return }
        let rest = Array(detail.songs.dropFirst(headCount))
        var idx = 0
        while idx < rest.count {
            let c = min(4, rest.count - idx)
            let batch = Array(rest[idx..<idx + c])
            let dict = await resolveBatch(batch)
            for item in batch.indices.compactMap({ dict[$0] ?? nil }) {
                AudioPlayerManager.shared.addToQueue(item)
            }
            idx += c
            playlistResolveProgress = min(total, headCount + idx)
        }
    }

    /// 并发解析一批歌单歌曲（同批 4 首并发出网，结果按原顺序返回）
    private func resolveBatch(_ songs: [PlaylistSong]) async -> [Int: MusicQueueItem?] {
        await withTaskGroup(of: (Int, MusicQueueItem?).self, returning: [Int: MusicQueueItem?].self) { group in
            for (i, s) in songs.enumerated() {
                group.addTask { (i, await self.resolvePlayFor(s)) }
            }
            var dict: [Int: MusicQueueItem?] = [:]
            for await (i, item) in group { dict[i] = item }
            return dict
        }
    }
}

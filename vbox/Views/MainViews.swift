import SwiftUI

// ============================================================
// MARK: - 文件说明
// 本文件包含首页（HomeView）和搜索页（SearchView）的实现。
// 实际入口为 App/ContentView.swift，由 ContentView 切换显示各页面。
//
// ⚠️ 以下结构体为废弃代码，已无任何外部引用，仅保留备查：
//   - MainTabView        旧版主标签视图（已被 ContentView 取代）
//   - GlassBottomTabBar  旧版底栏（已被 ContentView 内联底栏取代）
//   - LiquidBackground   旧版液态背景（已被 AppLiquidBackground 取代）
//   - CategoryView       旧版分类页（已被 CategoryTilesView 取代）
//   - CategoryCard       仅被废弃的 CategoryView 引用
//   - UserInfoSection    废弃，无任何引用
//   - ProfileMenuItem    废弃，无任何引用
//
// ✅ 以下结构体正在使用：
//   - HomeView           被 ContentView 引用（首页）
//   - SearchView         被 ContentView 引用（搜索页）
//   - SectionHeader      被 HomeView + DoubanHomeView 引用
//   - FlowLayout         被 DailyBattleMainView 引用
//   - edgeSwipeBack      被 PlayerViews + SourceDiscoveryView 引用
// ============================================================

// ⚠️ 废弃：旧版主标签视图，已被 ContentView 取代，不再使用
struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var tabHistory: [Int] = [0]
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack(alignment: .bottom) {
            // 主内容
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Image(systemName: selectedTab == 0 ? "house.fill" : "house")
                        Text("首页")
                    }
                    .tag(0)

                SearchView()
                    .tabItem {
                        Image(systemName: selectedTab == 1 ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                        Text("搜索")
                    }
                    .tag(1)

                WelfareTabGateView()
                    .tabItem {
                        Image(systemName: selectedTab == 2 ? "heart.fill" : "heart")
                        Text("福利")
                    }
                    .tag(2)

                LiveTVView()
                    .tabItem {
                        Image(systemName: selectedTab == 3 ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                        Text("直播")
                    }
                    .tag(3)

                ProfileView()
                    .tabItem {
                        Image(systemName: selectedTab == 4 ? "person.fill" : "person")
                        Text("设置")
                    }
                    .tag(4)
            }
            .accentColor(Color(hex: "E11D48"))

            // 底部悬浮半圆导航栏
            if !settings.isTabBarHidden {
                GlassBottomTabBar(selectedTab: $selectedTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.isTabBarHidden)
        .ignoresSafeArea(.keyboard)
        .edgeSwipeBack {
            guard selectedTab != 0 else { return }
            if tabHistory.last == selectedTab { tabHistory.removeLast() }
            selectedTab = tabHistory.last ?? 0
            if tabHistory.isEmpty { tabHistory = [selectedTab] }
        }
        .onChange(of: settings.searchRequestId) { _ in
            guard !settings.searchQuery.isEmpty else { return }
            selectedTab = 1
        }
        .onChange(of: selectedTab) { newValue in
            guard tabHistory.last != newValue else { return }
            tabHistory.append(newValue)
            if tabHistory.count > 8 { tabHistory.removeFirst(tabHistory.count - 8) }
        }
    }
}

extension View {
    /// 全局边缘侧滑返回（放宽触发区域和距离）
    /// 使用 highPriorityGesture 避免与 NavigationView 系统手势同时触发
    func edgeSwipeBack(_ action: @escaping () -> Void) -> some View {
        highPriorityGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = abs(value.translation.height)
                    // 放宽：左侧 55pt 内起滑，水平滑动超过 45pt，且基本水平
                    guard value.startLocation.x < 55, dx > 45, dx > dy else { return }
                    action()
                }
        )
    }
}

// ⚠️ 废弃：旧版底栏，已被 ContentView 内联底栏取代，不再使用
struct GlassBottomTabBar: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var settings: AppSettings

    private let tabs: [(icon: String, iconFilled: String, title: String)] = [
        ("house", "house.fill", "首页"),
        ("magnifyingglass.circle", "magnifyingglass.circle.fill", "搜索"),
        ("heart", "heart.fill", "福利"),
        ("antenna.radiowaves.left.and.right", "dot.radiowaves.left.and.right", "直播"),
        ("person", "person.fill", "设置")
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<tabs.count, id: \.self) { index in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selectedTab = index
                    }
                }) {
                    VStack(spacing: 1) {
                        Image(systemName: selectedTab == index ? tabs[index].iconFilled : tabs[index].icon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(selectedTab == index ? activeColor : inactiveColor)
                            .frame(height: 22)

                        Text(tabs[index].title)
                            .font(.system(size: 10, weight: selectedTab == index ? .semibold : .regular))
                            .foregroundColor(selectedTab == index ? activeColor : inactiveColor)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: min(UIScreen.main.bounds.width - 160, 250))
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .background(Capsule().fill(tabBarBaseColor))
                .overlay(
                    Capsule()
                        .stroke(tabBarStrokeColor, lineWidth: 1)
                )
        )
        .clipShape(Capsule())
        .padding(.horizontal, 36)
        .padding(.bottom, 8)
    }

    private var activeColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color.blue
    }

    private var inactiveColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.72) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondaryLabel) }
        return Color.gray
    }

    private var tabBarBaseColor: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.34) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemBackground).opacity(0.62) }
        return Color(uiColor: .systemBackground).opacity(0.86)
    }

    private var tabBarStrokeColor: Color {
        settings.usesVisualSkin ? Color.white.opacity(0.28) : Color.gray.opacity(0.2)
    }
}

// ⚠️ 废弃：旧版液态背景，已被 AppLiquidBackground 取代，不再使用
struct LiquidBackground: View {
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 动态流动的渐变
                ForEach(0..<3) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(hex: "E11D48").opacity(0.3),
                                    Color(hex: "F43F5E").opacity(0.2),
                                    Color(hex: "7C3AED").opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .offset(
                            x: CGFloat(phase + Double(index) * 2.0).truncatingRemainder(dividingBy: 10) - 5,
                            y: CGFloat(cos(phase * 2 + Double(index))).truncatingRemainder(dividingBy: 10) - 5
                        )
                        .blur(radius: 12)
                }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                phase = 10
            }
        }
    }
}

// MARK: - 首页视图（豆瓣推荐）
struct HomeView: View {
    @StateObject private var doubanService = DoubanService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var showSearch = false
    @State private var showRanking = false
    @State private var showHistory = false
    @State private var showSourcePicker = false
    @State private var selectedSource: SourceDisplayItem?
    @State private var allSources: [SourceDisplayItem] = []
    /// 缓存分组结果，避免每次渲染都重新分组（allSources 变化时重新计算）
    @State private var homeGroupedSourcesCache: [(key: String, items: [SourceDisplayItem])] = []
    private static var cachedBannerItems: [BannerItem] = []
    private static var cachedHotMovies: [DoubanSubject] = []
    private static var cachedHotTV: [DoubanSubject] = []
    private static var cachedHotVariety: [DoubanSubject] = []
    private static var cachedTop250: [DoubanSubject] = []
    private static var cachedShowingMovies: [DoubanSubject] = []
    private static var cachedHotGaiaMovies: [DoubanSubject] = []
    private static var cachedAmericanTV: [DoubanSubject] = []
    // 新增分类缓存
    private static var cachedComingSoon: [DoubanSubject] = []        // 即将上映
    private static var cachedMovieWeekly: [DoubanSubject] = []       // 一周口碑榜
    private static var cachedLatestMovies: [DoubanSubject] = []      // 最新电影
    private static var cachedChiTV: [DoubanSubject] = []             // 华语口碑剧集
    private static var cachedHotAnimation: [DoubanSubject] = []      // 热门动漫
    private static var cachedKoreanTV: [DoubanSubject] = []          // 热门韩剧
    private static var cachedJapaneseTV: [DoubanSubject] = []        // 热门日剧
    private static var hasHomeCache: Bool {
        !cachedBannerItems.isEmpty || !cachedHotMovies.isEmpty || !cachedHotTV.isEmpty || !cachedTop250.isEmpty
    }
    @State private var isLoading: Bool
    @State private var bannerItems: [BannerItem]
    @State private var hotMovies: [DoubanSubject]
    @State private var hotTV: [DoubanSubject]
    @State private var hotVariety: [DoubanSubject]
    @State private var top250: [DoubanSubject]
    @State private var showingMovies: [DoubanSubject]
    @State private var hotGaiaMovies: [DoubanSubject]
    @State private var americanTV: [DoubanSubject]
    // 新增分类状态
    @State private var comingSoon: [DoubanSubject]                   // 即将上映
    @State private var movieWeekly: [DoubanSubject]                  // 一周口碑榜
    @State private var latestMovies: [DoubanSubject]                 // 最新电影
    @State private var chiTV: [DoubanSubject]                        // 华语口碑剧集
    @State private var hotAnimation: [DoubanSubject]                 // 热门动漫
    @State private var koreanTV: [DoubanSubject]                     // 热门韩剧
    @State private var japaneseTV: [DoubanSubject]                   // 热门日剧
    @State private var currentIndex = 0
    @State private var loadTask: Task<Void, Never>? = nil

    init() {
        _isLoading = State(initialValue: !Self.hasHomeCache)
        _bannerItems = State(initialValue: Self.cachedBannerItems)
        _hotMovies = State(initialValue: Self.cachedHotMovies)
        _hotTV = State(initialValue: Self.cachedHotTV)
        _hotVariety = State(initialValue: Self.cachedHotVariety)
        _top250 = State(initialValue: Self.cachedTop250)
        _showingMovies = State(initialValue: Self.cachedShowingMovies)
        _hotGaiaMovies = State(initialValue: Self.cachedHotGaiaMovies)
        _americanTV = State(initialValue: Self.cachedAmericanTV)
        _comingSoon = State(initialValue: Self.cachedComingSoon)
        _movieWeekly = State(initialValue: Self.cachedMovieWeekly)
        _latestMovies = State(initialValue: Self.cachedLatestMovies)
        _chiTV = State(initialValue: Self.cachedChiTV)
        _hotAnimation = State(initialValue: Self.cachedHotAnimation)
        _koreanTV = State(initialValue: Self.cachedKoreanTV)
        _japaneseTV = State(initialValue: Self.cachedJapaneseTV)
    }

    var body: some View {
        ZStack {
            // 豆瓣首页始终存活，避免条件创建/销毁导致的卡顿和底栏状态丢失
            doubanHomeContent
                .zIndex(0)
                .allowsHitTesting(selectedSource == nil && !showSourcePicker)

            // ★ NavigationView 始终存活，避免 UINavigationController 创建/销毁导致的卡顿
            // 通过 opacity + allowsHitTesting 控制可见性，而非条件创建/销毁
            NavigationView {
                if let source = selectedSource {
                    SourceDiscoveryView(
                        source: source,
                        selectedSource: $selectedSource,
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                selectedSource = nil
                            }
                        }
                    )
                    .id(source.id)
                    .environmentObject(settings)
                }
            }
            .navigationViewStyle(.stack)
            .opacity(selectedSource != nil ? 1 : 0)
            .allowsHitTesting(selectedSource != nil)
            .zIndex(1)

            // 首页小竖长条选源浮层 — 放在外层 ZStack，与 doubanHomeContent 平级
            // 避免切换 showSourcePicker 时触发首页 ScrollView/LazyVStack 整体重算
            if showSourcePicker {
                homeSourceDropdownOverlay
                    .zIndex(2)
            }
        }
        .onAppear {
            // 预加载源列表（异步，不阻塞首屏渲染）
            // ★ 不再等待 initialize 完成，先显示已有数据，后台初始化完成后再刷新
            if allSources.isEmpty {
                Task.detached(priority: .utility) {
                    // 立即尝试获取当前可用的源（可能不完整但不为空）
                    let items = await SpiderManager.shared.fetchAllSourceDisplayItemsAsync()
                    await MainActor.run {
                        if allSources.isEmpty {
                            updateAllSources(items)
                        }
                    }
                    // 后台等待初始化完成，sourceListReady 变化时通过 onChange 刷新
                    await SpiderManager.shared.initialize()
                }
            }
        }
        .onChange(of: SpiderManager.shared.sourceListReady) { ready in
            if ready {
                Task {
                    let items = await SpiderManager.shared.fetchAllSourceDisplayItemsAsync()
                    await MainActor.run {
                        updateAllSources(items)
                    }
                }
            }
        }
        .onChange(of: settings.searchRequestId) { _ in
            if !settings.searchQuery.isEmpty { showSearch = true }
        }
        .onChange(of: selectedSource) { newValue in
            withAnimation(.easeInOut(duration: 0.3)) {
                settings.isTabBarHidden = newValue != nil
            }
        }
    }

    private var doubanHomeContent: some View {
        ZStack {
            ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).padding(.top, 100)
                        Text("正在加载...").font(.system(size: 14)).foregroundColor(.secondary)
                    }
                } else {
                    Group {
                        HomeSearchBar(
                            showSearch: $showSearch,
                            showRanking: $showRanking,
                            showHistory: $showHistory,
                            showSourcePicker: $showSourcePicker,
                            selectedSourceName: selectedSource?.name
                        )
                        if !bannerItems.isEmpty {
                            BannerCarousel(items: bannerItems, currentIndex: $currentIndex, settings: settings)
                        }
                        CategoryTilesView(settings: settings)
                        // 1. 影院热映
                        if !showingMovies.isEmpty {
                            SectionHeader(title: "影院热映", icon: "film.fill")
                            HorizontalSubjectRow(subjects: showingMovies, settings: settings)
                        }
                        // 2. 即将上映
                        if !comingSoon.isEmpty {
                            SectionHeader(title: "即将上映", icon: "calendar.badge.clock")
                            HorizontalSubjectRow(subjects: comingSoon, settings: settings)
                        }
                        // 3. 热门电影
                        if !hotMovies.isEmpty {
                            SectionHeader(title: "热门电影", icon: "flame.fill")
                            HorizontalSubjectRow(subjects: hotMovies, settings: settings)
                        }
                        // 4. 一周口碑榜
                        if !movieWeekly.isEmpty {
                            SectionHeader(title: "一周口碑榜", icon: "star.fill")
                            HorizontalSubjectRow(subjects: movieWeekly, settings: settings)
                        }
                        // 5. 新片榜
                        if !latestMovies.isEmpty {
                            SectionHeader(title: "新片榜", icon: "sparkles")
                            HorizontalSubjectRow(subjects: latestMovies, settings: settings)
                        }
                        // 6. TOP250
                        if !top250.isEmpty {
                            SectionHeader(title: "TOP250", icon: "crown.fill")
                            HorizontalSubjectRow(subjects: top250, settings: settings)
                        }
                        // 7. 热门剧集
                        if !hotTV.isEmpty {
                            SectionHeader(title: "热门剧集", icon: "tv.fill")
                            HorizontalSubjectRow(subjects: hotTV, settings: settings)
                        }
                        // 8. 华语口碑剧集
                        if !chiTV.isEmpty {
                            SectionHeader(title: "华语口碑剧集", icon: "flag.fill")
                            HorizontalSubjectRow(subjects: chiTV, settings: settings)
                        }
                        // 9. 值得看的英美剧
                        if !americanTV.isEmpty {
                            SectionHeader(title: "值得看的英美剧", icon: "globe")
                            HorizontalSubjectRow(subjects: americanTV, settings: settings)
                        }
                        // 10. 热门动漫
                        if !hotAnimation.isEmpty {
                            SectionHeader(title: "热门动漫", icon: "paintbrush.fill")
                            HorizontalSubjectRow(subjects: hotAnimation, settings: settings)
                        }
                        // 11. 热门综艺
                        if !hotVariety.isEmpty {
                            SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                            HorizontalSubjectRow(subjects: hotVariety, settings: settings)
                        }
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .refreshable { await loadData(force: true) }
        .onAppear {
            guard !Self.hasHomeCache else {
                restoreHomeCache()
                return
            }
            Task { await loadData(force: false) }
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchView()
                .environmentObject(settings)
        }
        .sheet(isPresented: $showRanking) {
            DoubanRankingView { keyword in
                showRanking = false
                settings.triggerSearch(keyword)
            }
                .environmentObject(settings)
        }
        .sheet(isPresented: $showHistory) {
            WatchHistoryView()
                .environmentObject(settings)
        }
        } // ZStack
    }

    // MARK: - 首页小竖长条选源浮层

    private var homeSourceDropdownOverlay: some View {
        ZStack(alignment: .topLeading) {
            // 半透明背景遮罩 — 仅处理点击关闭，不拦截子视图手势
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { showSourcePicker = false }

            // 弹窗主体
            VStack(spacing: 0) {
                // 标题栏
                HStack(spacing: 4) {
                    Text("切换源")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(homeDropdownTextColor)
                    Spacer()
                    Text("\(allSources.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "E11B48"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color(hex: "E11B48").opacity(0.15))
                        )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()
                    .background(homeDropdownDividerColor)

                // 源列表（按分类分组）
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(homeGroupedSources, id: \.key) { group in
                            // 分组标题
                            HStack(spacing: 4) {
                                Text(group.key)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(homeDropdownTextColor)
                                Spacer()
                                Text("\(group.items.count)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Color(hex: "E11B48"))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule()
                                            .fill(Color(hex: "E11B48").opacity(0.15))
                                    )
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(homeDropdownSectionHeaderBg)

                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                Button(action: {
                                    selectedSource = item
                                    showSourcePicker = false
                                }) {
                                    HStack(spacing: 8) {
                                        if item.id == selectedSource?.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(Color(hex: "E11B48"))
                                                .frame(width: 16)
                                        } else {
                                            Color.clear.frame(width: 16, height: 12)
                                        }
                                        HomeSourceMarqueeText(
                                            text: item.name,
                                            fontSize: 14,
                                            weight: item.id == selectedSource?.id ? .semibold : .regular,
                                            color: item.id == selectedSource?.id ? Color(hex: "E11B48") : homeDropdownTextColor
                                        )
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if idx < group.items.count - 1 {
                                    Divider()
                                        .padding(.leading, 38)
                                        .background(homeDropdownDividerColor)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: UIScreen.main.bounds.width * 0.4,
                   maxHeight: UIScreen.main.bounds.height * 0.5)
            .background(homeDropdownBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.top, 52)
            .padding(.leading, 12)
        }
    }

    private var homeDropdownBackground: some View {
        if settings.usesVisualSkin {
            return AnyView(
                LinearGradient(
                    colors: [Color(hex: "1a1a2e"), Color(hex: "16213e")],
                    startPoint: .top, endPoint: .bottom
                )
            )
        } else {
            return AnyView(Color(uiColor: .systemBackground))
        }
    }

    private var homeDropdownSectionHeaderBg: some View {
        if settings.usesVisualSkin {
            return AnyView(Color(hex: "1a1a2e").opacity(0.6))
        } else {
            return AnyView(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// 按分类分组，固定顺序：网盘 → API → 站源 → JS → 论坛
    /// 使用缓存避免每次渲染都重新分组（allSources 变化时重新计算）
    private var homeGroupedSources: [(key: String, items: [SourceDisplayItem])] {
        if !homeGroupedSourcesCache.isEmpty { return homeGroupedSourcesCache }
        let grouped = Dictionary(grouping: allSources) { $0.category.displayName }
        let order = ["网盘", "API", "站源", "JS", "论坛"]
        let result = order.compactMap { key in
            if let items = grouped[key], !items.isEmpty {
                return (key, items)
            }
            return nil
        }
        return result
    }

    /// 统一更新 allSources 和分组缓存
    private func updateAllSources(_ items: [SourceDisplayItem]) {
        allSources = items
        let grouped = Dictionary(grouping: items) { $0.category.displayName }
        let order = ["网盘", "API", "站源", "JS", "论坛"]
        homeGroupedSourcesCache = order.compactMap { key in
            if let groupItems = grouped[key], !groupItems.isEmpty {
                return (key, groupItems)
            }
            return nil
        }
    }

    private var homeDropdownTextColor: Color {
        settings.usesVisualSkin ? .white : .primary
    }

    private var homeDropdownDividerColor: Color {
        settings.usesVisualSkin ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)
    }

    @MainActor
    private func loadData(force: Bool) async {
        // 取消上一次加载任务，防止重入导致数组越界闪退
        loadTask?.cancel()

        loadTask = Task {
            if !force, Self.hasHomeCache {
                restoreHomeCache()
                return
            }
            isLoading = true

            // 第一梯队：核心分类，优先展示
            async let showing = fetchSafely { try await doubanService.fetchUpcomingCN(start: 0, count: 10) }
            async let movies = fetchSafely { try await doubanService.fetchHotMovies(start: 0, count: 10) }
            async let tv = fetchSafely { try await doubanService.fetchHotTV(start: 0, count: 10) }
            async let top = fetchSafely { try await doubanService.fetchTop250(start: 0, count: 10) }

            let showingResult = await showing
            guard !Task.isCancelled else { return }
            let moviesResult = await movies
            guard !Task.isCancelled else { return }
            let tvResult = await tv
            guard !Task.isCancelled else { return }
            let topResult = await top
            guard !Task.isCancelled else { return }

            // 第一梯队有数据就更新，保证首屏快速显示
            if !showingResult.isEmpty {
                showingMovies = showingResult
                Self.cachedShowingMovies = showingResult
            }
            if !moviesResult.isEmpty {
                hotMovies = moviesResult
                Self.cachedHotMovies = moviesResult
            }
            if !tvResult.isEmpty {
                hotTV = tvResult
                Self.cachedHotTV = tvResult
            }
            if !topResult.isEmpty {
                top250 = topResult
                Self.cachedTop250 = topResult
            }

            // 第二梯队：其他分类，错峰请求避免限流
            async let soon = fetchSafely { try await doubanService.fetchComingSoon(start: 0, count: 10) }
            async let weekly = fetchSafely { try await doubanService.fetchMovieWeekly(start: 0, count: 10) }
            async let latest = fetchSafely { try await doubanService.fetchLatestMovies(start: 0, count: 10) }
            async let chi = fetchSafely { try await doubanService.fetchPopularChiTV(start: 0, count: 10) }
            async let american = fetchSafely { try await doubanService.fetchAmericanTV(start: 0, count: 10) }
            async let anim = fetchSafely { try await doubanService.fetchHotAnimation(start: 0, count: 10) }
            async let korean = fetchSafely { try await doubanService.fetchKoreanTV(start: 0, count: 10) }
            async let japanese = fetchSafely { try await doubanService.fetchJapaneseTV(start: 0, count: 10) }
            async let variety = fetchSafely { try await doubanService.fetchHotVariety(start: 0, count: 10) }

            let soonResult = await soon
            guard !Task.isCancelled else { return }
            let weeklyResult = await weekly
            guard !Task.isCancelled else { return }
            let latestResult = await latest
            guard !Task.isCancelled else { return }
            let chiResult = await chi
            guard !Task.isCancelled else { return }
            let americanResult = await american
            guard !Task.isCancelled else { return }
            let animResult = await anim
            guard !Task.isCancelled else { return }
            let koreanResult = await korean
            guard !Task.isCancelled else { return }
            let japaneseResult = await japanese
            guard !Task.isCancelled else { return }
            let varietyResult = await variety
            guard !Task.isCancelled else { return }

            // 第二梯队：有数据才更新，空数据保留旧值（防止限流导致页面空白）
            if !soonResult.isEmpty {
                comingSoon = soonResult
                Self.cachedComingSoon = soonResult
            }
            if !weeklyResult.isEmpty {
                movieWeekly = weeklyResult
                Self.cachedMovieWeekly = weeklyResult
            }
            if !latestResult.isEmpty {
                latestMovies = latestResult
                Self.cachedLatestMovies = latestResult
            }
            if !chiResult.isEmpty {
                chiTV = chiResult
                Self.cachedChiTV = chiResult
            }
            if !americanResult.isEmpty {
                americanTV = americanResult
                Self.cachedAmericanTV = americanResult
            }
            if !animResult.isEmpty {
                hotAnimation = animResult
                Self.cachedHotAnimation = animResult
            }
            if !koreanResult.isEmpty {
                koreanTV = koreanResult
                Self.cachedKoreanTV = koreanResult
            }
            if !japaneseResult.isEmpty {
                japaneseTV = japaneseResult
                Self.cachedJapaneseTV = japaneseResult
            }
            if !varietyResult.isEmpty {
                hotVariety = varietyResult
                Self.cachedHotVariety = varietyResult
            }

            // Banner 随机抽取：从所有已加载分类中汇总，随机选取 6~8 条
            let allSubjects = (showingMovies + comingSoon + hotMovies + movieWeekly +
                               latestMovies + top250 + hotTV + chiTV + americanTV +
                               hotAnimation + koreanTV + japaneseTV + hotVariety)
                .filter { $0.ratingValue > 0 }

            guard !allSubjects.isEmpty else {
                isLoading = false
                return
            }

            let bannerCount = min(8, max(6, allSubjects.count))
            let picked = Array(allSubjects.shuffled().prefix(bannerCount))

            // 先用竖版封面创建 BannerItem（UI 立即可见），后续异步替换为横版海报
            bannerItems = picked.map { BannerItem(from: $0) }
            Self.cachedBannerItems = bannerItems

            isLoading = false
            // 首页已有可展示数据：通知启动页淡出进入首页
            SplashGateMonitor.shared.markHomeReady()

            // 异步获取横版海报 URL，逐条更新 + 预缓存前 3 张
            await fetchBackdropURLs()
        }
    }

    /// 逐条获取横版海报 URL 并更新 BannerItem，同时预缓存图片
    @MainActor
    private func fetchBackdropURLs() async {
        // 用快照循环，用 id 匹配更新，防止数组被替换后越界
        let itemsSnapshot = bannerItems
        for (_, item) in itemsSnapshot.enumerated() {
            guard !Task.isCancelled else { return }
            let backdropURL = await doubanService.fetchBackdropURL(subjectId: item.id)
            guard !Task.isCancelled else { return }
            if let backdropURL,
               let realIndex = bannerItems.firstIndex(where: { $0.id == item.id }) {
                bannerItems[realIndex] = item.withBackdropURL(backdropURL)
                Self.cachedBannerItems = bannerItems
                // 前 3 张预缓存到内存
                if realIndex < 3 {
                    ImagePreloader.shared.preload(backdropURL)
                }
            }
        }
    }

    private func fetchSafely(_ operation: @escaping () async throws -> [DoubanSubject]) async -> [DoubanSubject] {
        do {
            return try await operation()
        } catch {
            print("[HomeView] 分类加载失败: \(error)")
            return []
        }
    }

    private func restoreHomeCache() {
        bannerItems = Self.cachedBannerItems
        showingMovies = Self.cachedShowingMovies
        comingSoon = Self.cachedComingSoon
        hotMovies = Self.cachedHotMovies
        movieWeekly = Self.cachedMovieWeekly
        latestMovies = Self.cachedLatestMovies
        top250 = Self.cachedTop250
        hotTV = Self.cachedHotTV
        chiTV = Self.cachedChiTV
        americanTV = Self.cachedAmericanTV
        hotAnimation = Self.cachedHotAnimation
        koreanTV = Self.cachedKoreanTV
        japaneseTV = Self.cachedJapaneseTV
        hotVariety = Self.cachedHotVariety
        isLoading = false
        // 首页有可展示数据：通知启动页可以淡出进入首页
        SplashGateMonitor.shared.markHomeReady()
    }
}

// 首页顶部搜索区域
struct HomeSearchBar: View {
    @Binding var showSearch: Bool
    @Binding var showRanking: Bool
    @Binding var showHistory: Bool
    @Binding var showSourcePicker: Bool
    var selectedSourceName: String?
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 10) {
            // 多源选择按钮（移到最前面）
            Button {
                showSourcePicker = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18))
                    .foregroundColor(selectedSourceName != nil ? Color(hex: "34C759") : .primary)
            }
            .buttonStyle(.plain)

            // 搜索栏
            Button {
                showSearch = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                    Text("搜索影片、剧集")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .systemGray6))
                )
            }
            .buttonStyle(.plain)

            // 排行榜
            Button {
                showRanking = true
            } label: {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            // 历史记录
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)

            // AI 按钮 - 跳转到系统默认浏览器打开 Lobster-APP 仓库
            Button {
                if let url = URL(string: "https://github.com/vbox-Ai/Lobster-APP") {
                    UIApplication.shared.open(url)
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "8AB4F8"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

// 搜索栏头部
struct SearchBarHeader: View {
    @State private var searchText = ""
    var onSearch: ((String) -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // 搜索输入框
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color.secondary)

                TextField("搜索视频...", text: $searchText)
                    .foregroundColor(.primary)
                    .onSubmit { submit() }
                    .submitLabel(.search)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color(uiColor: .systemBackground).opacity(0.2), Color(uiColor: .systemBackground).opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )

            // 搜索按钮
            Button(action: { submit() }) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "E11D48"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color(hex: "0F0F23").opacity(0.95), Color(hex: "000000").opacity(0.98)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func submit() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        onSearch?(q)
    }
}

// 推荐轮播
struct FeaturedCarousel: View {
    let videos: [VodItem]
    @State private var currentIndex = 0

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(0..<min(5, videos.count), id: \.self) { index in
                FeaturedCard(video: videos[index])
                    .tag(index)
            }
        }
        .frame(height: 200)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if !videos.isEmpty {
            HStack(spacing: 8) {
                ForEach(0..<min(5, videos.count), id: \.self) { index in
                    Circle()
                        .fill(currentIndex == index ? Color(hex: "E11D48") : Color(uiColor: .systemBackground).opacity(0.3))
                        .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
                        .animation(.spring(response: 0.3), value: currentIndex)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

// 推荐卡片
struct FeaturedCard: View {
    let video: VodItem
    @State private var showDetail = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图片
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure(_):
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.title)
                                .foregroundColor(.gray)
                            Text("封面加载失败")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                case .empty:
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                        ProgressView()
                    }
                @unknown default:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: UIScreen.main.bounds.width - 32, height: 200)
            .clipped()

            // 渐变遮罩
            LinearGradient(
                colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(0.6),
                    Color.black.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 信息内容
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(video.vodName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    // 播放按钮
                    Button(action: { showDetail = true }) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E11D48"))

                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 44, height: 44)
                    }
                }

                HStack(spacing: 8) {
                    Label(video.vodYear ?? "", systemImage: "calendar")
                    Label(video.vodRemarks ?? "", systemImage: "film")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(uiColor: .systemBackground).opacity(0.15),
                            Color(uiColor: .systemBackground).opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onTapGesture { showDetail = true }
        .fullScreenCover(isPresented: $showDetail) {
            VideoDetailView(video: video)
        }
    }
}

// 视频卡片
struct VideoCard: View {
    let video: VodItem
    @State private var showDetail = false

    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(alignment: .leading, spacing: 10) {
                // 封面
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_):
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.25))
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                        .font(.title2)
                                        .foregroundColor(.gray)
                                    Text("加载失败")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        case .empty:
                            ZStack {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.15))
                                ProgressView()
                            }
                        @unknown default:
                            Rectangle()
                                .fill(Color.gray.opacity(0.25))
                        }
                    }
                    .frame(height: 140)
                    .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // 标题和信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.vodName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        if let year = video.vodYear, !year.isEmpty {
                            Text(year)
                                .font(.system(size: 11))
                                .foregroundColor(Color.secondary)
                        }
                    }

                    Spacer(minLength: 0)

                    // 来源标签放在信息区底部
                    if let remarks = video.vodRemarks, !remarks.isEmpty {
                        Text(remarks)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "E11D48"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color(hex: "E11D48").opacity(0.12))
                            )
                    }
                }
            }
            .padding(12)
            .background(
                // 毛玻璃卡片背景
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(uiColor: .systemBackground).opacity(0.1),
                                Color(uiColor: .systemBackground).opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
            .buttonStyle(PlainButtonStyle())
            .fullScreenCover(isPresented: $showDetail) {
                VideoDetailView(video: video)
            }
    }
}

// 分区头部
struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 搜索视图（新 UI）
struct SearchView: View {
    @StateObject private var spiderManager = SpiderManager.shared
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [VodItem] = []
    @State private var isSearchLoading = false
    @State private var searchHistory: [String] = []
    @State private var selectedDoubanTab = 0
    @State private var doubanSubjects: [String: [DoubanSubject]] = [:]
    @State private var searchDebugLogs: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var doubanLoading = false
    @State private var hasLoadedDefaultData = false
    @State private var showRankingView = false
    
    private let doubanTabs = ["豆瓣周榜", "华语口碑剧集", "一周口碑电影榜", "国内即将上映"]
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部搜索栏
            HStack(spacing: 8) {
                // 输入框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                        .searchWiggle(isActive: isSearchLoading)
                    TextField("搜索影片、剧集", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onChange(of: searchText) { value in
                            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                resetSearchState()
                            }
                        }
                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                            resetSearchState()
                        }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.gray)
                                .font(.system(size: 14, weight: .medium))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                
                // 豆瓣排行榜入口
                Button(action: { showRankingView = true }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.gray.opacity(0.15))
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(PlainButtonStyle())
                
                // 搜索按钮
                Button(action: { performSearch() }) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 40, height: 36)
                .background(Color(hex: "E11D48"))
                .cornerRadius(10)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // 分隔线
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            // 搜索调试面板（搜索框下方）
            if UserDefaults.standard.bool(forKey: "show_search_debug") && !searchDebugLogs.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("搜索调试")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Spacer()
                        Text("\(searchResults.count)条/\(Set(searchResults.compactMap { $0.vodRemarks }).count)源")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: true) {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(searchDebugLogs.enumerated()), id: \.offset) { idx, log in
                                    Text(log)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(log.hasPrefix("✅") ? .green.opacity(0.9) :
                                                           log.hasPrefix("❌") ? .red.opacity(0.9) :
                                                           log.hasPrefix("📦") ? .yellow.opacity(0.9) :
                                                           log.hasPrefix("☁️") ? .cyan.opacity(0.9) :
                                                           .white.opacity(0.7))
                                        .id(idx)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                        }
                        .onChange(of: searchDebugLogs.count) { _ in
                            if let last = searchDebugLogs.indices.last {
                                withAnimation { proxy.scrollTo(last) }
                            }
                        }
                    }
                    .frame(height: 120)
                }
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85))
                .cornerRadius(10)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            ZStack {
                if isSearching && !searchResults.isEmpty {
                    // 搜索中或搜索完成，已有结果：展示结果页
                    SearchResultsView(results: searchResults, searchText: searchText)
                } else if isSearching && !isSearchLoading && searchResults.isEmpty {
                    // 已结束搜索但无结果：展示空态
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundColor(.gray)
                        Text("未找到结果").font(.system(size: 16)).foregroundColor(.gray)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 默认/搜索中（无结果）：保持默认内容（搜索历史 + 豆瓣榜单），顶部以小条提示「搜索中」
                    ZStack(alignment: .top) {
                        defaultContentView
                        if isSearching && isSearchLoading {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("搜索中...").font(.system(size: 13)).foregroundColor(.gray)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .systemBackground).opacity(0.95))
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
                            .padding(.top, 6)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSearching)
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width > 80 && value.predictedEndTranslation.width > 120 {
                        dismiss()
                    }
                }
        )
        .overlay(
            HStack {
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .gesture(
                        DragGesture(minimumDistance: 10)
                            .onEnded { value in
                                if value.translation.width > 60 {
                                    dismiss()
                                }
                            }
                    )
                Spacer()
            }
        )
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onChange(of: settings.searchRequestId) { _ in
            runTriggeredSearch()
        }
        .onAppear {
            if !hasLoadedDefaultData {
                hasLoadedDefaultData = true
                Task {
                    await loadSearchHistory()
                    await loadDoubanData(force: false)
                }
                // 首次出现：如果有外部搜索请求则执行
                if !settings.searchQuery.isEmpty {
                    runTriggeredSearch()
                }
            } else if !settings.searchQuery.isEmpty && (!isSearching || searchResults.isEmpty) {
                // 防御性恢复：视图重新出现时，如果搜索状态被意外重置
                // （如 sheet dismiss 与 fullScreenCover present 转场竞争导致 onDisappear 清空状态），
                // 但仍有待执行的搜索关键词，则重新执行搜索。
                // 正常从详情页返回时 isSearching=true 且 searchResults 非空，不会触发此分支。
                runTriggeredSearch()
            }
            // 从详情页返回时：不做任何操作，保持现有搜索结果
        }
        .onDisappear {
            // 离开搜索页时停止搜索
            searchTask?.cancel()
            searchTask = nil
            isSearching = false
            isSearchLoading = false
        }
    }
    
    @ViewBuilder
    private var defaultContentView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                // 搜索历史
                if !searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "E11D48"))
                            Text("搜索历史")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                            Spacer()
                            Button("清空") {
                                searchHistory = []
                                cacheSearchHistory()
                            }
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "E11D48"))
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(searchHistory, id: \.self) { keyword in
                                    SearchHistoryChip(keyword: keyword) {
                                        searchText = keyword
                                        performSearch()
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 16)
                    .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                }
                
                // 豆瓣栏目标签
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(0..<doubanTabs.count, id: \.self) { index in
                                Button(action: {
                                    selectedDoubanTab = index
                                    Task { await loadDoubanData(force: false) }
                                }) {
                                    VStack(spacing: 6) {
                                        Text(doubanTabs[index])
                                            .font(.system(size: 14, weight: selectedDoubanTab == index ? .semibold : .medium))
                                            .foregroundColor(selectedDoubanTab == index ? Color(hex: "E11D48") : .secondary)
                                        Rectangle()
                                            .fill(selectedDoubanTab == index ? Color(hex: "E11D48") : Color.clear)
                                            .frame(height: 2)
                                            .clipShape(RoundedRectangle(cornerRadius: 1))
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.clear)
                                }
                                .buttonStyle(PlainButtonStyle())
                                if index < doubanTabs.count - 1 {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.15))
                                        .frame(width: 1)
                                        .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                    .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                }
                
                // 豆瓣数据列表
                if doubanLoading {
                    VStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            DoubanSkeletonCardItem()
                        }
                    }
                    .padding(.top, 12)
                } else if let subjects = doubanSubjects[doubanTabs[selectedDoubanTab]], !subjects.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(subjects) { subject in
                            SearchDoubanCardItem(subject: subject) {
                                runKeywordSearch(subject.title)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                
                // 分隔线
                Divider().frame(height: 1).background(Color.gray.opacity(0.15)).padding(.vertical, 8)
                
                // 全部站点（保持原样）
                if !spiderManager.allSites.isEmpty {
                    SectionHeader(title: "全部站点 (" + String(spiderManager.loadedSiteCount) + ")", icon: "list.star")
                        .padding(.top, 8)
                    ForEach(spiderManager.allSites, id: \.key) { site in
                        SiteRow(site: site)
                    }
                } else {
                    SearchSuggestionsView(onSelect: runKeywordSearch)
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .sheet(isPresented: $showRankingView) {
            DoubanRankingView { keyword in
                searchText = keyword
                performSearch()
            }
            .environmentObject(settings)
        }
    }

    private func performSearch() {
        searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            resetSearchState()
            return
        }
        isSearching = true
        isSearchLoading = true
        searchResults = []
        searchDebugLogs = []
        
        // 保存搜索历史
        if !searchHistory.contains(searchText) {
            searchHistory.insert(searchText, at: 0)
            if searchHistory.count > 10 {
                searchHistory.removeLast(searchHistory.count - 10)
            }
            cacheSearchHistory()
        }
        
        let keyword = searchText
        addSearchLog("🔍 开始搜索: \(keyword)")
        
        // 取消之前的搜索任务
        searchTask?.cancel()
        searchTask = Task {
            await self.spiderManager.searchStream(keyword: keyword, onBatch: { batch in
                if !batch.isEmpty {
                    Task { @MainActor in
                        self.searchResults.append(contentsOf: batch)
                        // 注意：isSearchLoading 在搜索完全结束后才设为 false，保持动画持续
                    }
                }
            }, onLog: { msg in
                self.addSearchLog(msg)
            })

            let totalCount = self.searchResults.count
            let sourceCount = Set(self.searchResults.compactMap { $0.vodRemarks }).count
            self.addSearchLog("✅ 搜索结束: 共\(totalCount)条/\(sourceCount)个源")
            await MainActor.run { self.isSearchLoading = false }
        }
    }
    
    private func addSearchLog(_ msg: String) {
        Task { @MainActor in
            searchDebugLogs.append(msg)
            if searchDebugLogs.count > 500 { searchDebugLogs.removeFirst(searchDebugLogs.count - 500) }
        }
    }

    private func runKeywordSearch(_ keyword: String) {
        searchText = keyword
        performSearch()
    }

    private func runTriggeredSearch() {
        let query = settings.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchText = query
        performSearch()
    }

    private func resetSearchState() {
        settings.searchQuery = ""
        isSearching = false
        isSearchLoading = false
        searchResults = []
    }
    
    private func loadSearchHistory() {
        if let saved = UserDefaults.standard.stringArray(forKey: "searchHistory"), !saved.isEmpty {
            searchHistory = saved
        }
    }
    
    private func cacheSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: "searchHistory")
    }
    
    @MainActor
    private func loadDoubanData(force: Bool = false) async {
        doubanLoading = true
        let tabName = doubanTabs[selectedDoubanTab]
        if !force, let existing = doubanSubjects[tabName], !existing.isEmpty {
            doubanLoading = false
            return
        }
        
        do {
            let subjects = try await DoubanService.shared.fetchByTab(tabName, start: 0, count: 20)
            doubanSubjects[tabName] = subjects
            doubanLoading = false
        } catch {
            print("Douban fetch error: \(error)")
            doubanLoading = false
        }
    }
}

// MARK: - 搜索栏组件
struct SearchBar: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    var onSearch: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(Color.gray)
                TextField("搜索视频、剧集...", text: $searchText).foregroundColor(.primary).onSubmit { performSearch() }
                if !searchText.isEmpty {
                    Button(action: { searchText = ""; isSearching = false }) { Image(systemName: "xmark.circle.fill").foregroundColor(Color.gray) }
                    .buttonStyle(.plain)
                }
            }.padding(.horizontal, 14).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.gray.opacity(0.1))).overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            if isSearching { Button("取消") { searchText = ""; isSearching = false; UIApplication.shared.endEditing() }.foregroundColor(Color(hex: "E11D48")).buttonStyle(.plain) }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Color(uiColor: .systemBackground))
    }
    private func performSearch() { guard !searchText.isEmpty else { return }; onSearch?() }
}

struct SearchSuggestionsView: View {
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Color(uiColor: .systemBackground)
    }
}

struct KeywordButton: View {
    let keyword: String
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Button(action: { onSelect(keyword) }) { Text(keyword).font(.system(size: 14)).foregroundColor(.primary).padding(.horizontal, 16).padding(.vertical, 8).background(Capsule().fill(Color.gray.opacity(0.1))).overlay(Capsule().stroke(Color.gray.opacity(0.3), lineWidth: 1)) }.buttonStyle(PlainButtonStyle())
    }
}

struct RecentSearchRow: View {
    let keyword: String
    var onSelect: (String) -> Void = { _ in }
    var body: some View {
        Button(action: { onSelect(keyword) }) {
        HStack {
            Text(keyword).font(.system(size: 15)).foregroundColor(.primary)
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Color.gray)
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchHistoryChip: View {
    let keyword: String
    let onSelect: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "E11D48"))
                Text(keyword)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.gray.opacity(0.08)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchHistoryDeleteButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(Color.gray)
        }
        .padding(.vertical, 12)
    }
}

struct SearchResultsView: View {
    let results: [VodItem]
    let searchText: String
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedSource: String? = nil
    @State private var selectedVideo: VodItem? = nil

    /// 按源分组（规范化源名称避免重复分组）
    /// 排序三级优先级：
    ///   1. 网盘资源（vodRemarks 带 ☁️，非 JS 蜘蛛）— engineKey == nil
    ///   2. JS 蜘蛛网盘资源（vodRemarks 带 ☁️，JS 蜘蛛）— engineKey != nil
    ///   3. 切片/站源/JS普通蜘蛛（vodRemarks 无 ☁️）
    ///   同级内按结果数量降序
    private var grouped: [(source: String, videos: [VodItem])] {
        var dict: [String: [VodItem]] = [:]
        for video in results {
            let rawSource = video.vodRemarks?.isEmpty == false ? video.vodRemarks ?? "" : "搜索结果"
            let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if dict[source] == nil { dict[source] = [] }
            dict[source]?.append(video)
        }
        /// 计算来源的排序层级：1=网盘原生, 2=JS蜘蛛网盘, 3=其他
        func sourceTier(_ source: String, videos: [VodItem]) -> Int {
            let isCloud = source.hasPrefix("☁️")
            let isJSSpider = videos.contains { $0.engineKey != nil }
            if isCloud && !isJSSpider { return 1 }
            if isCloud && isJSSpider { return 2 }
            return 3
        }
        return dict.map { (source: $0.key, videos: $0.value) }.sorted {
            let aTier = sourceTier($0.source, videos: $0.videos)
            let bTier = sourceTier($1.source, videos: $1.videos)
            if aTier != bTier { return aTier < bTier }
            return $0.videos.count > $1.videos.count
        }
    }

    private var sources: [String] { grouped.map { $0.source } }

    /// 当前选中源的结果，按剧名排序（让同一部剧挨在一起）
    private var currentVideos: [VodItem] {
        let sel = selectedSource ?? sources.first ?? ""
        let videos = grouped.first(where: { $0.source == sel })?.videos ?? []
        // 按剧名字母顺序排序，让同一部剧的不同集/版本挨在一起
        return videos.sorted {
            $0.vodName.localizedCompare($1.vodName) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if grouped.count <= 1 {
                singleColumnList(results)
            } else {
                multiColumnList()
            }
        }
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video, searchKeyword: searchText)
        }
    }

    private func singleColumnList(_ items: [VodItem]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    SearchResultRow(video: item)
                        .onTapGesture { selectedVideo = item }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(searchPanelBackground)
    }

    private func multiColumnList() -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // 左侧：资源站列表
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(sources, id: \.self) { name in
                            let sel = (selectedSource ?? sources.first ?? "") == name
                            Button(action: { selectedSource = name }) {
                                SourceNameLabel(name: name, isSelected: sel)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 7)
                                    .background(sel ? Color(hex: "E11D48") : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 6)
                }
                .frame(width: min(108, max(98, geometry.size.width * 0.23)))
                .background(searchPanelBackground)

                Divider().background(settings.usesVisualSkin ? Color.white.opacity(0.22) : Color.gray.opacity(0.3))

                // 右侧：该资源站的结果（按剧名排序）
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        ForEach(currentVideos) { item in
                            SearchResultRow(video: item).onTapGesture { selectedVideo = item }
                        }
                    }
                    .padding(12)
                }
                .background(searchPanelBackground)
            }
        }
        .onAppear { if selectedSource == nil { selectedSource = sources.first } }
    }

    private var searchPanelBackground: Color {
        settings.usesVisualSkin ? Color.black.opacity(settings.usesLiquidSkin ? 0.18 : 0.08) : Color(uiColor: .systemBackground)
    }
}

struct VideoNameLabel: View {
    let name: String
    let sourceCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 2)

            // 源数量角标
            Text("\(sourceCount)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? Color(hex: "E11D48") : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white.opacity(0.9) : Color.gray.opacity(0.35))
                )
        }
    }
}

struct SourceNameLabel: View {
    let name: String
    let isSelected: Bool

    private var hasCloudIcon: Bool {
        name.contains("☁️")
    }

    private var cleanName: String {
        name.replacingOccurrences(of: "☁️", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if hasCloudIcon {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? .white : Color.gray.opacity(0.45))
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 14)

            Text(cleanName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .multilineTextAlignment(.leading)
        }
    }
}

struct SearchResultRow: View {
    let video: VodItem
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            // 封面图
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in switch phase { case .success(let image): image.resizable().aspectRatio(contentMode: .fill); case .failure(_): ZStack { Rectangle().fill(Color.gray.opacity(0.15)); VStack { Image(systemName: "film").font(.title2).foregroundColor(.gray); Text("加载失败").font(.caption2).foregroundColor(.gray) } }; case .empty: ZStack { Rectangle().fill(Color.gray.opacity(0.1)); ProgressView() }; @unknown default: Rectangle().fill(Color.gray.opacity(0.15)) } }
                .frame(width: 85, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(video.vodName).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(2)
                HStack(spacing: 5) {
                    if let y = video.vodYear, !y.isEmpty { PlainTagBadge(text: y) }
                    if let a = video.vodArea, !a.isEmpty { PlainTagBadge(text: a) }
                }
                if let d = video.vodDirector, !d.isEmpty { Text("导演: \(d)").font(.system(size: 11)).foregroundColor(.gray).lineLimit(1) }
                if let a = video.vodActor, !a.isEmpty { Text("主演: \(a)").font(.system(size: 11)).foregroundColor(.gray).lineLimit(1) }

                Spacer(minLength: 0)

                // 资源站名称放在信息区底部居中
                if let r = video.vodRemarks, !r.isEmpty {
                    HStack {
                        Spacer()
                        SourceTagBadge(text: r)
                        Spacer()
                    }
                }
            }
            .frame(minHeight: 110, alignment: .top)
            Spacer()
            Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Color(hex: "E11D48"))
        }.padding(10).background(rowBackground).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var rowBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.28) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.58) }
        return Color.gray.opacity(0.05)
    }
}

struct TagBadge: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.gray.opacity(0.15)).clipShape(Capsule()) }
}

struct PlainTagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.gray)
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
    }
}

struct SourceTagBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(hex: "E11D48"))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: "E11D48").opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - 豆瓣卡片组件
struct SearchDoubanCardItem: View {
    let subject: DoubanSubject
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: subject.coverImageURL)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.15))
                }
                .frame(width: 70, height: 95)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)

                    if let rating = subject.rating, let value = rating.value {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", value))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }

                    Text(subject.card_subtitle ?? subject.genreText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)

                    Text("点击搜索 “\(subject.title)”")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "E11D48"))
                }

                Spacer()
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "E11D48"))
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct DoubanCardItem: View {
    let subject: DoubanSubject
    
    var body: some View {
        NavigationLink(destination: VideoDetailView(
            video: DoubanService.shared.toVodItem(subject: subject)
        )) {
            HStack(spacing: 12) {
                // 封面图
                AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: subject.coverImageURL)) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.gray.opacity(0.15))
                }
                .frame(width: 70, height: 95)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.gray.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
                
                // 信息
                VStack(alignment: .leading, spacing: 6) {
                    Text(subject.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    // 评分
                    if let rating = subject.rating, let value = rating.value {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", value))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }
                    
                    // 副标题/简介
                    Text(subject.card_subtitle ?? subject.genreText ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    
                    // 标签
                    HStack(spacing: 4) {
                        if let year = subject.year, !year.isEmpty {
                            Text(year)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.gray.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        if let genres = subject.genres, !genres.isEmpty {
                            Text(genres.prefix(2).joined(separator: " "))
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: "E11D48").opacity(0.1))
                                .foregroundColor(Color(hex: "E11D48"))
                                .clipShape(Capsule())
                        }
                    }
                }
                
                Spacer()
            }
            .padding(8)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 豆瓣骨架屏
struct DoubanSkeletonCardItem: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: 70, height: 95)
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 120, height: 14)
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 10)
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 60, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// ⚠️ 废弃：旧版分类视图，已被 CategoryTilesView 取代，不再使用
struct CategoryView: View {
    @EnvironmentObject private var settings: AppSettings
    private let categories = [
        (name: "电影", icon: "film.fill", type: "movie"),
        (name: "电视剧", icon: "tv.fill", type: "tv"),
        (name: "综艺", icon: "mic.fill", type: "variety"),
        (name: "动漫", icon: "sparkles", type: "animation"),
        (name: "纪录片", icon: "book.fill", type: "documentary"),
        (name: "直播", icon: "dot.radiowaves.left.and.right", type: "live"),
        (name: "音乐", icon: "music.note", type: "music"),
        (name: "体育", icon: "sportscourt.fill", type: "sports")
    ]
    
    @State private var selectedCategory: (name: String, type: String)?
    @State private var showCategorySheet = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 16
            ) {
                ForEach(categories, id: \.name) { category in
                    CategoryCard(name: category.name, icon: category.icon, onTap: {
                        selectedCategory = (name: category.name, type: category.type)
                        showCategorySheet = true
                    })
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .sheet(isPresented: $showCategorySheet) {
            if let category = selectedCategory {
                CategoryDetailView(categoryType: category.type, categoryName: category.name)
            }
        }
    }
}

// ⚠️ 废弃：仅被废弃的 CategoryView 引用，不再使用
struct CategoryCard: View {
    let name: String
    let icon: String
    let onTap: () -> Void
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                ZStack {
                    // 液态背景
                    LiquidBackground()
                        .frame(width: 60, height: 60)
                        .blur(radius: 10)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 60, height: 60)

                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(uiColor: .systemBackground).opacity(0.1),
                                Color(uiColor: .systemBackground).opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var cardBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.30) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.62) }
        return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8)
    }
}

// ⚠️ 废弃：无任何引用，不再使用
struct UserInfoSection: View {
    var body: some View {
        VStack(spacing: 16) {
            // 头像（无背景框，仅图标）
            Image(systemName: "person.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(Color(hex: "E11D48"))

            Text("访客用户")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.primary)

            Text("登录后同步收藏和历史记录")
                .font(.system(size: 13))
                .foregroundColor(Color.secondary)

            // 登录按钮
            Button(action: {}) {
                Text("立即登录")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .padding(.horizontal, 40)
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
    }
}

// ⚠️ 废弃：无任何引用，不再使用
struct ProfileMenuItem: View {
    let icon: String
    let title: String
    let badge: String?

    init(icon: String, title: String, badge: String? = nil) {
        self.icon = icon
        self.title = title
        self.badge = badge
    }

    var body: some View {
        Button(action: {}) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "E11D48"))
                    .frame(width: 32)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color(hex: "E11D48"))
                        )
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Color.primary.opacity(0.05)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}


// MARK: - 数据模型
// Mock数据
let mockVideos: [VodItem] = [
    VodItem(vodId: "test_001", vodName: "三体", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_002", vodName: "狂飙", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_003", vodName: "庆余年", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_004", vodName: "繁花", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_005", vodName: "肖申克的救赎", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_006", vodName: "黑袍纠察队", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_007", vodName: "权力的游戏", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_008", vodName: "绝命毒师", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_009", vodName: "复仇者联盟", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_010", vodName: "泰坦尼克号", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_011", vodName: "盗梦空间", vodPic: "https://via.placeholder.com/300x200"),
    VodItem(vodId: "test_012", vodName: "星际穿越", vodPic: "https://via.placeholder.com/300x200"),
]

// MARK: - 站点行组件
struct SiteRow: View {
    let site: SiteConfig

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(site.name).font(.system(size: 14, weight: .medium)).foregroundColor(.primary)
                Text(site.key).font(.system(size: 11)).foregroundColor(.gray)
            }
            Spacer()
            Text(site.type == 3 ? "JS" : "API").font(.system(size: 10)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(hex: "E11D48")).cornerRadius(4)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.gray.opacity(0.08))
    }
}

// MARK: - 流式布局
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: height > 0 ? height : 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for subview in row.subviews {
                subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += subview.dimensions(in: .unspecified).width + spacing
            }
            y += row.height + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        var currentX: CGFloat = 0
        let maxWidth = proposal.width ?? 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, !currentRow.subviews.isEmpty {
                rows.append(currentRow)
                currentRow = Row()
                currentX = 0
            }
            currentRow.subviews.append(subview)
            currentX += size.width + spacing
        }
        if !currentRow.subviews.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    private struct Row {
        var subviews: [LayoutSubviews.Element] = []
        var height: CGFloat {
            subviews.map { $0.dimensions(in: .unspecified).height }.max() ?? 0
        }
    }
}

// MARK: - 首页选源弹窗：单行跑马灯文本（超长名称自动横向滚动，避免换行破坏列表美观）

private struct HomeSourceMarqueeText: View {
    let text: String
    var fontSize: CGFloat = 14
    var weight: Font.Weight = .regular
    var color: Color = .primary

    private let pause: Double = 0.9
    private let gap: CGFloat = 48
    private let speed: CGFloat = 38

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    private var totalDistance: CGFloat { textWidth + gap }
    private var duration: Double { Double(totalDistance) / Double(speed) }

    private var shouldScroll: Bool {
        containerWidth > 0 && textWidth > containerWidth - 2
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(HomeMarqueeSizeReader { w in
                        textWidth = w
                    })

                if shouldScroll {
                    Text(text)
                        .font(.system(size: fontSize, weight: weight))
                        .foregroundColor(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: textWidth + gap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .offset(x: animate ? -totalDistance : 0)
            .onAppear {
                let cw = geo.size.width
                containerWidth = cw
                syncAnimation(cw: cw)
            }
            .onChange(of: geo.size.width) { newCW in
                containerWidth = newCW
                syncAnimation(cw: newCW)
            }
            .onChange(of: textWidth) { _ in
                syncAnimation(cw: geo.size.width)
            }
        }
        .frame(height: 20)
    }

    private func syncAnimation(cw: CGFloat) {
        containerWidth = cw
        guard shouldScroll else {
            animate = false
            return
        }
        animate = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            guard shouldScroll else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

private struct HomeMarqueeSizeReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { onChange(g.size.width) }
                .onChange(of: g.size.width) { _ in onChange(g.size.width) }
        }
    }
}

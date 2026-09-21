import SwiftUI

// MARK: - 多源发现页

struct SourceDiscoveryView: View {
    @EnvironmentObject private var settings: AppSettings

    let source: SourceDisplayItem
    @Binding var selectedSource: SourceDisplayItem?
    let onDismiss: () -> Void

    @State private var homeData: SourceHomeData?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedCategoryId: String?
    @State private var categoryVideos: [VodItem] = []
    @State private var isLoadingCategory = false
    @State private var showSourceDropdown = false
    @State private var allSources: [SourceDisplayItem] = []

    // 分页状态
    @State private var currentPage = 1
    @State private var isLoadingMore = false
    @State private var hasMorePages = true
    @State private var hasInitialCategoryLoad = false  // 防止 onAppear 首次渲染时立即触发加载更多

    // 自适应筛选状态
    @State private var filterOptions = SpiderManager.AdaptiveFilterOptions()
    @State private var selectedClass = "全部"
    @State private var selectedArea = "全部"
    @State private var selectedYear = "全部"
    @State private var selectedSort = "全部"

    private var displayCategories: [VodCategory] {
        guard let data = homeData else { return [] }
        if data.categories.isEmpty, !data.recommended.isEmpty {
            return [VodCategory(typeId: "__all__", typeName: "全部")]
        }
        return data.categories
    }

    private var displayVideos: [VodItem] {
        if selectedCategoryId != nil {
            return categoryVideos  // 选中分类时始终显示分类数据，即使为空也不回退到首页
        }
        return homeData?.recommended ?? []
    }

    /// 是否显示筛选栏（选中具体分类即显示，排序选项始终可用）
    private var shouldShowFilterBar: Bool {
        selectedCategoryId != nil && selectedCategoryId != "__all__"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // 顶部栏
                topBar

                if isLoading {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("正在加载 \(source.name)...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if let error = loadError, homeData == nil {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Button("重试") {
                            Task { await loadData() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            // 分类标签（左右滑动）
                            if !displayCategories.isEmpty {
                                categoryScrollBar
                            }

                            // 自适应筛选栏
                            if shouldShowFilterBar {
                                adaptiveFilterBar
                                    .padding(.bottom, 8)
                            }

                            // 内容网格
                            if displayVideos.isEmpty {
                                if isLoadingCategory {
                                    ProgressView()
                                        .padding(.vertical, 40)
                                } else {
                                    VStack(spacing: 12) {
                                        Image(systemName: "tray")
                                            .font(.system(size: 36))
                                            .foregroundColor(.secondary)
                                        Text(selectedCategoryId != nil ? "该分类暂无数据" : "暂无推荐内容")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                        Text("可前往搜索获取更多资源")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 80)
                                }
                            } else {
                                if isLoadingCategory {
                                    ProgressView()
                                        .padding(.vertical, 40)
                                }
                                videoGrid

                                // 加载更多
                                if selectedCategoryId != nil && selectedCategoryId != "__all__" && hasMorePages {
                                    loadMoreFooter
                                }
                            }
                        }
                        .padding(.bottom, 100)
                    }
                    .refreshable {
                        await refreshContent()
                    }
                }
            }
            .background(skinBackground)
            .navigationBarHidden(true)
            .edgeSwipeBack { onDismiss() }
            .onAppear {
                if allSources.isEmpty {
                    allSources = SpiderManager.shared.fetchAllSourceDisplayItems()
                }
                if homeData == nil { Task { await loadData() } }
            }
            .onDisappear {
                // 底栏状态由 HomeView.onChange(of: selectedSource) 统一控制
                // 通过 withAnimation 协调 overlay 移除和底栏恢复的动画
            }
            .onChange(of: source.id) { _ in
                // 切换源时重置状态并重新加载
                selectedCategoryId = nil
                categoryVideos = []
                homeData = nil
                loadError = nil
                currentPage = 1
                hasMorePages = true
                hasInitialCategoryLoad = false
                resetFilters()
                Task { await loadData() }
            }
            .onChange(of: selectedCategoryId) { newValue in
                // 关键修复：通过 onChange 驱动分类数据加载，避免 onTapGesture 中 Task 因视图重建丢失
                currentPage = 1
                hasMorePages = true
                hasInitialCategoryLoad = false
                if let catId = newValue {
                    if catId == "__all__" {
                        categoryVideos = []
                    } else {
                        categoryVideos = []
                        isLoadingCategory = true
                        Task { await loadCategoryContent(catId: catId) }
                    }
                }
            }

            // 左上角小竖长条选源浮层
            if showSourceDropdown {
                sourceDropdownOverlay
            }
        }
    }

    // MARK: - 左上角小竖长条选源浮层

    private var sourceDropdownOverlay: some View {
        ZStack {
            // 半透明背景，点击关闭
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture { showSourceDropdown = false }
        }
        .overlay(alignment: .topLeading) {
            // 小竖长条列表，对齐左上角
            VStack(spacing: 0) {
                // 标题栏
                HStack(spacing: 4) {
                    Text("切换源")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(dropdownTextColor)
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
                    .background(dropdownDividerColor)

                // 源列表（按分类分组）
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedDropdownSources, id: \.key) { group in
                            // 分组标题
                            HStack(spacing: 4) {
                                Text(group.key)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(dropdownTextColor)
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
                            .background(dropdownSectionHeaderBg)

                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                                Button(action: {
                                    selectedSource = item
                                    showSourceDropdown = false
                                }) {
                                    HStack(spacing: 8) {
                                        if item.id == source.id {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(Color(hex: "E11B48"))
                                                .frame(width: 16)
                                        } else {
                                            Color.clear.frame(width: 16, height: 12)
                                        }
                                        SourceMarqueeText(
                                            text: item.name,
                                            fontSize: 14,
                                            weight: item.id == source.id ? .semibold : .regular,
                                            color: item.id == source.id ? Color(hex: "E11B48") : dropdownTextColor
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
                                        .background(dropdownDividerColor)
                                }
                            }
                        }
                    }
                }
            }
            .frame(width: screenWidth * 0.4,
                   maxHeight: screenHeight * 0.5)
            .background(dropdownBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.top, 52)
            .padding(.leading, 12)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
        .animation(.easeInOut(duration: 0.18), value: showSourceDropdown)
    }

    private var dropdownBackground: some View {
        if settings.skinMode == .liquid {
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

    private var dropdownSectionHeaderBg: some View {
        if settings.skinMode == .liquid {
            return AnyView(Color(hex: "1a1a2e").opacity(0.6))
        } else {
            return AnyView(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// 按分类分组，固定顺序：网盘 → API → 站源 → JS → 论坛
    private var groupedDropdownSources: [(key: String, items: [SourceDisplayItem])] {
        let grouped = Dictionary(grouping: allSources) { $0.category.displayName }
        let order = ["网盘", "API", "站源", "JS", "论坛"]
        return order.compactMap { key in
            if let items = grouped[key], !items.isEmpty {
                return (key, items)
            }
            return nil
        }
    }

    private var dropdownTextColor: Color {
        settings.skinMode == .liquid ? .white : .primary
    }

    private var dropdownDividerColor: Color {
        settings.skinMode == .liquid ? Color.white.opacity(0.1) : Color.gray.opacity(0.15)
    }

    private var screenWidth: CGFloat { UIScreen.main.bounds.width }
    private var screenHeight: CGFloat { UIScreen.main.bounds.height }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 10) {
            // 返回豆瓣
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button(action: { showSourceDropdown = true }) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 源类型标签
            Text(source.category.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(categoryBadgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(categoryBadgeColor.opacity(0.12))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 分类滑动栏

    private var categoryScrollBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 推荐（默认）
                    SourceCategoryChip(
                        name: "推荐",
                        isSelected: selectedCategoryId == nil
                    )
                    .onTapGesture {
                        selectedCategoryId = nil
                        categoryVideos = []
                        resetFilters()
                    }

                    ForEach(displayCategories) { cat in
                        SourceCategoryChip(
                            name: cat.typeName,
                            isSelected: selectedCategoryId == cat.typeId
                        )
                        .onTapGesture {
                            if selectedCategoryId != cat.typeId {
                                resetFilters()
                                selectedCategoryId = cat.typeId
                                // 数据加载由 onChange(of: selectedCategoryId) 驱动
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - 自适应筛选栏

    private var adaptiveFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // 类型
                if !filterOptions.class.isEmpty {
                    AdaptiveFilterChip(
                        title: "类型",
                        value: selectedClass,
                        hasSelection: selectedClass != "全部"
                    ) {
                        presentFilterPicker(
                            title: "选择类型",
                            options: filterOptions.class,
                            selection: $selectedClass
                        )
                    }
                }

                // 地区
                if !filterOptions.area.isEmpty {
                    AdaptiveFilterChip(
                        title: "地区",
                        value: selectedArea,
                        hasSelection: selectedArea != "全部"
                    ) {
                        presentFilterPicker(
                            title: "选择地区",
                            options: filterOptions.area,
                            selection: $selectedArea
                        )
                    }
                }

                // 年份
                if !filterOptions.year.isEmpty {
                    AdaptiveFilterChip(
                        title: "年份",
                        value: selectedYear,
                        hasSelection: selectedYear != "全部"
                    ) {
                        presentFilterPicker(
                            title: "选择年份",
                            options: filterOptions.year,
                            selection: $selectedYear
                        )
                    }
                }

                // 排序（始终显示）
                AdaptiveFilterChip(
                    title: "排序",
                    value: sortDisplayValue(selectedSort),
                    hasSelection: selectedSort != "全部"
                ) {
                    presentFilterPicker(
                        title: "排序方式",
                        options: filterOptions.sort,
                        selection: $selectedSort
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    /// 排序值的显示名称映射
    private func sortDisplayValue(_ value: String) -> String {
        switch value {
        case "全部": return "默认"
        case "hits": return "热播"
        case "addtime": return "最新"
        case "score": return "高分"
        case "rand": return "随机"
        default: return value
        }
    }

    /// 重置所有筛选条件
    private func resetFilters() {
        selectedClass = "全部"
        selectedArea = "全部"
        selectedYear = "全部"
        selectedSort = "全部"
        filterOptions = SpiderManager.AdaptiveFilterOptions()
    }

    /// 弹出筛选选择器
    private func presentFilterPicker(title: String, options: [String], selection: Binding<String>) {
        let vc = UIApplication.shared.windows.first?.rootViewController
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

        for opt in options {
            let displayTitle = (title == "排序方式") ? sortDisplayValue(opt) : opt
            let action = UIAlertAction(title: displayTitle, style: .default) { _ in
                if selection.wrappedValue != opt {
                    selection.wrappedValue = opt
                    // 触发重新加载
                    if let catId = selectedCategoryId {
                        Task { await reloadCategoryWithFilters(categoryId: catId) }
                    }
                }
            }
            if selection.wrappedValue == opt {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        vc?.present(alert, animated: true)
    }

    // MARK: - 视频网格

    private var videoGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 16
        ) {
            ForEach(displayVideos.indices, id: \.self) { index in
                let video = displayVideos[index]
                NavigationLink(destination: VideoDetailView(video: video, searchKeyword: video.vodName, isFromSourceDiscovery: true)) {
                    SourceVideoCard(
                        video: video,
                        referer: source.referer,
                        settings: settings,
                        fallDelay: Double(index % 3) * 0.12
                    )
                }
                .id("\(index)|\(video.discoveryStableId)")
                .buttonStyle(.plain)
                .onAppear {
                    // 只有初次分类加载完成后，且用户滚动到接近底部时才触发加载更多
                    if hasInitialCategoryLoad && index >= displayVideos.count - 4 && !isLoadingMore && hasMorePages {
                        Task { await loadMoreContent() }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 加载更多底部

    private var loadMoreFooter: some View {
        HStack {
            if isLoadingMore {
                ProgressView()
                    .scaleEffect(0.8)
                Text("加载中...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Button(action: {
                    Task { await loadMoreContent() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                        Text("加载更多")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: - 皮肤

    private var skinBackground: some View {
        Group {
            if settings.skinMode == .liquid {
                LinearGradient(
                    colors: [Color(hex: "1a1a2e"), Color(hex: "16213e"), Color(hex: "0f3460")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            } else {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
    }

    private var categoryBadgeColor: Color {
        switch source.category {
        case .cloudCMS, .cloudSPA: return Color(hex: "007AFF")
        case .cloudForum: return Color(hex: "FF9500")
        case .api: return Color(hex: "34C759")
        case .jsSpider: return Color(hex: "AF52DE")
        case .zhanyuan: return Color(hex: "FF3B30")
        case .music: return Color(hex: "FF2D92")
        }
    }

    // MARK: - 数据加载

    private func loadData() async {
        isLoading = true
        loadError = nil
        currentPage = 1
        hasMorePages = true
        if let data = await SpiderManager.shared.fetchHomeData(for: source) {
            homeData = data
        } else {
            loadError = "\(source.name) 暂无数据，请检查网络或切换其他源"
        }
        isLoading = false
    }

    /// 下拉刷新
    private func refreshContent() async {
        if let catId = selectedCategoryId, catId != "__all__" {
            // 刷新当前分类
            currentPage = 1
            hasMorePages = true
            isLoadingCategory = true
            let items = await SpiderManager.shared.fetchSingleSourceCategoryContent(
                source: source,
                categoryTypeId: catId,
                page: 1
            )
            categoryVideos = items
            filterOptions = SpiderManager.extractAdaptiveFilters(from: items)
            hasMorePages = !items.isEmpty
            hasInitialCategoryLoad = true  // 刷新完成后允许滚动触发加载更多
            isLoadingCategory = false
        } else {
            // 刷新首页推荐：不设置 isLoading = true，保持 ScrollView 可见
            loadError = nil
            currentPage = 1
            hasMorePages = true
            if let data = await SpiderManager.shared.fetchHomeData(for: source) {
                homeData = data
                loadError = nil
            } else {
                loadError = "\(source.name) 暂无数据，请检查网络或切换其他源"
            }
        }
    }

    /// 加载更多（分页）
    private func loadMoreContent() async {
        guard let catId = selectedCategoryId, catId != "__all__", !isLoadingMore, hasMorePages else { return }
        isLoadingMore = true
        let nextPage = currentPage + 1
        let items = await SpiderManager.shared.fetchSingleSourceCategoryContent(
            source: source,
            categoryTypeId: catId,
            page: nextPage
        )
        if items.isEmpty {
            hasMorePages = false
        } else {
            categoryVideos.append(contentsOf: items)
            currentPage = nextPage
        }
        isLoadingMore = false
    }

    private func loadCategoryContent(catId: String) async {
        currentPage = 1
        hasMorePages = true
        hasInitialCategoryLoad = false
        let items = await SpiderManager.shared.fetchSingleSourceCategoryContent(
            source: source,
            categoryTypeId: catId,
            page: 1
        )
        categoryVideos = items
        // 从数据中自适应提取筛选选项
        filterOptions = SpiderManager.extractAdaptiveFilters(from: items)
        hasMorePages = !items.isEmpty
        hasInitialCategoryLoad = true  // 标记初次加载完成，后续滚动才触发加载更多
        isLoadingCategory = false
    }

    private func loadCategoryContent(_ cat: VodCategory) async {
        await loadCategoryContent(catId: cat.typeId)
    }

    private func reloadCategoryWithFilters(categoryId: String) async {
        isLoadingCategory = true
        currentPage = 1
        hasMorePages = true
        var params = SpiderManager.CategoryFilterParams()
        params.class = selectedClass == "全部" ? nil : selectedClass
        params.area = selectedArea == "全部" ? nil : selectedArea
        params.year = selectedYear == "全部" ? nil : selectedYear
        params.sort = selectedSort == "全部" ? nil : selectedSort

        let items = await SpiderManager.shared.fetchSingleSourceCategoryContent(
            source: source,
            categoryTypeId: categoryId,
            page: 1,
            filters: params
        )
        categoryVideos = items
        hasMorePages = !items.isEmpty
        isLoadingCategory = false
    }
}

// MARK: - 分类标签

private struct SourceCategoryChip: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color(hex: "E11B48") : Color(uiColor: .systemGray6))
            )
    }
}

// MARK: - 自适应筛选胶囊按钮

private struct AdaptiveFilterChip: View {
    let title: String
    let value: String
    let hasSelection: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(hasSelection ? Color(hex: "E11B48") : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(hasSelection ? Color(hex: "E11B48").opacity(0.1) : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                Capsule()
                    .stroke(hasSelection ? Color(hex: "E11B48").opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 视频卡片

private struct SourceVideoCard: View {
    let video: VodItem
    let referer: String?
    let settings: AppSettings
    let fallDelay: Double  // 坠落延迟（同行卡片 1→2→3 顺序错开）

    // 坠落动效状态
    @State private var hasAppeared = false
    // 初始坠落距离（卡片从上方坠落进入）— 增大幅度让效果更明显
    private let fallDistance: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图 — 固定 2:3 比例
            ZStack(alignment: .bottomTrailing) {
                Color(uiColor: .systemGray6)
                    .overlay(
                        PlatformAsyncImage.sourceCover(video.vodPic, referer: referer)
                            .id("\(video.vodPic)|\(referer ?? "")")
                            .aspectRatio(2/3, contentMode: .fill)
                            .clipped()
                    )

                // 备注标签
                if let remarks = video.vodRemarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(4)
                        .padding(4)
                }
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipped()
            .cornerRadius(8)

            // 标题
            Text(video.vodName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(settings.skinMode == .liquid ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // 年份/地区
            if let year = video.vodYear, !year.isEmpty {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        // 坠落动效：整个卡片（封面图+标题+年份）从上方坠落进入
        .opacity(hasAppeared ? 1 : 0)
        .offset(y: hasAppeared ? 0 : -fallDistance)
        .zIndex(hasAppeared ? 0 : -1)
        .animation(.spring(response: 0.6, dampingFraction: 0.68), value: hasAppeared)
        .onAppear {
            guard !hasAppeared else { return }
            // 按 fallDelay 顺序触发：同行3个卡片依次坠落（1→2→3）
            DispatchQueue.main.asyncAfter(deadline: .now() + fallDelay) {
                hasAppeared = true
            }
        }
    }
}

private extension VodItem {
    var discoveryStableId: String {
        "\(vodId)|\(vodName)|\(vodPic)|\(vodRemarks ?? "")"
    }
}

// MARK: - 单行跑马灯文本（超长名称自动横向滚动，避免换行破坏列表美观）

private struct SourceMarqueeText: View {
    let text: String
    var fontSize: CGFloat = 14
    var weight: Font.Weight = .regular
    var color: Color = .primary

    /// 滚动停顿（秒）
    private let pause: Double = 0.9
    /// 首尾文本间距（无缝拼接）
    private let gap: CGFloat = 48
    /// 每周期速度（pt/s）
    private let speed: CGFloat = 38

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var animate = false

    private var totalDistance: CGFloat { textWidth + gap }
    private var duration: Double {
        let dist = Double(totalDistance)
        return dist / Double(speed)
    }

    /// 是否需要滚动（文本超过容器宽度）
    private var shouldScroll: Bool {
        containerWidth > 0 && textWidth > containerWidth - 2
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 第一份文本（测量宽度）
                Text(text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(MarqueeSizeReader { w in
                        textWidth = w
                    })

                // 第二份文本（用于无缝循环，仅超长时显示）
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
        // 重置进度后延迟开始滚动
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

/// 测量子视图尺寸并回调
private struct MarqueeSizeReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { onChange(g.size.width) }
                .onChange(of: g.size.width) { _ in onChange(g.size.width) }
        }
    }
}

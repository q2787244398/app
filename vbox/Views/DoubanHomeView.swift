import SwiftUI
import UIKit

// MARK: - ⚠️ 废弃视图（未被任何代码引用，实际首页使用 MainViews.swift 中的 HomeView）
// 保留此文件仅为参考，请勿在此文件中修改首页逻辑。
// 实际首页调用链：ContentView → HomeView → doubanHomeContent（MainViews.swift:328）
@available(*, deprecated, message: "废弃视图，实际首页使用 HomeView（MainViews.swift）。HorizontalSubjectRow / SubjectCard / BannerCarousel 等公共组件仍被 HomeView 复用。")
struct DoubanHomeView: View {
    @StateObject private var doubanService = DoubanService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoading = true
    // Banner 轮播
    @State private var bannerItems: [BannerItem] = []
    // 电影类
    @State private var showingMovies: [DoubanSubject] = []       // 影院热映
    @State private var latestMovies: [DoubanSubject] = []        // 最新电影
    @State private var hotMovies: [DoubanSubject] = []           // 热门电影
    @State private var movieWeekly: [DoubanSubject] = []         // 一周口碑榜
    @State private var top250: [DoubanSubject] = []              // TOP250
    // 剧集类
    @State private var hotTV: [DoubanSubject] = []               // 热门剧集
    @State private var chiTV: [DoubanSubject] = []               // 华语口碑剧集
    @State private var americanTV: [DoubanSubject] = []          // 值得看的英美剧
    @State private var koreanTV: [DoubanSubject] = []            // 热门韩剧
    @State private var japaneseTV: [DoubanSubject] = []          // 热门日剧
    @State private var hotAnimation: [DoubanSubject] = []        // 热门动漫
    // 综艺类
    @State private var hotVariety: [DoubanSubject] = []          // 热门综艺
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).padding(.top, 100)
                    }
                } else {
                    // 1. Banner 轮播
                    if !bannerItems.isEmpty {
                        BannerCarousel(items: bannerItems, currentIndex: $currentIndex, settings: settings)
                    }
                    CategoryTilesView(settings: settings)
                    // 2. 影院热映
                    if !showingMovies.isEmpty {
                        SectionHeader(title: "影院热映", icon: "film.fill")
                        HorizontalSubjectRow(subjects: showingMovies, settings: settings)
                    }
                    // 3. 最新电影
                    if !latestMovies.isEmpty {
                        SectionHeader(title: "最新电影", icon: "calendar")
                        HorizontalSubjectRow(subjects: latestMovies, settings: settings)
                    }
                    // 4. 热门电影
                    if !hotMovies.isEmpty {
                        SectionHeader(title: "热门电影", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotMovies, settings: settings)
                    }
                    // 5. 一周口碑榜
                    if !movieWeekly.isEmpty {
                        SectionHeader(title: "一周口碑榜", icon: "star.fill")
                        HorizontalSubjectRow(subjects: movieWeekly, settings: settings)
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
                    // 10. 热门韩剧
                    if !koreanTV.isEmpty {
                        SectionHeader(title: "热门韩剧", icon: "heart.fill")
                        HorizontalSubjectRow(subjects: koreanTV, settings: settings)
                    }
                    // 11. 热门日剧
                    if !japaneseTV.isEmpty {
                        SectionHeader(title: "热门日剧", icon: "leaf.fill")
                        HorizontalSubjectRow(subjects: japaneseTV, settings: settings)
                    }
                    // 12. 热门动漫
                    if !hotAnimation.isEmpty {
                        SectionHeader(title: "热门动漫", icon: "paintbrush.fill")
                        HorizontalSubjectRow(subjects: hotAnimation, settings: settings)
                    }
                    // 13. 热门综艺
                    if !hotVariety.isEmpty {
                        SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                        HorizontalSubjectRow(subjects: hotVariety, settings: settings)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onAppear { Task { await loadData() } }
        .onReceive(timer) { _ in
            guard !bannerItems.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                currentIndex = (currentIndex + 1) % min(8, bannerItems.count)
            }
        }
    }
    
    private func loadData() {
        isLoading = true
        Task {
            // 独立加载每个分类，一个失败不影响其他
            // Banner 轮播
            async let banner = fetchSafely { try await doubanService.fetchTop250(start: 0, count: 10) }
            // 电影类
            async let showing = fetchSafely { try await doubanService.fetchUpcomingCN(start: 0, count: 10) }
            async let latest = fetchSafely { try await doubanService.fetchLatestMovies(start: 0, count: 10) }
            async let movies = fetchSafely { try await doubanService.fetchHotMovies(start: 0, count: 10) }
            async let weekly = fetchSafely { try await doubanService.fetchMovieWeekly(start: 0, count: 10) }
            async let top = fetchSafely { try await doubanService.fetchTop250(start: 0, count: 10) }
            // 剧集类
            async let tv = fetchSafely { try await doubanService.fetchHotTV(start: 0, count: 10) }
            async let chi = fetchSafely { try await doubanService.fetchPopularChiTV(start: 0, count: 10) }
            async let american = fetchSafely { try await doubanService.fetchAmericanTV(start: 0, count: 10) }
            async let korean = fetchSafely { try await doubanService.fetchKoreanTV(start: 0, count: 10) }
            async let japanese = fetchSafely { try await doubanService.fetchJapaneseTV(start: 0, count: 10) }
            async let anim = fetchSafely { try await doubanService.fetchHotAnimation(start: 0, count: 10) }
            // 综艺类
            async let variety = fetchSafely { try await doubanService.fetchHotVariety(start: 0, count: 10) }

            bannerItems = await banner.map { BannerItem(from: $0) }
            showingMovies = await showing
            latestMovies = await latest
            hotMovies = await movies
            movieWeekly = await weekly
            top250 = await top
            hotTV = await tv
            chiTV = await chi
            americanTV = await american
            koreanTV = await korean
            japaneseTV = await japanese
            hotAnimation = await anim
            hotVariety = await variety

            isLoading = false
        }
    }

    private func fetchSafely(_ operation: @escaping () async throws -> [DoubanSubject]) async -> [DoubanSubject] {
        do {
            return try await operation()
        } catch {
            print("[DoubanHome] 加载失败: \(error)")
            return []
        }
    }
}

// MARK: - Banner轮播（横版海报版）
struct BannerCarousel: View {
    let items: [BannerItem]
    @Binding var currentIndex: Int
    let settings: AppSettings
    @State private var dragOffset: CGFloat = 0
    @State private var autoPlayTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let cardWidth = geo.size.width * 0.88
                let cardHeight: CGFloat = 200
                let spacing: CGFloat = 12
                let sideScale: CGFloat = 0.88
                let sideOpacity: CGFloat = 0.5

                ZStack {
                    ForEach(0..<min(8, items.count), id: \.self) { index in
                        let offset = CGFloat(index - currentIndex)
                        let isCurrent = index == currentIndex
                        let scale = isCurrent ? 1.0 : sideScale
                        let opacity = isCurrent ? 1.0 : sideOpacity
                        let xOffset = offset * (cardWidth + spacing) + dragOffset
                        let zIndex = isCurrent ? 1.0 : 0.0

                        BannerCard3D(item: items[index], settings: settings, cardWidth: cardWidth, cardHeight: cardHeight)
                            .scaleEffect(scale)
                            .opacity(opacity)
                            .offset(x: xOffset)
                            .zIndex(zIndex)
                            .animation(.easeOut(duration: 0.35), value: currentIndex)
                            .animation(.easeOut(duration: 0.2), value: dragOffset)
                    }
                }
                .frame(width: geo.size.width, height: cardHeight)
                .contentShape(Rectangle())
                .onAppear {
                    startAutoPlay()
                    triggerPreload()
                }
                .onDisappear { stopAutoPlay() }
                .onChange(of: currentIndex) { _ in triggerPreload() }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            stopAutoPlay()
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let threshold: CGFloat = 50
                            if value.translation.width < -threshold {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    currentIndex = min(currentIndex + 1, min(8, items.count) - 1)
                                }
                            } else if value.translation.width > threshold {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    currentIndex = max(currentIndex - 1, 0)
                                }
                            }
                            dragOffset = 0
                            startAutoPlay()
                        }
                )
            }
            .frame(height: 200)

            HStack(spacing: 8) {
                ForEach(0..<min(8, items.count), id: \.self) { index in
                    Circle()
                        .fill(currentIndex == index ? Color(hex: "E11D48") : Color.gray.opacity(0.3))
                        .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// 预缓存当前项 + 后续 2 项的横版海报
    private func triggerPreload() {
        let urls = items.compactMap { $0.backdropURL }
        guard !urls.isEmpty else { return }
        ImagePreloader.shared.preloadBatch(urls: urls, currentIndex: currentIndex, lookahead: 2)
    }

    private func startAutoPlay() {
        stopAutoPlay()
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.35)) {
                if currentIndex < min(8, items.count) - 1 {
                    currentIndex += 1
                } else {
                    currentIndex = 0
                }
            }
        }
    }

    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
    }
}

// MARK: - Banner卡片（横版海报版）
struct BannerCard3D: View {
    let item: BannerItem
    let settings: AppSettings
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    @State private var retryCount: Int = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 图片层：固定 frame 确保布局一致，不随图片加载状态漂移
            imageLayer
                .frame(width: cardWidth, height: cardHeight)
                .clipped()

            // 底部渐变遮罩
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.4), Color.black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(width: cardWidth, height: cardHeight)

            // 左下角标题：固定 padding，始终位于卡片左下角
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.bottom, 12)
                .padding(.trailing, 12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .onTapGesture {
            settings.triggerSearch(item.title)
        }
    }

    @ViewBuilder
    private var imageLayer: some View {
        let imageURL = item.backdropURL ?? item.coverURL
        if let imageURL, !imageURL.isEmpty {
            // 优先使用预缓存的 UIImage（瞬时显示）
            if let cached = ImagePreloader.shared.cachedImage(for: imageURL) {
                Image(uiImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // 回退到 AsyncImage（首次加载或预缓存未命中时）
                // .id(retryCount) 确保失败重试时强制重新加载
                AsyncImage(url: DoubanImageProxyServer.shared.proxiedURL(for: imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        // 加载失败时自动重试（最多 3 次），解决代理服务器未就绪导致的首次加载失败
                        placeholderView(text: nil)
                            .onAppear {
                                if retryCount < 3 {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        retryCount += 1
                                    }
                                }
                            }
                    case .empty:
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.1))
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.gray)
                        }
                    @unknown default:
                        placeholderView(text: nil)
                    }
                }
                .id(retryCount)
            }
        } else {
            placeholderView(text: "暂无封面")
        }
    }

    private func placeholderView(text: String?) -> some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.15))
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 40))
                    .foregroundColor(.gray)
                if let text {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }
        }
    }
}



// MARK: - 分类磁贴
struct CategoryTilesView: View {
    let settings: AppSettings
    let categories = [
        ("movie", "🎬", "电影"), ("tv", "📺", "剧集"), ("variety", "🎭", "综艺"),
        ("top250", "🏆", "榜单"), ("animation", "🎨", "动漫"), ("hot", "🔥", "热门")
    ]
    @State private var selectedCategory: CategorySheetItem?
    @State private var activeType: String?

    struct CategorySheetItem: Identifiable {
        let id = UUID()
        let type: String
        let name: String
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories, id: \.0) { item in
                    CategoryTile(
                        icon: item.1,
                        title: item.2,
                        isSelected: activeType == item.0,
                        settings: settings
                    ) {
                        activeType = item.0
                        selectedCategory = CategorySheetItem(type: item.0, name: item.2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .sheet(item: $selectedCategory, onDismiss: {
            activeType = nil
        }) { category in
            CategoryDetailView(categoryType: category.type, categoryName: category.name)
                .environmentObject(settings)
        }
    }
}

struct CategoryTile: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let settings: AppSettings
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(icon).font(.system(size: 14))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? Color.white : Color.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isSelected ? Color(hex: "34C759") : tileBackground)
            )
            .overlay(
                Capsule().stroke(isSelected ? Color(hex: "34C759").opacity(0.7) : borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var borderColor: Color {
        settings.usesVisualSkin ? Color.white.opacity(0.2) : Color.gray.opacity(0.15)
    }

    private var tileBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.30) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.62) }
        return Color.gray.opacity(0.08)
    }
}

// MARK: - 横向主题行
struct HorizontalSubjectRow: View {
    let subjects: [DoubanSubject]
    let settings: AppSettings

    var body: some View {
        ScrollViewReader { _ in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                        SubjectCard(
                            subject: subject,
                            settings: settings,
                            fallDelay: Double(index) * 0.08
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - 主题卡片
struct SubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    let fallDelay: Double

    @State private var hasAppeared = false
    @State private var scaleAmount: CGFloat = 1.0
    @State private var isAtCenter = false

    private let fallDistance: CGFloat = 40
    // 震动反馈只触发一次
    private static let hapticGenerator = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let midX = geo.frame(in: .global).midX
            let screenMidX = UIScreen.main.bounds.width / 2
            let distance = abs(midX - screenMidX)

            // 距离越近缩放越大，范围 0.85 ~ 1.0
            let maxDist: CGFloat = 100
            let normalized = min(distance / maxDist, 1.0)
            let targetScale = 1.0 - normalized * 0.15

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    cardImage
                    ratingBadge
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(subject.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
            .scaleEffect(scaleAmount)
            .opacity(hasAppeared ? 1.0 : 0)
            .offset(y: hasAppeared ? 0 : -fallDistance)
            .animation(.spring(response: 0.6, dampingFraction: 0.68), value: hasAppeared)
            .contentShape(Rectangle())
            .onTapGesture {
                settings.triggerSearch(subject.title)
            }
            .onChange(of: targetScale) { newVal in
                withAnimation(.easeOut(duration: 0.15)) {
                    scaleAmount = newVal
                }
                // 卡片到达中心位置时触发震动
                let nowAtCenter = newVal > 0.97
                if nowAtCenter && !isAtCenter {
                    isAtCenter = true
                    SubjectCard.hapticGenerator.selectionChanged()
                } else if !nowAtCenter && isAtCenter {
                    isAtCenter = false
                }
            }
            .onAppear {
                scaleAmount = targetScale
            }
        }
        .frame(width: 120, height: 210, alignment: .topLeading)
        .onAppear {
            guard !hasAppeared else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + fallDelay) {
                hasAppeared = true
            }
        }
    }

    // MARK: - 封面图
    @ViewBuilder
    private var cardImage: some View {
        if let url = DoubanImageProxyServer.shared.proxiedURL(for: subject.coverImageURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 160)
                case .failure(_):
                    placeholderImage(icon: "photo", text: nil)
                case .empty:
                    ZStack {
                        Rectangle().fill(Color.gray.opacity(0.08))
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.gray)
                    }
                    .frame(width: 120, height: 160)
                @unknown default:
                    placeholderImage(icon: "photo", text: nil)
                }
            }
        } else {
            placeholderImage(icon: "photo", text: "暂无封面")
        }
    }

    // MARK: - 评分角标
    @ViewBuilder
    private var ratingBadge: some View {
        if subject.ratingValue > 0 {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.yellow)
                Text(String(format: "%.1f", subject.ratingValue))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.yellow)
            }
            .padding(4)
            .background(Color.black.opacity(0.5))
            .cornerRadius(4)
            .padding(4)
        }
    }

    // MARK: - 占位图
    @ViewBuilder
    private func placeholderImage(icon: String, text: String?) -> some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.1))
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.gray)
                if let text {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: 120, height: 160)
    }
}

//
//  RemoteWelfareHomeView.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：远程源福利专区首页，与现有 WelfareHomeView 并行存在。
//        - 顶部展示「使用福利远程源」Toggle（默认开），开启时才显示本 View
//        - 关闭时：调用方（ProfileView / ContentView）改用现有 WelfareHomeView
//        - 完全独立的数据源：从 WelfarePlatformConfigStore 拉平台列表
//        - 复用现有所有 Service / HomeView（通过 WelfarePlatformRouter 分发）
//        - 长按排序：使用 platformKey 持久化（与 name 索引并存，新用户用 platformKey）
//
//  使用：
//    if WelfarePlatformConfigStore.shared.switchEnabled {
//        RemoteWelfareHomeView()
//    } else {
//        WelfareHomeView()  // 旧版
//    }
//
//  修复记录：
//  - 修复1：编辑模式下图标区域滑动不灵敏 —— LongPressGesture 增加 maximumDistance: 15，
//    手指移动超过 15pt 则长按失败，ScrollView 滚动手势能正常接管
//  - 修复2：拖动卡片到边缘不自动滚动 —— 新增 AutoScrollTarget + ScrollViewDetector +
//    onEdgeProximity 回调，基于 CADisplayLink 实现平滑边缘自动滚动
//  - 修复3：震动功能无效 —— 将 UIImpactFeedbackGenerator 改为属性持有（避免临时实例被释放），
//    onAppear 时预先 prepare()，增加位置切换震动和结束震动
//

import SwiftUI
import UIKit
import Combine

struct RemoteWelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var configStore = WelfarePlatformConfigStore.shared
    @State private var selectedTab: RemoteWelfareCategory = .video
    @State private var isEditMode: Bool = false
    /// 排序后的平台列表（按 category 分别缓存）
    @State private var orderedPlatforms: [RemoteWelfareCategory: [WelfarePlatform]] = [:]
    @State private var navigatePlatformKey: String?

    // ===== 拖动排序边缘自动滚动 =====
    @State private var autoScrollDirection: CGFloat = 0 // -1 上 / 0 停 / 1 下
    @State private var autoScrollTimer: CADisplayLink?
    @State private var autoScrollTarget: AutoScrollTarget?
    @State private var scrollViewRef: UIScrollView?
    private let edgeThreshold: CGFloat = 100 // 距边缘多少 pt 触发自动滚动

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 1. Tab 切换栏
                tabBar

                // 2. 编辑模式提示
                if isEditMode {
                    editModeBar
                }

                // 3. 平台网格
                TabView(selection: $selectedTab) {
                    platformGrid(for: .video).tag(RemoteWelfareCategory.video)
                    platformGrid(for: .live).tag(RemoteWelfareCategory.live)
                    platformGrid(for: .comic).tag(RemoteWelfareCategory.comic)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(navigationProxy)
            .background(settings.usesVisualSkin ? Color.clear.ignoresSafeArea() : Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear {
                configStore.bootstrap()
                // 进入福利专区时，若启用了远程源，则重读本地最新配置（策略1 读本地文件，不联网）。
                // 开关关闭时不刷新，保证"清缓存 / 关开关后不显示远程平台"。
                if configStore.switchEnabled {
                    configStore.refresh()
                }
                loadOrder()
            }
        }
    }

    /// 统一隐藏跳转入口。
    /// 不把 NavigationLink 放进 LazyVGrid 单元，避免隐藏链接占用网格格子造成图标错位。
    private var navigationProxy: some View {
        NavigationLink(
            destination: Group {
                if let platform = navigationPlatform {
                    WelfarePlatformRouter.shared
                        .makeDestinationView(for: platform, settings: settings)
                        .environmentObject(settings)
                } else {
                    EmptyView()
                }
            },
            isActive: Binding(
                get: { navigatePlatformKey != nil },
                set: { active in
                    if !active { navigatePlatformKey = nil }
                }
            )
        ) {
            EmptyView()
        }
        .hidden()
    }

    private var navigationPlatform: WelfarePlatform? {
        for tab in RemoteWelfareCategory.allCases {
            if let platform = currentOrderedPlatforms(for: tab).first(where: { $0.platformKey == navigatePlatformKey }) {
                return platform
            }
        }
        return nil
    }

    // MARK: - Tab 切换栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RemoteWelfareCategory.allCases) { tab in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedTab = tab
                    }
                }) {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                            Text(tab.displayName)
                                .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                        }
                        .foregroundColor(selectedTab == tab
                                         ? .white
                                         : (settings.usesVisualSkin ? .white.opacity(0.6) : .primary.opacity(0.5))
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selectedTab == tab
                                  ? themeGradient(for: tab)
                                  : LinearGradient(colors: [Color.clear], startPoint: .leading, endPoint: .trailing))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 编辑模式提示

    private var editModeBar: some View {
        HStack {
            Text("长按卡片拖动排序，拖到边缘自动滚动").font(.system(size: 12)).foregroundColor(.secondary)
            Spacer()
            Button("完成") {
                withAnimation { isEditMode = false; saveOrder() }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    // MARK: - 平台网格

    private func platformGrid(for tab: RemoteWelfareCategory) -> some View {
        let platforms = currentOrderedPlatforms(for: tab)

        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                if platforms.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 60)
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("此分类下暂无平台")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                        spacing: 16
                    ) {
                        ForEach(Array(platforms.enumerated()), id: \.element.platformKey) { index, platform in
                            if isEditMode {
                                RemotePlatformSortableCard(
                                    platform: platform,
                                    index: index,
                                    totalCount: platforms.count,
                                    gradient: platformGradient(platform.name),
                                    onMove: { fromIdx, toIdx in
                                        movePlatform(from: fromIdx, to: toIdx, tab: tab)
                                    },
                                    onEdgeProximity: { direction in
                                        handleEdgeProximity(
                                            direction: direction,
                                            proxy: proxy
                                        )
                                    }
                                )
                                .id(platform.platformKey)
                            } else {
                                RemotePlatformIconCard(platform: platform, gradient: platformGradient(platform.name))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        navigatePlatformKey = platform.platformKey
                                    }
                                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 12) {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        navigatePlatformKey = nil
                                        withAnimation { isEditMode = true }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 100)
                    .background(
                        ScrollViewDetector { scrollView in
                            scrollViewRef = scrollView
                        }
                    )
                }
            }
            .onChange(of: isEditMode) { editing in
                if !editing {
                    stopAutoScroll()
                }
            }
        }
    }

    // MARK: - 边缘自动滚动逻辑

    private func handleEdgeProximity(
        direction: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard direction != 0 else {
            stopAutoScroll()
            return
        }

        // direction 同时表示方向和速度（-1.0 ~ 1.0，绝对值越大越快）
        // 方向改变或速度变化较大时，更新自动滚动
        let currentSpeed = abs(autoScrollDirection)
        let newSpeed = abs(direction)
        let directionChanged = (autoScrollDirection > 0) != (direction > 0)
        let speedChanged = abs(currentSpeed - newSpeed) > 0.2

        if directionChanged || autoScrollDirection == 0 {
            autoScrollDirection = direction
            startAutoScroll(direction: direction)
        } else if speedChanged {
            autoScrollDirection = direction
            updateAutoScrollSpeed(direction: direction)
        }
    }

    private func startAutoScroll(direction: CGFloat) {
        stopAutoScroll()

        // 基础速度 3pt/帧，乘以速度因子（0.3~1.0）
        let baseSpeed: CGFloat = 3.0
        let speedFactor = max(0.3, abs(direction))
        let actualSpeed = baseSpeed * speedFactor
        let actualDirection: CGFloat = direction > 0 ? 1 : -1

        autoScrollTarget = AutoScrollTarget(
            direction: actualDirection,
            speed: actualSpeed,
            scrollViewRef: scrollViewRef
        )
        autoScrollTimer = CADisplayLink(target: autoScrollTarget!, selector: #selector(AutoScrollTarget.tick(_:)))
        autoScrollTimer?.add(to: .main, forMode: .common)
    }

    private func updateAutoScrollSpeed(direction: CGFloat) {
        guard let target = autoScrollTarget else { return }
        let baseSpeed: CGFloat = 3.0
        let speedFactor = max(0.3, abs(direction))
        target.speed = baseSpeed * speedFactor
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    // MARK: - 排序与持久化

    /// 当前展示的平台（按用户排序后）
    private func currentOrderedPlatforms(for tab: RemoteWelfareCategory) -> [WelfarePlatform] {
        if let cached = orderedPlatforms[tab] {
            return cached
        }
        return configStore.platforms(in: tab)
    }

    /// 移动平台（编辑模式下拖拽）
    private func movePlatform(from fromIdx: Int, to toIdx: Int, tab: RemoteWelfareCategory) {
        var current = currentOrderedPlatforms(for: tab)
        guard fromIdx < current.count, toIdx < current.count else { return }
        let item = current.remove(at: fromIdx)
        current.insert(item, at: toIdx)
        orderedPlatforms[tab] = current
    }

    /// 排序结果保存到 UserDefaults（key: fuli_remote_platform_order_v2）
    /// 数据结构：[categoryKey: [platformKey, ...]]
    private func saveOrder() {
        var data: [String: [String]] = [:]
        for (cat, plats) in orderedPlatforms {
            data[cat.rawValue] = plats.map { $0.platformKey }
        }
        if let json = try? JSONSerialization.data(withJSONObject: data, options: []) {
            UserDefaults.standard.set(json, forKey: "fuli_remote_platform_order_v2")
        }
    }

    /// 加载排序
    private func loadOrder() {
        guard let json = UserDefaults.standard.data(forKey: "fuli_remote_platform_order_v2"),
              let dict = try? JSONSerialization.jsonObject(with: json) as? [String: [String]] else {
            return
        }
        for (key, order) in dict {
            guard let cat = RemoteWelfareCategory(rawValue: key) else { continue }
            let all = configStore.platforms(in: cat)
            let ordered = order.compactMap { pk in all.first { $0.platformKey == pk } }
            // 加上新增的（用户排序后远端新增的平台）
            let remaining = all.filter { p in !ordered.contains(where: { $0.platformKey == p.platformKey }) }
            orderedPlatforms[cat] = ordered + remaining
        }
    }

    // MARK: - 颜色（与现有 WelfareHomeView 保持一致的渐变色方案）

    private func themeGradient(for tab: RemoteWelfareCategory) -> LinearGradient {
        switch tab {
        case .video:
            return LinearGradient(
                colors: [Color(red: 1.0, green: 0.35, blue: 0.55), Color(red: 0.95, green: 0.20, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .live:
            return LinearGradient(
                colors: [Color(red: 0.40, green: 0.30, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .comic:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// 平台颜色（基于 platformKey hash 派生，确保每个平台颜色稳定）
    private func platformGradient(_ name: String) -> [Color] {
        // 与 WelfareHomeView 中 platformGradient 同样的 hash 派生
        let colors: [[Color]] = [
            [Color(red: 1.0, green: 0.35, blue: 0.55), Color(red: 0.95, green: 0.20, blue: 0.45)],
            [Color(red: 0.40, green: 0.30, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
            [Color(red: 0.20, green: 0.65, blue: 0.95), Color(red: 0.10, green: 0.45, blue: 0.85)],
            [Color(red: 1.0, green: 0.55, blue: 0.20), Color(red: 0.95, green: 0.40, blue: 0.10)],
            [Color(red: 0.30, green: 0.75, blue: 0.45), Color(red: 0.20, green: 0.60, blue: 0.35)],
            [Color(red: 0.85, green: 0.30, blue: 0.65), Color(red: 0.70, green: 0.20, blue: 0.50)],
            [Color(red: 0.40, green: 0.50, blue: 0.95), Color(red: 0.25, green: 0.35, blue: 0.85)],
            [Color(red: 1.0, green: 0.65, blue: 0.30), Color(red: 0.95, green: 0.50, blue: 0.15)],
        ]
        let hash = abs(name.hashValue) % colors.count
        return colors[hash]
    }
}

// MARK: - 子组件
// 注意：AutoScrollTarget / ScrollViewDetector / UIView.superview(ofType:)
// 已在 WelfareHomeView.swift 中定义，同一 module 内共享，此处不重复定义

/// 远程平台卡片（普通态，可点击跳转）
struct RemotePlatformIconCard: View {
    let platform: WelfarePlatform
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: platform.icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
            }
            .frame(width: 52, height: 52)
            .shadow(color: gradient.first?.opacity(0.3) ?? .clear, radius: 6, x: 0, y: 3)

            Text(platform.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(width: 72, height: 86)
    }
}

/// 远程平台卡片（编辑态，可拖拽排序）
///
/// 修复要点：
/// 1. LongPressGesture 设置 maximumDistance: 15 —— 手指移动超过 15pt 则长按手势失败，
///    ScrollView 的滚动手势能正常响应，解决"图标区域滑动不灵敏"问题
/// 2. 新增 onEdgeProximity 回调 —— 拖动到屏幕边缘时触发自动滚动
/// 3. UIImpactFeedbackGenerator 改为属性持有 + onAppear 时 prepare() —— 解决震动无效问题
/// 4. 三级震动反馈：拾取(light) → 位置切换(light intensity 0.6) → 结束(medium)
struct RemotePlatformSortableCard: View {
    let platform: WelfarePlatform
    let index: Int
    let totalCount: Int
    let gradient: [Color]
    let onMove: (Int, Int) -> Void
    var onEdgeProximity: ((CGFloat) -> Void)? = nil

    // 拖动状态
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var currentIndex: Int = 0
    @State private var cardGlobalY: CGFloat = 0

    // ===== 震动反馈 =====
    // 必须作为属性持有，不能在手势闭包里临时创建
    // 临时创建的 UIImpactFeedbackGenerator 实例会被立即释放，导致震动丢失
    private let lightFeedback = UIImpactFeedbackGenerator(style: .light)
    private let mediumFeedback = UIImpactFeedbackGenerator(style: .medium)

    // 布局常量
    private let columns = 4
    private let cardWidth: CGFloat = 88   // 72 + 16 spacing
    private let cardHeight: CGFloat = 102 // 86 + 16 spacing

    var body: some View {
        GeometryReader { geo in
            cardContent
                .frame(width: 72, height: 86)
                .offset(dragOffset)
                .scaleEffect(isDragging ? 1.15 : 1.0)
                .shadow(color: isDragging ? .black.opacity(0.3) : .clear,
                        radius: isDragging ? 10 : 0,
                        y: isDragging ? 5 : 0)
                .zIndex(isDragging ? 999 : 0)
                .onAppear {
                    cardGlobalY = geo.frame(in: .global).midY
                    // 预先准备震动发生器，确保第一次触发时能及时响应
                    // 这是震动能正常工作的关键 —— iOS 的 Taptic Engine 需要预热时间
                    lightFeedback.prepare()
                    mediumFeedback.prepare()
                }
                .gesture(
                    // 长按进入拖动模式
                    //
                    // 【关键修复】maximumDistance: 15
                    // 手指移动超过 15pt 则长按手势失败，ScrollView 的滚动手势能正常接管。
                    // 原来没有设置 maximumDistance，导致手指在图标上滑动时，
                    // 长按手势一直在"等待识别"，与 ScrollView 的滚动手势竞争，
                    // 表现为"图标区域滑动不灵敏 / 滑动失效"。
                    LongPressGesture(minimumDuration: 0.4, maximumDistance: 15)
                        .onEnded { _ in
                            // 再次 prepare，确保 Taptic Engine 处于激活状态
                            lightFeedback.prepare()
                            mediumFeedback.prepare()
                            lightFeedback.impactOccurred()
                            currentIndex = index
                            cardGlobalY = geo.frame(in: .global).midY
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isDragging = true
                            }
                        }
                        .sequenced(before:
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard isDragging else { return }
                                    dragOffset = value.translation
                                    handleDragChange(
                                        translation: value.translation,
                                        currentGlobalY: cardGlobalY + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    handleDragEnd()
                                }
                        )
                )
        }
        .frame(width: 72, height: 86)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }

    private var cardContent: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: platform.icon)
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                // 编辑模式右上角小提示
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.25)))
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(width: 52, height: 52)

            Text(platform.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private func handleDragChange(translation: CGSize, currentGlobalY: CGFloat) {
        let currentRow = currentIndex / columns
        let currentCol = currentIndex % columns

        let deltaRow = Int(round(translation.height / cardHeight))
        let deltaCol = Int(round(translation.width / cardWidth))

        var targetRow = currentRow + deltaRow
        var targetCol = currentCol + deltaCol

        targetCol = min(max(targetCol, 0), columns - 1)

        let totalRows = (totalCount + columns - 1) / columns
        targetRow = min(max(targetRow, 0), totalRows - 1)

        var targetIndex = targetRow * columns + targetCol
        targetIndex = min(max(targetIndex, 0), totalCount - 1)

        // 位置变化时触发轻震动（碰到卡片的手感）
        if targetIndex != currentIndex {
            lightFeedback.impactOccurred(intensity: 0.6)
            lightFeedback.prepare() // 每次触发后重新 prepare，保证下次及时响应
            onMove(currentIndex, targetIndex)
            currentIndex = targetIndex
        }

        // ===== 边缘自动滚动检测（基于屏幕坐标）=====
        if let edgeProximity = onEdgeProximity, isDragging {
            let screenHeight = UIScreen.main.bounds.height
            let edgeMargin: CGFloat = 100  // 距屏幕边缘多少 pt 触发

            let distanceFromTop = currentGlobalY
            let distanceFromBottom = screenHeight - currentGlobalY

            if distanceFromTop < edgeMargin {
                // 越靠近顶部，滚动越快（速度因子 0.3~1.0）
                let speedFactor = max(0.3, 1 - distanceFromTop / edgeMargin)
                edgeProximity(-speedFactor)  // 负值 = 向上滚动
            } else if distanceFromBottom < edgeMargin {
                let speedFactor = max(0.3, 1 - distanceFromBottom / edgeMargin)
                edgeProximity(speedFactor)   // 正值 = 向下滚动
            } else {
                edgeProximity(0) // 离开边缘区域，停止自动滚动
            }
        }
    }

    private func handleDragEnd() {
        // 停止边缘自动滚动
        onEdgeProximity?(0)

        // 拖动结束，中震动（落位的手感）
        mediumFeedback.impactOccurred()
        mediumFeedback.prepare()
        lightFeedback.prepare()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isDragging = false
            dragOffset = .zero
        }
    }
}

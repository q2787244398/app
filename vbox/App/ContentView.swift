import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @State private var selectedTab: Tab = .home
    @State private var showUpdateSheet: Bool = false
    @State private var showDownloadPopup: Bool = false
    @ObservedObject private var downloadManager = DownloadManager.shared

    // ---- 动态启动页：数据门控 + 10 秒兜底 ----
    @State private var showSplash: Bool = true
    @State private var splashAppearTime: Date = Date()
    @ObservedObject private var splashMonitor = SplashGateMonitor.shared
    private let splashMinHold: TimeInterval = 1.2   // 最短展示时长，避免一闪而过

    enum Tab: String, CaseIterable {
        case home = "首页"
        case search = "搜索"
        case shortDrama = "短剧"
        case live = "直播"
        case welfare = "福利"
        case profile = "我的"

        // 未选中空心图标
        var iconOutline: String {
            switch self {
            case .home: return "house"
            case .search: return "magnifyingglass"
            case .shortDrama: return "play.rectangle"
            case .live: return "antenna.radiowaves.left.and.right"
            case .welfare: return "gift"
            case .profile: return "person"
            }
        }

        // 选中实心图标
        var iconFill: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass.circle.fill"
            case .shortDrama: return "play.rectangle.fill"
            case .live: return "dot.radiowaves.left.and.right"
            case .welfare: return "gift.fill"
            case .profile: return "person.fill"
            }
        }
    }

    /// 动态可见 Tab 列表：福利未解锁时不显示福利 Tab
    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.home, .shortDrama, .live, .profile]
        if settings.welfareUnlocked && settings.welfareEnabled {
            tabs.insert(.welfare, at: 3)
        }
        return tabs
    }

    var body: some View {
        ZStack {
            if settings.usesLiquidSkin {
                AppLiquidBackground()
                    .ignoresSafeArea()
            } else if settings.usesFrostedSkin {
                AppFrostedBackground()
                    .ignoresSafeArea()
            } else {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
            }

            ZStack(alignment: .bottom) {
                // 页面内容区域，全屏无遮挡
                Group {
                    switch selectedTab {
                    case .home: HomeView()
                    case .search: SearchView()
                    case .shortDrama: ShortDramaView()
                    case .live: LiveTVView()
                    case .welfare: WelfareTabGateView()
                    case .profile: ProfileView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // 远程源状态通知条 + 下载胶囊通知 + 悬浮式底部导航栏
                VStack(spacing: 0) {
                    RemoteSourceStatusBar()
                    DownloadCapsuleNotification()

                    // 悬浮式底部导航栏
                    if !settings.isTabBarHidden {
                        HStack(spacing: 0) {
                            ForEach(visibleTabs, id: \.self) { tab in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedTab = tab
                                    }
                                } label: {
                                    VStack(spacing: 1) {
                                        Image(systemName: selectedTab == tab ? tab.iconFill : tab.iconOutline)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(selectedTab == tab ? activeTabColor : inactiveTabColor)

                                        Text(tab.rawValue)
                                            .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                                            .foregroundColor(selectedTab == tab ? activeTabColor : inactiveTabColor)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .frame(maxWidth: min(UIScreen.main.bounds.width - 140, CGFloat(visibleTabs.count * 56 + 28)))
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
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .environmentObject(settings)
        .preferredColorScheme(settings.preferredColorScheme)
        .tint(activeTabColor)
        // ★ 移除隐式 .animation() 修饰符，避免与 HomeView overlay 的 transition 动画冲突
        // 底栏动画现在由 withAnimation 显式驱动（HomeView.onChange(of: selectedSource) 和 onDismiss）
        .onChange(of: settings.searchRequestId) { _ in
            if !settings.searchQuery.isEmpty { selectedTab = .home }
        }
        .onAppear {
            // 记录启动页出现时间，用于最短展示时长与 10 秒兜底
            splashAppearTime = Date()
            // 更新检测与爬虫初始化并行执行，避免弹窗延迟
            Task {
                await SpiderManager.shared.initialize()
            }
            Task {
                await UpdateManager.shared.checkForUpdate()
                if UpdateManager.shared.hasUpdate {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showUpdateSheet = true
                        }
                    }
                }
            }
            // 10 秒兜底：首页数据迟迟未就绪时强制退出启动页，避免卡启动页
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    dismissSplashIfNeeded()
                }
            }
        }
        // 首页数据就绪：立即淡出启动页进入首页
        .onChange(of: splashMonitor.homeDataReady) { ready in
            if ready { dismissSplashIfNeeded() }
        }
        .overlay {
            if showUpdateSheet {
                UpdateSheet(isPresented: $showUpdateSheet)
                    .transition(.opacity)
                    .zIndex(10)
            } else if UpdateManager.shared.isMinimized {
                FloatingDownloadBubble(onTap: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        UpdateManager.shared.isMinimized = false
                    }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showUpdateSheet = true
                    }
                })
                .transition(.scale.combined(with: .opacity))
                .zIndex(9)
            }
        }
        // 下载管理悬浮弹窗
        .overlay {
            if showDownloadPopup {
                DownloadManagementPopup(isPresented: $showDownloadPopup)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        // 悬浮下载按键（不在弹窗显示时、未被手动隐藏时显示）
        .overlay {
            if !showDownloadPopup && !showUpdateSheet && !downloadManager.isFloatingButtonManuallyHidden {
                FloatingVideoDownloadButton(onTap: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showDownloadPopup = true
                    }
                })
                .zIndex(5)
            }
        }
        // 动态启动页覆盖层（最高层级，覆盖弹窗与底栏）
        .overlay {
            if showSplash {
                VboxSplashView()
                    .transition(.opacity)
                    .zIndex(30)
            }
        }
        .onChange(of: UpdateManager.shared.isMinimized) { _ in
            // 下载完成时自动弹出
            if UpdateManager.shared.isMinimized && !UpdateManager.shared.isDownloading {
                UpdateManager.shared.isMinimized = false
                withAnimation(.easeInOut(duration: 0.25)) {
                    showUpdateSheet = true
                }
            }
        }
    }

    /// 淡出启动页：同时满足"最短展示时长"与"数据就绪或 10 秒兜底"才执行
    private func dismissSplashIfNeeded() {
        guard showSplash,
              Date().timeIntervalSince(splashAppearTime) >= splashMinHold else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            showSplash = false
        }
    }

    private var activeTabColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var inactiveTabColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.72) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondaryLabel) }
        return Color(uiColor: .systemGray2)
    }

    private var tabBarBaseColor: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.34) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemBackground).opacity(0.62) }
        return Color(uiColor: .systemBackground).opacity(0.9)
    }

    private var tabBarStrokeColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.22) }
        if settings.usesFrostedSkin { return Color.white.opacity(0.34) }
        return Color(uiColor: .systemGray4)
    }
}

struct AppLiquidBackground: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "050816"),
                    Color(hex: "111827"),
                    Color(hex: "1E1B4B")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(hex: "22D3EE").opacity(0.34))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: phase ? 130 : -120, y: phase ? -240 : -160)

            Circle()
                .fill(Color(hex: "A855F7").opacity(0.42))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: phase ? -150 : 140, y: phase ? 120 : 260)

            Circle()
                .fill(Color(hex: "F43F5E").opacity(0.24))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: phase ? 90 : -80, y: phase ? 320 : 140)
        }
        .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

struct AppFrostedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(hex: "EEF2FF").opacity(0.55),
                    Color(hex: "FDF2F8").opacity(0.45)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(hex: "60A5FA").opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 74)
                .offset(x: -120, y: -190)

            Circle()
                .fill(Color(hex: "C084FC").opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 86)
                .offset(x: 150, y: 220)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.72)
        }
    }
}

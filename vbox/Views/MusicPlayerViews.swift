import SwiftUI
import AVFoundation

// MARK: - Mini Player 浮层
//
// 交互手势：
//   1. 左滑（水平向左）→ 显示"关闭"按钮，点它关闭并隐藏浮层；
//   2. 右滑（水平向右一段距离）→ 折叠到左侧屏幕边缘（收起为小胶囊）；
//   3. 上下拖动 → 在屏幕内自由移动（松手后吸附到 顶部↔底部 之间最近位置）。

struct MiniPlayerBar: View {
    @ObservedObject private var player = AudioPlayerManager.shared
    @StateObject private var settings = AppSettings()

    @State private var positionY: CGFloat = 0        // 垂直偏移（0=底部基准）
    @State private var isCollapsed: Bool = false     // 已折叠到左边缘
    @State private var isDragging: Bool = false
    @State private var dragOffset: CGSize = .zero    // 拖动过程中的临时增量
    @State private var showCloseButton: Bool = false // 左滑后显示关闭按钮

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    // 折叠时贴左的小胶囊宽度；展开时内容横条的期望宽度
    // 尺寸与布局常量
    private let barWidth: CGFloat = 320        // 展开态横条宽度
    private let collapsedWidth: CGFloat = 52   // 折叠态小胶囊宽度
    private let expandedHeight: CGFloat = 60   // 展开态高度
    private let collapsedHeight: CGFloat = 52  // 折叠态高度
    private let horizontalMargin: CGFloat = 12 // 左右留白
    private let bottomMargin: CGFloat = 66     // 底部基准留白（抬升到悬浮 tab 栏之上）
    private let topReserve: CGFloat = 100      // 顶部安全余量（状态栏等）

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Group 包裹迷你条与全屏呈现：让 .fullScreenCover(正在播放页) 不随
            // currentSong 的存亡而被移除, 保证任何播放状态下全屏页都能呈现/退出。
            Group {
            if let song = player.currentSong {
                let barHeight = (isCollapsed ? collapsedHeight : expandedHeight)
                let baseBottom = max(h - barHeight - bottomMargin, 0)
                // 拖动过程中的实时垂直偏移（跟随手指，y 为正表示向下）
                let liveUp = isDragging ? positionY - dragOffset.height : positionY
                // 关闭按钮的浮现程度：左滑时逐渐露出，松手/点按后收起
                let reveal: CGFloat = showCloseButton
                    ? 1
                    : (isDragging && dragOffset.width < 0 ? min(1, -dragOffset.width / 80) : 0)

                // 横条主体
                HStack(spacing: isCollapsed ? 0 : 12) {
                    if isCollapsed {
                        // 折叠态：贴左边缘的小胶囊，点击展开
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { isCollapsed = false }
                        } label: {
                            Group {
                                if let url = URL(string: song.coverURL) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(Color(.systemGray5))
                                            .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                                    }
                                } else {
                                    Rectangle().fill(Color(.systemGray5))
                                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                                }
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        // 展开态封面
                        Group {
                            if let url = URL(string: song.coverURL) {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(Color(.systemGray5))
                                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                                }
                            } else {
                                Rectangle().fill(Color(.systemGray5))
                                    .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        // 歌名 + 进度
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if player.duration > 0 {
                                ProgressView(value: player.currentTime, total: player.duration)
                                    .tint(accentColor)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // 播放/暂停
                        Button(action: { player.togglePlayPause() }) {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 30))
                                .foregroundColor(accentColor)
                        }
                        .buttonStyle(.plain)

                        // 下一首
                        Button(action: { player.playNext() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(player.queue.count <= 1)
                    }
                }
                // 关闭按钮浮现时在右侧预留空间，避免遮挡控制按钮
                .padding(.leading, isCollapsed ? 6 : 14)
                .padding(.trailing, (reveal > 0.1 && !isCollapsed) ? 36 : (isCollapsed ? 6 : 14))
                .padding(.vertical, isCollapsed ? 6 : 8)
                .background(
                    RoundedRectangle(cornerRadius: isCollapsed ? 22 : 12)
                        .fill(isCollapsed
                              ? AnyShapeStyle(Color(.systemBackground).opacity(0.92))
                              : AnyShapeStyle(.ultraThinMaterial))
                        .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                )
                .overlay(alignment: .trailing) {
                    // 左滑后浮现的关闭按钮（红色圆钮，点击关闭整个浮层）
                    Button {
                        closePlayer()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.red))
                    .shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
                    .offset(x: (1 - reveal) * 16)
                    .opacity(reveal)
                    .allowsHitTesting(reveal > 0.1)
                }
                .frame(width: isCollapsed ? collapsedWidth : barWidth, height: barHeight, alignment: .leading)
                .opacity(isDragging ? 0.95 : 1.0)
                // 自由定位：坐标原点在容器左上角。
                // x 展开时水平居中，折叠时贴左留 12；y 以底部为基准，向上随 positionY 自由移动。
                .offset(
                    x: (isCollapsed ? horizontalMargin : (w - barWidth) / 2),
                    y: baseBottom - liveUp
                )
                .highPriorityGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            isDragging = true
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            isDragging = false
                            finalizeDrag(drag: value, containerHeight: h)
                            dragOffset = .zero
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isCollapsed {
                                isCollapsed = false
                            } else if showCloseButton {
                                showCloseButton = false
                            } else {
                                player.showFullPlayer = true
                            }
                        }
                    }
                )
                .animation(.easeInOut(duration: 0.2), value: positionY)
                .animation(.easeInOut(duration: 0.25), value: isCollapsed)
                .animation(.easeInOut(duration: 0.15), value: reveal)
                .onAppear { player.saveQueue() }
                .onDisappear { player.saveQueue() }
            }
            }
            // 全屏"正在播放"页挂载到 Group 层：不依赖 currentSong 是否存在
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                MusicPlayerFullView()
            }
        }
    }

    private func finalizeDrag(drag: DragGesture.Value, containerHeight: CGFloat) {
        let dx = drag.translation.width
        let dy = drag.translation.height

        // 折叠态：仅允许上下移动位置，横向手势忽略（点击小胶囊展开）
        if isCollapsed {
            if abs(dy) > max(abs(dx), 20) {
                moveVertically(by: -dy, containerHeight: containerHeight)
            }
            return
        }

        // 横向手势优先判定
        if abs(dx) > abs(dy) {
            if dx < -50 {
                // 左滑 → 显示关闭按钮（再点红色圆钮即可关闭）
                withAnimation(.easeInOut(duration: 0.2)) { showCloseButton = true }
            } else if dx > 60 {
                // 右滑 → 折叠到左侧屏幕边缘
                withAnimation(.easeInOut(duration: 0.25)) {
                    showCloseButton = false
                    isCollapsed = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showCloseButton = false }
            }
            return
        }

        // 上下拖动 → 在 顶部↔底部 之间自由移动
        moveVertically(by: -dy, containerHeight: containerHeight)
    }

    private func moveVertically(by delta: CGFloat, containerHeight: CGFloat) {
        let barHeight = isCollapsed ? collapsedHeight : expandedHeight
        let maxUp = max(containerHeight - barHeight - bottomMargin - topReserve, 0)
        let newY = min(max(positionY + delta, 0), maxUp)
        withAnimation(.easeInOut(duration: 0.2)) {
            positionY = newY
            showCloseButton = false
        }
    }

    private func closePlayer() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCloseButton = false
            isCollapsed = false
            positionY = 0
        }
        player.stop()
    }
}

// MARK: - 全屏播放器

struct MusicPlayerFullView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = AudioPlayerManager.shared
    @StateObject private var settings = AppSettings()
    @State private var seekValue: Double = 0
    @State private var isSeeking: Bool = false
    @State private var showQueue: Bool = false
    // P3-C2：歌词状态（仅 lx 完整型插件如刀源能取到，念心留空隐藏）
    @State private var lyricLines: [(TimeInterval, String)] = []
    @State private var isLyricLoading = false
    // P3-C1：音质切换中状态
    @State private var isSwitchingQuality = false
    // 歌词/封面切换：true 时歌词主导（大区滚动歌词），false 时封面主导 + 下方小歌词
    @State private var showLyrics = false

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 背景：永远先铺一层深色渐变兜底，保证封面加载失败/无歌时
            // 白色顶栏（退出箭头/标题）与控制按钮始终清晰可见。
            // 修复 P1-A9：之前只在 coverURL 为空时走渐变，
            // 只要 coverURL 字符串非空（即使图加载失败）就进 AsyncImage 分支，
            // placeholder 是 .systemBackground(白) + 40% 黑叠层 = 浅灰，
            // 白 chevron.down 在浅灰上对比度极低，看起来像"没有退出键"。
            LinearGradient(
                colors: [accentColor.opacity(0.92), accentColor.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 封面图（加载成功才显示，失败时完全不遮挡渐变底）
            if let song = player.currentSong, let url = URL(string: song.coverURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                            .ignoresSafeArea()
                            .overlay(Color.black.opacity(0.4))
                            .blur(radius: 20)
                    case .failure:
                        // 加载失败 → 让底层渐变透出来，什么都不画
                        Color.clear
                    default:
                        // 加载中 → 用深色半透明占位，保证白字/白按钮可读
                        Color.black.opacity(0.25).ignoresSafeArea()
                    }
                }
            }

            VStack {
                // 顶部栏（额外加深色磨砂底，极端情况下也能看清白箭头）
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Spacer()
                    Text("正在播放")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Button(action: {
                        player.repeatMode = MusicRepeatMode.allCases[
                            (player.repeatMode.rawValue + 1) % MusicRepeatMode.allCases.count
                        ]
                    }) {
                        Image(systemName: player.repeatMode.iconName)
                            .font(.system(size: 18))
                            .foregroundColor(accentColor)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    // P1-A9：顶栏加一层极淡的深色磨砂，给退出键再上一层保险
                    Color.black.opacity(0.15)
                        .blur(radius: 8)
                )

                Spacer()

                // 歌词主导 / 封面主导切换
                if showLyrics {
                    if lyricLines.isEmpty {
                        emptyLyricHint
                    } else {
                        lyricList(height: 360, idPrefix: "lyr_main")
                    }
                } else {
                    if let song = player.currentSong, let url = URL(string: song.coverURL) {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemGray4))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 50))
                                        .foregroundColor(.white.opacity(0.5))
                                )
                        }
                        .frame(width: 260, height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemGray4))
                            .frame(width: 260, height: 260)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 50))
                                    .foregroundColor(.white.opacity(0.5))
                            )
                    }
                }
                if !showLyrics {
                    Spacer()
                }

                // 歌名 + 来源
                VStack(spacing: 4) {
                    Text(player.currentSong?.name ?? "")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(player.currentSong?.artist ?? "")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }

                // 进度条
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekValue : player.currentTime },
                            set: { newValue in
                                isSeeking = true
                                seekValue = newValue
                            }
                        ),
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { editing in
                            if !editing {
                                player.seek(to: seekValue)
                                isSeeking = false
                            }
                        }
                    )
                    .tint(.white)

                    HStack {
                        Text(formatTime(player.currentTime))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text(formatTime(player.duration))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                // 控制按钮
                HStack(spacing: 40) {
                    Button(action: { player.playPrevious() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                    .disabled(player.queue.count <= 1)

                    Button(action: { player.togglePlayPause() }) {
                        Image(systemName: player.isLoading ? "hourglass" : (player.isPlaying ? "pause.fill" : "play.fill"))
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    }

                    Button(action: { player.playNext() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                    }
                    .disabled(player.queue.count <= 1)
                }
                .padding(.top, 16)

                // 队列按钮 + 歌词/封面切换
                HStack(spacing: 24) {
                    Button(action: { showQueue = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12))
                            Text("播放队列 (\(player.queue.count))")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(.white.opacity(0.7))
                    }
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) { showLyrics.toggle() }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: showLyrics ? "photo" : "text.quote")
                                .font(.system(size: 12))
                            Text(showLyrics ? "封面" : "歌词")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(showLyrics ? accentColor : .white.opacity(0.7))
                    }
                }
                .padding(.top, 12)

                // P3-C1：音质切换（仅 lx 源且插件声明多档音质时显示）
                qualitySwitchBar

                // P3-C2：歌词区（歌词主导模式下已在上方大区显示，此处隐藏避免重复）
                if !showLyrics {
                    lyricSection
                }

                Spacer(minLength: 20)
            }
        }
        // 播放失败/切换提示横幅（自动消失）
        .overlay(alignment: .top) {
            if let notice = player.playbackNotice {
                PlaybackNoticeBanner(text: notice, accentColor: accentColor)
                    .padding(.top, 46)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // 提示自动清除
        .task(id: player.playbackNotice) {
            guard player.playbackNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if player.playbackNotice != nil { player.playbackNotice = nil }
        }
        .sheet(isPresented: $showQueue) {
            MusicQueueSheet()
        }
        // P3-C2：当前曲目变化时异步拉取歌词
        .onChange(of: player.currentSong?.id) { _ in
            loadLyricForCurrent()
        }
        .onAppear { loadLyricForCurrent() }
        // P1-A10：下拉手势关闭全屏播放页
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global)
                .onEnded { value in
                    let dy = value.translation.height
                    // 向下滑动超过 80pt 且垂直为主 → 关闭
                    guard dy > 80, abs(dy) > abs(value.translation.width) else { return }
                    dismiss()
                }
        )
    }

    // MARK: - P3-C2 歌词加载
    private func loadLyricForCurrent() {
        guard let song = player.currentSong,
              LXBridgeEngine.lxKeyMap[song.engineKey] != nil,
              NodeRuntimeManager.shared.isLXReady else {
            lyricLines = []
            isLyricLoading = false
            return
        }
        isLyricLoading = true
        let engine = LXBridgeEngine(siteKey: song.engineKey)
        Task { @MainActor in
            // 歌词按歌曲归属平台定向取（优先命中缓存），避免聚合源全平台逐源轮询
            let raw = await engine.fetchLyricForSong(id: song.id,
                                                     preferSources: song.musicPlatform.flatMap { [$0] })
            lyricLines = Self.parseLRC(raw)
            isLyricLoading = false
        }
    }

    /// P3-C2：解析 LRC 文本 → 排序后的 (时间, 歌词) 行
    private static func parseLRC(_ lrc: String) -> [(TimeInterval, String)] {
        guard !lrc.isEmpty else { return [] }
        var out: [(TimeInterval, String)] = []
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]") else { return [] }
        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let matchedEnd = matches.map { $0.range.location + $0.range.length }.max() ?? 0
            let lyric = ns.substring(from: matchedEnd)
            for m in matches {
                let mm = Double((ns.substring(with: m.range(at: 1)) as NSString).doubleValue) ?? 0
                let ss = Double((ns.substring(with: m.range(at: 2)) as NSString).doubleValue) ?? 0
                var t = mm * 60 + ss
                if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound {
                    let fracStr = ns.substring(with: m.range(at: 3))
                    let frac = (fracStr as NSString).doubleValue
                    t += frac / pow(10, Double(fracStr.count))
                }
                if !lyric.isEmpty { out.append((t, lyric)) }
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// P3-C2：按当前播放时间返回激活歌词行下标
    private var activeLyricIndex: Int {
        guard let song = player.currentSong, LXBridgeEngine.lxKeyMap[song.engineKey] != nil else { return -1 }
        let t = player.currentTime
        guard let i = lyricLines.lastIndex(where: { $0.0 <= t }) else {
            return lyricLines.isEmpty ? -1 : 0
        }
        return i
    }
}

// MARK: - 音质切换 + 歌词 UI

extension MusicPlayerFullView {
    @ViewBuilder private var qualitySwitchBar: some View {
        if let song = player.currentSong,
           LXBridgeEngine.lxKeyMap[song.engineKey] != nil,
           song.availQualities.count > 1 {
            let qualities = uniquePreservingOrder(song.availQualities)
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                ForEach(Array(qualities.enumerated()), id: \.element) { _, q in
                    let selected = song.quality == q
                    Button(action: {
                        guard !isSwitchingQuality, song.quality != q else { return }
                        isSwitchingQuality = true
                        player.switchQuality(q) { _ in
                            isSwitchingQuality = false
                        }
                    }) {
                        Text(q)
                            .font(.system(size: 11, weight: selected ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(selected ? accentColor : Color.white.opacity(0.15))
                            )
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSwitchingQuality)
                }
            }
            .padding(.top, 14)
        }
    }

    @ViewBuilder private var lyricSection: some View {
        if isLyricLoading {
            HStack(spacing: 6) {
                ProgressView().tint(.white.opacity(0.6))
                Text("歌词加载中…").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
            }
            .padding(.top, 12)
            .frame(height: 90)
            .frame(maxWidth: .infinity)
        } else if !lyricLines.isEmpty {
            lyricList(height: 200, idPrefix: "lyr_mini")
                .padding(.top, 12)
        } else {
            // 无歌词（念心等）：整区隐藏
            EmptyView()
        }
    }

    /// 无歌词（念心/固定源）时歌词主导模式的提示
    private var emptyLyricHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.35))
            Text("该来源暂无歌词")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    /// 供封面主导（迷你区）/ 歌词主导（大区）复用的滚动歌词
    private func lyricList(height: CGFloat, idPrefix: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { i, pair in
                        Text(pair.1)
                            .font(.system(size: height > 250 ? 17 : 14))
                            .foregroundColor(i == activeLyricIndex ? accentColor : .white.opacity(0.55))
                            .fontWeight(i == activeLyricIndex ? .bold : .regular)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(idPrefix + "_\(i)")
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    startPoint: .center, endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
            .onChange(of: activeLyricIndex) { newIndex in
                if newIndex >= 0 {
                    withAnimation(.linear(duration: 0.2)) {
                        proxy.scrollTo(idPrefix + "_\(newIndex)", anchor: .center)
                    }
                }
            }
        }
    }

    private func uniquePreservingOrder(_ arr: [String]) -> [String] {
        var seen = Set<String>()
        return arr.filter { seen.insert($0).inserted }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 播放提示横幅

struct PlaybackNoticeBanner: View {
    let text: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color.black.opacity(0.78))
        )
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
    }
}

// MARK: - 播放队列弹窗

struct MusicQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = AudioPlayerManager.shared
    @StateObject private var settings = AppSettings()

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(player.queue.indices, id: \.self) { index in
                    let item = player.queue[index]
                    let isCurrent = (index == player.currentIndex)
                    HStack(spacing: 12) {
                            Group {
                                if let url = URL(string: item.coverURL) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Rectangle().fill(Color(.systemGray5))
                                            .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                                    }
                                } else {
                                    Rectangle().fill(Color(.systemGray5))
                                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                                    .foregroundColor(isCurrent ? accentColor : .primary)
                                    .lineLimit(1)
                                Text(item.artist)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(accentColor)
                            } else {
                                Button {
                                    player.removeFromQueue(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { player.playQueue(player.queue, startIndex: index) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("播放队列 (\(player.queue.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

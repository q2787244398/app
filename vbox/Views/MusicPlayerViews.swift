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

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 背景
            if let song = player.currentSong, let url = URL(string: song.coverURL) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.systemBackground)
                }
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.4))
                .blur(radius: 20)
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }

            VStack {
                // 顶部
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
                .padding(.top, 10)

                Spacer()

                // 封面
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

                Spacer()

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

                // 队列按钮
                Button(action: { showQueue = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12))
                        Text("播放队列 (\(player.queue.count))")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 12)
                }

                Spacer(minLength: 20)
            }
        }
        .sheet(isPresented: $showQueue) {
            MusicQueueSheet()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
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

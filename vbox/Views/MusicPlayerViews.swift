import SwiftUI
import AVFoundation

// MARK: - Mini Player 浮层

struct MiniPlayerBar: View {
    @ObservedObject private var player = AudioPlayerManager.shared
    @State private var dragOffset: CGFloat = 0
    @StateObject private var settings = AppSettings()

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var body: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                // 封面
                if let url = URL(string: song.coverURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color(.systemGray5))
                            .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                }

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

                Spacer()

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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 2)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .onTapGesture {
                player.showFullPlayer = true
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.height > 50 {
                            player.stop()
                        }
                    }
            )
            .fullScreenCover(isPresented: $player.showFullPlayer) {
                MusicPlayerFullView()
            }
            .onAppear {
                player.saveQueue()
            }
            .onDisappear {
                player.saveQueue()
            }
        }
    }
}

// MARK: - 全屏播放器

struct MusicPlayerFullView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var player = AudioPlayerManager.shared
    @StateObject private var settings = AppSettings()
    @State private var seekValue: Double = 0
    @State private var isSeeking: Bool = false

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
                            .font(.system(size: 20, weight: .semibold))
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
                        Image(systemName: player.isLoading ? "hourglass" : (player.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                            .font(.system(size: 60))
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
                Button(action: { /* 队列列表 */ }) {
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
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "00:00" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

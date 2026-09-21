import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - 播放模式

enum MusicRepeatMode: Int, CaseIterable {
    case sequential = 0  // 顺序播放
    case single        = 1  // 单曲循环
    case shuffle       = 2  // 随机播放

    var iconName: String {
        switch self {
        case .sequential: return "repeat"
        case .single:     return "repeat.1"
        case .shuffle:    return "shuffle"
        }
    }

    var displayName: String {
        switch self {
        case .sequential: return "顺序播放"
        case .single:     return "单曲循环"
        case .shuffle:    return "随机播放"
        }
    }
}

// MARK: - 队列条目

struct MusicQueueItem: Identifiable, Equatable {
    let id: String          // vodId
    let name: String        // 歌名
    let artist: String      // 来源/歌手
    let coverURL: String    // 封面图
    let playURL: String     // 播放地址
    let sourceName: String  // 源名称
    let engineKey: String   // 引擎 Key

    init(from song: VodItem, sourceName: String, engineKey: String, playURL: String) {
        self.id = song.vodId
        self.name = song.vodName
        self.artist = song.vodRemarks ?? sourceName
        self.coverURL = song.vodPic
        self.playURL = playURL
        self.sourceName = sourceName
        self.engineKey = engineKey
    }
}

// MARK: - AudioPlayerManager

@MainActor
final class AudioPlayerManager: NSObject, ObservableObject {

    // MARK: - 单例

    static let shared = AudioPlayerManager()

    // MARK: - 播放器

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?

    // MARK: - 状态（UI 绑定）

    @Published var queue: [MusicQueueItem] = []
    @Published var currentIndex: Int = -1
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var repeatMode: MusicRepeatMode = .sequential
    @Published var showFullPlayer: Bool = false
    @Published var isLoading: Bool = false

    private override init() {
        super.init()
        setupRemoteCommandCenter()
    }

    // MARK: - 当前曲目

    var currentSong: MusicQueueItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    // MARK: - 队列管理

    func setQueue(_ items: [MusicQueueItem], startIndex: Int = 0) {
        queue = items
        currentIndex = startIndex
    }

    func addToQueue(_ item: MusicQueueItem) {
        queue.append(item)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            stop()
        }
    }

    // MARK: - 播放控制

    func play(item: MusicQueueItem) {
        // 如果队列中没有这首歌，加入队列
        if !queue.contains(where: { $0.id == item.id }) {
            queue.append(item)
            currentIndex = queue.count - 1
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        }

        startPlayback()
    }

    func playQueue(_ items: [MusicQueueItem], startIndex: Int = 0) {
        queue = items
        currentIndex = startIndex
        startPlayback()
    }

    private func startPlayback() {
        guard queue.indices.contains(currentIndex) else { return }
        let item = queue[currentIndex]

        isLoading = true
        setupAudioSession()

        // 阶段四：写入播放历史
        let record = HistoryRecord(
            name: "[音乐] \(item.name)",
            laiyuan: item.sourceName,
            imgurl: item.coverURL,
            detailurl: item.playURL,
            detailua: "",
            xianlu: 0,
            jishu: 0,
            progress: 0
        )
        DatabaseManager.shared.addOrUpdateHistory(record)

        guard let url = URL(string: item.playURL) else {
            print("[AudioPlayer] 无效 URL: \(item.playURL)")
            isLoading = false
            return
        }

        // 停止旧播放器
        player?.pause()
        cleanupObservers()

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // 监听播放状态
        playerItemObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                if item.status == .readyToPlay {
                    self.duration = item.duration.seconds > 0 ? item.duration.seconds : 0
                    self.isLoading = false
                    self.player?.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                } else if item.status == .failed {
                    self.isLoading = false
                    self.isPlaying = false
                    print("[AudioPlayer] 播放失败: \(item.error?.localizedDescription ?? "")")
                }
            }
        }

        // 时间监听
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = time.seconds
                self.updateNowPlayingInfo()
            }
        }

        // 播放结束通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func resume() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func stop() {
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        cleanupObservers()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingInfo()
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        if repeatMode == .single {
            // 单曲循环：重播当前曲目
            player?.seek(to: .zero)
            player?.play()
        } else {
            if repeatMode == .shuffle {
                currentIndex = Int.random(in: 0..<queue.count)
            } else {
                currentIndex += 1
                if currentIndex >= queue.count { currentIndex = 0 }
            }
            startPlayback()
        }
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            // 前 3 秒内按上一首，否则从头播放
            seek(to: 0)
            return
        }
        if repeatMode == .shuffle {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex -= 1
            if currentIndex < 0 { currentIndex = queue.count - 1 }
        }
        startPlayback()
    }

    // MARK: - 播放结束

    @objc private func playerDidFinish() {
        playNext()
    }

    // MARK: - AudioSession

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayer] AudioSession 设置失败: \(error)")
        }
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        if let song = currentSong {
            info[MPMediaItemPropertyTitle] = song.name
            info[MPMediaItemPropertyArtist] = song.artist
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 远程控制

    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }

        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }

        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }

        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
    }

    // MARK: - 清理

    private func cleanupObservers() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    // MARK: - 队列持久化（阶段四）

    private let queueKey = "music_queue_items"
    private let queueIndexKey = "music_queue_index"

    func saveQueue() {
        guard !queue.isEmpty else {
            UserDefaults.standard.removeObject(forKey: queueKey)
            UserDefaults.standard.removeObject(forKey: queueIndexKey)
            return
        }
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: queueKey)
            UserDefaults.standard.set(currentIndex, forKey: queueIndexKey)
        }
    }

    func restoreQueue() {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let items = try? JSONDecoder().decode([MusicQueueItem].self, from: data) else { return }
        queue = items
        currentIndex = UserDefaults.standard.integer(forKey: queueIndexKey)
        if currentIndex < 0 || currentIndex >= queue.count { currentIndex = 0 }
        print("[AudioPlayer] 恢复队列: \(items.count) 首, 当前第 \(currentIndex + 1) 首")
    }

    func hasRestorableQueue() -> Bool {
        UserDefaults.standard.data(forKey: queueKey) != nil
    }
}

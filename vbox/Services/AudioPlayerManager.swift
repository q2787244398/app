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

struct MusicQueueItem: Identifiable, Equatable, Codable {
    let id: String          // vodId
    let name: String        // 歌名
    let artist: String      // 来源/歌手
    let coverURL: String    // 封面图
    let playURL: String     // 播放地址
    let sourceName: String  // 源名称
    let engineKey: String   // 引擎 Key

    // P1-A0 / P3：扩展字段。均以可空/默认值声明，配合 decodeIfPresent 保证旧存档解码不崩溃。
    var quality: String? = nil          // 音质标识（128k/320k/flac...）
    var qualityIndex: Int? = nil        // 当前音质在 availQualities 中的下标（归档用）
    var lyric: String? = nil            // LRC 歌词文本
    var duration: Int? = nil            // 时长（秒，插件返回 interval 格式化后解析）
    var albumName: String? = nil        // 专辑名
    var availQualities: [String] = []   // 可选音质档位（读插件 qualitys 声明）
    // P1-A7：lx 歌曲归属平台 + 原始 musicInfo（音质切换需重新走 musicUrl 时透传给插件）
    var musicPlatform: String? = nil
    var lxMusicInfo: String? = nil

    init(from song: VodItem, sourceName: String, engineKey: String, playURL: String) {
        self.id = song.vodId
        self.name = song.vodName
        self.artist = song.vodRemarks ?? sourceName
        self.coverURL = song.vodPic
        self.playURL = playURL
        self.sourceName = sourceName
        self.engineKey = engineKey
        // P2-B2/B3 / P3-C1：透传 lx 搜索结果元数据（时长/专辑/可发音质）
        self.duration = song.metaDuration
        self.albumName = song.albumName
        if !song.availQualities.isEmpty { self.availQualities = song.availQualities }
        // P1-A7：保留平台 + 原始 musicInfo 供音质切换复用
        self.musicPlatform = song.musicPlatform
        self.lxMusicInfo = song.lxMusicInfo
    }

    /// 直接构造（用于榜单/歌单：spider 把多首歌曲拼进一个 playUrl，这里按解析结果逐首构造）
    init(name: String, artist: String, coverURL: String, playURL: String, sourceName: String, engineKey: String) {
        self.id = playURL
        self.name = name
        self.artist = artist
        self.coverURL = coverURL
        self.playURL = playURL
        self.sourceName = sourceName
        self.engineKey = engineKey
    }

    /// 复制构造（P3-C1 音质切换用）：保留除 playURL/quality 外的全部字段，
    /// 以便在保留播放进度的同时无缝替换直链。
    init(copying base: MusicQueueItem, playURL: String, quality: String?) {
        self.id = base.id
        self.name = base.name
        self.artist = base.artist
        self.coverURL = base.coverURL
        self.playURL = playURL
        self.sourceName = base.sourceName
        self.engineKey = base.engineKey
        self.quality = quality
        self.qualityIndex = base.qualityIndex
        self.lyric = base.lyric
        self.duration = base.duration
        self.albumName = base.albumName
        self.availQualities = base.availQualities
        self.musicPlatform = base.musicPlatform
        self.lxMusicInfo = base.lxMusicInfo
    }

    // ---- P1-A0：显式 Codable，新增字段全部 decodeIfPresent，缺失时回退默认值，旧存档可安全解码 ----
    private enum CodingKeys: String, CodingKey {
        case id, name, artist, coverURL, playURL, sourceName, engineKey
        case quality, qualityIndex, lyric, duration, albumName, availQualities, musicPlatform, lxMusicInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        artist = try c.decode(String.self, forKey: .artist)
        coverURL = try c.decode(String.self, forKey: .coverURL)
        playURL = try c.decode(String.self, forKey: .playURL)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        engineKey = try c.decode(String.self, forKey: .engineKey)
        quality = try c.decodeIfPresent(String.self, forKey: .quality)
        qualityIndex = try c.decodeIfPresent(Int.self, forKey: .qualityIndex)
        lyric = try c.decodeIfPresent(String.self, forKey: .lyric)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName)
        availQualities = try c.decodeIfPresent([String].self, forKey: .availQualities) ?? []
        musicPlatform = try c.decodeIfPresent(String.self, forKey: .musicPlatform)
        lxMusicInfo = try c.decodeIfPresent(String.self, forKey: .lxMusicInfo)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(artist, forKey: .artist)
        try c.encode(coverURL, forKey: .coverURL)
        try c.encode(playURL, forKey: .playURL)
        try c.encode(sourceName, forKey: .sourceName)
        try c.encode(engineKey, forKey: .engineKey)
        try c.encodeIfPresent(quality, forKey: .quality)
        try c.encodeIfPresent(qualityIndex, forKey: .qualityIndex)
        try c.encodeIfPresent(lyric, forKey: .lyric)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(albumName, forKey: .albumName)
        try c.encode(availQualities, forKey: .availQualities)
        try c.encodeIfPresent(musicPlatform, forKey: .musicPlatform)
        try c.encodeIfPresent(lxMusicInfo, forKey: .lxMusicInfo)
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
    /// 播放器即时提示（如“播放失败，正在切换下一首”），由全屏页短暂展示后自动清除
    @Published var playbackNotice: String? = nil

    // 播放失败保护：连续失败 < 队列长度时才自动跳，防止整单全挂死循环
    private var consecutiveFailures = 0
    // 是否已针对当前曲目尝试过一次直链重解析（仅 lx 聚合源），切歌时复位
    private var didReResolveCurrent = false

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
        saveQueue()
    }

    func addToQueue(_ item: MusicQueueItem) {
        queue.append(item)
        saveQueue()
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            stop()
        }
        saveQueue()
    }

    // MARK: - 播放控制

    func play(item: MusicQueueItem) {
        didReResolveCurrent = false
        consecutiveFailures = 0
        // 如果队列中没有这首歌，加入队列
        if !queue.contains(where: { $0.id == item.id }) {
            queue.append(item)
            currentIndex = queue.count - 1
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        }

        saveQueue()
        startPlayback()
    }

    func playQueue(_ items: [MusicQueueItem], startIndex: Int = 0) {
        didReResolveCurrent = false
        consecutiveFailures = 0
        queue = items
        currentIndex = startIndex
        saveQueue()
        startPlayback()
    }

    private func startPlayback(seekTo initialTime: Double? = nil) {
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
                    // 成功开播：复位失败计数，一首歌只重解析一次
                    self.consecutiveFailures = 0
                    self.didReResolveCurrent = false
                    // P3-C1：音质切换时保留原进度（±3s 内），否则从头播放
                    if let t = initialTime, t > 0 {
                        self.player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    self.player?.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                } else if item.status == .failed {
                    self.isLoading = false
                    self.isPlaying = false
                    self.playbackNotice = "播放失败，正在切换下一首"
                    print("[AudioPlayer] 播放失败: \(item.error?.localizedDescription ?? "")")
                    // #6：lx 聚合源直链常有过期/失效，先按归属平台重解析一次当前曲目
                    let isAggregator = LXBridgeEngine.lxKeyMap[item.engineKey] != nil
                    if isAggregator && !self.didReResolveCurrent {
                        self.reResolveCurrent()
                        return
                    }
                    // #1：其余情况自动跳到下一首（连续失败保护，避免整单全坏死循环）
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures < self.queue.count && self.queue.count > 1 {
                        self.playNext()
                    } else {
                        self.consecutiveFailures = 0
                    }
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
        if player == nil {
            // 播放器为空（如队列恢复后），重新初始化播放
            startPlayback()
        } else {
            player?.play()
            isPlaying = true
            updateNowPlayingInfo()
        }
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

        // 清空队列，使 MiniPlayerBar 自动隐藏
        queue = []
        currentIndex = -1
        saveQueue()

        // 停用 AudioSession，避免影响视频播放器
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // 清除锁屏控制信息
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlayingInfo()
    }

    // MARK: - P3-C1：多音质切换（仅 lx 音乐源）

    /// 重新走 lx musicUrl 拉取指定档位直链，用 replaceCurrentItem 无缝衔接并保留播放进度。
    /// 非 lx 音乐源（不支持音质切换）直接回调 false 不做任何改动，绝不影响视频/普通音乐源。
    func switchQuality(_ q: String, completion: ((Bool) -> Void)? = nil) {
        guard currentIndex >= 0, queue.indices.contains(currentIndex) else {
            completion?(false); return
        }
        let item = queue[currentIndex]
        guard LXBridgeEngine.lxKeyMap[item.engineKey] != nil else {
            completion?(false); return
        }
        Task {
            let engine = LXBridgeEngine(siteKey: item.engineKey)
            do {
                // P1-A7：音质切换复用已保留的平台 + 原始 musicInfo，避免聚合源用 `id` 全平台竞速失败。
                var rawInfo: [String: Any]? = nil
                if let str = item.lxMusicInfo, let d = str.data(using: .utf8) {
                    rawInfo = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                }
                let prefer: [String]? = item.musicPlatform.flatMap { [$0] }
                let singer = rawInfo?["singer"] as? String
                let url = try await engine.resolvePlayURL(id: item.id, quality: q,
                                                          preferSources: prefer, musicInfo: rawInfo,
                                                          name: item.name, singer: singer,
                                                          albumName: item.albumName)
                guard !url.isEmpty, queue.indices.contains(currentIndex) else {
                    completion?(false); return
                }
                let progress = currentTime
                let rebuilt = MusicQueueItem(copying: queue[currentIndex], playURL: url, quality: q)
                queue[currentIndex] = rebuilt
                saveQueue()
                startPlayback(seekTo: progress)
                completion?(true)
            } catch {
                print("[AudioPlayer] 音质切换失败: \(error)")
                completion?(false)
            }
        }
    }

    // MARK: - 直链失败重解析（#6，仅 lx 聚合源直链过期/失效时使用）

    /// 当前曲目播放失败时，按归属平台 + 原始 musicInfo 重新解析直链；成功则重播当前曲目，
    /// 失败则交由调用方（failed 分支）自动跳到下一首。每首曲目至多重解析一次，避免死循环。
    private func reResolveCurrent() {
        guard queue.indices.contains(currentIndex) else { playNext(); return }
        let item = queue[currentIndex]
        guard LXBridgeEngine.lxKeyMap[item.engineKey] != nil else { playNext(); return }
        let engine = LXBridgeEngine(siteKey: item.engineKey)
        Task {
            do {
                var rawInfo: [String: Any]? = nil
                if let str = item.lxMusicInfo, let d = str.data(using: .utf8) {
                    rawInfo = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                }
                let prefer: [String]? = item.musicPlatform.flatMap { [$0] }
                let url = try await engine.resolvePlayURL(id: item.id, quality: item.quality,
                                                          preferSources: prefer, musicInfo: rawInfo,
                                                          name: item.name,
                                                          singer: rawInfo?["singer"] as? String,
                                                          albumName: item.albumName)
                guard !url.isEmpty, queue.indices.contains(currentIndex) else { self.playNext(); return }
                let rebuilt = MusicQueueItem(copying: queue[currentIndex], playURL: url, quality: item.quality)
                queue[currentIndex] = rebuilt
                saveQueue()
                didReResolveCurrent = true
                startPlayback(seekTo: 0)
            } catch {
                print("[AudioPlayer] 重解析失败，自动跳下一首: \(error)")
                self.playNext()
            }
        }
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
            didReResolveCurrent = false
            saveQueue()
            startPlayback()
        }
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        didReResolveCurrent = false
        if currentTime > 3 {
            // 超过 3 秒则从头播放
            seek(to: 0)
            return
        }
        if repeatMode == .shuffle {
            currentIndex = Int.random(in: 0..<queue.count)
        } else {
            currentIndex -= 1
            if currentIndex < 0 { currentIndex = queue.count - 1 }
        }
        saveQueue()
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

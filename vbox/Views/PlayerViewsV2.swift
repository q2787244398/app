import SwiftUI
import AVKit
import AVFoundation
import Combine
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

extension Notification.Name {
    static let vboxVLCPlay = Notification.Name("vbox.vlc.play")
    static let vboxVLCPause = Notification.Name("vbox.vlc.pause")
    static let vboxVLCSeek = Notification.Name("vbox.vlc.seek")
    static let vboxVLCSpeed = Notification.Name("vbox.vlc.speed")
    static let vboxMPVPlay = Notification.Name("vbox.mpv.play")
    static let vboxMPVPause = Notification.Name("vbox.mpv.pause")
    static let vboxMPVSeek = Notification.Name("vbox.mpv.seek")
    static let vboxMPVSpeed = Notification.Name("vbox.mpv.speed")
    static let vboxMPVStop = Notification.Name("vbox.mpv.stop")
    static let vboxMDKPlay = Notification.Name("vbox.mdk.play")
    static let vboxMDKPause = Notification.Name("vbox.mdk.pause")
    static let vboxMDKSeek = Notification.Name("vbox.mdk.seek")
    static let vboxMDKSpeed = Notification.Name("vbox.mdk.speed")
}

// 屏幕方向辅助类
class OrientationHelper {
    static var currentOrientationMask: UIInterfaceOrientationMask = .all
    private static var lastGeometryUpdateAt: Date = .distantPast
    private static var pendingGeometryUpdate: DispatchWorkItem?
    private static let geometryUpdateMinInterval: TimeInterval = 0.7

    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        currentOrientationMask = orientation
        // 根据当前设备方向决定锁定哪个横屏方向
        let currentDeviceOrientation = UIDevice.current.orientation
        let targetOrientation: UIInterfaceOrientation
        if orientation == .landscape {
            if currentDeviceOrientation == .landscapeLeft {
                targetOrientation = .landscapeLeft
            } else {
                targetOrientation = .landscapeRight
            }
        } else {
            targetOrientation = .portrait
        }
        requestGeometryUpdate(orientation, targetOrientation: targetOrientation, force: true)
    }

    static func unlockOrientation() {
        currentOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        requestGeometryUpdate([.portrait, .landscapeLeft, .landscapeRight])
    }

    static func rotateToLandscape() {
        // 支持左右两种横屏方向，根据设备当前方向自动选择
        let currentOrientation = UIDevice.current.orientation
        let targetOrientation: UIInterfaceOrientation
        switch currentOrientation {
        case .landscapeLeft:
            targetOrientation = .landscapeLeft
        case .landscapeRight:
            targetOrientation = .landscapeRight
        case .portrait, .portraitUpsideDown, .faceUp, .faceDown, .unknown:
            targetOrientation = .landscapeRight
        @unknown default:
            targetOrientation = .landscapeRight
        }
        let mask: UIInterfaceOrientationMask = (targetOrientation == .landscapeLeft) ? .landscapeLeft : .landscapeRight
        currentOrientationMask = mask
        requestGeometryUpdate(mask, targetOrientation: targetOrientation)
    }

    /// 播放器进入时：允许左右双向横屏+竖屏，自动跟随手机方向
    static func allowAllOrientations() {
        currentOrientationMask = [.portrait, .landscapeLeft, .landscapeRight]
        requestGeometryUpdate([.portrait, .landscapeLeft, .landscapeRight])
    }

    private static func requestGeometryUpdate(
        _ orientation: UIInterfaceOrientationMask,
        targetOrientation: UIInterfaceOrientation? = nil,
        force: Bool = false
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                requestGeometryUpdate(orientation, targetOrientation: targetOrientation, force: force)
            }
            return
        }

        // App 非活跃时不要触发 scene 几何更新，避免前后台切换过程中卡在 scene-update。
        guard UIApplication.shared.applicationState == .active else {
            pendingGeometryUpdate?.cancel()
            pendingGeometryUpdate = nil
            return
        }

        let performUpdate = {
            guard UIApplication.shared.applicationState == .active,
                  let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            pendingGeometryUpdate = nil
            lastGeometryUpdateAt = Date()
            if let targetOrientation {
                UIDevice.current.setValue(targetOrientation.rawValue, forKey: "orientation")
            }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            if targetOrientation != nil {
                UINavigationController.attemptRotationToDeviceOrientation()
            }
        }

        let elapsed = Date().timeIntervalSince(lastGeometryUpdateAt)
        if force || elapsed >= geometryUpdateMinInterval {
            pendingGeometryUpdate?.cancel()
            performUpdate()
        } else {
            pendingGeometryUpdate?.cancel()
            let workItem = DispatchWorkItem(block: performUpdate)
            pendingGeometryUpdate = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (geometryUpdateMinInterval - elapsed),
                execute: workItem
            )
        }
    }
}

// MARK: - 画中画/小窗口辅助类
class PiPHelper: NSObject {
    static let shared = PiPHelper()
    
    private var pipController: AVPictureInPictureController?
    private var pipStatusObserver: Any?
    private var pipPlayerLayer: AVPlayerLayer?
    private var floatingWindow: UIWindow?
    private var floatingPlayerView: UIView?
    private var isFloatingMode = false
    private var pipStartRetries: Int = 0
    
    private override init() {
        super.init()
        // 监听屏幕拉伸模式变化，对所有播放器视图统一设置 contentMode
        NotificationCenter.default.addObserver(self, selector: #selector(handleVideoGravityChanged(_:)), name: .vboxVideoGravityChanged, object: nil)
    }

    @objc private func handleVideoGravityChanged(_ notification: Notification) {
        guard let mode = notification.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
        let contentMode: UIView.ContentMode
        switch mode {
        case .aspectFill:
            contentMode = .scaleAspectFill
        case .aspectFit:
            contentMode = .scaleAspectFit
        case .resize:
            contentMode = .scaleToFill
        }

        DispatchQueue.main.async {
            guard let rootView = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows
                .first(where: { $0.isKeyWindow })?.rootViewController?.view else { return }

            let candidates = ["Player", "Video", "GL", "Metal", "Render", "AliPlayer", "VLC", "IJK", "MPV", "MDK"]
            self.setContentMode(contentMode, for: rootView, classNameHints: candidates)
        }
    }

    private func setContentMode(_ contentMode: UIView.ContentMode, for view: UIView, classNameHints: [String]) {
        let className = String(describing: type(of: view))
        let isPlayerView = classNameHints.contains(where: { className.contains($0) })
            || view is AVPlayerLayer
            || view.layer is AVPlayerLayer
            || String(describing: type(of: view.layer)).contains("Metal")
            || String(describing: type(of: view.layer)).contains("OpenGL")
        if isPlayerView {
            view.contentMode = contentMode
            view.clipsToBounds = true
        }
        for subview in view.subviews {
            setContentMode(contentMode, for: subview, classNameHints: classNameHints)
        }
    }

    /// 保存 AVPlayerViewController 内部的 playerLayer 引用，供画中画使用
    func setPlayerLayer(_ layer: AVPlayerLayer) {
        // 如果 PiP 控制器已存在且使用的是旧 layer，需要重新创建
        if pipPlayerLayer !== layer && pipController != nil {
            cleanupPiPController()
        }
        pipPlayerLayer = layer
    }
    
    // MARK: - AVPlayer 原生画中画
    func setupPiP(for player: AVPlayer) {
        // 清理旧的 PiP 控制器
        cleanupPiPController()

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            print("[PiP] 当前设备不支持画中画")
            return
        }

        // 激活音频会话（iOS 要求必须有活跃音频会话才能启动 PiP）
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PiP] 音频会话激活失败: \(error.localizedDescription)")
        }

        // 优先使用 AVPlayerViewController 内部的 playerLayer（已挂载在视图层级中）
        let playerLayer: AVPlayerLayer
        if let existingLayer = pipPlayerLayer {
            playerLayer = existingLayer
            print("[PiP] 复用 AVPlayerViewController 内部的 playerLayer")
        } else {
            // 回退：创建独立的 playerLayer
            let newLayer = AVPlayerLayer(player: player)
            newLayer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            newLayer.videoGravity = .resizeAspect
            pipPlayerLayer = newLayer
            playerLayer = newLayer
            // 关键修复：将 playerLayer 挂载到隐藏 UIWindow，
            // 否则 AVPictureInPictureController 的 isPictureInPicturePossible 永远为 false
            mountPlayerLayerToHiddenWindow(playerLayer)
            print("[PiP] 创建独立 playerLayer 并挂载到隐藏 UIWindow")
        }

        let pipContentSource = AVPictureInPictureController.ContentSource(playerLayer: playerLayer)

        pipController = AVPictureInPictureController(contentSource: pipContentSource)
        pipController?.delegate = self

        pipStartRetries = 0

        pipStatusObserver = pipController?.observe(\AVPictureInPictureController.isPictureInPicturePossible, options: .new) { [weak self] _, change in
            DispatchQueue.main.async {
                if let isPossible = change.newValue, isPossible {
                    print("[PiP] isPictureInPicturePossible 变为 true")
                    self?.tryStartPiP()
                }
                NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
            }
        }

        // 先检查是否已经可以启动
        if pipController?.isPictureInPicturePossible == true {
            tryStartPiP()
        } else {
            schedulePiPStartRetry()
        }
    }
    
    private func tryStartPiP() {
        guard pipStartRetries < 5 else {
            print("[PiP] 超过最大重试次数，放弃启动 PiP")
            return
        }
        pipController?.startPictureInPicture()
        pipStartRetries += 1
    }
    
    private func schedulePiPStartRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.pipController?.isPictureInPicturePossible == true {
                self.tryStartPiP()
            } else if self.pipStartRetries < 5 {
                self.schedulePiPStartRetry()
            }
        }
    }
    
    func stopPiP() {
        pipController?.stopPictureInPicture()
        cleanupPiPController()
    }

    private func cleanupPiPController() {
        pipController?.stopPictureInPicture()
        if pipStatusObserver != nil {
            pipStatusObserver = nil
        }
        pipController = nil
        // 注意：不释放 pipPlayerLayer，因为它属于 AVPlayerViewController 的视图层级
    }

    /// 将 AVPlayerLayer 挂载到隐藏 UIWindow（参照 MDK/MPV PiP 管理器实现）
    /// AVPictureInPictureController.ContentSource(playerLayer:) 要求 playerLayer 必须在视图层级中
    private func mountPlayerLayerToHiddenWindow(_ layer: AVPlayerLayer) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else {
            print("[PiP] 警告：无法获取 UIWindowScene，playerLayer 未挂载")
            return
        }

        // 如果已有隐藏窗口，直接复用
        if let existingWindow = floatingWindow {
            if let containerView = existingWindow.rootViewController?.view.subviews.first {
                containerView.layer.addSublayer(layer)
                return
            }
        }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: -1)
        window.backgroundColor = .clear
        window.isHidden = false
        window.alpha = 0.01
        window.isUserInteractionEnabled = false

        let containerView = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        containerView.layer.addSublayer(layer)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(containerView)

        floatingWindow = window
        print("[PiP] playerLayer 已挂载到隐藏 UIWindow")
    }
    
    var isPiPPossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }
    
    // MARK: - 浮动小窗口（用于 VLC/MPV 等非 AVPlayer 内核）
    func showFloatingWindow(sourceView: UIView) {
        guard !isFloatingMode else { return }
        isFloatingMode = true
        
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let scene = windowScene else { return }
        
        let window = UIWindow(windowScene: scene)
        // 使用 alert 层级以上，确保浮窗不会被系统 PiP/Alert 遮挡
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 10)
        window.backgroundColor = .clear
        window.isHidden = false
        window.makeKeyAndVisible()
        
        let containerView = UIView(frame: CGRect(x: scene.screen.bounds.width - 220, y: 80, width: 200, height: 112))
        containerView.backgroundColor = .black
        containerView.layer.cornerRadius = 12
        containerView.layer.masksToBounds = true
        containerView.layer.shadowColor = UIColor.black.cgColor
        containerView.layer.shadowOpacity = 0.5
        containerView.layer.shadowOffset = CGSize(width: 0, height: 4)
        containerView.layer.shadowRadius = 12
        
        // 将源视图的播放器层复制到浮动窗口中
        // 找到sourceView中的播放器子视图并复制
        let playerSubviews = sourceView.subviews.filter { subview in
            // 识别播放器视图：通常是全屏的黑色背景视图或包含视频内容的视图
            return subview.frame.equalTo(sourceView.bounds) || subview.backgroundColor == .black
        }
        if let playerView = playerSubviews.first {
            // 创建截图作为初始显示
            if let snapshot = playerView.snapshotView(afterScreenUpdates: true) {
                snapshot.frame = containerView.bounds
                snapshot.tag = 1001 // 标记为截图视图
                containerView.addSubview(snapshot)
            }
            // 启动定时器更新截图，模拟视频播放效果
            startSnapshotTimer(sourceView: playerView)
        } else {
            // 回退：使用整个sourceView的截图，并启动定时更新
            if let snapshot = sourceView.snapshotView(afterScreenUpdates: true) {
                snapshot.frame = containerView.bounds
                snapshot.tag = 1001
                containerView.addSubview(snapshot)
            }
            startSnapshotTimer(sourceView: sourceView)
        }
        
        // 关闭按钮
        let closeBtn = UIButton(frame: CGRect(x: containerView.bounds.width - 32, y: 4, width: 28, height: 28))
        closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeBtn.tintColor = .white
        closeBtn.addTarget(self, action: #selector(hideFloatingWindow), for: .touchUpInside)
        containerView.addSubview(closeBtn)
        
        // 添加拖拽手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        containerView.addGestureRecognizer(panGesture)
        
        // 双击恢复全屏
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        containerView.addGestureRecognizer(doubleTap)
        
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tapGesture.require(toFail: doubleTap)
        containerView.addGestureRecognizer(tapGesture)
        
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(containerView)
        
        floatingWindow = window
        floatingPlayerView = containerView
        
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    @objc func hideFloatingWindow() {
        stopSnapshotTimer()
        floatingWindow?.isHidden = true
        floatingWindow = nil
        floatingPlayerView = nil
        isFloatingMode = false
        
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let superview = view.superview
        let translation = gesture.translation(in: superview)
        
        view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
        gesture.setTranslation(.zero, in: superview)
        
        if gesture.state == .ended {
            // 吸附到最近的边缘
            let screenBounds = UIScreen.main.bounds
            var targetX: CGFloat
            if view.center.x < screenBounds.width / 2 {
                targetX = view.bounds.width / 2 + 8
            } else {
                targetX = screenBounds.width - view.bounds.width / 2 - 8
            }
            // 限制 Y 范围
            let minY = view.bounds.height / 2 + 50
            let maxY = screenBounds.height - view.bounds.height / 2 - 50
            let targetY = min(max(view.center.y, minY), maxY)
            
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
                view.center = CGPoint(x: targetX, y: targetY)
            }
        }
    }
    
    @objc private func handleDoubleTap() {
        hideFloatingWindow()
        NotificationCenter.default.post(name: .vboxPiPRestoreFullScreen, object: nil)
    }
    
    @objc private func handleSingleTap() {
        // 单击暂停/播放
        NotificationCenter.default.post(name: .vboxPiPTogglePlayPause, object: nil)
    }
    
    func updateFloatingSnapshot(_ snapshot: UIImage?) {
        guard let containerView = floatingPlayerView else { return }
        // 移除旧的截图视图
        containerView.subviews.first(where: { $0 is UIImageView })?.removeFromSuperview()
        guard let image = snapshot else { return }
        let imageView = UIImageView(image: image)
        imageView.frame = containerView.bounds
        imageView.contentMode = .scaleAspectFill
        containerView.insertSubview(imageView, at: 0)
    }
    
    // MARK: - 定时更新截图，模拟视频播放
    private var snapshotTimer: Timer?
    private var snapshotDisplayLink: CADisplayLink?
    private weak var snapshotSourceView: UIView?
    
    private func startSnapshotTimer(sourceView: UIView) {
        snapshotSourceView = sourceView
        snapshotTimer?.invalidate()
        snapshotDisplayLink?.invalidate()

        // CADisplayLink 用于前台时保持画面同步，但限制为 5fps（200ms/帧）
        // 默认 60fps 会在每帧创建/销毁 snapshotView，导致主线程严重过载
        let displayLink = CADisplayLink(target: self, selector: #selector(updateSnapshotFrame))
        displayLink.preferredFramesPerSecond = 5
        displayLink.add(to: .main, forMode: .common)
        snapshotDisplayLink = displayLink

        // 额外用 Timer 兜底（后台 CADisplayLink 会暂停）
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateSnapshotFrame()
        }
    }

    @objc private func updateSnapshotFrame() {
        guard let sourceView = snapshotSourceView,
              let containerView = floatingPlayerView,
              !containerView.bounds.isEmpty else { return }

        // 捕获播放器视图当前帧，afterScreenUpdates=false 避免阻塞
        guard let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else { return }

        // 移除旧的截图视图
        containerView.subviews.filter { $0.tag == 1001 }.forEach { $0.removeFromSuperview() }
        snapshot.frame = containerView.bounds
        snapshot.tag = 1001
        containerView.insertSubview(snapshot, at: 0)
    }
    
    private func stopSnapshotTimer() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        snapshotDisplayLink?.invalidate()
        snapshotDisplayLink = nil
        snapshotSourceView = nil
    }
    
    var isFloating: Bool { isFloatingMode }
}

extension PiPHelper: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        print("[PiP] 启动画中画失败: \(error.localizedDescription)")
        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: nil)
    }
}

// MARK: - PiP 相关通知
extension Notification.Name {
    static let vboxPiPStatusChanged = Notification.Name("vbox.pip.statusChanged")
    static let vboxPiPRestoreFullScreen = Notification.Name("vbox.pip.restoreFullScreen")
    static let vboxPiPTogglePlayPause = Notification.Name("vbox.pip.togglePlayPause")
    static let vboxVideoGravityChanged = Notification.Name("vbox.videoGravity.changed")
}

// MARK: - 新版本播放器 (爱奇艺风格) - 简化版本，确保编译通过
struct VideoPlayerViewV2: View {
    let video: VodItem
    /// 详情页已解析好的集数列表，优先使用，避免播放器重复解析 vodPlayUrl 导致选源不一致和卡死
    let preParsedEpisodes: [(name: String, url: String)]?
    @StateObject private var playerState = PlayerState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(video: VodItem, preParsedEpisodes: [(name: String, url: String)]? = nil) {
        self.video = video
        self.preParsedEpisodes = preParsedEpisodes
        _playerState = StateObject(wrappedValue: PlayerState())
    }
    // 修复: 存储 PiP 观察者 token，onDisappear 时用 token 移除
    @State private var pipRestoreObserver: NSObjectProtocol?
    @State private var pipToggleObserver: NSObjectProtocol?
    @State private var avPlayerPiPStatusObserver: NSObjectProtocol?
    @State private var avPlayerPiPFallbackObserver: NSObjectProtocol?
    /// VideoToolbox PiP 失败观察者
    @State private var vtPiPFailureObserver: NSObjectProtocol?
    /// VideoToolbox PiP 状态变化观察者
    @State private var vtPiPStatusObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体 - 始终显示，包含加载状态
            PlayerContainerView(
                player: playerState.player,
                playerState: playerState,
                video: video
            )
            .persistentSystemOverlays(.hidden)

            // 下载胶囊通知 — 顶部显示，不影响播放器交互
            VStack {
                PlayerCapsuleNotification()
                Spacer()
            }
            .allowsHitTesting(false)
            .zIndex(200)

            // 错误提示（附带调试日志）
            if let error = playerState.loadError {
                ErrorViewWithLogs(error: error, logs: playerState.debugLogs, onRetry: { playerState.retry(video: video) })
                    .zIndex(100)
            }

            // 调试日志浮层（开关控制，加载中+播放中都显示）
            // 放在返回键下方，左右避开按钮区域
            if playerState.showDebugOverlay && !playerState.debugLogs.isEmpty {
                VStack {
                    HStack(alignment: .top, spacing: 0) {
                        // 左侧返回按钮预留区
                        Spacer().frame(width: 96)

                        ZStack(alignment: .topTrailing) {
                            ScrollView(showsIndicators: true) {
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(playerState.debugLogs.enumerated()), id: \.offset) { idx, log in
                                        Text(log)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(.green.opacity(0.9))
                                            .id(idx)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(6)
                                .padding(.trailing, 22) // 右侧留出按钮空间
                            }
                            .frame(maxWidth: 560)
                            .frame(height: 126)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(6)
                            .contentShape(Rectangle())
                            .allowsHitTesting(true)

                            // 右上角导出按钮
                            Button(action: {
                                playerState.exportDebugLogs()
                            }) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .zIndex(1)
                        }

                        // 右侧锁定按钮预留区
                        Spacer().frame(width: 96)
                    }
                    .padding(.top, 54)  // 返回键下方（返回键高度约44pt + 间距）
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            // 进入播放器：先强制横屏，然后允许所有方向（自动跟随手机）
            OrientationHelper.rotateToLandscape()
            playerState.isPortrait = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OrientationHelper.allowAllOrientations()
            }
            playerState.setupPlayer(video: video, preParsedEpisodes: preParsedEpisodes)
            
            // 监听PiP恢复全屏和暂停/播放通知
            // 修复: 存储 token 并使用 weak 引用，防止 playerState 泄漏
            if let old = pipRestoreObserver { NotificationCenter.default.removeObserver(old) }
            if let old = pipToggleObserver { NotificationCenter.default.removeObserver(old) }
            if let old = avPlayerPiPStatusObserver { NotificationCenter.default.removeObserver(old) }
            if let old = avPlayerPiPFallbackObserver { NotificationCenter.default.removeObserver(old) }
            pipRestoreObserver = NotificationCenter.default.addObserver(forName: .vboxPiPRestoreFullScreen, object: nil, queue: .main) { [weak playerState] _ in
                playerState?.isPiPActive = false
            }
            pipToggleObserver = NotificationCenter.default.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak playerState] note in
                guard let playerState else { return }
                if let playing = note.object as? Bool {
                    if let player = playerState.player {
                        playing ? player.play() : player.pause()
                    }
                    playerState.isPlaying = playing
                    return
                }
                playerState.togglePlayback(player: playerState.player)
            }
            avPlayerPiPStatusObserver = NotificationCenter.default.addObserver(forName: .vboxAVPlayerPiPStatusChanged, object: nil, queue: .main) { [weak playerState] note in
                guard let playerState, let active = note.object as? Bool else { return }
                playerState.isPiPActive = active
            }
            avPlayerPiPFallbackObserver = NotificationCenter.default.addObserver(forName: .vboxAVPlayerPiPFallback, object: nil, queue: .main) { [weak playerState] _ in
                guard let playerState else { return }
                playerState.isPiPActive = false
                playerState.currentPiPStrategy = .backgroundAudioOnly
                playerState.log("[PlayerV2] AVPlayer 代理/转封装画中画失败，已降级为后台声音，避免冻屏")
            }

            // VideoToolbox PiP 状态变化
            vtPiPStatusObserver = NotificationCenter.default.addObserver(forName: .vboxVTPiPStatusChanged, object: nil, queue: .main) { [weak playerState] note in
                guard let playerState, let active = note.object as? Bool else { return }
                playerState.isPiPActive = active
                if active {
                    playerState.log("[PlayerV2] VideoToolbox 硬解码 PiP 已启动")
                }
            }

            // VideoToolbox PiP 失败：降级为后台声音
            vtPiPFailureObserver = NotificationCenter.default.addObserver(forName: .vboxVTPiPFailed, object: nil, queue: .main) { [weak playerState] _ in
                guard let playerState else { return }
                playerState.isPiPActive = false
                playerState.currentPiPStrategy = .backgroundAudioOnly
                playerState.log("[PlayerV2] VideoToolbox 硬解码 PiP 失败，已降级为后台声音")
            }
        }
        .onDisappear {
            // 恢复竖屏；不要立刻再 unlock，避免连续触发 scene 几何更新。
            OrientationHelper.lockOrientation(.portrait)
            playerState.cleanup()
            // 修复: 使用 token 移除观察者，removeObserver(self,...) 对 block-based 观察者无效
            if let obs = pipRestoreObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = pipToggleObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = avPlayerPiPStatusObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = avPlayerPiPFallbackObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = vtPiPStatusObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = vtPiPFailureObserver { NotificationCenter.default.removeObserver(obs) }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background, .inactive:
                playerState.handleSceneBackground()
            case .active:
                // 回前台时只登记恢复任务，不在 scene-update 回调里同步停止 PiP 或恢复播放。
                playerState.handleSceneForeground(shouldStopPiP: playerState.isPiPActive)
            @unknown default:
                break
            }
        }
    }

}

// MARK: - 通用集数项
struct EpisodeItem: Identifiable {
    let id: Int
    let name: String
    let url: String
    /// 来源蜘蛛 key，普通选集切换时用于继续命中远程源播放策略
    var engineKey: String?
    /// 资源类型标记（用于切集时选择不同播放逻辑）
    var sourceType: EpisodeSourceType
    /// 百度文件索引（仅百度网盘使用）
    var baiduFileIndex: Int?
    /// 夸克文件索引（仅夸克网盘使用）
    var quarkFileIndex: Int?
    /// UC 文件 fid（仅 UC 网盘切换集数使用）
    var ucFileFid: String?
    /// UC 文件 shareFidToken（仅 UC 网盘切换集数使用）
    var ucShareFidToken: String?
    /// 迅雷文件 ID（仅迅雷云盘切换集数使用）
    var xunleiFileId: String?
    /// 阿里文件 ID（仅阿里云盘切换集数使用）
    var aliFileId: String?
    /// 115 文件 pickCode（仅115网盘切换集数使用）
    var one15PickCode: String?
    /// 123 文件 ID 和 ETag（仅123云盘切换集数使用）
    var pan123FileId: String?
    var pan123ETag: String?
    /// 139 文件 contentId 和 catalogId（仅139云盘切换集数使用）
    var pan139ContentId: String?
    var pan139CatalogId: String?
    /// 189 文件 ID（仅天翼云盘切换集数使用）
    var pan189FileId: String?
    /// Node 托管盘 playID（A1 接缝 /spider/push/4/play 使用，115/123/139/189/迅雷/光鸭/蜗牛）
    var nodePlayID: String?
    /// Node 托管盘类型（切集取链时用于映射盘别）
    var nodeDriveType: CloudDriveManager.DriveType?
    /// 播放头信息
    var headers: [String: String] = [:]
    /// 是否需要兼容内核
    var useCompatibility: Bool = false

    enum EpisodeSourceType: String {
        case normal = "normal"       // 普通资源
        case baidu = "baidu"         // 百度网盘
        case quark = "quark"         // 夸克网盘
        case xunlei = "xunlei"       // 迅雷云盘
        case ali = "ali"             // 阿里云盘
        case one15 = "one15"         // 115网盘
        case pan123 = "pan123"       // 123云盘
        case pan139 = "pan139"       // 139云盘
        case pan189 = "pan189"       // 天翼云盘
        case drive = "drive"        // 其他网盘
        case node = "node"           // Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛）
    }
}

// MARK: - 播放器状态管理
class PlayerState: ObservableObject {
    /// 弹幕预设颜色表
    static let presetColors: [Int: Int] = [
        0: 16777215, // 原始颜色（不使用）
        1: 16777215, // 白色 #FFFFFF
        2: 16776960, // 黄色 #FFFF00
        3: 65280,    // 绿色 #00FF00
        4: 255,      // 蓝色 #0000FF
        5: 16711680, // 红色 #FF0000
        6: 16761035, // 粉色 #FF69B4
        7: 0         // 随机颜色（特殊标记，实际颜色在赋值时随机选取）
    ]
    /// 随机颜色候选列表（排除白色，因为白色在浅色背景上不可见）
    static let randomColorPool: [Int] = [
        16776960, // 黄色
        65280,    // 绿色
        255,      // 蓝色
        16711680, // 红色
        16761035, // 粉色
        16753920, // 橙色 #FF8C00
        65535,    // 青色 #00FFFF
        10025886  // 紫色 #9932CC
    ]

    enum PlaybackEngineMode: String {
        case system = "系统内核"
        case compatibility = "兼容内核"
    }

    enum PiPStrategy: Equatable {
        case system              // AVPlayer 原生系统画中画
        case videoToolbox        // VideoToolbox 硬解码画中画（独立下载+硬解码）
        case avPlayerProxy       // 兼容内核播放 + AVPlayer 代理/转封装画中画
        case frameBridged        // 兼容内核帧桥接画中画
        case backgroundAudioOnly // 不启动假画中画，仅退后台保留声音
        case unavailable

        var supportsVisualPiP: Bool {
            switch self {
            case .system, .videoToolbox, .avPlayerProxy, .frameBridged:
                return true
            case .backgroundAudioOnly, .unavailable:
                return false
            }
        }

        var allowsControl: Bool {
            switch self {
            case .system, .videoToolbox, .avPlayerProxy, .frameBridged, .backgroundAudioOnly:
                return true
            case .unavailable:
                return false
            }
        }
    }

    enum PlaybackEnginePreference: String, CaseIterable, Identifiable {
        case auto = "自动"
        case system = "系统"
        case mdk = "MDK"
        case vlc = "VLC"
        case mpv = "MPV"
        case ijk = "IJK"
        case ali = "阿里"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .auto:
                return "普通资源走系统内核，特殊格式自动走兼容内核"
            case .system:
                return "强制使用 AVPlayer，适合普通 MP4"
            case .mdk:
                return "MDK 内核，优先稳定播放，后台默认保留声音"
            case .vlc:
                return "优先使用 VLC，不支持系统画中画"
            case .mpv:
                return "MPV 内核，复杂网盘资源优先使用代理画中画"
            case .ijk:
                return "IJKPlayer 内核，适合网盘直链"
            case .ali:
                return "阿里云播放器内核，原生系统画中画，夸克直链首选"
            }
        }
    }

    enum VideoGravityMode: String, CaseIterable {
        case aspectFill = "填充"
        case aspectFit = "适应"
        case resize = "拉伸"

        var avGravity: AVLayerVideoGravity {
            switch self {
            case .aspectFill: return .resizeAspectFill
            case .aspectFit: return .resizeAspect
            case .resize: return .resize
            }
        }

        var icon: String {
            switch self {
            case .aspectFill: return "arrow.up.left.and.arrow.down.right"
            case .aspectFit: return "aspectratio"
            case .resize: return "arrow.left.and.right"
            }
        }
    }

    @Published var player: AVPlayer?
    @Published var isPlaying = true
    @Published var showControls = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isSeeking = false
    @Published var seekPreviewTime: Double = 0
    @Published var isLoading = true
    @Published var loadError: String?
    @Published var showSettings = false
    @Published var showEpisodePicker = false
    @Published var showQualityPicker = false
    @Published var showDanmakuSettings = false
    @Published var showEnginePicker = false
    @Published var showDanmakuInput = false
    @Published var showToolsMenu = false
    @Published var showSkipSettings = false
    @Published var showDanmakuSearch = false
    @Published var showLongPressSpeedSettings = false  // 长按倍速设置弹窗
    @Published var showLongPressSpeedHint = false        // 长按倍速提示浮层
    @Published var showSubtitleSettings = false          // 字幕设置弹窗
    // 长按倍速设置（持久化），默认 2.0x
    @Published var longPressSpeed: Double = UserDefaults.standard.object(forKey: "player_long_press_speed") as? Double ?? 2.0 {
        didSet { UserDefaults.standard.set(longPressSpeed, forKey: "player_long_press_speed") }
    }
    // 长按倍速内部状态
    private var preLongPressSpeed: Double = 1.0
    private var isLongPressing = false
    // 片头片尾设置：按视频 vodId 独立存储，同一剧集所有集数共享
    @Published var skipIntroEnabled = false
    @Published var skipIntroSeconds = 0
    @Published var skipOutroEnabled = false
    @Published var skipOutroSeconds = 0
    @Published var skipOutroTriggered = false  // 防止跳过片尾重复触发
    @Published var skipIntroTriggered = false  // 防止跳过片头重复触发
    @Published var isSwitchingEpisode = false  // 防止兼容内核 Timer 重入导致连续切集
    @Published var currentDanmakuEpisodeId: Int? = nil
    @Published var loadingMessage = "正在解析播放地址..."
    @Published var selectedQuality = 1
    @Published var playbackSpeed: Double = 1.0
    @Published var showDanmaku = true        // 弹幕开关默认打开
    @Published var isPortrait = false
    @Published var danmakuOpacity: Double = 0.8
    @Published var danmakuFontSize: CGFloat = 16
    @Published var danmakuArea: Double = 0.25       // 弹幕显示区域比例 0.25/0.5/0.75/1.0
    @Published var danmakuSpeed: Double = 1.0       // 弹幕滚动速度倍率 0.5/0.75/1.0/1.5/2.0
    @Published var danmakuColorMode: Int = 7       // 0=原始颜色, 1=白色, 2=黄色, 3=绿色, 4=蓝色, 5=红色, 6=粉色, 7=随机(默认)
    @Published var isOrientationLocked = false
    @Published var isPiPActive = false
    // 三个播放器设置开关，持久化到 UserDefaults
    @Published var autoPlayNext: Bool = UserDefaults.standard.object(forKey: "player_auto_play_next") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPlayNext, forKey: "player_auto_play_next") }
    }
    @Published var backgroundPlay: Bool = UserDefaults.standard.object(forKey: "player_background_play") as? Bool ?? true {
        didSet { UserDefaults.standard.set(backgroundPlay, forKey: "player_background_play") }
    }
    @Published var pipEnabled: Bool = UserDefaults.standard.object(forKey: "player_pip_enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(pipEnabled, forKey: "player_pip_enabled") }
    }
    @Published var showDebugOverlay: Bool = UserDefaults.standard.bool(forKey: "show_debug_overlay") {
        didSet { UserDefaults.standard.set(showDebugOverlay, forKey: "show_debug_overlay") }
    }
    @Published var videoGravity: VideoGravityMode = .aspectFill {
        didSet {
            if oldValue != videoGravity {
                NotificationCenter.default.post(name: .vboxVideoGravityChanged, object: nil, userInfo: ["mode": videoGravity])
            }
        }
    }
    @Published var volume: Double = 0.5
    @Published var brightness: Double = 0.5
    @Published var danmakuItems: [DanmakuRenderItem] = []
    @Published var danmakuLoadedCount = 0
    @Published var currentEpisodeIndex = 0
    /// 选集弹窗当前的显示排序方向（false=正序第1集在顶，true=倒序最后一集在顶）。
    /// 提升为 PlayerState 持久状态，使 playNextEpisode / hasNextEpisode 能感知用户的排序选择，
    /// 修复"倒序下播下一集仍按正序数组 +1"导致切集错乱的问题。
    @Published var episodesReversed = false
    @Published var debugLogs: [String] = []  // 可视化调试日志
    @Published var playbackEngineMode: PlaybackEngineMode = .system
    @Published var compatibilityHint: String?
    @Published var compatibilityURL: URL?
    @Published var compatibilityHeaders: [String: String] = [:]
    @Published var compatibilityEngineName: String = "VLC"
    @Published var currentPiPStrategy: PiPStrategy = .system
    @Published var enginePreference: PlaybackEnginePreference = .auto
    @Published var baiduFileList: [BaiduFileItem] = [] // 百度多文件列表
    @Published var baiduShareURL: String = ""    // 百度分享链接
    @Published var baiduCachedTimeRanges: [(start: Double, end: Double)] = []
    /// 场景恢复保护：防止 watchdog 因主线程阻塞杀进程
    @Published var isRestoringFromBackground = false
    private var sceneRestorationTask: Task<Void, Never>?
    @Published var isFavorite: Bool = false  // 当前视频是否已收藏
    
    @Published var subtitleCues: [SubtitleCue] = []        // 解析后的字幕数据
    @Published var showSubtitle: Bool = false               // 字幕开关
    @Published var subtitleFileName: String = ""            // 当前字幕文件名
    @Published var subtitleFontSize: CGFloat = 18           // 字幕字号
    @Published var subtitleColorIndex: Int = 0              // 0=白 1=黄 2=青
    @Published var currentSubtitleText: String? = nil       // 当前应显示的字幕文本

    // 通用集数列表（所有资源类型共用）
    @Published var episodeItems: [EpisodeItem] = []

    /// 详情页传来的已解析集数，避免播放器重复解析 vodPlayUrl 导致选源不一致和卡死
    var preParsedEpisodes: [(name: String, url: String)]? = nil

    /// 当前集资源类型（用于判断走系统画中画还是应用内小窗）
    var currentEpisodeSourceType: EpisodeItem.EpisodeSourceType {
        guard currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count else { return .normal }
        return episodeItems[currentEpisodeIndex].sourceType
    }
    
    var baiduBduss: String = ""                  // 百度Token
    var baiduPcsCookie: String = ""              // 百度PCS下载Cookie
    // 夸克网盘多文件列表
    var quarkFileList: [CloudDriveManager.QuarkShareFile] = []
    var quarkShareURL: String = ""
    var quarkCookie: String = ""
    var quarkRoutePreference: String? = nil     // 线路偏好: "original"(原画) / "transcode"(普画)
    private var currentVideo: VodItem?

    /// 当前视频标题（供搜索弹窗预填）
    var currentVideoTitle: String {
        if !episodeItems.isEmpty, currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count {
            let name = episodeItems[currentEpisodeIndex].name
            return (name as NSString).deletingPathExtension
        }
        return currentVideo?.vodName ?? ""
    }
    private var allDanmakuItems: [LogVarDanmakuItem] = []
    private var emittedDanmakuIDs = Set<Int>()
    private var danmakuTask: Task<Void, Never>?
    private var lastProgressSaveAt: Date = .distantPast
    private var baiduStreamRetryCount = 0        // 百度PCS流403后自动刷新直链次数
    private var baiduPrefetchTask: Task<Void, Never>?
    private var baiduPrefetchingIds = Set<String>()
    private var baiduNearEndPrefetchedIndexes = Set<Int>()
    private var quarkFallbackURL: String?
    private var quarkFallbackHeaders: [String: String]?
    private var quarkFallbackSource: String?
    private var quarkFallbackAttempted = false
    private var quarkFallbackTimeoutTask: Task<Void, Never>?
    private var playbackSessionId = UUID()
    private var playbackWatchdogTask: Task<Void, Never>?
    /// 修复: seek 完成回调超时保护任务，防止 isSeeking 永久为 true
    private var seekTimeoutTask: Task<Void, Never>?
    private var m3u8ProbeCache: [String: M3U8ProbeCacheEntry] = [:]
    private var currentBaiduLocalProxyURL: URL?
    private var currentBaiduStreamId: String?
    private var baiduCacheObserver: NSObjectProtocol?
    /// 修复: 存储 cloudDriveLog 观察者 token，防止泄漏
    private var cloudDriveLogObserver: NSObjectProtocol?
    private var lastBaiduProgressReportAt: Date = .distantPast

    private enum M3U8PlaylistKind: String {
        case fmp4 = "hls-fmp4"
        case ts = "hls-ts"
        case unknown = "hls-unknown"
    }

    private struct M3U8ProbeCacheEntry {
        let kind: M3U8PlaylistKind
        let expiresAt: Date
    }

    private var isVLCBuildAvailable: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    private var isMPVBuildAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    private var isMDKBuildAvailable: Bool {
        #if canImport(swift_mdk)
        return true
        #else
        return false
        #endif
    }

    private var isIJKBuildAvailable: Bool {
        #if canImport(IJKMediaFrameworkWithSSL)
        return true
        #else
        return false
        #endif
    }

    private var isAliPlayerBuildAvailable: Bool {
        // canImport 对手动添加的 framework 可能不生效，改为运行时检测
        return NSClassFromString("AliPlayer") != nil
    }

    private var shouldUseCompatibilityEngine: Bool {
        switch enginePreference {
        case .auto:
            return playbackEngineMode == .compatibility && (isMDKBuildAvailable || isMPVBuildAvailable || isVLCBuildAvailable || isIJKBuildAvailable || isAliPlayerBuildAvailable)
        case .system:
            return false
        case .mdk:
            return isMDKBuildAvailable
        case .vlc:
            return isVLCBuildAvailable
        case .mpv:
            return isMPVBuildAvailable
        case .ijk:
            return isIJKBuildAvailable
        case .ali:
            return isAliPlayerBuildAvailable
        }
    }

    /// 当前使用的兼容内核是否支持系统级画中画
    var isCurrentCompatibilityEngineSupportsPiP: Bool {
        currentPiPStrategy.supportsVisualPiP
    }

    /// 当前画中画按钮是否可用。
    /// 对百度复杂格式等不稳定路线，按钮仍可退后台播放声音，但不会标记为可视 PiP。
    var isPiPSupported: Bool {
        currentPiPStrategy.allowsControl && (currentPiPStrategy != .backgroundAudioOnly || backgroundPlay)
    }

    var pipButtonSystemImage: String {
        if isPiPActive { return "pip.exit" }
        return currentPiPStrategy == .backgroundAudioOnly ? "speaker.wave.2.fill" : "pip.enter"
    }

    private func compatibilityPiPStrategy(engineName: String, url: URL?) -> PiPStrategy {
        let isBaiduProxy = url?.host == "127.0.0.1" && (url?.path.contains("baidu-stream") ?? false)
        if isBaiduProxy {
            // 百度资源的 AVPlayer 代理 PiP 和 VideoToolbox 硬解码 PiP 已在真机验证中出现启动超时/无桌面小窗。
            // 为避免点击小窗后误以为有画面，正式链路先只保留后台声音保底。
            return .backgroundAudioOnly
        }
        if engineName.contains("MPV") || engineName.contains("mpv") {
            return .frameBridged
        }
        return .backgroundAudioOnly
    }

    var currentEngineButtonTitle: String {
        switch enginePreference {
        case .auto:
            if playbackEngineMode == .compatibility {
                // 显示实际使用的兼容内核名称，避免与 EngineResolver 决策不一致
                let shortName = compatibilityEngineName
                    .replacingOccurrences(of: "-MoltenVK", with: "")
                    .replacingOccurrences(of: "Player", with: "")
                return "自动/\(shortName)"
            }
            return "自动"
        case .system:
            return "系统"
        case .mdk:
            return "MDK"
        case .vlc:
            return "VLC"
        case .mpv:
            return "MPV"
        case .ijk:
            return "IJK"
        case .ali:
            return "阿里"
        }
    }

    private func preferredCompatibilityEngineName(for url: URL? = nil) -> String {
        switch enginePreference {
        case .mdk:
            return isMDKBuildAvailable ? "MDK" : "VLC"
        case .mpv:
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .vlc:
            return isVLCBuildAvailable ? "VLC" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .ijk:
            return isIJKBuildAvailable ? "IJKPlayer" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .ali:
            return isAliPlayerBuildAvailable ? "AliPlayer" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .auto:
            if isMDKBuildAvailable, shouldPreferMDK(for: url) {
                return "MDK"
            }
            if isAliPlayerBuildAvailable, shouldPreferAliPlayer(for: url) {
                return "AliPlayer"
            }
            if isIJKBuildAvailable, shouldPreferIJK(for: url) {
                return "IJKPlayer"
            }
            if isMPVBuildAvailable, shouldPreferMPV(for: url) {
                return "MPV-MoltenVK"
            }
            if isVLCBuildAvailable {
                return "VLC"
            }
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .system:
            return "系统"
        }
    }

    private func shouldPreferMDK(for url: URL?) -> Bool {
        guard isMDKBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 夸克 Go 代理流（m3u8 转码 + download_url 直链）优先 MDK
        // MDK 已针对夸克流配置 VT 硬解(m3u8)/FFmpeg软解(download_url) + 缓冲预热
        if text.contains("quark-m3u8") || text.contains("quark-stream") { return true }
        if text.contains("baidu-stream") { return true }
        if text.contains(".mkv") || text.contains("mkv") { return true }
        return false
    }

    private func shouldPreferMPV(for url: URL?) -> Bool {
        guard isMPVBuildAvailable else { return false }
        guard let url else { return compatibilityHint != nil }
        let text = url.absoluteString.lowercased()
        // 百度原画走 MPV，夸克已优先 IJK
        if text.contains("baidu-stream") { return true }
        if text.contains(".mkv") || text.contains("mkv") { return true }
        if compatibilityHint?.contains("MKV") == true { return true }
        if compatibilityHint?.contains("百度原画") == true { return true }
        return false
    }

    private func shouldPreferIJK(for url: URL?) -> Bool {
        guard isIJKBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 夸克/UC/百度直链优先 IJKPlayer
        if text.contains("quark-stream") { return true }
        if text.contains("quark-m3u8") { return true }
        if text.contains("uc-stream") { return true }
        if text.contains("baidu-stream") { return true }
        return false
    }

    private func shouldPreferAliPlayer(for url: URL?) -> Bool {
        guard isAliPlayerBuildAvailable else { return false }
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        // 云盘本地代理 URL（127.0.0.1:18080）对 AliPlayer 兼容性差，自动模式下不优先。
        // AliPlayer 保留用于普通网络视频或阿里直链场景。
        if text.contains("quark-stream") { return false }
        if text.contains("quark-m3u8") { return false }
        if text.contains("baidu-stream") { return false }
        if text.contains("127.0.0.1") { return false }
        return false
    }

    private func compatibilityReason(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        let rules: [(String, String)] = [
            (".mkv", "MKV 封装"),
            (".flv", "FLV 封装"),
            (".avi", "AVI 封装"),
            (".rmvb", "RMVB 封装"),
            ("hevc", "HEVC/H.265"),
            ("h265", "HEVC/H.265"),
            ("x265", "HEVC/H.265"),
            ("10bit", "10bit 视频"),
            ("hdr", "HDR 视频"),
            ("4k", "4K 高码率"),
            ("高码率", "高码率视频")
        ]
        return rules.first(where: { lower.contains($0.0) })?.1
    }

    private func shouldTryBaiduAVPlayerFirst(resourceName: String, playlistKind: M3U8PlaylistKind?) -> Bool {
        if playlistKind != nil { return true }
        let lower = resourceName.lowercased()
        let nativeExtensions = [".mp4", ".m4v", ".mov", ".m3u8"]
        if nativeExtensions.contains(where: { lower.contains($0) }) { return true }
        if lower.contains("m3u8") { return true }
        return compatibilityReason(for: resourceName) == nil
    }

    func cycleVideoGravity() {
        let allModes = VideoGravityMode.allCases
        if let idx = allModes.firstIndex(of: videoGravity) {
            videoGravity = allModes[(idx + 1) % allModes.count]
        }
        log("[PlayerV2] 屏幕拉伸模式切换为：\(videoGravity.rawValue)")
    }

    func selectPlaybackEngine(_ preference: PlaybackEnginePreference) {
        let oldPreference = enginePreference
        enginePreference = preference
        showEnginePicker = false
        switch preference {
        case .auto:
            log("[PlayerV2] 已切换内核策略：自动")
        case .system:
            log("[PlayerV2] 已切换内核策略：系统内核")
        case .mdk:
            log("[PlayerV2] 已切换内核策略：MDK\(isMDKBuildAvailable ? "" : "（当前构建未包含 MDK）")")
        case .vlc:
            log("[PlayerV2] 已切换内核策略：VLC\(isVLCBuildAvailable ? "" : "（当前构建未包含 VLC）")")
        case .mpv:
            log("[PlayerV2] 已切换内核策略：MPV-MoltenVK\(isMPVBuildAvailable ? "" : "（当前构建未包含 Libmpv）")")
        case .ijk:
            log("[PlayerV2] 已切换内核策略：IJKPlayer\(isIJKBuildAvailable ? "" : "（当前构建未包含 IJKPlayer）")")
        case .ali:
            // 如果当前未检测到 AliPlayer，再次触发运行时加载（应对 TrollStore 等场景下启动时未成功加载的情况）
            if !isAliPlayerBuildAvailable {
                loadAliyunPlayerIfNeeded()
            }
            log("[PlayerV2] 已切换内核策略：AliPlayer\(isAliPlayerBuildAvailable ? "" : "（当前构建未包含 AliyunPlayer）")")
        }

        // 如果正在播放网盘资源（夸克/百度），切换内核后立即用新引擎重新播放当前资源
        if oldPreference != preference, isPlaying || compatibilityURL != nil || player != nil {
            // ★ 修复切换内核闪退（GPU 驱动崩溃、无崩溃日志）：
            // 之前的方案只改 compatibilityEngineName 但保留 compatibilityURL，
            // SwiftUI 会在同一个视图更新周期内同时 dismantle 旧内核 + create 新内核，
            // 导致旧内核 GPU 资源（Metal device / OpenGL ES context）尚未完全释放时
            // 新内核就创建 EAGLContext → GPU 驱动冲突 → 进程被系统杀死（无 crash log）。
            //
            // 正确做法分三步：
            // 1. 先清空 compatibilityURL → SwiftUI 只 dismantle 旧内核，不创建新内核
            // 2. 等一个 runloop tick + 额外延迟，确保旧内核 GPU 资源完全释放
            // 3. 再同时设置新引擎名 + URL → SwiftUI 创建新内核，此时 GPU 已干净
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                let oldURLString = self.compatibilityURL?.absoluteString ?? ""
                let engineName = self.preferredCompatibilityEngineName(
                    for: self.compatibilityURL
                ) ?? "VLC"

                // 第 1 步：清空 compatibilityURL，触发 SwiftUI 拆解旧内核视图（不创建新内核）
                await MainActor.run {
                    self.compatibilityURL = nil
                }
                // 等待 SwiftUI 完成 dismantle + GPU 驱动清理
                // dismantleUIView → stop() → teardown() 是同步调用，但 GPU 资源释放可能延迟
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

                // 第 2 步：设置新引擎名 + URL，触发 SwiftUI 创建新内核视图
                // 此时旧内核 GPU 资源已完全释放，新内核 attach 安全
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.compatibilityEngineName = engineName
                    if let url = URL(string: oldURLString) {
                        self.compatibilityURL = url
                    }
                    self.loadingMessage = "正在切换 \(engineName)..."
                    self.isLoading = true
                }
                // 等待新内核完成初始化
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

                // 第 3 步：用新引擎重新播放当前资源
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.restartCurrentResourceWithNewEngine()
                }
            }
        }

        // 修复: 移除重复的 switchBaiduFile 调用。
        // restartCurrentResourceWithNewEngine() 内部已对百度多文件场景调用了 switchBaiduFile，
        // 此处再调一次会创建两个并发 Task，导致切换到 MPV 时 mpv_create 重入闪退。
        // 仅在非切换内核场景（首次进入播放页、选集切换）才需要走 switchBaiduFile。
    }

    /// 切换内核后，用新引擎重新播放当前正在播放的资源
    private func restartCurrentResourceWithNewEngine() {
        // 夸克多文件：重新播放当前集
        if !quarkFileList.isEmpty, currentEpisodeIndex < quarkFileList.count,
           !quarkShareURL.isEmpty {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let file = self.quarkFileList[self.currentEpisodeIndex]
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: "\(self.quarkShareURL)/\(file.fid)")
                    await self.playResolvedDriveVideo(result)
                } catch {
                    self.log("[PlayerV2] 切换内核后重新播放夸克失败: \(error.localizedDescription)")
                }
            }
            return
        }

        // 百度多文件
        if !baiduFileList.isEmpty, currentEpisodeIndex < baiduFileList.count,
           !baiduShareURL.isEmpty {
            switchBaiduFile(index: currentEpisodeIndex)
            return
        }

        // 通用网盘/普通资源：如果有当前播放 URL，直接重新走 playDriveVideo
        if let url = compatibilityURL?.absoluteString, !url.isEmpty {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.playDriveVideo(url: url, headers: self.compatibilityHeaders)
            }
            return
        }

        // 系统播放器 AVPlayer 场景：如果正在播放，重新创建播放器以应用新内核选择
        if let url = player?.currentItem?.asset as? AVURLAsset {
            currentTask?.cancel()
            currentTask = Task { [weak self] in
                guard let self else { return }
                await self.playDriveVideo(url: url.url.absoluteString, headers: [:])
            }
        }
    }

    /// 切换百度多文件中的指定文件播放
    func switchBaiduFile(index: Int) {
        guard index >= 0, index < baiduFileList.count else {
            isSwitchingEpisode = false
            return
        }
        let file = baiduFileList[index]
        let url = baiduShareURL
        guard !url.isEmpty else {
            isSwitchingEpisode = false
            return
        }
        
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.startBaiduPlayback(
                shareURL: url,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "选集"
            )
        }
    }

    func seek(to seconds: Double) {
        // 清理弹幕状态：拖拽后需要重新发射目标时间附近的弹幕
        emittedDanmakuIDs.removeAll()
        danmakuItems = []
        if compatibilityURL != nil {
            guard duration.isFinite, duration > 0 else { return }
            let target = max(0, min(seconds, duration))
            isSeeking = true
            seekPreviewTime = target
            currentTime = target
            isLoading = false
            log("[PlayerV2] \(compatibilityEngineName) 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")
            // 修复: 百度网盘走 MDK 内核时，compatibilityEngineName="MDK" 不含 "MPV"，
            // 导致 seek 通知被错误发往 VLC，MDK 引擎从未收到 seek 命令。
            // 新增 .vboxMDKSeek 路由，确保 MDK 内核也能收到拖拽进度跳转。
            let notification: Notification.Name
            if compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK") {
                notification = .vboxMPVSeek
            } else if compatibilityEngineName.contains("MDK") {
                notification = .vboxMDKSeek
            } else {
                notification = .vboxVLCSeek
            }
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["seconds": target])
            isSeeking = false
            return
        }
        guard let player, duration.isFinite, duration > 0 else { return }
        let target = max(0, min(seconds, duration))
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        seekPreviewTime = target
        loadingMessage = "正在跳转到 \(formatDuration(target))..."
        isLoading = true
        log("[PlayerV2] 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")

        // 修复: 取消上一次 seek 超时保护任务（连续拖拽场景）
        seekTimeoutTask?.cancel()

        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                // 修复: seek 完成回调触发，取消超时保护任务
                self.seekTimeoutTask?.cancel()
                self.seekTimeoutTask = nil
                self.currentTime = target
                self.isSeeking = false
                self.isLoading = false
                if finished, self.isPlaying {
                    self.player?.play()
                }
            }
        }

        // 修复: 启动 seek 超时保护，3 秒内若完成回调未触发则强制重置状态
        // 防止 AVPlayer 在某些流媒体（如部分 HLS）上 seek 完成回调永不触发，
        // 导致 isSeeking 永久为 true、控制面板卡死。
        // 此超时不影响网盘播放：网盘 seek 正常情况下在 1 秒内完成。
        seekTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.isSeeking else { return }
            self.log("[PlayerV2] ⚠️ seek 完成回调超时(3s)，强制重置 isSeeking 状态")
            self.isSeeking = false
            self.isLoading = false
            self.currentTime = target
            if self.isPlaying {
                self.player?.play()
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func playNextBaiduFile() {
        let next = currentEpisodeIndex + 1
        guard next < baiduFileList.count else {
            log("[Baidu] 已经是最后一集")
            isSwitchingEpisode = false
            return
        }
        switchBaiduFile(index: next)
    }
    
    /// 是否有下一集（通用）。
    /// 感知排序方向：episodesReversed=true 时"下一集"是数组中的前一个元素，
    /// 而不是 +1。这样倒序播放时点"下一集"会按用户看到的顺序推进。
    var hasNextEpisode: Bool {
        if episodesReversed {
            return currentEpisodeIndex > 0
        }
        if !episodeItems.isEmpty {
            return currentEpisodeIndex + 1 < episodeItems.count
        }
        return currentEpisodeIndex + 1 < baiduFileList.count
    }
    
    /// 播放下一集（通用）。
    /// 感知排序方向：正序 → +1；倒序 → -1。
    func playNextEpisode() {
        // 防重入：兼容内核 Timer 在切集完成前可能再次触发
        guard !isSwitchingEpisode else {
            log("[PlayerV2] ⚠️ 正在切集中，跳过重复的 playNextEpisode 调用")
            return
        }
        let step = episodesReversed ? -1 : 1
        let nextIndex = currentEpisodeIndex + step
        guard nextIndex >= 0 else {
            log("[PlayerV2] 已播放到最后一集（倒序到头）")
            isSwitchingEpisode = false
            return
        }
        isSwitchingEpisode = true
        if !episodeItems.isEmpty {
            guard nextIndex < episodeItems.count else {
                log("[PlayerV2] 已播放到最后一集")
                isSwitchingEpisode = false
                return
            }
            switchToEpisode(index: nextIndex)
        } else {
            guard nextIndex < baiduFileList.count else {
                log("[PlayerV2] 已播放到最后一集")
                isSwitchingEpisode = false
                return
            }
            switchBaiduFile(index: nextIndex)
        }
    }

    /// 如果有下一集则自动播放（用于播放结束回调）
    func playNextEpisodeIfAvailable() {
        guard autoPlayNext else {
            log("[PlayerV2] 自动播放下一集已关闭")
            return
        }
        guard hasNextEpisode else {
            log("[PlayerV2] 已播放到最后一集")
            return
        }
        log("[PlayerV2] 自动播放下一集")
        playNextEpisode()
    }

    func togglePlayback(player: AVPlayer?) {
        if let player {
            isPlaying ? player.pause() : player.play()
            isPlaying.toggle()
            updateIdleTimer()
            return
        }
        guard compatibilityURL != nil else { return }
        let isMPVorIJK = compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK")
        let isMDK = compatibilityEngineName.contains("MDK")
        if isPlaying {
            let pauseNotification: Notification.Name = isMPVorIJK ? .vboxMPVPause : (isMDK ? .vboxMDKPause : .vboxVLCPause)
            NotificationCenter.default.post(name: pauseNotification, object: nil)
        } else {
            let playNotification: Notification.Name = isMPVorIJK ? .vboxMPVPlay : (isMDK ? .vboxMDKPlay : .vboxVLCPlay)
            NotificationCenter.default.post(name: playNotification, object: nil)
        }
        isPlaying.toggle()
        updateIdleTimer()
    }

    /// 更新屏幕自动锁屏状态
    /// 播放中禁用自动锁屏，暂停/停止时恢复
    /// 注：主要防锁屏逻辑已迁移至 SwiftUI .onChange(of: isPlaying) 统一管理，
    /// 此方法保留作为 togglePlayback 的同步兜底
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isPlaying
    }

    func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if let player {
            player.rate = isPlaying ? Float(speed) : 0
        }
        if compatibilityURL != nil {
            let isMPVorIJK = compatibilityEngineName.contains("MPV") || compatibilityEngineName.contains("IJK")
            let isMDK = compatibilityEngineName.contains("MDK")
            let notification: Notification.Name = isMPVorIJK ? .vboxMPVSpeed : (isMDK ? .vboxMDKSpeed : .vboxVLCSpeed)
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["speed": speed])
            log("[PlayerV2] \(compatibilityEngineName) 倍速切换：\(String(format: "%.2f", speed))X")
        }
    }

    // MARK: - 长按倍速
    /// 长按屏幕开始：记录当前倍速，切换到长按倍速
    func startLongPressSpeed() {
        guard !isLongPressing else { return }
        isLongPressing = true
        preLongPressSpeed = playbackSpeed
        changePlaybackSpeed(longPressSpeed)
        showLongPressSpeedHint = true
        // 震动触感反馈
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// 松手结束：恢复长按前的倍速
    func endLongPressSpeed() {
        guard isLongPressing else { return }
        isLongPressing = false
        changePlaybackSpeed(preLongPressSpeed)
        showLongPressSpeedHint = false
    }

    // MARK: - 字幕

    /// 加载字幕文件
    func loadSubtitle(url: URL) {
        // 文档选择器返回的 URL 可能需要安全作用域访问权限
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let cues = SubtitleParser.parse(url: url), !cues.isEmpty else {
            log("[PlayerV2] 字幕解析失败: \(url.lastPathComponent)")
            return
        }
        subtitleCues = cues
        subtitleFileName = url.deletingPathExtension().lastPathComponent
        showSubtitle = true
        currentSubtitleText = nil
        log("[PlayerV2] ✅ 字幕加载成功: \(subtitleFileName) (\(cues.count) 条)")
    }

    /// 清除字幕
    func clearSubtitle() {
        subtitleCues = []
        showSubtitle = false
        subtitleFileName = ""
        currentSubtitleText = nil
    }

    /// 根据当前播放时间更新字幕显示（二分查找）
    func updateSubtitle(currentTime: Double) {
        guard showSubtitle, !subtitleCues.isEmpty else {
            if currentSubtitleText != nil { currentSubtitleText = nil }
            return
        }

        // 二分查找当前时间对应的字幕
        var lo = 0, hi = subtitleCues.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let cue = subtitleCues[mid]
            if currentTime < cue.startTime {
                hi = mid - 1
            } else if currentTime > cue.endTime {
                lo = mid + 1
            } else {
                // 命中
                if currentSubtitleText != cue.text {
                    currentSubtitleText = cue.text
                }
                return
            }
        }
        // 未命中：清空
        if currentSubtitleText != nil { currentSubtitleText = nil }
    }

    /// 字幕颜色
    var subtitleColor: Color {
        switch subtitleColorIndex {
        case 1: return .yellow
        case 2: return .cyan
        default: return .white
        }
    }

    func changeQuality(index: Int) {
        selectedQuality = index
        if !baiduFileList.isEmpty {
            log("[Baidu] 当前百度DLNA播放为源文件/原画链路，暂不支持转码清晰度切换")
        }
    }

    /// 从URL中检测视频画质并更新 selectedQuality（0=标清, 1=高清, 2=蓝光）
    func detectVideoQuality(from urlString: String) {
        let lower = urlString.lowercased()
        // 蓝光/4K
        if lower.contains("蓝光") || lower.contains("bd") || lower.contains("bluray") ||
           lower.contains("2160") || lower.contains("4k") || lower.contains("uhd") {
            selectedQuality = 2
            log("[PlayerV2] 画质检测: 蓝光")
            return
        }
        // 高清/1080p
        if lower.contains("高清") || lower.contains("1080") || lower.contains("超清") ||
           lower.contains("hd") || lower.contains("fhd") || lower.contains("full") {
            selectedQuality = 1
            log("[PlayerV2] 画质检测: 高清")
            return
        }
        // 标清/720p及以下
        if lower.contains("标清") || lower.contains("720") || lower.contains("480") ||
           lower.contains("360") || lower.contains("sd") || lower.contains("low") {
            selectedQuality = 0
            log("[PlayerV2] 画质检测: 标清")
            return
        }
        // 默认高清
        log("[PlayerV2] 画质检测: 默认高清")
    }

    private func loadDanmaku(for video: VodItem, fileName: String) {
        danmakuTask?.cancel()
        allDanmakuItems = []
        danmakuItems = []
        emittedDanmakuIDs.removeAll()
        danmakuLoadedCount = 0

        let query = bestDanmakuQuery(video: video, fileName: fileName)
        guard !query.isEmpty else { return }
        log("[Danmaku] 开始匹配：\(query)")
        danmakuTask = Task { [weak self] in
            // 先匹配episodeId，保存到状态
            if let episodeId = await LogVarDanmakuService.shared.matchEpisode(fileName: query) {
                await MainActor.run {
                    self?.currentDanmakuEpisodeId = episodeId
                }
            }
            let items = await LogVarDanmakuService.shared.matchAndFetch(fileName: query)
            await MainActor.run {
                guard let self else { return }
                self.allDanmakuItems = items.sorted { $0.time < $1.time }
                self.danmakuLoadedCount = items.count
                self.emittedDanmakuIDs.removeAll()
                self.danmakuItems = []
                self.log(items.isEmpty ? "[Danmaku] 未匹配到弹幕" : "[Danmaku] 已加载 \(items.count) 条弹幕")
            }
        }
    }

    /// 手动搜索并加载弹幕（用户从搜索弹窗选择后调用）
    func manualLoadDanmaku(episodeId: Int) {
        danmakuTask?.cancel()
        allDanmakuItems = []
        danmakuItems = []
        emittedDanmakuIDs.removeAll()
        danmakuLoadedCount = 0
        currentDanmakuEpisodeId = episodeId

        log("[Danmaku] 手动加载弹幕，episodeId=\(episodeId)")
        danmakuTask = Task { [weak self] in
            let items = await LogVarDanmakuService.shared.fetchDanmaku(episodeId: episodeId)
            await MainActor.run {
                guard let self else { return }
                self.allDanmakuItems = items.sorted { $0.time < $1.time }
                self.danmakuLoadedCount = items.count
                self.emittedDanmakuIDs.removeAll()
                self.danmakuItems = []
                if !items.isEmpty {
                    self.showDanmaku = true
                }
                self.log(items.isEmpty ? "[Danmaku] 该集无弹幕" : "[Danmaku] 已加载 \(items.count) 条弹幕")
            }
        }
    }

    private func bestDanmakuQuery(video: VodItem, fileName: String) -> String {
        let candidate = (fileName as NSString).deletingPathExtension
        // 网盘资源通常有真实文件名，优先使用
        if candidate.count >= 4,
           candidate != "baidu-stream",
           candidate != "quark-stream",
           candidate != "ali-stream",
           !candidate.hasPrefix("http"),
           !candidate.allSatisfy({ $0.isNumber }) {
            return candidate
        }
        // 切片资源或文件名不规范时，使用视频标题+集数组合
        let episodeNum = extractEpisodeNumber(from: fileName)
        if episodeNum > 1 {
            return "\(video.vodName) E\(String(format: "%02d", episodeNum))"
        }
        return video.vodName
    }
    
    /// 从文件名提取集数（用于弹幕查询增强）
    private func extractEpisodeNumber(from fileName: String) -> Int {
        let name = (fileName as NSString).deletingPathExtension
        let patterns = [
            #"[Ee][Pp]?(\d{1,3})(?:\b|[^0-9])"#,
            #"第\s*(\d{1,3})\s*[集话话期]"#,
            #"\.(\d{1,3})\."#,
            #"_(\d{1,3})_"#,
            #"\s(\d{1,3})\s"#
        ]
        for pattern in patterns {
            if let range = name.range(of: pattern, options: .regularExpression) {
                let numStr = String(name[range]).filter { $0.isNumber }
                if let num = Int(numStr), num > 0 {
                    return num
                }
            }
        }
        return 1
    }

    /// 轨道占用记录：[laneIndex: (最后一条弹幕进入时间, 最后一条弹幕内容长度)]
    private var laneOccupancy: [Int: (time: Double, contentLength: Int)] = [:]
    /// 记录每条弹幕的预估宽度，用于水平碰撞检测
    private var danmakuWidthCache: [Int: CGFloat] = [:]
    /// 限制弹幕刷新频率
    private var lastDanmakuUpdateTime: Double = -1

    func updateDanmaku(at time: Double) {
        guard showDanmaku, !allDanmakuItems.isEmpty, time.isFinite else { return }
        lastDanmakuUpdateTime = time
        // 时间窗口必须覆盖观察器间隔（0.5s），否则大量弹幕会被漏掉
        let windowStart = max(0, time - 0.55)
        let windowEnd = time + 0.1
        let newItems = allDanmakuItems
            .filter { $0.time >= windowStart && $0.time <= windowEnd && !emittedDanmakuIDs.contains($0.id) }
            .prefix(8)

        guard !newItems.isEmpty || !danmakuItems.isEmpty else { return }
        for item in newItems {
            emittedDanmakuIDs.insert(item.id)
        }
        // 弹幕持续时间：速度越快持续时间越短
        let baseDuration = 8.0
        let duration = baseDuration / max(danmakuSpeed, 0.25)
        // 动态计算轨道数：根据字体大小和显示区域
        let laneHeight = danmakuFontSize + 22
        // 使用更合理的预估高度，竖屏约 400pt，横屏约 220pt
        let areaHeight = isPortrait ? 400.0 * danmakuArea : 220.0 * danmakuArea
        let maxLanes = max(4, Int(areaHeight / laneHeight))
        let screenW = isPortrait ? CGFloat(400) : CGFloat(700) // 横屏更宽

        // 清理已过期的轨道占用记录（弹幕已离开屏幕）
        laneOccupancy = laneOccupancy.filter { _, info in
            time - info.time < duration
        }

        let appended = newItems.compactMap { item -> DanmakuRenderItem? in
            let itemWidth = max(80, CGFloat(item.content.count) * danmakuFontSize * (item.content.isASCII ? 0.6 : 0.72))
            danmakuWidthCache[item.id] = itemWidth

            // 水平碰撞检测：计算前一条弹幕当前位置，确保新弹幕不会追上
            let minGap: Double = 1.8 // 同轨道最小时间间隔（秒）
            let minHorizontalGap: CGFloat = 100.0 // 水平最小间距（点）

            var assignedLane = 0
            var foundLane = false

            for lane in 0..<maxLanes {
                if let lastInfo = laneOccupancy[lane] {
                    let timeGap = time - lastInfo.time
                    // 时间间隔必须足够
                    guard timeGap >= minGap else { continue }

                    // 水平碰撞检测：使用当前 lane 上一条弹幕的宽度
                    let lastWidth = max(80, CGFloat(lastInfo.contentLength) * danmakuFontSize * (item.content.isASCII ? 0.6 : 0.72))
                    let lastProgress = min(max(timeGap / duration, 0), 1)
                    let lastXPos = screenW - lastProgress * (screenW + lastWidth)
                    let lastRightEdge = lastXPos + lastWidth

                    // 新弹幕从右侧进入的位置
                    let newStartX = screenW

                    // 如果前一条弹幕尾部还在屏幕右侧足够远，新弹幕可以安全进入
                    if lastRightEdge < newStartX - minHorizontalGap {
                        assignedLane = lane
                        foundLane = true
                        break
                    }
                } else {
                    assignedLane = lane
                    foundLane = true
                    break
                }
            }

            // 找不到安全轨道直接丢弃该弹幕，避免重叠
            guard foundLane else { return nil }

            // 更新轨道占用时间和内容长度
            laneOccupancy[assignedLane] = (time: time, contentLength: item.content.count)

            return DanmakuRenderItem(
                id: item.id,
                content: item.content,
                time: max(time, item.time),
                lane: assignedLane,
                color: danmakuColorMode == 0 ? item.color : (danmakuColorMode == 7 ? Self.randomColorPool.randomElement() ?? item.color : Self.presetColors[danmakuColorMode] ?? item.color),
                duration: duration
            )
        }
        danmakuItems = (danmakuItems + appended)
            .filter { time - $0.time < $0.duration }
            .suffix(40) // 限制同时渲染的弹幕数量，避免卡顿
    }

    // MARK: - 发送弹幕
    /// 发送弹幕：先本地立即显示，再异步提交到服务器
    func sendDanmaku(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        let baseDuration = 8.0
        let duration = baseDuration / max(danmakuSpeed, 0.25)
        let color = danmakuColorMode == 0 ? 16777215 : (danmakuColorMode == 7 ? Self.randomColorPool.randomElement() ?? 16777215 : Self.presetColors[danmakuColorMode] ?? 16777215)
        let time = currentTime
        // 用一个较大的随机 ID 避免和服务器弹幕 ID 冲突
        let localId = Int.random(in: 1_000_000...9_999_999)

        // 本地立即显示：找一条空闲轨道
        let laneHeight = danmakuFontSize + 22
        let areaHeight = isPortrait ? 400.0 * danmakuArea : 220.0 * danmakuArea
        let maxLanes = max(4, Int(areaHeight / Double(laneHeight)))
        var assignedLane = 0
        var foundLane = false
        for lane in 0..<maxLanes {
            if let lastInfo = laneOccupancy[lane] {
                if time - lastInfo.time >= 1.8 { assignedLane = lane; foundLane = true; break }
            } else {
                assignedLane = lane; foundLane = true; break
            }
        }
        // 所有轨道都被占用时，选最久未使用的轨道
        if !foundLane {
            var oldestTime = Double.infinity
            for (lane, info) in laneOccupancy {
                if info.time < oldestTime { oldestTime = info.time; assignedLane = lane }
            }
        }
        laneOccupancy[assignedLane] = (time: time, contentLength: content.count)

        let renderItem = DanmakuRenderItem(
            id: localId,
            content: content,
            time: time,
            lane: assignedLane,
            color: color,
            duration: duration
        )
        danmakuItems.append(renderItem)

        // 异步提交到服务器
        guard let episodeId = currentDanmakuEpisodeId else {
            log("[Danmaku] 发送失败：未匹配到剧集 episodeId")
            return
        }
        Task {
            let success = await LogVarDanmakuService.shared.sendDanmaku(
                episodeId: episodeId,
                content: content,
                time: time,
                mode: 1,
                color: color
            )
            await MainActor.run {
                self.log(success ? "[Danmaku] 弹幕发送成功：\(content)" : "[Danmaku] 弹幕发送失败：\(content)")
            }
        }
    }

    private func playbackProgressKey(for video: VodItem) -> String {
        "playback_progress_v2_\(video.vodId)_\(currentEpisodeIndex)"
    }

    // MARK: - 片头片尾设置（按视频 vodId 独立存储）
    private func skipSettingsPrefix(for video: VodItem) -> String {
        "skip_\(video.vodId)"
    }

    /// 加载当前视频的片头片尾设置（同一剧集所有集数共享）
    func loadSkipSettings(for video: VodItem) {
        let p = skipSettingsPrefix(for: video)
        skipIntroEnabled = UserDefaults.standard.bool(forKey: "\(p)_intro_enabled")
        skipIntroSeconds = UserDefaults.standard.integer(forKey: "\(p)_intro_seconds")
        skipOutroEnabled = UserDefaults.standard.bool(forKey: "\(p)_outro_enabled")
        skipOutroSeconds = UserDefaults.standard.integer(forKey: "\(p)_outro_seconds")
        skipOutroTriggered = false
        skipIntroTriggered = false
        log("[PlayerV2] 加载片头片尾设置: 片头=\(skipIntroEnabled ? "开" : "关")(\(skipIntroSeconds)s) 片尾=\(skipOutroEnabled ? "开" : "关")(\(skipOutroSeconds)s)")
    }

    /// 保存当前视频的片头片尾设置
    func saveSkipSettings() {
        guard let video = currentVideo else { return }
        let p = skipSettingsPrefix(for: video)
        UserDefaults.standard.set(skipIntroEnabled, forKey: "\(p)_intro_enabled")
        UserDefaults.standard.set(skipIntroSeconds, forKey: "\(p)_intro_seconds")
        UserDefaults.standard.set(skipOutroEnabled, forKey: "\(p)_outro_enabled")
        UserDefaults.standard.set(skipOutroSeconds, forKey: "\(p)_outro_seconds")
    }

    private func restorePlaybackProgress(for video: VodItem) {
        let key = playbackProgressKey(for: video)
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 10 else { return }
        currentTime = saved
        seekPreviewTime = saved
        log("[Progress] 已恢复上次进度：\(formatDuration(saved))")
    }

    func savePlaybackProgress(force: Bool = false) {
        guard let video = currentVideo, currentTime.isFinite, currentTime > 5 else { return }
        if duration > 0, duration - currentTime < 15 {
            // 快进到末尾：清除进度，移到后台执行避免 SQLite/UserDefaults 阻塞主线程
            let key = playbackProgressKey(for: video)
            let videoId = video.vodId
            Task.detached(priority: .utility) {
                UserDefaults.standard.removeObject(forKey: key)
                let favorites = DatabaseManager.shared.queryFavorites()
                if let record = favorites.first(where: { $0.detailurl == videoId }),
                   let fid = record.id {
                    DatabaseManager.shared.removeFavorite(id: fid)
                }
            }
            return
        }
        guard force || Date().timeIntervalSince(lastProgressSaveAt) > 5 else { return }
        lastProgressSaveAt = Date()
        // 所有 I/O 操作移到后台队列，避免 SQLite + UserDefaults 阻塞主线程
        let key = playbackProgressKey(for: video)
        let timeToSave = currentTime
        let episodeToSave = currentEpisodeIndex
        let videoName = video.vodName
        let videoRemarks = video.vodRemarks ?? ""
        let videoPic = video.vodPic ?? ""
        let videoId = video.vodId
        let videoEngineKey = video.engineKey
        Task.detached(priority: .utility) {
            UserDefaults.standard.set(timeToSave, forKey: key)
            let platformKey: String = {
                guard let ek = videoEngineKey, ek.hasPrefix("__fuli_welfare__:") else { return "" }
                return String(ek.dropFirst("__fuli_welfare__:".count))
            }()
            let record = HistoryRecord(
                name: videoName,
                laiyuan: videoRemarks,
                imgurl: videoPic,
                detailurl: videoId,
                detailua: platformKey,
                xianlu: episodeToSave,
                jishu: 0,
                progress: timeToSave,
                lastPlayedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addOrUpdateHistory(record)
        }
    }

    // MARK: - 收藏功能

    /// 检查当前视频是否已收藏
    func checkFavoriteStatus() {
        guard let video = currentVideo else { return }
        isFavorite = DatabaseManager.shared.isFavorite(
            detailurl: video.vodId,
            xianlu: currentEpisodeIndex,
            jishu: 0
        )
    }

    /// 切换收藏状态
    func toggleFavorite() {
        guard let video = currentVideo else { return }
        if isFavorite {
            // 取消收藏：从数据库中查找并删除
            let favorites = DatabaseManager.shared.queryFavorites()
            if let record = favorites.first(where: {
                $0.detailurl == video.vodId &&
                $0.xianlu == currentEpisodeIndex
            }) {
                if let id = record.id {
                    DatabaseManager.shared.removeFavorite(id: id)
                    isFavorite = false
                    log("[Favorite] 已取消收藏: \(video.vodName)")
                }
            }
        } else {
            // 添加收藏
            let platformKey: String = {
                guard let ek = video.engineKey, ek.hasPrefix("__fuli_welfare__:") else { return "" }
                return String(ek.dropFirst("__fuli_welfare__:".count))
            }()
            let record = FavoriteRecord(
                name: video.vodName,
                laiyuan: video.vodRemarks ?? "",
                imgurl: video.vodPic ?? "",
                detailurl: video.vodId,
                detailua: platformKey,
                xianlu: currentEpisodeIndex,
                jishu: 0,
                addedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addFavorite(record)
            isFavorite = true
            log("[Favorite] 已收藏: \(video.vodName)")
        }
    }

    func formatDuration(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    /// 百度网盘统一播放入口：
    /// - 进入播放器：解析出文件列表后立即调用，默认播放第一集
    /// - 手动选集：带指定 fs_id 调用
    /// 这样不会只停在“文件列表成功”而不继续触发 Worker /play。
    private func startBaiduPlayback(
        shareURL: String,
        bduss: String,
        pcsCookie: String = "",
        file: BaiduFileItem,
        index: Int,
        reason: String
    ) async {
        let episodeNo = index + 1
        log("[Baidu] ②\(reason)第\(episodeNo)集：\(file.name)，主路链→原有链路兜底...")
        await MainActor.run {
            currentEpisodeIndex = index
            skipOutroTriggered = false
            skipIntroTriggered = false
            isSwitchingEpisode = false
            if let video = currentVideo {
                loadDanmaku(for: video, fileName: file.name)
                restorePlaybackProgress(for: video)
            }
            isLoading = true
            loadingMessage = "正在获取百度视频地址..."
            loadError = nil
            if let reason = compatibilityReason(for: file.name) {
                playbackEngineMode = .compatibility
                compatibilityHint = reason
                log("[PlayerV2] 当前资源疑似需要兼容内核：\(reason)")
            } else {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
        }

        do {
            let resolveStart = Date()
            let result = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                shareURL: shareURL,
                bduss: bduss,
                fsId: file.fsId,
                fileName: file.name,
                pcsCookie: pcsCookie
            )
            log("[Baidu-iBoxRoute] ✅ 第\(episodeNo)集 iBox-style 路链播放地址获取成功，耗时=\(Int(Date().timeIntervalSince(resolveStart) * 1000))ms")
            if !reason.contains("刷新") && !reason.contains("重试") {
                baiduStreamRetryCount = 0
            }
            let source = result.source ?? "未知路链"
            log("[Baidu] 第\(episodeNo)集命中路链：\(source)")
            if source.contains("m3u8") || result.url.lowercased().contains(".m3u8") || result.url.contains("/share/streaming") {
                await MainActor.run {
                    playbackEngineMode = .system
                    compatibilityHint = nil
                }
                log("[Baidu] M3U8 兜底路链使用系统 HLS 内核")
            }
            let streamHeaders = mergedBaiduStreamHeaders(result.headers)
            await playDriveVideo(url: result.url, headers: streamHeaders)
        } catch let error as DriveError {
            let specificMsg: String
            switch error {
            case .noPlayURL(let reason): specificMsg = reason
            case .saveFailed: specificMsg = "转存失败"
            case .invalidResponse: specificMsg = "服务器响应异常"
            default: specificMsg = error.localizedDescription
            }
            log("[Baidu] ❌ 第\(episodeNo)集：\(specificMsg)")
            await MainActor.run {
                self.failPlayback(specificMsg)
            }
        } catch {
            log("[Baidu] ❌ 第\(episodeNo)集：\(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("百度播放失败: \(error.localizedDescription)")
            }
        }
    }

    /// 添加调试日志（同时打印到控制台和UI）
    /// 使用 DispatchQueue.main.async 而非 Task，避免高频日志调用时大量 Task 对象
    /// 挤占主线程协程调度队列导致 UI 卡顿
    /// 当前播放器内核名称（用于日志标识）
    private var currentEngineLabel: String {
        switch playbackEngineMode {
        case .system:
            return "AVPlayer"
        case .compatibility:
            return compatibilityEngineName
        }
    }
    
    func log(_ msg: String) {
        print(msg)
        // 转发到统一日志系统 (player 分类，带内核标识)
        let level: LogLevel = msg.contains("失败") || msg.contains("错误") || msg.contains("❌") ? .error : .info
        let engine = Thread.isMainThread ? currentEngineLabel : "Player"
        let logMsg = "[\(engine)] \(msg.replacingOccurrences(of: "[PlayerV2] ", with: ""))"
        AppLogStore.shared.log(level, .player, logMsg)
        
        let short = msg.replacingOccurrences(of: "[PlayerV2] ", with: "")
        if Thread.isMainThread {
            debugLogs.append(short)
            // 修复: 批量删除降低频率，原 removeFirst(count-500) 每条日志都触发 O(n) 操作
            if debugLogs.count > 600 { debugLogs.removeFirst(100) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.debugLogs.append(short)
                if (self?.debugLogs.count ?? 0) > 600 {
                    self?.debugLogs.removeFirst(100)
                }
            }
        }
    }

    /// 导出调试日志到文件并弹出分享面板
    func exportDebugLogs() {
        var content = debugLogs.joined(separator: "\n")

        // ===== 附加 Go 代理诊断日志 =====
        let proxyLogs = GoProxyManager.shared.getDebugLogs()
        let proxyStats = GoProxyManager.shared.getStats()
        if !proxyLogs.isEmpty && proxyLogs != "[]" {
            content += "\n\n===== Go代理诊断日志 =====\n"
            if let data = proxyLogs.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for entry in arr {
                    let ts = entry["ts"] as? String ?? ""
                    let msg = entry["msg"] as? String ?? ""
                    content += "[\(ts)] \(msg)\n"
                }
            } else {
                content += proxyLogs + "\n"
            }
        }
        if !proxyStats.isEmpty && proxyStats != "{}" {
            content += "\n===== Go代理统计 =====\n\(proxyStats)\n"
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "playback_debug_\(dateFormatter.string(from: Date())).log"

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            log("[PlayerV2] 日志已导出: \(fileName) (\(content.count) bytes)")

            // 弹出系统分享面板
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                // 分享完成后清理临时文件
                try? FileManager.default.removeItem(at: fileURL)
            }

            // 找到最顶层的 viewController 来 present（避免 rootVC 已有 presentedVC 时 present 失败）
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                log("[PlayerV2] 日志导出失败: 找不到根视图控制器")
                return
            }

            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }

            // iPad 上需要设置 popover 源
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            topVC.present(activityVC, animated: true) { [weak self] in
                self?.log("[PlayerV2] 分享面板已弹出")
            }
        } catch {
            log("[PlayerV2] 日志导出失败: \(error.localizedDescription)")
        }
    }

    private func bindBaiduCacheProgress(for localURL: URL?) {
        currentBaiduLocalProxyURL = localURL
        baiduCachedTimeRanges = []
        currentBaiduStreamId = URLComponents(url: localURL ?? URL(fileURLWithPath: ""), resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value
        if baiduCacheObserver == nil {
            baiduCacheObserver = NotificationCenter.default.addObserver(
                forName: .vboxBaiduStreamCacheProgress,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleBaiduCacheProgress(notification)
            }
        }
    }

    private func handleBaiduCacheProgress(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? String,
              id == currentBaiduStreamId,
              duration.isFinite,
              duration > 0,
              let totalBytes = notification.userInfo?["totalBytes"] as? Int64,
              totalBytes > 0,
              let ranges = notification.userInfo?["ranges"] as? [[String: Int64]]
        else { return }

        let total = Double(totalBytes)
        baiduCachedTimeRanges = ranges.compactMap { item in
            guard let start = item["start"], let end = item["end"], end >= start else { return nil }
            let startTime = max(0, min(Double(start) / total * duration, duration))
            let endTime = max(0, min(Double(end + 1) / total * duration, duration))
            return (start: startTime, end: endTime)
        }

        // 计算预加载缓冲信息并输出到调试日志
        let cachedBytes = ranges.reduce(Int64(0)) { acc, item in
            guard let start = item["start"], let end = item["end"] else { return acc }
            return acc + max(0, end - start + 1)
        }
        let cachedMB = Double(cachedBytes) / 1024.0 / 1024.0
        let aheadRanges = baiduCachedTimeRanges.filter { $0.start > currentTime }
        let aheadSeconds = aheadRanges.reduce(0.0) { $0 + max(0, $1.end - max($1.start, currentTime)) }
        let bufferStatus: String
        if aheadSeconds < 10 {
            bufferStatus = "⚠️不足"
        } else if aheadSeconds < 30 {
            bufferStatus = "🟡一般"
        } else {
            bufferStatus = "🟢充足"
        }
        log("[预加载] 缓冲:\(String(format: "%.0f", aheadSeconds))秒\(bufferStatus) | 缓存:\(String(format: "%.1f", cachedMB))MB")
    }

    func reportBaiduCacheProgressIfNeeded(force: Bool = false) {
        guard let currentBaiduLocalProxyURL else { return }
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastBaiduProgressReportAt) >= 4 else { return }
        lastBaiduProgressReportAt = now
        DoubanImageProxyServer.shared.reportBaiduStreamProgress(
            localURL: currentBaiduLocalProxyURL,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func logDrivePlayResult(_ result: PlayResult) {
        if result.driveType == .quark {
            log("[Quark] 主线路：\(result.source ?? "未知")，host=\(URL(string: result.url)?.host ?? "unknown")")
            if let fallbackURL = result.fallbackURL {
                log("[Quark] 兜底线路：\(result.fallbackSource ?? "未知")，host=\(URL(string: fallbackURL)?.host ?? "unknown")")
            } else {
                log("[Quark] 兜底线路：暂无")
            }
        }
    }

    private func playResolvedDriveVideo(_ result: PlayResult) async {
        if result.driveType == .quark {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = result.fallbackURL
            quarkFallbackHeaders = result.fallbackHeaders
            quarkFallbackSource = result.fallbackSource
            logDrivePlayResult(result)
            await playDriveVideo(url: result.url, headers: result.headers, driveType: result.driveType)
        } else {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = nil
            quarkFallbackHeaders = nil
            quarkFallbackSource = nil
            await playDriveVideo(url: result.url, headers: result.headers, driveType: result.driveType)
        }
    }

    @discardableResult
    private func switchToQuarkFallback(reason: String) -> Bool {
        guard !quarkFallbackAttempted,
              let url = quarkFallbackURL,
              !url.isEmpty else {
            log("[Quark] 兜底线路不可用，无法切换：\(reason)")
            return false
        }

        quarkFallbackAttempted = true
        quarkFallbackTimeoutTask?.cancel()
        let headers = quarkFallbackHeaders ?? [:]
        let source = quarkFallbackSource ?? "v2-play-m3u8"
        log("[Quark] 原画线路失败，切换兜底线路：\(source)，原因：\(reason)")

        Task { [weak self] in
            guard let self else { return }
            await self.playDriveVideo(url: url, headers: headers)
        }
        return true
    }

    private func scheduleQuarkPrimaryFallbackTimeout(playerItem: AVPlayerItem, startedAt: Date) {
        guard quarkFallbackURL != nil, !quarkFallbackAttempted else { return }
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = Task { [weak self, weak playerItem] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, let playerItem, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.player?.currentItem === playerItem,
                      self.isLoading,
                      playerItem.status != .readyToPlay,
                      !self.quarkFallbackAttempted else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.log("[Quark] 原画线路首帧超时 \(elapsed)ms，准备切换 m3u8 兜底")
                self.switchToQuarkFallback(reason: "首帧超时")
            }
        }
    }

    private func prefetchNextBaiduFile(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < baiduFileList.count else { return }
        guard !baiduShareURL.isEmpty else { return }
        let nextFile = baiduFileList[nextIndex]
        guard !nextFile.fsId.isEmpty, !baiduPrefetchingIds.contains(nextFile.fsId) else { return }
        baiduPrefetchingIds.insert(nextFile.fsId)
        let shareURL = baiduShareURL
        let bduss = baiduBduss
        let pcsCookie = baiduPcsCookie

        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = Task { [weak self] in
            guard let self else { return }
            self.log("[Baidu-MainRoute] 开始预取下一集主路链 PlayItem：第\(nextIndex + 1)集 \(nextFile.name)")
            do {
                _ = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                    shareURL: shareURL,
                    bduss: bduss,
                    fsId: nextFile.fsId,
                    fileName: nextFile.name,
                    pcsCookie: pcsCookie
                )
                self.log("[Baidu-MainRoute] ✅ 第\(nextIndex + 1)集主路链 PlayItem 已准备")
            } catch {
                self.log("[Baidu-MainRoute] ⚠️ 第\(nextIndex + 1)集主路链预取失败，保留原链路兜底：\(error.localizedDescription)")
            }
            await MainActor.run {
                self.baiduPrefetchingIds.remove(nextFile.fsId)
            }
        }
    }

    private func mergedBaiduStreamHeaders(_ headers: [String: String]) -> [String: String] {
        var merged = headers
        let resultCookie = headerValue(headers, named: "Cookie") ?? ""
        let webCookie = normalizeBaiduCookie(baiduBduss)
        let finalCookie = mergeCookieStrings([resultCookie, webCookie])

        if !finalCookie.isEmpty {
            merged["Cookie"] = finalCookie
        }

        if headerValue(merged, named: "User-Agent") == nil {
            merged["User-Agent"] = "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) AppleWebKit/537.36 (KHTML, like Gecko)&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1&network_type=wifi&app_id=250528&size=c1080_u1600"
        }
        if headerValue(merged, named: "Referer") == nil {
            merged["Referer"] = "https://pan.baidu.com/"
        }

        let lowerCookie = finalCookie.lowercased()
        log("[Baidu] 本地代理合并Cookie：hasBDUSS=\(lowerCookie.contains("bduss=")), hasSTOKEN=\(lowerCookie.contains("stoken=")), hasPANPSC=\(lowerCookie.contains("panpsc=")), hasPTOKEN=\(lowerCookie.contains("ptoken"))")
        return merged
    }

    private func headerValue(_ headers: [String: String], named name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    private func normalizeBaiduCookie(_ raw: String) -> String {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "" }
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.range(of: #"BDUSS=|PANPSC=|PTOKEN|STOKEN=|BAIDUID="#, options: [.regularExpression, .caseInsensitive]) != nil {
            return input
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
                .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)
        }

        if input.contains("|") {
            let cleaned = input.replacingOccurrences(of: #"^BDUSS="#, with: "", options: [.regularExpression, .caseInsensitive])
            let parts = cleaned.components(separatedBy: "|")
            var cookie = "BDUSS=\(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))"
            if parts.count >= 2 {
                let stoken = parts[1]
                    .replacingOccurrences(of: #"^STOKEN="#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stoken.isEmpty {
                    cookie += "; STOKEN=\(stoken)"
                }
            }
            return cookie
        }

        return "BDUSS=\(input.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func mergeCookieStrings(_ cookies: [String]) -> String {
        var orderedKeys: [String] = []
        var values: [String: (name: String, value: String)] = [:]

        for cookie in cookies where !cookie.isEmpty {
            for part in cookie.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil {
                    orderedKeys.append(key)
                }
                values[key] = (name, value)
            }
        }

        return orderedKeys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var hasRetriedNoReferer = false
    private var endObserver: AnyCancellable?
    private var currentTask: Task<Void, Never>?
    /// 🔧 修复: 标记 handlePlayUrl 是否正在执行，防止后台详情任务并发启动第二个 handlePlayUrl
    private var isHandlingPlayUrl = false
    
    func setupPlayer(video: VodItem, preParsedEpisodes: [(name: String, url: String)]? = nil) {
        currentTask?.cancel()
        // 场景恢复期间不启动新播放器，避免主线程阻塞触发 watchdog
        if isRestoringFromBackground {
            log("[PlayerV2] 场景恢复中，延迟播放器初始化")
            sceneRestorationTask?.cancel()
            sceneRestorationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self?.setupPlayer(video: video, preParsedEpisodes: preParsedEpisodes) }
            }
            return
        }
        let isSameVideo = currentVideo?.vodId == video.vodId && currentVideo?.engineKey == video.engineKey
        let sessionId = UUID()
        playbackSessionId = sessionId
        isHandlingPlayUrl = false
        if !isSameVideo {
            episodeItems = []
            currentEpisodeIndex = 0
        }
        self.preParsedEpisodes = preParsedEpisodes
        currentVideo = video
        brightness = UIScreen.main.brightness
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
        restorePlaybackProgress(for: video)
        loadSkipSettings(for: video)
        loadDanmaku(for: video, fileName: video.vodName)

        // 监听 CloudDriveManager 的日志广播，显示在播放器 Debug Overlay
        // 修复: 存储观察者 token，setupPlayer 可能被多次调用（重试），先移除旧观察者
        if let oldObserver = cloudDriveLogObserver {
            NotificationCenter.default.removeObserver(oldObserver)
        }
        cloudDriveLogObserver = NotificationCenter.default.addObserver(
            forName: .cloudDriveLog,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let msg = notification.object as? String else { return }
            self?.log(msg)
        }

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await resolvePlayUrl(video: video, sessionId: sessionId)
        }
    }

    // MARK: - 场景生命周期保护（防止 watchdog 超时杀进程）

    /// 进入后台时调用：根据设置决定是否暂停播放器，取消耗时任务
    func handleSceneBackground() {
        sceneRestorationTask?.cancel()
        sceneRestorationTask = nil
        isRestoringFromBackground = false
        currentTask?.cancel()
        currentTask = nil
        // 后台播放开关：开启时不暂停播放器，音频继续在后台播放
        if !backgroundPlay {
            player?.pause()
            isPlaying = false
            // 显式恢复锁屏：.onChange 会同步设置，但后台场景下系统可能重置 idle timer，
            // 在此显式确保暂停播放时恢复自动锁屏
            UIApplication.shared.isIdleTimerDisabled = false
        }
        // 进度保存移到后台队列，避免 SQLite 操作阻塞主线程触发 watchdog
        let videoToSave = currentVideo
        let timeToSave = currentTime
        let episodeToSave = currentEpisodeIndex
        let progressKey = videoToSave.map { playbackProgressKey(for: $0) }
        let durationToSave = duration
        let lastSaveAt = lastProgressSaveAt
        Task.detached(priority: .utility) {
            guard let video = videoToSave, let key = progressKey,
                  timeToSave.isFinite, timeToSave > 5 else { return }
            if durationToSave > 0, durationToSave - timeToSave < 15 {
                UserDefaults.standard.removeObject(forKey: key)
                let favorites = DatabaseManager.shared.queryFavorites()
                if let record = favorites.first(where: { $0.detailurl == video.vodId }),
                   let fid = record.id {
                    DatabaseManager.shared.removeFavorite(id: fid)
                }
                return
            }
            guard Date().timeIntervalSince(lastSaveAt) > 0 else { return }
            UserDefaults.standard.set(timeToSave, forKey: key)
            let platformKey: String = {
                guard let ek = video.engineKey, ek.hasPrefix("__fuli_welfare__:") else { return "" }
                return String(ek.dropFirst("__fuli_welfare__:".count))
            }()
            let record = HistoryRecord(
                name: video.vodName,
                laiyuan: video.vodRemarks ?? "",
                imgurl: video.vodPic ?? "",
                detailurl: video.vodId,
                detailua: platformKey,
                xianlu: episodeToSave,
                jishu: 0,
                progress: timeToSave,
                lastPlayedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addOrUpdateHistory(record)
        }
        lastProgressSaveAt = Date()
        log(backgroundPlay ? "[PlayerV2] 进入后台，后台播放已开启，播放器继续运行" : "[PlayerV2] 进入后台，已暂停播放器并取消任务")
    }

    /// 回到前台时调用：异步恢复播放器，带超时保护
    func handleSceneForeground(shouldStopPiP: Bool = false) {
        guard !isRestoringFromBackground else { return }
        isRestoringFromBackground = true
        sceneRestorationTask?.cancel()
        sceneRestorationTask = Task { [weak self] in
            guard let self = self else { return }
            // 给场景更新留出宽限期，避免在 scene-update 回调内同步处理播放器/PiP 触发 watchdog。
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.isRestoringFromBackground = false
                if shouldStopPiP || self.isPiPActive {
                    #if canImport(Libmpv)
                    MPVPiPManager.shared.stopPiP()
                    NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: false)
                    #endif
                    #if canImport(swift_mdk)
                    MDKPipManager.shared.stopPiP()
                    if self.compatibilityEngineName.contains("MDK") {
                        NotificationCenter.default.post(name: .vboxMDKRequestStopPiP, object: nil)
                    }
                    #endif
                    PiPHelper.shared.stopPiP()
                    MPVAVPlayerPiPProxy.shared.stopProxyPiP()
                    self.isPiPActive = false
                    self.log("[PlayerV2] 回到前台，已延迟关闭 PiP")
                }
                // 只恢复播放，不做任何重解析/网络请求
                if self.player?.currentItem != nil, self.player?.rate == 0 {
                    self.player?.play()
                    self.isPlaying = true
                    // 显式重新禁用锁屏：isPlaying 可能后台时已为 true（后台播放模式），
                    // .onChange 不会触发，需在此手动恢复防锁屏状态
                    UIApplication.shared.isIdleTimerDisabled = true
                    self.log("[PlayerV2] 回到前台，已恢复播放")
                }
            }
        }
    }

    func cleanup() {
        currentTask?.cancel()
        currentTask = nil
        sceneRestorationTask?.cancel()
        sceneRestorationTask = nil
        isRestoringFromBackground = false
        playbackSessionId = UUID()
        stopPlaybackWatchdog()
        // 修复: 清理 seek 超时保护任务
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        danmakuTask?.cancel()
        danmakuTask = nil
        savePlaybackProgress(force: true)
        // 恢复自动锁屏
        UIApplication.shared.isIdleTimerDisabled = false
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = nil
        quarkFallbackURL = nil
        quarkFallbackHeaders = nil
        quarkFallbackSource = nil
        quarkFallbackAttempted = false
        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = nil
        baiduPrefetchingIds.removeAll()
        baiduNearEndPrefetchedIndexes.removeAll()
        if let baiduCacheObserver {
            NotificationCenter.default.removeObserver(baiduCacheObserver)
            self.baiduCacheObserver = nil
        }
        currentBaiduLocalProxyURL = nil
        currentBaiduStreamId = nil
        baiduCachedTimeRanges = []
        cleanupObservers()
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
        compatibilityURL = nil
        compatibilityHeaders = [:]
        currentPiPStrategy = .system
        // 修复: 使用 token 移除观察者，removeObserver(self,...) 对 block-based 观察者无效
        if let obs = cloudDriveLogObserver {
            NotificationCenter.default.removeObserver(obs)
            cloudDriveLogObserver = nil
        }
        // 清理 PiP 控制器（异步到主线程，避免 @MainActor 隔离冲突）
        Task { @MainActor in
            #if canImport(Libmpv)
            MPVPiPManager.shared.cleanupPiPController()
            #endif
            #if canImport(swift_mdk)
            MDKPipManager.shared.cleanupPiPController()
            #endif
            ViewCapturePiPManager.shared.cleanupPiP()
            MPVAVPlayerPiPProxy.shared.stopProxyPiP()
        }
    }
    
    // MARK: - 网盘视频处理
    private func handleCloudVideo(video: VodItem) async {
        log("[PlayerV2] 处理网盘视频...")
        
        // 检查 vodPlayUrl 是否是 JSON 格式的网盘链接列表
        if let playUrl = video.vodPlayUrl, playUrl.hasPrefix("[") {
            do {
                if let data = playUrl.data(using: .utf8),
                   let links = try JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    log("[PlayerV2] 解析到 \(links.count) 个网盘链接")
                    
                    // 尝试播放第一个有可用token的网盘链接
                    for link in links {
                        guard let url = link["url"], !url.isEmpty else { continue }
                        
                        if let driveType = CloudDriveManager.detectDrive(from: url) {
                            let tokens = CloudDriveManager.shared.tokens(for: driveType)
                            if !tokens.isEmpty || CloudDriveManager.isNodeManagedDrive(driveType) {
                                log("[PlayerV2] 尝试播放 \(driveType.displayName)")
                                await handleDriveUrl(url, driveType: driveType)
                                return
                            }
                        }
                    }
                    
                    await MainActor.run {
                        self.failPlayback("网盘资源播放失败：请检查网盘Token配置")
                    }
                    return
                }
            } catch {
                log("[PlayerV2] JSON解析失败: \(error)")
            }
        }
        
        // 检查 vodPlayUrl 是否是单个网盘链接
        if let playUrl = video.vodPlayUrl, !playUrl.isEmpty,
           let driveType = CloudDriveManager.detectDrive(from: playUrl) {
            log("[PlayerV2] 单个网盘链接: \(driveType.displayName)")
            await handleDriveUrl(playUrl, driveType: driveType)
            return
        }
        
        // 如果 vodId 是详情页URL，重新解析
        if video.vodId.hasPrefix("http") {
            log("[PlayerV2] 从详情页解析网盘链接...")
            if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId), !result.links.isEmpty {
                log("[PlayerV2] 解析到 \(result.links.count) 个链接")
                
                for link in result.links {
                    if let driveType = CloudDriveManager.detectDrive(from: link.url) {
                        let tokens = CloudDriveManager.shared.tokens(for: driveType)
                        if !tokens.isEmpty || CloudDriveManager.isNodeManagedDrive(driveType) {
                            log("[PlayerV2] 尝试播放 \(driveType.displayName): \(link.name)")
                            await handleDriveUrl(link.url, driveType: driveType)
                            return
                        }
                    }
                }
            }
        }
        
        await MainActor.run {
            self.failPlayback("网盘资源解析失败：未找到可播放链接")
        }
    }
    
    private func splitVboxFragment(from url: String) -> (baseURL: String, params: [String: String]) {
        let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return (url, [:]) }
        let fragment = String(parts[1])
        var params: [String: String] = [:]
        var passthrough: [String] = []
        for item in fragment.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                passthrough.append(String(item))
                continue
            }
            let key = String(pair[0])
            let value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
            if key.hasPrefix("vbox_") {
                params[key] = value
            } else {
                passthrough.append(String(item))
            }
        }
        let base = passthrough.isEmpty ? String(parts[0]) : "\(parts[0])#\(passthrough.joined(separator: "&"))"
        return (base, params)
    }

    private func appendVboxFragment(to url: String, params: [String: String]) -> String {
        let payload = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        return url.contains("#") ? "\(url)&\(payload)" : "\(url)#\(payload)"
    }

    private func handleDriveUrl(_ urlString: String, driveType: CloudDriveManager.DriveType) async {
        let split = splitVboxFragment(from: urlString)
        let cleanShareURL = split.baseURL
        let vboxParams = split.params
        if !vboxParams.isEmpty {
            log("[PlayerV2] 检测到详情页指定网盘文件参数，已分离干净分享链接")
        }

        // ═══════════════════════════════════════════════════════════
        // ★ Node 托管网盘统一入口（115/123/139/189/迅雷/光鸭/蜗牛）
        // 文件列表与播放取链全部走 A1 接缝（Node 常驻系统），不依赖本地 Token；
        // 失败直接报错（不降级原生路链）。百度/夸克/阿里/UC 原生链路不受影响。
        // ═══════════════════════════════════════════════════════════
        if CloudDriveManager.isNodeManagedDrive(driveType) {
            await handleNodeManagedDrive(urlString: urlString, cleanShareURL: cleanShareURL, vboxParams: vboxParams, driveType: driveType)
            return
        }

        let tokens = CloudDriveManager.shared.tokens(for: driveType)
        guard !tokens.isEmpty else {
            await MainActor.run {
                self.failPlayback("未配置\(driveType.displayName) Token")
            }
            return
        }

        // 阿里云盘：先获取文件列表，多文件则展示选集列表
        if driveType == .ali {
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[Ali] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.aliGetAllPlayableFiles(shareURL: cleanShareURL)
                log("[Ali] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_fid fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fileId == fid })
                } ?? 0
                let reason = vboxParams["vbox_fid"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[Ali] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .ali, aliFileId: f.fileId)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("阿里文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let result = try await CloudDriveManager.shared.resolveAliFilePlayURL(
                    shareURL: cleanShareURL,
                    fileId: files[selectedIndex].fileId,
                    fileName: files[selectedIndex].fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[Ali] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                // 降级到单文件解析（原有行为）
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置阿里云盘 Token"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 阿里云盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 阿里云盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("阿里解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        // 百度网盘：先获取文件列表，多文件则展示选择列表
        if driveType == .baidu {
            guard let pair = CloudDriveManager.shared.baiduTokenPair() else {
                await MainActor.run {
                    self.failPlayback("缺少百度 Web Cookie：需要 BDUSS/STOKEN，PCS Cookie 不能替代")
                }
                return
            }
            // 注册百度日志回调到悬浮日志
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[Baidu] ①请求分享页... WebToken=\(pair.web.name), PCSToken=\(pair.pcs?.name ?? "未配置")")
            do {
                let files = try await CloudDriveManager.shared.baiduGetFileList(shareURL: cleanShareURL, bduss: pair.web.value)
                log("[Baidu] ✅ 成功，共\(files.count)个文件: \(files.map { $0.name }.joined(separator: ", "))")
                await MainActor.run {
                    baiduFileList = files
                    baiduShareURL = cleanShareURL
                    baiduBduss = pair.web.value
                    baiduPcsCookie = pair.pcs?.value ?? ""
                    // 填充通用集数列表
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.name, url: "", sourceType: .baidu, baiduFileIndex: idx)
                    }
                }
                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("百度文件列表为空")
                    }
                    return
                }

                let selectedIndex = vboxParams["vbox_fsid"].flatMap { fsId in
                    files.firstIndex(where: { $0.fsId == fsId })
                } ?? 0
                let targetFile = files[selectedIndex]
                let reason = vboxParams["vbox_fsid"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                await startBaiduPlayback(
                    shareURL: cleanShareURL,
                    bduss: pair.web.value,
                    pcsCookie: pair.pcs?.value ?? "",
                    file: targetFile,
                    index: selectedIndex,
                    reason: reason
                )
                return
            } catch let error as DriveError {
                let specificMsg: String
                switch error {
                case .noPlayURL(let reason): specificMsg = reason
                case .invalidShareURL: specificMsg = "无效的分享链接"
                case .invalidResponse: specificMsg = "服务器响应异常"
                default: specificMsg = error.localizedDescription
                }
                log("[Baidu] ❌ ①出错: \(specificMsg)")
                await MainActor.run { self.failPlayback(specificMsg) }
                return
            } catch {
                log("[Baidu] ❌ ①出错: \(error.localizedDescription)")
                await MainActor.run { self.failPlayback("百度解析失败: \(error.localizedDescription)") }
                return
            }
        }
        
        // 夸克网盘：先获取完整文件列表，多文件则展示选择列表
        if driveType == .quark {
            guard let token = CloudDriveManager.shared.tokens(for: .quark).first else {
                await MainActor.run {
                    self.failPlayback("未配置夸克网盘 Cookie")
                }
                return
            }
            log("[Quark] ①获取完整文件列表...")
            do {
                let files = try await CloudDriveManager.shared.quarkGetFileList(shareURL: cleanShareURL, cookie: token.value)
                log("[Quark] ✅ 成功，共\(files.count)个可播放文件")

                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fid == fid })
                } ?? 0
                await MainActor.run {
                    quarkFileList = files
                    quarkShareURL = cleanShareURL
                    quarkCookie = token.value
                    quarkRoutePreference = vboxParams["vbox_route"]
                    currentEpisodeIndex = selectedIndex
                    // 填充通用集数列表
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: "\(cleanShareURL)/\(f.fid)", sourceType: .quark, quarkFileIndex: idx)
                    }
                }
                
                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("夸克文件列表为空")
                    }
                    return
                }

                let resolveURL: String
                if selectedIndex < files.count {
                    var resolveParams: [String: String] = ["vbox_fid": files[selectedIndex].fid]
                    if let route = vboxParams["vbox_route"], !route.isEmpty {
                        resolveParams["vbox_route"] = route
                    }
                    resolveURL = appendVboxFragment(to: cleanShareURL, params: resolveParams)
                } else {
                    resolveURL = cleanShareURL
                }
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: resolveURL)
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[Quark] ❌ 获取文件列表失败: \(error.localizedDescription)")
                // 降级到单文件解析
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch {
                    await MainActor.run { self.failPlayback("夸克解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }
        
        // UC 网盘：先获取完整文件列表，多文件则展示选集列表
        if driveType == .uc {
            guard let token = tokens.first else {
                await MainActor.run {
                    self.failPlayback("未配置UC网盘 Cookie")
                }
                return
            }
            log("[UC] ①获取完整文件列表...")
            do {
                let files = try await CloudDriveManager.shared.ucGetFileList(shareURL: cleanShareURL, cookie: token.value)
                log("[UC] ✅ 成功，共\(files.count)个可播放文件")

                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fid == fid })
                } ?? 0
                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .drive, ucFileFid: f.fid, ucShareFidToken: f.shareFidToken)
                    }
                }

                if vboxParams["vbox_fid"] != nil, selectedIndex < files.count {
                    let targetFile = files[selectedIndex]
                    let result = try await CloudDriveManager.shared.resolveUCPlayURLForFile(
                        shareURL: cleanShareURL,
                        cookie: token.value,
                        fileFid: targetFile.fid,
                        shareFidToken: targetFile.shareFidToken
                    )
                    await playResolvedDriveVideo(result)
                    return
                }
            } catch {
                log("[UC] ⚠️ 获取文件列表失败，降级到单文件: \(error.localizedDescription)")
            }
            
            // 播放第一个文件
            do {
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                await playResolvedDriveVideo(result)
            } catch let error as DriveError {
                let msg: String
                switch error {
                case .tokenNotConfigured: msg = "未配置UC网盘 Token"
                case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                case .noPlayURL(let reason): msg = reason
                case .invalidShareURL: msg = "无效的分享链接"
                case .saveFailed: msg = "转存失败"
                case .invalidResponse: msg = "服务器响应异常"
                case .notImplemented: msg = "暂不支持"
                }
                log("[PlayerV2] ❌ UC网盘 播放失败: \(msg)")
                await MainActor.run { self.failPlayback(msg) }
            } catch {
                log("[PlayerV2] ❌ UC网盘 解析异常: \(error.localizedDescription)")
                await MainActor.run { self.failPlayback("UC解析异常: \(error.localizedDescription)") }
            }
            return
        }

        // 迅雷云盘：先获取文件列表，多文件则展示选集列表
        if driveType == .xunlei {
            guard let token = CloudDriveManager.shared.tokens(for: .xunlei).first else {
                await MainActor.run {
                    self.failPlayback("未配置迅雷云盘 Cookie")
                }
                return
            }
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[Xunlei] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.xunleiGetFileList(shareURL: cleanShareURL, cookie: token.value)
                log("[Xunlei] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_fid fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_fid"].flatMap { fid in
                    files.firstIndex(where: { $0.fileId == fid })
                } ?? 0
                let reason = vboxParams["vbox_fid"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[Xunlei] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .xunlei, xunleiFileId: f.fileId)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("迅雷文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let result = try await CloudDriveManager.shared.resolveXunleiFilePlayURL(
                    shareURL: cleanShareURL,
                    cookie: token.value,
                    fileId: files[selectedIndex].fileId,
                    fileName: files[selectedIndex].fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[Xunlei] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                // 降级到单文件解析（原有行为）
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置迅雷云盘 Cookie"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 迅雷云盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 迅雷云盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("迅雷解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        // 115网盘：先获取文件列表，多文件则展示选集列表
        if driveType == .one15 {
            guard let token = CloudDriveManager.shared.tokens(for: .one15).first else {
                await MainActor.run {
                    self.failPlayback("未配置115网盘 Cookie/CID")
                }
                return
            }
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[115] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.one15GetAllPlayableFiles(shareURL: cleanShareURL, cid: token.value)
                log("[115] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_pickcode fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_pickcode"].flatMap { pickcode in
                    files.firstIndex(where: { $0.pickCode == pickcode })
                } ?? 0
                let reason = vboxParams["vbox_pickcode"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[115] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .one15, one15PickCode: f.pickCode)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("115文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let targetFile = files[selectedIndex]
                let result = try await CloudDriveManager.shared.resolve115FilePlayURL(
                    shareURL: cleanShareURL,
                    cid: token.value,
                    pickCode: targetFile.pickCode,
                    fileName: targetFile.fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[115] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置115网盘 Cookie/CID"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 115网盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 115网盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("115解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        // 123云盘：先获取文件列表，多文件则展示选集列表
        if driveType == .pan123 {
            guard let token = CloudDriveManager.shared.tokens(for: .pan123).first else {
                await MainActor.run {
                    self.failPlayback("未配置123云盘 Cookie")
                }
                return
            }
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[123] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.pan123GetAllFiles(shareURL: cleanShareURL, token: token.value)
                log("[123] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_fileId fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_fileId"].flatMap { fileId in
                    files.firstIndex(where: { $0.fileId == fileId })
                } ?? 0
                let reason = vboxParams["vbox_fileId"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[123] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .pan123, pan123FileId: f.fileId, pan123ETag: f.eTag)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("123文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let targetFile = files[selectedIndex]
                let result = try await CloudDriveManager.shared.resolve123FilePlayURL(
                    shareURL: cleanShareURL,
                    token: token.value,
                    fileId: targetFile.fileId,
                    eTag: targetFile.eTag,
                    fileName: targetFile.fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[123] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置123云盘 Cookie"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 123云盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 123云盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("123解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        // 139云盘：先获取文件列表，多文件则展示选集列表
        if driveType == .pan139 {
            guard let token = CloudDriveManager.shared.tokens(for: .pan139).first else {
                await MainActor.run {
                    self.failPlayback("未配置139云盘 Cookie")
                }
                return
            }
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[139] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.pan139GetAllFiles(shareURL: cleanShareURL, cookie: token.value)
                log("[139] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_contentId fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_contentId"].flatMap { contentId in
                    files.firstIndex(where: { $0.contentId == contentId })
                } ?? 0
                let reason = vboxParams["vbox_contentId"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[139] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .pan139, pan139ContentId: f.contentId, pan139CatalogId: f.catalogId)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("139文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let targetFile = files[selectedIndex]
                let result = try await CloudDriveManager.shared.resolve139FilePlayURL(
                    shareURL: cleanShareURL,
                    cookie: token.value,
                    contentId: targetFile.contentId,
                    catalogId: targetFile.catalogId,
                    fileName: targetFile.fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[139] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置139云盘 Cookie"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 139云盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 139云盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("139解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        // 天翼云盘：先获取文件列表，多文件则展示选集列表
        if driveType == .pan189 {
            guard let token = CloudDriveManager.shared.tokens(for: .pan189).first else {
                await MainActor.run {
                    self.failPlayback("未配置天翼云盘 Cookie")
                }
                return
            }
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[189] ①获取文件列表...")
            do {
                let files = try await CloudDriveManager.shared.pan189GetAllFiles(shareURL: cleanShareURL, cookie: token.value)
                log("[189] ✅ 成功，共\(files.count)个文件")

                // 详情页指定剧集：通过 vbox_fileId fragment 定位用户点击的集数
                let selectedIndex = vboxParams["vbox_fileId"].flatMap { fileId in
                    files.firstIndex(where: { $0.fileId == fileId })
                } ?? 0
                let reason = vboxParams["vbox_fileId"] != nil ? "详情页指定剧集" : (files.count == 1 ? "自动播放单文件" : "自动播放")
                log("[189] 选集: index=\(selectedIndex) reason=\(reason)")

                await MainActor.run {
                    currentEpisodeIndex = selectedIndex
                    episodeItems = files.enumerated().map { idx, f in
                        EpisodeItem(id: idx, name: f.fileName, url: cleanShareURL,
                                    sourceType: .pan189, pan189FileId: f.fileId)
                    }
                }

                guard !files.isEmpty else {
                    await MainActor.run {
                        self.failPlayback("天翼文件列表为空")
                    }
                    return
                }

                // 播放选中的文件
                let targetFile = files[selectedIndex]
                let result = try await CloudDriveManager.shared.resolve189FilePlayURL(
                    shareURL: cleanShareURL,
                    cookie: token.value,
                    fileId: targetFile.fileId,
                    fileName: targetFile.fileName
                )
                await playResolvedDriveVideo(result)
                return
            } catch {
                log("[189] ❌ 获取文件列表失败，降级到单文件解析: \(error.localizedDescription)")
                do {
                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
                    await playResolvedDriveVideo(result)
                } catch let error as DriveError {
                    let msg: String
                    switch error {
                    case .tokenNotConfigured: msg = "未配置天翼云盘 Cookie"
                    case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
                    case .noPlayURL(let reason): msg = reason
                    case .invalidShareURL: msg = "无效的分享链接"
                    case .saveFailed: msg = "转存失败"
                    case .invalidResponse: msg = "服务器响应异常"
                    case .notImplemented: msg = "暂不支持"
                    }
                    log("[PlayerV2] ❌ 天翼云盘 播放失败: \(msg)")
                    await MainActor.run { self.failPlayback(msg) }
                } catch {
                    log("[PlayerV2] ❌ 天翼云盘 解析异常: \(error.localizedDescription)")
                    await MainActor.run { self.failPlayback("天翼解析失败: \(error.localizedDescription)") }
                }
                return
            }
        }

        do {
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
            await playResolvedDriveVideo(result)
        } catch let error as DriveError {
            let msg: String
            switch error {
            case .tokenNotConfigured: msg = "未配置\(driveType.displayName) Token"
            case .nodeNotReady(let name): msg = "\(name) 需要 Node 常驻系统，当前未就绪，请稍后重试"
            case .noPlayURL(let reason): msg = reason
            case .invalidShareURL: msg = "无效的分享链接"
            case .saveFailed: msg = "转存失败"
            case .invalidResponse: msg = "服务器响应异常"
            case .notImplemented: msg = "暂不支持"
            }
            log("[PlayerV2] ❌ \(driveType.displayName) 播放失败: \(msg)")
            await MainActor.run {
                self.failPlayback(msg)
            }
        } catch {
            let msg = "解析异常: \(error.localizedDescription)"
            log("[PlayerV2] ❌ \(driveType.displayName) \(msg)")
            await MainActor.run {
                self.failPlayback(msg)
            }
        }
    }

    /// Node 托管网盘统一处理（115/123/139/189/迅雷/光鸭/蜗牛）：
    /// 解析文件列表（集数）→ 定位选中集 → A1 接缝取链播放。
    /// 失败直接报错，不降级原生路链（vbox 原生路链已废弃）。
    private func handleNodeManagedDrive(urlString: String, cleanShareURL: String, vboxParams: [String: String], driveType: CloudDriveManager.DriveType) async {
        CloudDriveManager.onLog = { [weak self] msg in
            self?.log("[PlayerV2] \(msg)")
        }
        log("[Node] \(driveType.displayName) ①获取文件列表 (A1 接缝)...")
        do {
            let share = try await CloudDriveManager.shared.resolveNodeShare(cleanShareURL, driveType: driveType)
            let entries = share.entries

            // 详情页指定剧集：通过 vbox_node fragment（playID）定位用户点击的集数。
            // Node 每次 detail 会重新生成 playToken（含 stoken/expiry），同一文件的
            // playID 整串可能变化，因此精确匹配失败时回退用稳定标识（fileId，其次文件名）
            // 匹配同一文件；命中后仍用本次解析出的 playID 取链，避免 token 过期。
            let selectedIndex: Int
            if let playID = vboxParams["vbox_node"], !playID.isEmpty {
                var matched = entries.firstIndex(where: { $0.playID == playID })
                if matched == nil, let key = nodeStableFileKey(fromPlayID: playID) {
                    matched = entries.firstIndex(where: { nodeStableFileKey(fromPlayID: $0.playID) == key })
                    if let m = matched {
                        log("[Node] ⚠️ \(driveType.displayName) playID 整串未命中，已按 fileId=\(key) 匹配到 index=\(m)")
                    }
                }
                if matched == nil, let name = nodePlayIDFileName(fromPlayID: playID) {
                    matched = entries.firstIndex(where: { $0.name == name })
                    if let m = matched {
                        log("[Node] ⚠️ \(driveType.displayName) playID 整串/fileId 均未命中，已按文件名匹配到 index=\(m)")
                    }
                }
                guard let idx = matched else {
                    log("[Node] ❌ \(driveType.displayName) 详情页指定剧集未命中文件列表")
                    throw NodePanError.nodeRejected("详情页指定剧集未命中文件列表")
                }
                selectedIndex = idx
            } else {
                selectedIndex = 0
            }
            let reason = vboxParams["vbox_node"] != nil ? "详情页指定剧集" : (entries.count == 1 ? "自动播放单文件" : "自动播放")
            log("[Node] ✅ \(driveType.displayName) 共\(entries.count)个文件，选集: index=\(selectedIndex) reason=\(reason)")

            await MainActor.run {
                currentEpisodeIndex = selectedIndex
                episodeItems = entries.enumerated().map { idx, entry in
                    EpisodeItem(id: idx, name: entry.name, url: cleanShareURL,
                                sourceType: .node, nodePlayID: entry.playID, nodeDriveType: driveType)
                }
            }

            guard !entries.isEmpty else {
                await MainActor.run {
                    self.failPlayback("\(driveType.displayName)文件列表为空")
                }
                return
            }

            // 播放选中的文件（A1 接缝 /spider/push/4/play）
            let result = try await CloudDriveManager.shared.resolveNodePlay(playID: entries[selectedIndex].playID, driveType: driveType)
            await playResolvedDriveVideo(result)
        } catch {
            let msg = "\(driveType.displayName) Node 解析失败: \(error.localizedDescription)"
            log("[Node] ❌ \(msg)")
            await MainActor.run {
                self.failPlayback(msg)
            }
        }
    }
    
    // MARK: - Node playID 稳定匹配辅助

    /// 从 Node playID（base64 JSON）中解析稳定文件标识（fileId，其次 playToken.fid）。
    /// 用于跨次解析匹配同一文件：Node 每次 detail 都会重新生成 playToken，
    /// 导致同一文件的 playID 整串不同，不能只靠整串相等定位。
    private func nodeStableFileKey(fromPlayID playID: String) -> String? {
        guard let obj = Self.decodeNodePlayIDObject(playID) else { return nil }
        if let fid = obj["fileId"] as? String, !fid.isEmpty { return fid }
        if let token = obj["playToken"] as? String,
           let tokenObj = Self.decodeJSONObject(token),
           let fid = tokenObj["fid"] as? String, !fid.isEmpty {
            return fid
        }
        return nil
    }

    /// 从 Node playID 中解析展示文件名（最后兜底匹配用）
    private func nodePlayIDFileName(fromPlayID playID: String) -> String? {
        Self.decodeNodePlayIDObject(playID)?["name"] as? String
    }

    /// playID base64 → JSON 字典；兼容 data URL 前缀，以及 "+" 被当作空格解码的情况
    private static func decodeNodePlayIDObject(_ playID: String) -> [String: Any]? {
        var source = playID.replacingOccurrences(of: " ", with: "+")
        if let range = source.range(of: "base64,") {
            source = String(source[range.upperBound...])
        }
        guard let data = Data(base64Encoded: source, options: .ignoreUnknownCharacters) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// JSON 字符串（playToken 是嵌套 JSON 文本）→ 字典
    private static func decodeJSONObject(_ jsonString: String) -> [String: Any]? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func playDriveVideo(url: String, headers: [String: String], driveType: DriveTypeAlias? = nil) async {
        guard !Task.isCancelled else {
            log("[PlayerV2] 已取消的网盘播放任务，跳过播放器提交")
            return
        }
        let playStartTime = Date()
        let sessionId = await MainActor.run { beginPlaybackSession() }
        await MainActor.run {
            isLoading = true
            skipOutroTriggered = false
            skipIntroTriggered = false
            isSwitchingEpisode = false
            loadingMessage = "正在缓冲首帧..."
        }
        let finalURLString: String
        if url.contains("baidupcs.com") || url.contains("d.pcs.baidu.com") {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "baidu") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 百度PCS走本地代理: \(finalURLString)")
            } else {
                log("[PlayerV2] ❌ 百度本地代理创建失败，iBox-style 路线不回退直连")
                await MainActor.run {
                    self.failPlayback("百度本地代理创建失败")
                }
                return
            }
        } else if isQuarkM3U8PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedQuarkM3U8URL(for: url, headers: headers) {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克 m3u8 走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克 m3u8 本地代理创建失败，回退直连")
            }
        } else if isQuarkDirectPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "quark") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克直链走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克本地代理创建失败，回退直连")
            }
        } else if isAliPlaybackURL(url) {
            if isAliVideoM3u8URL(url) {
                // 转码 m3u8 直连，AVPlayer 原生支持 HLS，代理会破坏 m3u8 协议
                finalURLString = url
                log("[PlayerV2] 阿里云盘转码直连 (不走代理): m3u8")
            } else if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "ali") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 阿里云盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 阿里云盘本地代理创建失败，回退直连")
            }
        } else if isUCPlaybackURL(url) {
            // UC CDN 直链不走本地代理，本地代理注入的 Android UA + Referer 会导致 CDN 拒绝 Range 请求
            // 播放器原生网络栈直接请求 CDN，兼容性更好
            finalURLString = url
            log("[PlayerV2] UC网盘直连 (不走代理)")
        } else if is115PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "115") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 115网盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 115本地代理创建失败，回退直连")
            }
        } else if isXunleiPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "xunlei") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 迅雷云盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 迅雷本地代理创建失败，回退直连")
            }
        } else {
            finalURLString = url
        }

        guard let urlObj = createURL(from: finalURLString) else {
            await MainActor.run {
                if self.playbackSessionId == sessionId {
                    self.failPlayback("播放地址格式错误")
                }
            }
            return
        }
        let isBaiduLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("baidu-stream")
        let isQuarkLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-stream")
        let isQuarkM3U8LocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-m3u8")
        let resourceName = currentPlaybackResourceName(fallbackURL: urlObj, originalURL: url)
        let playlistKind = await probeM3U8IfNeeded(url: urlObj, headers: headers)
        let isUCLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("uc-stream")
        let isCloudLocalProxy = urlObj.host == "127.0.0.1"
            && (urlObj.path.contains("ali-stream") || isUCLocalProxy || urlObj.path.contains("115-stream") || urlObj.path.contains("xunlei-stream"))
        let shouldFallbackBaiduAVPlayerToCompatibility = isBaiduLocalProxy
            && enginePreference == .auto
            && shouldTryBaiduAVPlayerFirst(resourceName: resourceName, playlistKind: playlistKind)
        await MainActor.run {
            bindBaiduCacheProgress(for: isBaiduLocalProxy ? urlObj : nil)
        }
        guard await MainActor.run(body: { self.playbackSessionId == sessionId }) else { return }

        // 夸克 m3u8 转码流（Go 代理）：优先 MDK（VT 硬解 + 缓冲预热），其次 MPV/VLC。
        // 夸克直链 download_url（Go 代理）：优先 MDK（FFmpeg 软解 + 重连），其次 MPV/VLC。
        // MDK 已针对夸克流做了专项优化（VT 硬解/FFmpeg 软解/readahead/avio buffer），
        // 必须优先使用以发挥性能。AliPlayer 对本地代理 URL 兼容性差，不优先选择。
        if (isQuarkLocalProxy || isQuarkM3U8LocalProxy) && enginePreference == .auto {
            let proxyType = isQuarkLocalProxy ? "quark-stream" : "quark-m3u8"
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .compatibility
                compatibilityHint = isQuarkLocalProxy ? "夸克网盘直链" : "夸克网盘转码"
            }
            if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "\(proxyType) 优先 MDK（VT硬解+缓冲预热）")
                log("[Quark] 自动模式下\(proxyType)优先使用 MDK（VT硬解+缓冲预热）")
            } else if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "\(proxyType)（MDK 不可用）")
                log("[Quark] MDK 不可用，\(proxyType)降级使用 MPV-MoltenVK")
            } else if isIJKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "\(proxyType)（MDK/MPV 不可用）")
                log("[Quark] MDK/MPV 不可用，\(proxyType)降级使用 IJKPlayer")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "\(proxyType) MDK/MPV/IJK 均不可用")
                log("[Quark] MDK/MPV/IJK 均不可用，\(proxyType)降级使用 VLC")
            }
        } else if (isUCLocalProxy || driveType == .uc || isUCPlaybackURL(url)) && enginePreference == .auto {
            // UC网盘资源（直连或本地代理）：一律优先兼容内核，禁止 AVPlayer。
            // 原因：AVPlayer 播放 UC 网盘 CDN 直链时会出现"舞台声"（音频路由异常），
            // 必须使用 MDK/MPV/IJK 等兼容内核，与百度网盘策略一致。
            let ucReason = isUCLocalProxy ? "UC网盘本地代理" : "UC网盘直链"
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .compatibility
                compatibilityHint = ucReason
                currentPiPStrategy = compatibilityPiPStrategy(engineName: preferredCompatibilityEngineName(for: urlObj), url: urlObj)
                loadingMessage = "正在使用兼容内核..."
            }
            if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "UC网盘强制兼容内核：\(ucReason)")
                log("[UC] 自动模式下UC网盘强制使用 MPV-MoltenVK 兼容内核，不再尝试 AVPlayer")
            } else if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "UC网盘强制兼容内核（MPV 不可用）：\(ucReason)")
                log("[UC] MPV 不可用，UC网盘强制降级使用 MDK 兼容内核")
            } else if isIJKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "UC网盘强制兼容内核（MPV/MDK 不可用）：\(ucReason)")
                log("[UC] MPV/MDK 不可用，UC网盘降级使用 IJKPlayer")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "UC网盘强制兼容内核（MPV/MDK/IJK 不可用）：\(ucReason)")
                log("[UC] MPV/MDK/IJK 不可用，UC网盘降级使用 VLC 兼容内核")
            }
        } else if isBaiduLocalProxy && enginePreference == .auto {
            // 百度网盘资源一律优先兼容内核，禁止自动模式再尝试 AVPlayer 主播放链路。
            // 原因：百度本地代理 + 鉴权 + 大文件加载会导致 AVPlayer 启动慢/超时，影响用户播放体验。
            let reason = compatibilityReason(for: resourceName) ?? "百度原画本地代理"
            let baiduCompatibilityEngine = preferredCompatibilityEngineName(for: urlObj)
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .compatibility
                compatibilityHint = reason
                currentPiPStrategy = compatibilityPiPStrategy(engineName: baiduCompatibilityEngine, url: urlObj)
                loadingMessage = "正在使用兼容内核..."
            }
            if isMPVBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "baidu-stream 强制兼容内核：\(reason)")
                log("[Baidu] 自动模式下百度资源强制使用 MPV-MoltenVK 兼容内核，不再尝试 AVPlayer")
            } else if isMDKBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MDK", reason: "baidu-stream 强制兼容内核（MPV 不可用）")
                log("[Baidu] MPV 不可用，百度资源强制降级使用 MDK")
            } else if isVLCBuildAvailable {
                logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "baidu-stream 强制兼容内核（MPV/MDK 均不可用）")
                log("[Baidu] MPV/MDK 均不可用，百度资源强制降级使用 VLC 兼容内核")
            }
        } else if enginePreference == .auto, isM3U8URL(urlObj) || playlistKind != nil {
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .system
                compatibilityHint = nil
                currentPiPStrategy = .system
            }
            let kind = playlistKind ?? .unknown
            let reason = kind == .fmp4 ? "#EXT-X-MAP/.m4s" : (kind == .ts ? "TS切片" : "m3u8未探测到fMP4特征")
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: kind, engine: "AVPlayer", reason: reason)
        } else if enginePreference == .auto, shouldPreferIJK(for: urlObj) {
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .compatibility
                compatibilityHint = "夸克网盘直链"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "IJKPlayer", reason: "真实文件名/URL命中夸克直链")
            log("[Quark] 自动模式下夸克直链使用 IJKPlayer")
        } else if enginePreference == .auto, shouldPreferMPV(for: urlObj) {
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                playbackEngineMode = .compatibility
                compatibilityHint = compatibilityReason(for: resourceName) ?? "复杂封装"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "真实文件名/URL命中复杂封装")
        } else if enginePreference == .auto {
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "AVPlayer", reason: "默认系统内核")
        }
        guard await MainActor.run(body: { self.playbackSessionId == sessionId }) else { return }

        if shouldUseCompatibilityEngine {
            let engineName = preferredCompatibilityEngineName(for: urlObj)
            log("[PlayerV2] 使用 \(engineName) 兼容内核播放：\(compatibilityHint ?? "特殊格式")")
            await MainActor.run {
                guard playbackSessionId == sessionId else { return }
                player?.pause()
                player = nil
                compatibilityEngineName = engineName
                compatibilityURL = urlObj
                compatibilityHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
                currentPiPStrategy = compatibilityPiPStrategy(engineName: engineName, url: urlObj)
                detectVideoQuality(from: urlObj.absoluteString)
                isPlaying = true
                // 修复: 显式禁用自动锁屏，防止 isPlaying 初始值为 true 时 .onChange 不触发
                UIApplication.shared.isIdleTimerDisabled = true
                isLoading = false
                isSwitchingEpisode = false
                stopPlaybackWatchdog()
            }
            return
        } else if playbackEngineMode == .compatibility {
            if enginePreference == .mpv {
                log("[PlayerV2] 已选择 MPV，但当前构建未包含 Libmpv，暂用系统内核尝试")
            } else {
                log("[PlayerV2] 资源需要兼容内核，但当前构建未包含可用兼容内核或已强制系统内核，暂用系统内核尝试")
            }
        }
        
        let assetHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
        let asset = AVURLAsset(url: urlObj, options: ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = urlObj.host == "127.0.0.1" ? 0.5 : 10.0

        // 修复舞台声：在创建 AVPlayer 之前配置 AVAudioSession，
        // 确保音频输出到扬声器而非听筒。与 MDK/MPV 引擎保持一致。
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            self.log("[PlayerV2] ⚠️ AVAudioSession 激活失败: \(error.localizedDescription)")
        }

        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                guard self.playbackSessionId == sessionId else { return }
                switch status {
                case .readyToPlay:
                    if isQuarkLocalProxy || isQuarkM3U8LocalProxy {
                        self.quarkFallbackTimeoutTask?.cancel()
                    }
                    // 修复舞台声：播放就绪后强制音频输出到扬声器，防止路由到听筒
                    do {
                        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                    } catch {
                        self.log("[PlayerV2] ⚠️ overrideOutputAudioPort 失败: \(error.localizedDescription)")
                    }
                    let size = playerItem.presentationSize
                    let elapsed = Int(Date().timeIntervalSince(playStartTime) * 1000)
                    self.log("[PlayerV2] 网盘 PlayerItem 准备就绪，耗时=\(elapsed)ms，画面=\(Int(size.width))x\(Int(size.height))")
                    self.isLoading = false
                    // 恢复上次播放进度 或 跳过片头
                    if self.currentTime > 10, let p = self.player {
                        let resume = self.currentTime
                        self.log("[Progress] 网盘自动跳转到上次进度：\(self.formatDuration(resume))")
                        p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    } else if self.skipIntroEnabled, self.skipIntroSeconds > 0, !self.skipIntroTriggered, let p = self.player {
                        self.skipIntroTriggered = true
                        let skip = Double(self.skipIntroSeconds)
                        self.log("[PlayerV2] ⏩ 网盘跳过片头 \(self.formatDuration(skip))")
                        p.seek(to: CMTime(seconds: skip, preferredTimescale: 600))
                        self.currentTime = skip
                    }
                    // 对夸克/百度本地代理都执行首帧黑屏检测（红色封面/和谐文件会返回尺寸为0）
                    self.scheduleVideoTrackCheck(
                        for: playerItem,
                        startedAt: playStartTime,
                        isBaiduLocalProxy: isBaiduLocalProxy,
                        isQuarkLocalProxy: isQuarkLocalProxy || isQuarkM3U8LocalProxy,
                        fallbackURL: urlObj,
                        fallbackHeaders: assetHeaders
                    )
                case .failed:
                    let nsError = playerItem.error as? NSError
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    self.log("[PlayerV2] ❌ 网盘 PlayerItem 失败: code=\(nsError?.code ?? -1) domain=\(nsError?.domain ?? "") desc=\(errorDesc)")
                    let underlyingDesc: String
                    if let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? Error {
                        underlyingDesc = underlying.localizedDescription
                        self.log("[PlayerV2] ❌ 网盘底层错误: \(underlyingDesc)")
                    } else {
                        underlyingDesc = ""
                    }

                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Baidu] ⚠️ 百度PCS流返回403，准备刷新直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                        return
                    }
                    if isCloudLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 网盘本地代理返回403，建议重新进入播放刷新直链")
                    }
                    if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克本地代理返回403，后续需要重新刷新 download_url")
                        if self.switchToQuarkFallback(reason: "原画线路 403") { return }
                    }
                    // 夸克常见失败：NSURLErrorDomain code=-1 / "The network connection was lost"。
                    // 一般是上游签名失效或 UA/Cookie 不匹配被风控，提示用户重新进入触发刷新。
                    if isQuarkLocalProxy && self.isQuarkConnectionLost(error: nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克播放连接被中断 (network connection lost)，疑似签名/风控，建议返回重新播放刷新直链")
                        if self.switchToQuarkFallback(reason: "原画线路连接中断") { return }
                    }
                    if self.isUnsupportedMediaError(nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 当前资源疑似 AVPlayer 不支持，建议后续使用兼容内核")
                        if shouldFallbackBaiduAVPlayerToCompatibility {
                            self.switchBaiduAVPlayerFailureToCompatibility(url: urlObj, headers: assetHeaders, reason: "系统内核不支持当前百度格式")
                            return
                        } else if isQuarkLocalProxy {
                            if self.switchToQuarkFallback(reason: "系统内核不支持原画格式") { return }
                        } else {
                            Task { @MainActor in
                                self.failPlayback("当前资源格式/编码不受系统播放器支持，建议使用兼容内核")
                            }
                            return
                        }
                    }
                    if shouldFallbackBaiduAVPlayerToCompatibility {
                        self.switchBaiduAVPlayerFailureToCompatibility(url: urlObj, headers: assetHeaders, reason: "系统内核播放失败")
                        return
                    }
                    Task { @MainActor in
                        self.failPlayback("网盘播放失败: \(errorDesc)")
                    }
                case .unknown:
                    self.log("[PlayerV2] 网盘 PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }

        let localFailureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    guard let self else { return }
                    guard self.playbackSessionId == sessionId else { return }
                    self.log("[PlayerV2] ❌ 网盘播放中断: \(error.localizedDescription)")
                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Baidu] ⚠️ 百度PCS播放中断疑似403，清理旧直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                    } else if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似403，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断 403")
                    } else if isQuarkLocalProxy && self.isQuarkConnectionLost(error: error as NSError, errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似连接丢失，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断")
                    } else if shouldFallbackBaiduAVPlayerToCompatibility {
                        self.switchBaiduAVPlayerFailureToCompatibility(url: urlObj, headers: assetHeaders, reason: "系统内核播放中断")
                    } else {
                        Task { @MainActor in
                            self.failPlayback("网盘播放失败: \(error.localizedDescription)")
                        }
                    }
                }
            }

        // 监听播放正常结束（网盘 AVPlayer 回退路径）
        let localEndObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.playbackSessionId == sessionId else { return }
                self.log("[PlayerV2] 网盘播放结束")
                self.playNextEpisodeIfAvailable()
            }

        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = !(isBaiduLocalProxy || isQuarkLocalProxy || isQuarkM3U8LocalProxy)
        if isQuarkLocalProxy {
            scheduleQuarkPrimaryFallbackTimeout(playerItem: playerItem, startedAt: playStartTime)
        } else if isQuarkM3U8LocalProxy {
            quarkFallbackTimeoutTask?.cancel()
        }
        
        let didCommitPlayer = await MainActor.run { () -> Bool in
            guard playbackSessionId == sessionId else { return false }
            if let observer = timeObserver { player?.removeTimeObserver(observer) }
            cleanupObservers()
            statusObserver = localStatusObserver
            failureObserver = localFailureObserver
            endObserver = localEndObserver
            player?.pause()
            player = p
            currentPiPStrategy = .system
            isPlaying = true
            // 修复: 显式禁用自动锁屏（网盘 AVPlayer 路径）
            UIApplication.shared.isIdleTimerDisabled = true
            // 修复竞态：await MainActor.run 挂起期间，本地代理响应极快可能导致
            // playerItem.status 已变为 .readyToPlay，观察者已在主队列回调中设置了 isLoading=false。
            // 此处若盲目覆盖为 true，status 不再变化，观察者不会再次触发，界面永久卡在"正在缓冲首帧..."。
            // 仅在仍未就绪时才设为 loading 状态。
            if playerItem.status != .readyToPlay {
                isLoading = true
                loadingMessage = "正在缓冲首帧..."
            }
            startPlaybackWatchdog(for: sessionId)
            return true
        }
        guard didCommitPlayer else { return }

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            guard self.playbackSessionId == sessionId, self.player === p else { return }
            self.currentTime = time.seconds
            self.updateSubtitle(currentTime: time.seconds)
            if let d = p.currentItem?.duration {
                self.duration = d.seconds.isFinite ? d.seconds : 0
            }
            if isBaiduLocalProxy {
                self.prefetchNextBaiduFileNearEnd(current: self.currentTime, duration: self.duration)
                self.reportBaiduCacheProgressIfNeeded()
            }
            // 跳过片尾：网盘资源接近结尾时自动播放下一集
            if self.skipOutroEnabled, self.skipOutroSeconds > 0, !self.skipOutroTriggered,
               self.duration > 0, self.currentTime > 0,
               self.currentTime >= self.duration - Double(self.skipOutroSeconds) {
                self.skipOutroTriggered = true
                self.log("[PlayerV2] ⏩ 网盘跳过片尾 \(self.formatDuration(Double(self.skipOutroSeconds)))，自动播放下一集")
                self.playNextEpisode()
            }
        }

        p.play()

        if shouldFallbackBaiduAVPlayerToCompatibility {
            Task { @MainActor [weak self, weak p] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, let p, self.player === p else { return }
                guard self.playbackSessionId == sessionId, self.loadError == nil else { return }
                guard p.currentItem?.status != .readyToPlay else { return }
                self.log("[Baidu] AVPlayer 6秒内未就绪，回退原兼容内核")
                self.switchBaiduAVPlayerFailureToCompatibility(url: urlObj, headers: assetHeaders, reason: "系统内核启动超时")
            }
        }

        // 安全兜底：播放器已实际播放（有进度/在播放）但 isLoading 仍为 true 时，清除 loading 状态。
        // 覆盖观察者回调因各种极端时序未被处理的边界情况。
        Task { @MainActor [weak self, weak p] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let p, self.player === p else { return }
            guard self.playbackSessionId == sessionId else { return }
            guard self.isLoading, self.loadError == nil else { return }
            let isPlaying = p.rate > 0 || p.timeControlStatus == .playing
            let seconds = p.currentTime().seconds
            let itemStatus = p.currentItem?.status
            if isPlaying || seconds > 0 || itemStatus == .readyToPlay {
                self.log("[PlayerV2] ⚠️ 播放器已就绪/播放中但 isLoading 仍为 true，自动清除 loading 状态 (rate=\(p.rate), seconds=\(String(format: "%.1f", seconds)), status=\(String(describing: itemStatus)))")
                self.isLoading = false
            }
        }
    }

    private func prefetchNextBaiduFileNearEnd(current: Double, duration: Double) {
        guard duration.isFinite, duration > 0, current.isFinite, current > 0 else { return }
        guard currentEpisodeIndex + 1 < baiduFileList.count else { return }
        guard !baiduNearEndPrefetchedIndexes.contains(currentEpisodeIndex) else { return }

        let remaining = duration - current
        let threshold = duration >= 20 * 60 ? 180.0 : max(30.0, duration * 0.15)
        guard remaining <= threshold else { return }

        baiduNearEndPrefetchedIndexes.insert(currentEpisodeIndex)
        log("[Baidu-Preload] 当前集接近结尾，剩余\(Int(max(0, remaining)))秒，开始预取下一集")
        prefetchNextBaiduFile(after: currentEpisodeIndex)
    }

    private func isHTTPForbidden(errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        return text.contains("403") || text.contains("forbidden")
    }

    private func currentPlaybackResourceName(fallbackURL: URL, originalURL: String) -> String {
        if currentEpisodeIndex >= 0, currentEpisodeIndex < baiduFileList.count {
            return baiduFileList[currentEpisodeIndex].name
        }
        if let decoded = fallbackURL.lastPathComponent.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        if let original = URL(string: originalURL)?.lastPathComponent.removingPercentEncoding, !original.isEmpty {
            return original
        }
        return fallbackURL.absoluteString
    }

    private func shouldPreferMPVByResourceName(_ resourceName: String, url: URL) -> Bool {
        let text = "\(resourceName) \(url.absoluteString)".lowercased()
        if text.contains(".mp4") || text.contains(".m3u8") || text.contains(".m4v") || text.contains(".mov") {
            return false
        }
        return text.contains(".mkv")
            || text.contains("mkv")
            || text.contains("hevc")
            || text.contains("h265")
            || text.contains("x265")
            || text.contains("10bit")
            || text.contains("hdr")
            || text.contains("4k")
    }

    private func isM3U8URL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains(".m3u8") || url.path.lowercased().contains("m3u8")
    }

    private func logEngineResolver(resourceName: String, url: URL, playlistKind: M3U8PlaylistKind?, engine: String, reason: String) {
        let kindText = playlistKind?.rawValue ?? "none"
        log("[EngineResolver] resource=\(resourceName), kind=\(kindText), engine=\(engine), reason=\(reason), url=\(url.absoluteString.prefix(80))")
    }

    private func probeM3U8IfNeeded(url: URL, headers: [String: String]) async -> M3U8PlaylistKind? {
        guard isM3U8URL(url) else { return nil }

        // [优化] 本地代理 m3u8 流直接跳过探测，避免 1.5 秒超时拖慢首帧
        // 夸克/百度等 Go 代理 m3u8 流的类型是已知的，不需要 HTTP 探测
        let urlString = url.absoluteString.lowercased()
        if urlString.contains("127.0.0.1") && urlString.contains("quark-m3u8") {
            log("[EngineResolver] quark-m3u8 本地代理，跳过探测（TS 分片）")
            return .ts
        }
        if urlString.contains("127.0.0.1") && urlString.contains("baidu-m3u8") {
            log("[EngineResolver] baidu-m3u8 本地代理，跳过探测（TS 分片）")
            return .ts
        }

        let key = url.absoluteString
        if let cached = m3u8ProbeCache[key], cached.expiresAt > Date() {
            log("[EngineResolver] m3u8探测缓存命中：\(cached.kind.rawValue)")
            return cached.kind
        }

        do {
            let kind = try await probeM3U8Playlist(url: url, headers: headers)
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: kind, expiresAt: Date().addingTimeInterval(5 * 60))
            log("[EngineResolver] m3u8探测完成：\(kind.rawValue)")
            return kind
        } catch {
            log("[EngineResolver] m3u8探测失败，默认系统内核：\(error.localizedDescription)")
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: .unknown, expiresAt: Date().addingTimeInterval(60))
            return .unknown
        }
    }

    private func probeM3U8Playlist(url: URL, headers: [String: String]) async throws -> M3U8PlaylistKind {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let sample = String(data: data.prefix(131_072), encoding: .utf8)?.lowercased() ?? ""
        if sample.contains("#ext-x-map") || sample.contains(".m4s") {
            return .fmp4
        }
        if sample.contains(".ts") || sample.contains("mpegts") {
            return .ts
        }
        return .unknown
    }

    /// 判断是否是夸克侧常见的"连接被中断"。AVPlayer 在签名失效或 TLS 被风控关闭时通常返回
    /// NSURLErrorDomain code=-1（NSURLErrorUnknown）或 -1005（NSURLErrorNetworkConnectionLost），
    /// 描述里会带 "network connection was lost" / "未知错误"。
    private func isQuarkConnectionLost(error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        if let error, error.domain == NSURLErrorDomain {
            if [-1, -1005, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(error.code) {
                return true
            }
        }
        return text.contains("network connection was lost")
            || text.contains("connection was lost")
            || text.contains("未知错误")
    }

    /// 夸克 download_url 实际跳转后域名波动较大（drive、dl、cdn、pcs、video 等多种 host）。
    /// 这里只要落在 *.quark.cn 且不属于 API/页面域，都认为是真实播放直链，需要走本地代理补 Header。
    private func isQuarkDirectPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "drive-pc.quark.cn",
            "drive-h.quark.cn",
            "drive-m.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isQuarkM3U8PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard rawURL.lowercased().contains(".m3u8") else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isAliPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host.contains("aliyundrive.com") || host.contains("alipan.com") || host.contains("aliyunpds.com") {
            return true
        }
        return host.hasSuffix(".aliyuncs.com") || host.contains("aliyun")
    }

    /// 阿里云盘转码 CDN m3u8 URL 识别
    /// 三重条件确保不影响其他网盘和阿里直链：
    /// 1. host 含 "aliyun" — 仅阿里云盘（排除百度/夸克/115/迅雷/UC）
    /// 2. host 含 "video" — 仅视频转码 CDN（排除阿里数据 CDN *-data.aliyundrive.net）
    /// 3. 路径含 /lt/ 或 /qv/ — 仅转码路径（排除阿里直链下载）
    private func isAliVideoM3u8URL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        return host.contains("aliyun") && host.contains("video")
               && (path.contains("/lt/") || path.contains("/qv/"))
    }

    private func isUCPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host == "uc.cn" || host.hasSuffix(".uc.cn") {
            let excluded: Set<String> = ["drive.uc.cn", "pc-api.uc.cn", "www.uc.cn"]
            return !excluded.contains(host)
        }
        return host.contains("ucdl") || host.contains("ucloud")
    }

    private func is115PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        return host == "115.com"
            || host.hasSuffix(".115.com")
            || host.contains("115cdn.com")
            || host.contains("anxia.com")
            || host.contains("cdnfhnup")
            || host.contains("fhnqqso")
    }

    private func isXunleiPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host.hasSuffix(".xunlei.com") || host == "xunlei.com" {
            let excluded: Set<String> = [
                "pan.xunlei.com",
                "i.xunlei.com",
                "x-api-pan.xunlei.com",
                "xluser-ssl.xunlei.com",
                "www.xunlei.com"
            ]
            return !excluded.contains(host)
        }
        return host.contains("fntx")
            || host.contains("xlgateway")
            || host.hasSuffix(".xunlei.cn")
    }

    private func isUnsupportedMediaError(_ error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc) \(error?.domain ?? "")".lowercased()
        if error?.domain == AVFoundationErrorDomain && [-11828, -11833].contains(error?.code ?? 0) {
            return true
        }
        return text.contains("-11828") || text.contains("-12847") || text.contains("无法打开") || text.contains("not open")
    }

    private func scheduleVideoTrackCheck(
        for item: AVPlayerItem,
        startedAt: Date,
        isBaiduLocalProxy: Bool,
        isQuarkLocalProxy: Bool,
        fallbackURL: URL,
        fallbackHeaders: [String: String]
    ) {
        // 修复: 移除仅限百度/夸克的 guard，对所有 AVPlayer 路径执行首帧检测
        // 普通 m3u8/蜘蛛资源也可能遇到视频编码不兼容导致有声音无画面
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard self.player?.currentItem === item, self.loadError == nil else { return }
            let size = item.presentationSize
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let seconds = self.player?.currentTime().seconds ?? 0
            // 修复: 增加 AVPlayerItem.tracks 视频轨检查，更快发现无视频轨的情况
            let hasVideoTrack = item.tracks.contains { $0.assetTrack?.mediaType == .video }
            self.log("[PlayerV2] 首帧检测：耗时=\(elapsed)ms，进度=\(String(format: "%.1f", seconds))s，画面=\(Int(size.width))x\(Int(size.height))，视频轨=\(hasVideoTrack)")
            if !hasVideoTrack || (seconds > 2 && (size.width <= 1 || size.height <= 1)) {
                if isQuarkLocalProxy {
                    self.log("[PlayerV2] ⚠️ 夸克视频有播放进度但无画面，疑似文件已被和谐或转码失败")
                    self.failPlayback("该视频在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
                } else if isBaiduLocalProxy {
                    self.log("[PlayerV2] ⚠️ 百度视频有播放进度但画面尺寸为0，疑似视频轨/编码不兼容")
                    self.switchBaiduAVPlayerFailureToCompatibility(url: fallbackURL, headers: fallbackHeaders, reason: "系统内核无视频画面")
                } else {
                    self.log("[PlayerV2] ⚠️ 普通/蜘蛛资源有播放进度但无视频画面，疑似编码不兼容")
                    self.switchAVPlayerVideoTrackFailureToMPV(url: fallbackURL, headers: fallbackHeaders)
                }
            }
        }
        // 修复: 启动第二个延迟检测（8秒），覆盖 5 秒内播放器被替换导致首帧检测被跳过、
        // 而新播放器的 .readyToPlay 回调中 scheduleVideoTrackCheck 尚未触发的时序盲区。
        // 8 秒足够 AVPlayer 完成首帧解码，且不会影响正常播放体验。
        // 此检测仅在新播放器仍持有同一 item 时执行，不会误杀被替换的旧 item。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            // 检查当前播放器的 item（可能是新替换的）是否仍无视频画面
            guard let currentItem = self.player?.currentItem, self.loadError == nil else { return }
            // 如果 item 已经被 scheduleVideoTrackCheck 的 5 秒检测处理过，跳过
            guard currentItem === item else { return }
            let size = currentItem.presentationSize
            let seconds = self.player?.currentTime().seconds ?? 0
            let hasVideoTrack = currentItem.tracks.contains { $0.assetTrack?.mediaType == .video }
            // 只有确实有进度但无画面时才触发，避免误判
            guard seconds > 2, !hasVideoTrack || (size.width <= 1 || size.height <= 1) else { return }
            self.log("[PlayerV2] 首帧检测(8s补充)：进度=\(String(format: "%.1f", seconds))s，画面=\(Int(size.width))x\(Int(size.height))，视频轨=\(hasVideoTrack)")
            if isQuarkLocalProxy {
                self.failPlayback("该视频在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
            } else if isBaiduLocalProxy {
                self.switchBaiduAVPlayerFailureToCompatibility(url: fallbackURL, headers: fallbackHeaders, reason: "系统内核无视频画面")
            } else {
                self.switchAVPlayerVideoTrackFailureToMPV(url: fallbackURL, headers: fallbackHeaders)
            }
        }
    }

    private func switchBaiduAVPlayerFailureToCompatibility(url: URL, headers: [String: String], reason: String) {
        guard enginePreference == .auto else {
            log("[Baidu] 当前为手动系统内核策略，不自动切换兼容内核")
            return
        }
        guard isMPVBuildAvailable || isMDKBuildAvailable || isIJKBuildAvailable || isVLCBuildAvailable else {
            log("[Baidu] 当前构建没有可用兼容内核，保留系统内核")
            return
        }

        let engineName = preferredCompatibilityEngineName(for: url)
        log("[Baidu] AVPlayer 优先尝试失败，回退兼容内核 \(engineName)：\(reason)")
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        cleanupObservers()
        stopPlaybackWatchdog()
        player?.pause()
        player = nil
        compatibilityEngineName = engineName
        compatibilityURL = url
        compatibilityHeaders = url.host == "127.0.0.1" ? [:] : headers
        currentPiPStrategy = compatibilityPiPStrategy(engineName: engineName, url: url)
        detectVideoQuality(from: url.absoluteString)
        playbackEngineMode = .compatibility
        compatibilityHint = reason
        isPlaying = true
        // 修复: 显式禁用自动锁屏（百度回退兼容内核路径）
        UIApplication.shared.isIdleTimerDisabled = true
        isLoading = false
        isSwitchingEpisode = false
        loadError = nil
    }

    private func switchAVPlayerVideoTrackFailureToMPV(url: URL, headers: [String: String]) {
        guard enginePreference != .system, isMPVBuildAvailable else {
            log("[PlayerV2] 当前构建/策略无法自动切 MPV，保留系统内核")
            return
        }

        log("[PlayerV2] 自动切换到 MPV-MoltenVK：系统内核有进度但无视频画面")
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        compatibilityEngineName = "MPV-MoltenVK"
        compatibilityURL = url
        compatibilityHeaders = headers
        currentPiPStrategy = compatibilityPiPStrategy(engineName: "MPV-MoltenVK", url: url)
        detectVideoQuality(from: url.absoluteString)
        playbackEngineMode = .compatibility
        compatibilityHint = "系统内核无视频画面"
        isPlaying = true
        // 修复: 显式禁用自动锁屏（切 MPV 路径，MPV play() 也会设置但提前设置更安全）
        UIApplication.shared.isIdleTimerDisabled = true
        isLoading = true
        isSwitchingEpisode = false
        loadingMessage = "正在切换 MPV-MoltenVK..."
    }

    private func retryCurrentBaiduPlaybackAfterForbidden() {
        guard baiduStreamRetryCount < 1 else {
            log("[Baidu] ❌ 百度PCS流403重试后仍失败，请更新PCS Cookie或重新扫码登录")
            Task { @MainActor in
                self.failPlayback("百度PCS返回403：请更新PCS Cookie或重新扫码登录")
            }
            return
        }

        guard !baiduShareURL.isEmpty,
              currentEpisodeIndex >= 0,
              currentEpisodeIndex < baiduFileList.count
        else {
            log("[Baidu] ❌ 无法重试：缺少分享链接或当前集信息")
            return
        }

        baiduStreamRetryCount += 1
        let file = baiduFileList[currentEpisodeIndex]
        let index = currentEpisodeIndex
        CloudDriveManager.shared.invalidateBaiduPlaybackCache(
            shareURL: baiduShareURL,
            fsId: file.fsId,
            bduss: baiduBduss,
            pcsCookie: baiduPcsCookie,
            reason: "PCS403刷新直链重试"
        )
        log("[Baidu] ♻️ 已清理当前集旧 dlink/播放缓存，将优先用 path 刷新")
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.startBaiduPlayback(
                shareURL: self.baiduShareURL,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "PCS403刷新直链重试"
            )
        }
    }
    
    func retry(video: VodItem) {
        currentTask?.cancel()
        stopPlaybackForFailure()
        loadError = nil
        isLoading = true
        isPlaying = false
        showControls = true
        setupPlayer(video: video)
    }
    
    // MARK: - 播放地址解析
    private func isCurrentPlaybackSession(_ sessionId: UUID?, video: VodItem) async -> Bool {
        guard let sessionId = sessionId else { return true }
        return await MainActor.run {
            self.playbackSessionId == sessionId &&
            self.currentVideo?.vodId == video.vodId &&
            self.currentVideo?.engineKey == video.engineKey
        }
    }

    private func resolvePlayUrl(video: VodItem, sessionId: UUID) async {
        log("[PlayerV2] 开始解析播放地址: \(video.vodId)")
        guard await isCurrentPlaybackSession(sessionId, video: video) else {
            log("[PlayerV2] 跳过旧播放会话的解析请求: \(video.vodId)")
            return
        }
        
        // 检查是否是网盘资源（通过 vodRemarks 或 vodId 判断）
        if video.vodRemarks?.contains("网盘") == true || video.vodRemarks?.hasPrefix("☁️") == true {
            log("[PlayerV2] 检测到网盘资源，走网盘播放链路")
            await handleCloudVideo(video: video)
            return
        }
        
        // 如果 vodId 是 HTTP URL，可能是网盘详情页
        if video.vodId.hasPrefix("http://") || video.vodId.hasPrefix("https://") {
            // 检查是否包含网盘域名
            let panDomains = ["aliyundrive.com", "alipan.com", "pan.quark.cn", "pan.baidu.com", 
                              "115.com", "115cdn.com", "drive.uc.cn", "pan.uc.cn",
                              "yun.139.com", "caiyun.139.com", "123pan.com", "123cloud.cn"]
            if panDomains.contains(where: { video.vodId.contains($0) }) {
                log("[PlayerV2] 检测到网盘URL，走网盘播放链路")
                await handleCloudVideo(video: video)
                return
            }
        }

        // MissAV 专属链路：解析详情页得到真实 m3u8/mp4，并透传 Referer/Origin/User-Agent
        if (video.vodPlayFrom ?? "").contains("missav"),
           let source = await MissAVService.shared.resolvePlayableSource(for: video),
           let url = createURL(from: source.url) {
            log("[PlayerV2] MissAV 解析成功，带 header 原生播放")
            await MainActor.run { initPlayer(url: url, customHeaders: source.headers) }
            return
        }
        
        let spider = await SpiderManager.shared
        var playUrl: String? = video.vodPlayUrl
        var playFrom: String? = video.vodPlayFrom
        
        // 步骤0: 优先使用详情页传来的已解析集数，避免播放器重复解析导致选源不一致和卡死
        if episodeItems.isEmpty, let preParsed = preParsedEpisodes, !preParsed.isEmpty {
            episodeItems = preParsed.enumerated().map { idx, ep in
                EpisodeItem(id: idx, name: ep.name, url: ep.url, engineKey: video.engineKey, sourceType: .normal)
            }
            // 根据 vodName 自动定位到当前集（多级匹配策略）
            currentEpisodeIndex = Self.matchEpisodeIndex(vodName: video.vodName, episodes: episodeItems)
            if currentEpisodeIndex >= 0 {
                log("[PlayerV2] 步骤0: 使用预解析集数(\(episodeItems.count)集)，定位到: \(episodeItems[currentEpisodeIndex].name)")
            } else {
                currentEpisodeIndex = 0
                log("[PlayerV2] 步骤0: 使用预解析集数(\(episodeItems.count)集)，未匹配到当前集，默认第1集")
            }
            log("[PlayerV2] 步骤0: 预解析集数填充完成，共\(episodeItems.count)集")
        }
        
        // 步骤1: 先用传入的播放地址尝试播放，同时后台获取详情
        log("[PlayerV2] 步骤1: 先尝试已有地址播放，后台异步获取详情...")
        
        // 先直接用已有地址尝试播放（如果有）
        if let existingUrl = video.vodPlayUrl, !existingUrl.isEmpty {
            // 解析普通资源多集数据，填充通用集数列表（已有预解析集数时跳过，避免二次解析）
            if episodeItems.isEmpty {
                parseNormalEpisodes(playFrom: video.vodPlayFrom ?? "", playUrl: existingUrl, targetEpisodeName: video.vodName, engineKey: video.engineKey)
            }
            
            let firstUrl: String
            if !episodeItems.isEmpty, currentEpisodeIndex >= 0, currentEpisodeIndex < episodeItems.count {
                firstUrl = episodeItems[currentEpisodeIndex].url
                log("[PlayerV2] 步骤1: 使用当前集[\(currentEpisodeIndex)]: \(firstUrl.prefix(80))...")
            } else {
                firstUrl = extractBestPlayableUrl(playFrom: video.vodPlayFrom ?? "", playUrl: existingUrl)
            }
            let firstUrlClean = firstUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstUrlClean.isEmpty {
                log("[PlayerV2] 步骤1: 先尝试已有地址: \(firstUrlClean.prefix(80))...")
                // 修复竞态: 标记正在处理，防止后台详情任务并发启动第二个 handlePlayUrl。
                // 注意: isHandlingPlayUrl 不会在此处复位为 false，而是由后台详情 Task
                // 检查完毕后才复位，关闭竞态窗口（原实现在 await 间隙已复位 false）。
                await MainActor.run { self.isHandlingPlayUrl = true }
                await handlePlayUrl(firstUrlClean, spider: spider, video: video, customHeaders: video.customHeaders, sessionId: sessionId)
                // 修复: 不在此处复位 isHandlingPlayUrl，延迟到后台详情检查之后
            }
            
            // 后台异步获取详情，成功后更新播放地址（仅在已有地址时后台更新）
            Task { [weak self] in
                guard let self = self else { return }
                log("[PlayerV2] 步骤1: 后台获取详情...")
                if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName, engineKey: video.engineKey),
                   let newUrl = detail.vodPlayUrl, !newUrl.isEmpty {
                    guard await self.isCurrentPlaybackSession(sessionId, video: video) else {
                        self.log("[PlayerV2] 丢弃旧播放会话的后台详情结果: \(video.vodId)")
                        return
                    }
                    log("[PlayerV2] 步骤1: 后台详情成功，检查是否需要更新")
                    // 后台详情返回后也更新集数列表
                    self.parseNormalEpisodes(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl, targetEpisodeName: video.vodName, engineKey: detail.engineKey ?? video.engineKey)
                    let newBest: String
                    if !self.episodeItems.isEmpty, self.currentEpisodeIndex >= 0, self.currentEpisodeIndex < self.episodeItems.count {
                        newBest = self.episodeItems[self.currentEpisodeIndex].url
                    } else {
                        newBest = self.extractBestPlayableUrl(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl)
                    }
                    if !newBest.isEmpty {
                        await MainActor.run {
                            // 修复: isHandlingPlayUrl 在第一个 handlePlayUrl 完成后仍为 true，
                            // 直到此处检查完毕才复位，确保后台详情不会在竞态窗口内启动第二个 handlePlayUrl
                            if (self.player == nil || self.loadError != nil) && !self.isHandlingPlayUrl {
                                self.loadError = nil
                                Task { await self.handlePlayUrl(newBest, spider: spider, video: video, sessionId: sessionId) }
                            } else {
                                self.log("[PlayerV2] 步骤1: 已有播放器在运行或正在解析，跳过更新")
                            }
                            // 修复: 现在安全复位，后台详情检查完毕，竞态窗口关闭
                            self.isHandlingPlayUrl = false
                        }
                    } else {
                        // 修复: newBest 为空时也要复位
                        await MainActor.run { self.isHandlingPlayUrl = false }
                    }
                } else {
                    log("[PlayerV2] 步骤1: 后台详情无结果")
                    // 修复: 详情无结果时复位
                    await MainActor.run { self.isHandlingPlayUrl = false }
                }
            }
            
            // 已有地址时，等后台详情更新即可
            log("[PlayerV2] 步骤1: 等待后台详情更新...")
            return
        }
        
        // 如果有预解析集数但无已有地址（如"立即播放"时 vodPlayUrl 为空），直接用当前集播放
        // 避免同步获取详情导致 UI 卡死
        if !episodeItems.isEmpty {
            let playIdx = currentEpisodeIndex >= 0 && currentEpisodeIndex < episodeItems.count ? currentEpisodeIndex : 0
            let directUrl = episodeItems[playIdx].url
            log("[PlayerV2] 步骤1: 无已有地址但有预解析集数，直接播放第\(playIdx + 1)集: \(directUrl.prefix(80))...")
            await MainActor.run { self.isHandlingPlayUrl = true }
            await handlePlayUrl(directUrl, spider: spider, video: video, customHeaders: video.customHeaders, sessionId: sessionId)
            await MainActor.run { self.isHandlingPlayUrl = false }
            return
        }
        
        // ★ 修复: 无已有播放地址时，同步等待详情获取，避免竞态导致"服务器未返回播放地址"
        // 原实现: 后台 Task 异步获取详情，但主流程立即检查 playUrl (为空) → 报错
        // 修复后: 无已有地址时，主流程 await 详情获取，拿到地址后再继续播放
        log("[PlayerV2] 步骤1: 无已有地址，同步获取详情...")
        if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName, engineKey: video.engineKey) {
            guard await isCurrentPlaybackSession(sessionId, video: video) else {
                log("[PlayerV2] 丢弃旧播放会话的详情结果: \(video.vodId)")
                return
            }
            playUrl = detail.vodPlayUrl
            playFrom = detail.vodPlayFrom
            if let newUrl = detail.vodPlayUrl, !newUrl.isEmpty {
                log("[PlayerV2] 步骤1: 详情获取成功，解析剧集...")
                parseNormalEpisodes(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl, targetEpisodeName: video.vodName, engineKey: detail.engineKey ?? video.engineKey)
            } else {
                log("[PlayerV2] 步骤1: 详情返回但无播放地址")
            }
        } else {
            log("[PlayerV2] 步骤1: 详情获取失败")
        }
        
        // 步骤2: 检查 playUrl 的类型并处理
        guard let finalPlayUrl = playUrl, !finalPlayUrl.isEmpty else {
            log("[PlayerV2] 错误: 没有可用的播放地址")
            await MainActor.run {
                self.failPlayback("服务器未返回播放地址（详情页无视频源），请尝试其他资源或站点")
            }
            return
        }
        
        log("[PlayerV2] 步骤2: 处理播放地址")
        
        // 从 $$$ 多源格式中提取最佳 URL
        let bestUrl = extractBestPlayableUrl(playFrom: playFrom ?? "", playUrl: finalPlayUrl)
        log("[PlayerV2] 最佳URL: \(bestUrl.prefix(80))...")
        
        await handlePlayUrl(bestUrl, spider: spider, video: video, sessionId: sessionId)
    }
    
    // MARK: - 安全创建URL（处理编码）
    private func createURL(from urlString: String) -> URL? {
        // 先尝试直接创建
        if let url = URL(string: urlString) {
            return url
        }
        
        // 如果失败，尝试进行URL编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功: \(urlString.prefix(50))... -> \(encoded.prefix(50))...")
                return url
            }
        }
        
        // 尝试对路径部分编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功(2): \(urlString.prefix(50))...")
                return url
            }
        }
        
        log("[PlayerV2] ❌ URL创建失败: \(urlString)")
        return nil
    }
    
    /// 通用：判断字符串是否为"可作为直链交给播放器"的干净 HTTP URL。
    /// 真实直链不应包含协议元字符（$、# 及全角 ＄／＃），且能被 URL 正常解析。
    /// 用于在播放前过滤掉源返回的畸形/含分隔符的候选，避免选中后请求 404。
    private static func isCleanDirectMediaUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        if trimmed.contains("$") || trimmed.contains("#")
            || trimmed.contains("＄") || trimmed.contains("＃") {
            return false
        }
        return URL(string: trimmed) != nil
    }
    
    /// 判断 episode.url 是否是不含 http 的占位符/相对路径，需要调用 playerContent 解析
    /// 保持 http/https 直链的原有播放行为，避免影响 CMS/API/网盘等其他资源
    private func shouldCallPlayerContentForEpisode(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // http/https 链接保持原有直接播放逻辑（可能是直链或播放页）
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return false
        }
        // 非 http 链接（如剧迷的 vid-ep_id、相对路径等），尝试 playerContent
        return true
    }
    
    /// 🔧 修复: 判断URL是否为AVPlayer/CoreMedia支持的标准播放协议
    /// 自定义协议（如 xk://）返回 false，避免传给 AVPlayer 报 -1002 错误并卡界面
    private func isStandardPlayScheme(_ urlString: String) -> Bool {
        let lowerUrl = urlString.lowercased()
        return lowerUrl.hasPrefix("http://")
            || lowerUrl.hasPrefix("https://")
            || lowerUrl.hasPrefix("file://")
            || lowerUrl.hasPrefix("rtmp://")
            || lowerUrl.hasPrefix("rtsp://")
            || lowerUrl.hasPrefix("udp://")
            || lowerUrl.hasPrefix("rtp://")
    }

    /// 判断 URL 是否像可直接交给播放器的媒体地址。
    /// 用于避免把普通 HTML 播放页、官方平台页或解析页当成直链塞给播放器。
    private func isLikelyDirectMediaUrl(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowerUrl = trimmed.lowercased()
        guard isStandardPlayScheme(lowerUrl) else { return false }

        if let url = URL(string: trimmed) {
            let host = (url.host ?? "").lowercased()
            let path = url.path.lowercased()
            let ext = url.pathExtension.lowercased()

            if host == "127.0.0.1" || host == "localhost" {
                return true
            }

            let mediaExts = ["m3u8", "mp4", "flv", "m4v", "mov", "ts", "webm", "mkv", "avi", "m4s"]
            if mediaExts.contains(ext) { return true }

            if path.contains(".m3u8") || path.contains(".mp4") || path.contains(".flv") || path.contains(".ts") {
                return true
            }
        }

        let mediaMarkers = [
            ".m3u8", ".mp4", ".flv", ".m4v", ".mov", ".ts", ".webm", ".mkv", ".avi", ".m4s",
            "/m3u8", "m3u8?", "hls", "playlist", "streaming", "/stream", "/playurl"
        ]
        return mediaMarkers.contains { lowerUrl.contains($0) }
    }

    /// 检测 URL 是否为 DASH/MPD 代理地址
    /// biliys spider 返回的播放 URL 含 /proxy/mpd/，Node.js 返回 application/dash+xml
    /// AVPlayer 不支持 DASH，需自动切换到 MPV/VLC/MDK 兼容内核
    private func isDashProxyUrl(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        return lower.contains("/proxy/mpd/") || lower.contains("/proxy/seg/")
    }

    /// 统一处理 playerContent 返回结果并播放（含 parse:1 二次解析和 header 透传）
    private func playFromPlayerContentResult(
        _ pr: PlayerContentResult,
        episodeName: String,
        spider: SpiderManager,
        baseHeaders: [String: String]? = nil,
        sessionId: UUID? = nil,
        video: VodItem? = nil
    ) async {
        if let video = video {
            guard await isCurrentPlaybackSession(sessionId, video: video) else {
                log("[PlayerV2] 丢弃旧播放会话的 playerContent 结果: \(video.vodId)")
                return
            }
        }
        // 修复: playUrl 为空字符串时回退到 url（JS侧返回 null 时 playUrl 为 nil，空字符串时也需回退）
        // 再修复: node bundle play 返回 [画质名, MPD地址, ...] 成对数组，url 首元素是画质名不是地址；
        // 需从 urls 数组选取首个 http(s) 真实地址（playUrl 仍保持优先，不影响既有 JS 蜘蛛）
        let pu = pr.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? SpiderManager.firstPlayableURL(in: pr)
        var mergedHeaders = baseHeaders ?? [:]
        if let spiderHeaders = pr.header {
            for (key, value) in spiderHeaders where !key.isEmpty {
                mergedHeaders[key] = value
            }
        }
        if pr.parse == 1, let rawUrl = pu, !rawUrl.isEmpty {
            log("[PlayerV2] playerContent 返回 parse=1，重新走解析器链路: \(rawUrl.prefix(60))")
            if let reparsedUrl = await spider.parsePlayUrl(from: rawUrl) {
                log("[PlayerV2] ✅ playerContent 二次解析成功: \(reparsedUrl.prefix(60))")
                if let url = createURL(from: reparsedUrl) {
                    await MainActor.run {
                        guard sessionId == nil || playbackSessionId == sessionId else { return }
                        initPlayer(url: url, customHeaders: mergedHeaders)
                    }
                    return
                }
            }
            log("[PlayerV2] ⚠️ playerContent 二次解析失败")
            // parse=1 语义是“需要解析”。二次解析失败后，只有媒体直链才允许兜底播放；
            // 普通播放页或自定义协议不再传给播放器，避免界面长期停在缓冲状态。
            if let rawUrl = pu, !isLikelyDirectMediaUrl(rawUrl) {
                log("[PlayerV2] ❌ playerContent parse=1 解析失败且不是媒体直链，不传给播放器: \(rawUrl.prefix(60))")
                await MainActor.run {
                    guard sessionId == nil || playbackSessionId == sessionId else { return }
                    self.failPlayback("播放地址解析失败，请尝试更换源或清晰度")
                }
                return
            }
        }
        // 🔧 修复: 直链分支也校验协议，自定义协议不传给 AVPlayer
        if let pu = pu, !pu.isEmpty, isStandardPlayScheme(pu), let url = createURL(from: pu) {
            // ★ DASH 检测: spider 返回 MPD 代理 URL 时，AVPlayer 不支持 DASH，
            // 自动切换到兼容内核 (MPV/VLC/MDK)
            if isDashProxyUrl(pu) {
                log("[PlayerV2] 🔍 检测到 DASH/MPD 代理 URL，切换到兼容内核: \(pu.prefix(60))")
                await MainActor.run {
                    guard sessionId == nil || playbackSessionId == sessionId else { return }
                    self.playbackEngineMode = .compatibility
                    self.compatibilityHint = "B站 DASH 流"
                    self.compatibilityURL = url
                    self.compatibilityHeaders = mergedHeaders
                    self.compatibilityEngineName = self.preferredCompatibilityEngineName(for: url)
                    self.currentPiPStrategy = self.compatibilityPiPStrategy(
                        engineName: self.compatibilityEngineName,
                        url: url
                    )
                }
                return
            }

            log("[PlayerV2] ✅ playerContent 直链成功: \(pu.prefix(60))")
            await MainActor.run {
                guard sessionId == nil || playbackSessionId == sessionId else { return }
                self.currentTime = 0
                self.initPlayer(url: url, customHeaders: mergedHeaders)
                if let video = self.currentVideo {
                    self.restorePlaybackProgress(for: video)
                    self.loadDanmaku(for: video, fileName: episodeName)
                }
            }
        } else if let pu = pu, !pu.isEmpty {
            log("[PlayerV2] ❌ playerContent 返回非标准协议，不传给播放器: \(pu.prefix(60))")
            await MainActor.run {
                self.failPlayback("播放地址格式不支持，请尝试更换源")
            }
        } else {
            // 🔧 修复: playUrl 和 url 均为 nil/空时，必须调用 failPlayback
            // 否则 isLoading 永远为 true，界面永久卡在"正在缓冲首帧..."，只能划后台关闭
            log("[PlayerV2] ❌ playerContent 返回空URL(playUrl=nil, url=nil)，触发失败回调")
            await MainActor.run {
                self.failPlayback("播放地址为空，请尝试更换源或清晰度")
            }
        }
    }
    
    /// 解码 base64 JSON 格式的播放地址（如哇哇影视的 episode.url）
    /// base64 解码后是 JSON: {"name":"第1集","url":"https://...","parse":"","ag":"..."}
    /// 返回 (url, headers) 元组，如果解码失败返回 nil
    private func decodeBase64JsonUrl(_ b64String: String) -> (url: String, headers: [String: String])? {
        // 去除可能的 $ 前缀（如 "第1集$eyJuYW1lIjo..."）
        var b64 = b64String
        if let dollarRange = b64.range(of: "$") {
            b64 = String(b64[dollarRange.upperBound...])
        }
        // 清理空白字符
        b64 = b64.trimmingCharacters(in: .whitespacesAndNewlines)
        // 保留原始 playID（去 $ 前缀、无 padding），用于 Node 网盘桥接时按 playID 精确定位文件
        let rawPlayID = b64
        // 补全 base64 padding
        let pad = (4 - b64.count % 4) % 4
        if pad > 0 {
            b64 += String(repeating: "=", count: pad)
        }
        // 解码 base64
        guard let data = Data(base64Encoded: b64),
              let jsonStr = String(data: data, encoding: .utf8) else {
            log("[PlayerV2] base64 解码失败: \(b64String.prefix(40))")
            return nil
        }
        // 解析 JSON 提取 url 字段
        guard let jsonData = jsonStr.data(using: .utf8),
              let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            log("[PlayerV2] JSON 解析失败: \(jsonStr.prefix(60))")
            return nil
        }
        let url = String(describing: jsonObj["url"] ?? "")
        if url.isEmpty {
            // 🔧 修复: Node 蜘蛛（push/jutou 等）返回网盘协议 JSON 时没有 url 字段，
            // 而是 {"providerId":"quark","shareId":"...","fileId":"...","playToken":"...","mode":"..."}。
            // 原来直接判死 → 播放失败。这里桥接成标准网盘分享 URL（带 vbox_node/vbox_fid fragment），
            // 上层 handlePlayUrl 递归时会命中既有云盘检测分支，走 handleDriveUrl → handleNodeManagedDrive
            // （A1 接缝 /spider/push/4/*），与仓库远程源网盘播放链路完全一致，不影响其它源。
            if let bridged = Self.bridgeNodePanJSON(jsonObj, rawPlayID: rawPlayID) {
                log("[PlayerV2] ✅ Node 网盘协议 JSON 桥接成功: \(bridged.url.prefix(80))")
                return bridged
            }
            log("[PlayerV2] JSON 中 url 字段为空: \(jsonStr.prefix(60))")
            return nil
        }
        // 确保 url 是完整的 http URL
        var result = url
        if !result.lowercased().hasPrefix("http://") && !result.lowercased().hasPrefix("https://") {
            if result.hasPrefix("//") {
                result = "https:" + result
            } else if !result.isEmpty {
                result = "https://" + result
            }
        }
        // 提取 headers（如 User-Agent）
        var headers: [String: String] = [:]
        if let ag = jsonObj["ag"] as? String, !ag.isEmpty {
            headers["User-Agent"] = ag
        }
        return (result, headers)
    }

    /// 🔧 Node 网盘协议 JSON → 标准网盘分享链接桥接
    ///
    /// Node 蜘蛛（push/jutou 等）play 返回的 base64 JSON 没有 url 字段，而是：
    ///   {"providerId":"quark|thunder|pan115|...","shareId":"...","fileId":"...","name":"...","playToken":"...","mode":"..."}
    /// 这是 push spider 的 playID 载荷。桥接策略：
    ///   - Node 托管盘（迅雷/115/123/139/189/光鸭/蜗牛）：构造成分享链接 + `#vbox_node=<原始playID>`，
    ///     走 handleDriveUrl → handleNodeManagedDrive（A1 接缝 /spider/push/4/*），按 playID 精确定位文件；
    ///   - 原生盘（夸克/百度/UC/阿里）：构造成分享链接 + `#vbox_fid=<fileId>`，
    ///     走既有原生 Token 路链（百度/阿里/UC 用 fid 定位文件）。
    ///     夸克例外：本地已配置原生夸克 Token 时走原生（vbox_fid）；未配置时改走
    ///     Node 夸克独立路链（`#vbox_nd=1&vbox_node=<原始playID>`），两条路链凭据互不影响；
    ///   - 未知 providerId 返回 nil（保持原判死行为，不改变其它源逻辑）。
    private static func bridgeNodePanJSON(_ json: [String: Any], rawPlayID: String) -> (url: String, headers: [String: String])? {
        guard let providerId = json["providerId"] as? String,
              let shareId = json["shareId"] as? String,
              !providerId.isEmpty, !shareId.isEmpty else {
            return nil
        }
        let fileId = (json["fileId"] as? String) ?? ""
        let lower = providerId.lowercased()
        let shareURL: String
        let nodeManaged: Bool
        // 夸克专用：本地无原生夸克 Token 时改走 Node 夸克独立路链（#vbox_nd=1）
        var quarkNodeRoute = false
        switch lower {
        case "quark":
            shareURL = "https://pan.quark.cn/s/\(shareId)"
            nodeManaged = false
            // 凭据二选一：已配置原生夸克 Token → 维持现状走原生（vbox_fid）；
            // 未配置 → 走 Node 夸克路链（vbox_nd=1&vbox_node），避免只登了 Node 夸克的用户播放失败
            quarkNodeRoute = CloudDriveManager.shared.tokens(for: .quark).isEmpty
        case "thunder", "xunlei":
            shareURL = "https://pan.xunlei.com/s/\(shareId)"
            nodeManaged = true
        case "pan115", "one15":
            shareURL = "https://115.com/s/\(shareId)"
            nodeManaged = true
        case "pan123":
            shareURL = "https://www.123pan.com/s/\(shareId)"
            nodeManaged = true
        case "pan189", "189":
            shareURL = "https://cloud.189.cn/t/\(shareId)"
            nodeManaged = true
        case "new139", "139", "pan139":
            shareURL = "https://yun.139.com/s/\(shareId)"
            nodeManaged = true
        case "guangya":
            shareURL = "https://guangyapan.com/s/\(shareId)"
            nodeManaged = true
        case "woniu4k", "woniu":
            shareURL = "https://woniu4k.com/s/\(shareId)"
            nodeManaged = true
        case "baidu":
            shareURL = "https://pan.baidu.com/s/1\(shareId)"
            nodeManaged = false
        case "uc":
            shareURL = "https://drive.uc.cn/s/\(shareId)"
            nodeManaged = false
        case "ali", "aliyun", "alipan":
            shareURL = "https://www.alipan.com/s/\(shareId)"
            nodeManaged = false
        default:
            return nil
        }
        // Node 托管盘：vbox_node=原始 playID（精确匹配文件列表条目）；
        // 原生盘：vbox_fid=fileId（夸克/百度/阿里用 fid 定位用户点击的集数）
        // playID/fileId 可能含 base64 特殊字符（+/=），percent-encoding 后放入 fragment，
        // splitVboxFragment 会 removingPercentEncoding 还原，与 Node 侧返回的原始值一致
        let encodedPlayID = rawPlayID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rawPlayID
        let encodedFileID = fileId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? fileId
        let fragment: String
        if quarkNodeRoute {
            // 夸克 Node 路链：必须带 vbox_nd=1 让 detectDrive 判为 .quarkNode；
            // 有原始 playID 时附 vbox_node 精确定位文件（与详情页派生的夸克Node源格式一致）
            fragment = rawPlayID.isEmpty ? "vbox_nd=1" : "vbox_nd=1&vbox_node=\(encodedPlayID)"
        } else if nodeManaged, !rawPlayID.isEmpty {
            fragment = "vbox_node=\(encodedPlayID)"
        } else if !fileId.isEmpty {
            fragment = "vbox_fid=\(encodedFileID)"
        } else {
            fragment = ""
        }
        let finalURL = fragment.isEmpty ? shareURL : "\(shareURL)#\(fragment)"
        // 透传 Node 返回的 UA
        var headers: [String: String] = [:]
        if let ag = json["ag"] as? String, !ag.isEmpty {
            headers["User-Agent"] = ag
        }
        return (finalURL, headers)
    }
    
    /// 从 URL 字符串中提取域名
    private func extractHost(from urlString: String) -> String {
        if let url = URL(string: urlString), let host = url.host {
            return host
        }
        // 尝试从字符串中提取域名
        if let regex = try? NSRegularExpression(pattern: "https?://([^/]+)"),
           let match = regex.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range(at: 1), in: urlString) {
            return String(urlString[range])
        }
        return ""
    }
    
    // MARK: - 处理单个播放地址
    private func handlePlayUrl(_ urlString: String, spider: SpiderManager, video: VodItem, customHeaders: [String: String]? = nil, sessionId: UUID? = nil) async {
        guard await isCurrentPlaybackSession(sessionId, video: video) else {
            log("[PlayerV2] 跳过旧播放会话的播放地址处理: \(urlString.prefix(60))")
            return
        }
        log("[PlayerV2] 处理地址: \(urlString.prefix(80))...")

        // 修复: base64 JSON 预解码（哇哇影视等站点的 episode.url 是 base64 编码的 JSON）
        // JS 引擎的 b64decodeStr 可能因原生桥接问题返回空值，导致 playerContent 拿到未解码的 base64
        // 在 Swift 侧直接解码，绕过 JS 引擎的问题
        if urlString.hasPrefix("eyJ") {
            if let decoded = decodeBase64JsonUrl(urlString) {
                log("[PlayerV2] base64 JSON 预解码成功: \(decoded.url.prefix(80))")
                // 合并 base64 JSON 中提取的 header（如 User-Agent）
                var mergedHdrs = customHeaders ?? [:]
                for (k, v) in decoded.headers where !k.isEmpty { mergedHdrs[k] = v }
                // 用解码后的 URL 递归调用，走正常的直链/解析流程
                await handlePlayUrl(decoded.url, spider: spider, video: video, customHeaders: mergedHdrs.isEmpty ? nil : mergedHdrs, sessionId: sessionId)
                return
            }
            log("[PlayerV2] ⚠️ base64 JSON 预解码失败，继续走 playerContent")
        }

        // 🔧 修复: 自定义协议（如 xk://）优先走 playerContent 解析
        // 避免 xk:// 地址被解析器/WKWebView 处理导致失败或卡死
        let lowerUrl = urlString.lowercased()
        let isStandardScheme = lowerUrl.hasPrefix("http://")
                          || lowerUrl.hasPrefix("https://")
                          || lowerUrl.hasPrefix("file://")
                          || lowerUrl.hasPrefix("rtmp://")
                          || lowerUrl.hasPrefix("rtsp://")
        if !isStandardScheme && !urlString.isEmpty {
            log("[PlayerV2] 检测到自定义协议，优先调用 playerContent: \(urlString.prefix(60))")
            if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString, engineKey: video.engineKey) {
                await self.playFromPlayerContentResult(pr, episodeName: video.vodName, spider: spider, baseHeaders: customHeaders, sessionId: sessionId, video: video)
                return
            }
            log("[PlayerV2] ⚠️ 自定义协议 playerContent 无结果，继续尝试解析器")
        }

        // 检测官方平台URL（需要解析器转直链）
        let officialDomains = ["iqiyi.com", "v.qq.com", "youku.com", "mgtv.com", "v.youku.com", "www.mgtv.com", "www.iqiyi.com"]
        let isOfficialPlatform = officialDomains.contains { urlString.contains($0) }

        // 远程源可声明 playStrategy=scriptFirst，让指定 Python 蜘蛛的官方地址先走脚本自带解析。
        // 未声明该策略的源保持原有逻辑：官方平台 URL 仍优先走全局解析器，不影响其他资源。
        if isOfficialPlatform {
            let playStrategy = await MainActor.run {
                SpiderManager.shared.allSites
                    .first { $0.key == video.engineKey }?
                    .playStrategy?
                    .lowercased()
            }
            if playStrategy == "scriptfirst" {
                log("[PlayerV2] playStrategy=scriptFirst，优先调用脚本 playerContent")
                if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString, engineKey: video.engineKey) {
                    await self.playFromPlayerContentResult(pr, episodeName: video.vodName, spider: spider, baseHeaders: customHeaders, sessionId: sessionId, video: video)
                    return
                }
                log("[PlayerV2] ⚠️ scriptFirst playerContent 无结果，回退全局解析器")
            }
        }

        // 检查是否是直链（官方平台URL永不视为直链）
        let isDirectLink: Bool = {
            if isOfficialPlatform { return false }
            // file:// 本地文件始终视为直链
            if urlString.hasPrefix("file://") { return true }
            guard urlString.hasPrefix("http") else { return false }
            let cleanPath: String
            if let url = URL(string: urlString) {
                cleanPath = url.path
            } else if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: encoded) {
                cleanPath = url.path
            } else {
                cleanPath = urlString
            }
            let ext = (cleanPath as NSString).pathExtension.lowercased()
            let videoExts = ["m3u8", "mp4", "flv", "m4v", "ts", "webm", "mkv", "avi", "mov"]
            if videoExts.contains(ext) { return true }
            if cleanPath.contains("/hls/") || cleanPath.contains("/video/") { return true }
            // 兜底：福利平台（vodRemarks 含 [福利]）且是 http(s) URL 时，
            // 只有看起来像媒体直链（m3u8/mp4/hls 等）才直接播放，
            // 否则落入解析器链路，避免把网页 URL 当直链播放导致 AVFoundation -11850
            if (video.vodRemarks?.contains("[福利]") == true) &&
               (urlString.hasPrefix("http://") || urlString.hasPrefix("https://")) {
                return isLikelyDirectMediaUrl(urlString)
            }
            return false
        }()

        if isDirectLink {
            log("[PlayerV2] 直链模式: 直接使用 URL=\(urlString.prefix(100))")
            if let url = createURL(from: urlString) {
                log("[PlayerV2] ✅ URL创建成功, 协议=\(url.scheme ?? "nil"), 主机=\(url.host ?? "nil")")
                await MainActor.run {
                    guard sessionId == nil || playbackSessionId == sessionId else { return }
                    initPlayer(url: url, customHeaders: customHeaders)
                }
                return
            }
            log("[PlayerV2] ❌ 直链URL创建失败, raw=\(urlString.prefix(120))")
        }

        // 提前检测云盘分享链接（如 pan.xunlei.com/s/、pan.quark.cn/s/ 等），
        // 云盘链接无法通过解析器/playerContent/nativeDetail 处理，直接由云盘 API 解析，失败即报错
        if let driveType = CloudDriveManager.detectDrive(from: urlString) {
            let tokens = CloudDriveManager.shared.tokens(for: driveType)
            // Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛）由 Node 常驻系统解析，
            // 不依赖本地 Token，与 handleCloudVideo 的判定保持一致
            if tokens.isEmpty && !CloudDriveManager.isNodeManagedDrive(driveType) {
                let msg = "未配置\(driveType.displayName) Token，请到 设置→网盘播放 中添加"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { self.failPlayback(msg) }
                return
            }
            log("[PlayerV2] ✅ 提前检测到 \(driveType.displayName) 分享链接，直接走云盘解析")
            await handleDriveUrl(urlString, driveType: driveType)
            return
        }

        // 需要解析的链接：先试解析器，再试 playerContent
        if isOfficialPlatform {
            log("[PlayerV2] 解析模式: 检测到官方平台URL，强制走解析器")
        } else {
            log("[PlayerV2] 解析模式: 非直链，尝试解析器")
        }

        // 1. 优先用解析器（subManager.parses + customParsers）
        let allParsers = await MainActor.run { SpiderManager.shared.subManager.parses + SpiderManager.shared.customParsers }
        if !allParsers.isEmpty {
            log("[PlayerV2] 尝试 \(allParsers.count) 个解析器...")
            for parser in allParsers {
                let parseURL = parser.url + (urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString)
                guard let reqURL = URL(string: parseURL) else { continue }
                do {
                    var req = URLRequest(url: reqURL)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let resp = String(data: data, encoding: .utf8) {
                        let patterns = ["https?://[^\\s\"<>]+\\.m3u8[^\\s\"<>]*", "https?://[^\\s\"<>]+\\.mp4[^\\s\"<>]*"]
                        for pattern in patterns {
                            if let regex = try? NSRegularExpression(pattern: pattern),
                               let match = regex.firstMatch(in: resp, range: NSRange(resp.startIndex..., in: resp)),
                               let r = Range(match.range, in: resp) {
                                let result = String(resp[r])
                                if result.hasPrefix("http"), let url = createURL(from: result) {
                                    log("[PlayerV2] ✅ 解析器[\(parser.name)]成功: \(result.prefix(60))")
                                    await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                                    return
                                }
                            }
                        }
                    }
                } catch { continue }
            }
        }

        // 2. 调用 SpiderManager.parsePlayUrl 兜底（含16个公共解析器+WKWebView回退）
        log("[PlayerV2] 内置解析器失败，尝试 SpiderManager.parsePlayUrl 兜底...")
        if let parsedUrl = await spider.parsePlayUrl(from: urlString) {
            log("[PlayerV2] ✅ SpiderManager 解析成功: \(parsedUrl.prefix(60))")
            if let url = createURL(from: parsedUrl) {
                await MainActor.run {
                    guard sessionId == nil || playbackSessionId == sessionId else { return }
                    initPlayer(url: url, customHeaders: customHeaders)
                }
                return
            }
        }

        // 3. 尝试 QuickJS playerContent
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString, engineKey: video.engineKey) {
            let pu = pr.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? pr.url
            // 合并 JS 蜘蛛返回的 header（如剧迷需要 Referer/UA），不覆盖已有自定义头
            var mergedHeaders = customHeaders ?? [:]
            if let spiderHeaders = pr.header {
                for (key, value) in spiderHeaders where !key.isEmpty {
                    mergedHeaders[key] = value
                }
                log("[PlayerV2] 合并 playerContent header: \(mergedHeaders.keys.sorted().joined(separator: ","))")
            }
            // 关键修复：如果 playerContent 返回 parse:1，说明 URL 需要走解析器链路
            // 不能直接传给播放器（如 v.qq.com 网页地址），需要重新走 SpiderManager.parsePlayUrl
            if pr.parse == 1, let rawUrl = pu, !rawUrl.isEmpty {
                log("[PlayerV2] playerContent 返回 parse=1，重新走解析器链路: \(rawUrl.prefix(60))")
                if let reparsedUrl = await spider.parsePlayUrl(from: rawUrl) {
                    log("[PlayerV2] ✅ playerContent 二次解析成功: \(reparsedUrl.prefix(60))")
                    if let url = createURL(from: reparsedUrl) {
                        await MainActor.run {
                            guard sessionId == nil || playbackSessionId == sessionId else { return }
                            initPlayer(url: url, customHeaders: mergedHeaders)
                        }
                        return
                    }
                }
                log("[PlayerV2] ⚠️ playerContent 二次解析失败，仅媒体直链允许兜底播放")
                if let pu = pu, !pu.isEmpty, isLikelyDirectMediaUrl(pu), let url = createURL(from: pu) {
                    log("[PlayerV2] ✅ playerContent parse=1 兜底媒体直链: \(pu.prefix(60))")
                    await MainActor.run {
                        guard sessionId == nil || playbackSessionId == sessionId else { return }
                        initPlayer(url: url, customHeaders: mergedHeaders)
                    }
                    return
                } else if let rawUrl = pu, !rawUrl.isEmpty {
                    log("[PlayerV2] ❌ 备用路径: parse=1 解析失败且不是媒体直链，不再继续兜底: \(rawUrl.prefix(60))")
                    await MainActor.run {
                        guard sessionId == nil || playbackSessionId == sessionId else { return }
                        self.failPlayback("播放地址解析失败，请尝试更换源或清晰度")
                    }
                    return
                }
            } else if let pu = pu, !pu.isEmpty, isStandardPlayScheme(pu), let url = createURL(from: pu) {
                // ★ DASH 检测: spider 返回 MPD 代理 URL 时，AVPlayer 不支持 DASH
                if isDashProxyUrl(pu) {
                    log("[PlayerV2] 🔍 剧集切换检测到 DASH/MPD，切换兼容内核: \(pu.prefix(60))")
                    await MainActor.run {
                        guard sessionId == nil || playbackSessionId == sessionId else { return }
                        self.playbackEngineMode = .compatibility
                        self.compatibilityHint = "B站 DASH 流"
                        self.compatibilityURL = url
                        self.compatibilityHeaders = mergedHeaders
                        self.compatibilityEngineName = self.preferredCompatibilityEngineName(for: url)
                        self.currentPiPStrategy = self.compatibilityPiPStrategy(
                            engineName: self.compatibilityEngineName,
                            url: url
                        )
                    }
                    return
                }

                log("[PlayerV2] ✅ playerContent 成功: \(pu.prefix(60))")
                await MainActor.run {
                    guard sessionId == nil || playbackSessionId == sessionId else { return }
                    initPlayer(url: url, customHeaders: mergedHeaders)
                }
                return
            } else if let pu = pu, !pu.isEmpty {
                log("[PlayerV2] ❌ 备用路径: playerContent 返回非标准协议，跳过: \(pu.prefix(60))")
            }
        }

        // 尝试 nativeDetail 作为备选
        log("[PlayerV2] 备选: 尝试 nativeDetail...")
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            log("[PlayerV2] nativeDetail 成功")
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            log("[PlayerV2] 解析出 \(urls.count) 个播放地址")
            for (index, videoUrl) in urls.enumerated() {
                log("[PlayerV2] 地址\(index): \(videoUrl.prefix(60))...")
            }
            // 通用选择：只在"干净直链"候选中挑选，优先直链媒体（.m3u8/.mp4），
            // 避免用 contains 子串匹配选中仍含 $$$/第01集$ 等分隔符的畸形串导致 404。
            let cleanUrls = urls.filter { Self.isCleanDirectMediaUrl($0) }
            let du = cleanUrls.first(where: {
                let lower = $0.lowercased()
                return lower.contains(".m3u8") || lower.contains(".mp4")
            })
                ?? cleanUrls.first
                ?? urls.first(where: { !$0.contains("$") && !$0.contains("#") })
                ?? pu
            if !du.isEmpty {
                if let url = createURL(from: du) {
                    await MainActor.run { initPlayer(url: url, customHeaders: customHeaders) }
                    return
                }
                log("[PlayerV2] ❌ nativeDetail URL创建失败")
            }
        }
        
        // 检查是否是网盘链接
        log("[PlayerV2] 步骤5: 检查网盘链接...")
        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? urlString
        log("[PlayerV2] 待检测URL: \(playUrlToCheck.prefix(80))")
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            log("[PlayerV2] ✅ 检测到 \(driveType.displayName) 网盘链接")
            // 检查是否配置了Token；Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛/夸克Node）
            // 由 Node 常驻系统解析，不依赖本地 Token，与 handleCloudVideo 的判定保持一致
            let tokens = CloudDriveManager.shared.tokens(for: driveType)
            log("[PlayerV2] \(driveType.displayName) Token数量: \(tokens.count)")
            if tokens.isEmpty && !CloudDriveManager.isNodeManagedDrive(driveType) {
                let msg = "未配置\(driveType.displayName) Token，请到 设置→网盘播放 中添加"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { self.failPlayback(msg) }
                return
            }
            log("[PlayerV2] ⏳ 正在调用 \(driveType.displayName) API 解析...")
            await handleDriveUrl(playUrlToCheck, driveType: driveType)
            return
        } else {
            log("[PlayerV2] ⚠️ 未识别为网盘链接")
        }
        
        // 所有方式失败
        log("[PlayerV2] ❌ 所有方式都失败")
        await MainActor.run {
            self.failPlayback("无法获取可用播放地址，请检查网络或更换其他资源")
        }
    }
    
    // MARK: - 从 $$$ 多源格式中提取最佳播放 URL
    private func extractBestPlayableUrl(playFrom: String, playUrl: String) -> String {
        // 不含 $$$ → 单源，按 # 和 $ 提取第一集
        if !playUrl.contains("$$$") {
            return extractFirstEpisodeUrl(playUrl)
        }
        
        // 含 $$$ → 多源，按 $$$ 分割
        let froms = playFrom.components(separatedBy: "$$$")
        let urlBlocks = playUrl.components(separatedBy: "$$$")
        
        // 为每个源提取第一集URL，按优先级排序：有 http 的 > 有 parse 可解析的 > 其他
        var candidates: [(source: String, url: String, hasHttp: Bool)] = []
        for i in 0..<min(froms.count, urlBlocks.count) {
            let src = froms[i]
            let firstUrl = extractFirstEpisodeUrl(urlBlocks[i])
            let hasHttp = firstUrl.hasPrefix("http")
            if !firstUrl.isEmpty {
                candidates.append((src, firstUrl, hasHttp))
                log("[PlayerV2] 源[\(i)] \(src): \(firstUrl.prefix(60))... http=\(hasHttp)")
            }
        }
        
        // 优先选有 http URL 的源
        if let best = candidates.first(where: { $0.hasHttp }) {
            log("[PlayerV2] 选择源: \(best.source) (http直链)")
            return best.url
        }
        
        // 没有 http 源，返回第一个
        if let first = candidates.first {
            log("[PlayerV2] 使用首个源: \(first.source)")
            return first.url
        }
        
        return playUrl
    }
    
    /// 从单个源块（如 "第1集$url1#第2集$url2"）提取第一集URL
    private func extractFirstEpisodeUrl(_ block: String) -> String {
        if block.contains("#") {
            // 取第一集
            let firstEp = block.components(separatedBy: "#").first ?? block
            if let range = firstEp.range(of: "$") {
                return String(firstEp[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return firstEp.trimmingCharacters(in: .whitespaces)
        } else if block.contains("$") {
            if let range = block.range(of: "$") {
                return String(block[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return block.trimmingCharacters(in: .whitespaces)
    }
    
    // 保留旧方法供其他地方使用
    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        // macCMS 约定格式：$$$ 分隔线路（部分源用它在"一集"内分隔 播放页/直链 候选），
        // # 分隔集数，$ 分隔"集名$url"。先按 $$$ 拆，再按 # 拆，最后按 $ 取 url，
        // 保证每个候选都是独立干净的 URL，避免把 $$$/第01集$ 等畸形串残留进结果。
        let sourceBlocks = playUrl.components(separatedBy: "$$$")
        for block in sourceBlocks {
            let blockTrimmed = block.trimmingCharacters(in: .whitespaces)
            guard !blockTrimmed.isEmpty else { continue }
            let pieces = blockTrimmed.contains("#")
                ? blockTrimmed.components(separatedBy: "#")
                : [blockTrimmed]
            for piece in pieces {
                let p = piece.trimmingCharacters(in: .whitespaces)
                guard !p.isEmpty else { continue }
                if let range = p.range(of: "$") {
                    let u = String(p[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty { urls.append(u) }
                } else {
                    urls.append(p)
                }
            }
        }
        return urls
    }
    
    /// 解析普通资源多集数据，填充通用集数列表 episodeItems
    private func parseNormalEpisodes(playFrom: String, playUrl: String, targetEpisodeName: String? = nil, engineKey: String? = nil) {
        // 如果已经有百度/夸克集数，不覆盖
        guard episodeItems.isEmpty else { return }
        
        // 确定使用哪个源的URL块
        let urlBlock: String
        if playUrl.contains("$$$") {
            // 多源：优先选有 http 直链的源（集数最多），避免选中非直链源导致 handlePlayUrl
            // 走 tryWKWebViewParse（@MainActor）卡死 UI。若无直链源则回退到集数最多的源。
            let urlBlocks = playUrl.components(separatedBy: "$$$")
            var bestDirectBlock = ""
            var bestDirectCount = 0
            var bestAnyBlock = urlBlocks.first ?? ""
            var bestAnyCount = 0
            for block in urlBlocks {
                let parts = block.components(separatedBy: "#").filter { part in
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return false }
                    let urlPart = extractFirstEpisodeUrl(trimmed)
                    return !urlPart.isEmpty
                }
                let count = parts.count
                if count > bestAnyCount {
                    bestAnyCount = count
                    bestAnyBlock = block
                }
                // 检查该源是否有 http 直链
                if let firstPart = parts.first {
                    let firstUrl = extractFirstEpisodeUrl(firstPart)
                    if firstUrl.hasPrefix("http"), count > bestDirectCount {
                        bestDirectCount = count
                        bestDirectBlock = block
                    }
                }
            }
            // 优先使用直链源，无直链源时回退到集数最多的源
            urlBlock = bestDirectCount > 0 ? bestDirectBlock : (bestAnyCount > 0 ? bestAnyBlock : (urlBlocks.first { !$0.isEmpty } ?? ""))
        } else {
            urlBlock = playUrl
        }
        
        // 解析集数
        var items: [EpisodeItem] = []
        if urlBlock.contains("#") {
            let parts = urlBlock.components(separatedBy: "#")
            for (idx, part) in parts.enumerated() {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let name: String
                let url: String
                if let range = trimmed.range(of: "$") {
                    name = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                    url = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    name = "第\(idx + 1)集"
                    url = trimmed
                }
                guard !url.isEmpty else { continue }
                items.append(EpisodeItem(
                    id: idx,
                    name: name.isEmpty ? "第\(idx + 1)集" : name,
                    url: url,
                    engineKey: engineKey,
                    sourceType: .normal
                ))
            }
        }
        
        // 修复：单集资源（电影）也要显示，原逻辑 items.count>1 导致单集不显示
        if items.count >= 1 {
            log("[PlayerV2] 解析到 \(items.count) 集普通资源: \(items.map { $0.name }.joined(separator: ", "))")
            episodeItems = items
            // 根据 vodName 自动定位到当前集（智能匹配）
            if let target = targetEpisodeName {
                let matchedIdx = Self.matchEpisodeIndex(vodName: target, episodes: items)
                if matchedIdx >= 0 {
                    currentEpisodeIndex = matchedIdx
                    log("[PlayerV2] 自动定位到集数: \(items[matchedIdx].name) (index=\(matchedIdx))")
                }
            }
        }
    }
    
    // MARK: - 集数智能匹配
    
    /// 根据 vodName 智能匹配当前集数的索引
    /// 多级匹配策略：
    /// 1. 精确匹配（集名与 vodName 末尾完全匹配）
    /// 2. 包含匹配（vodName 包含集名）
    /// 3. 数字提取匹配（从 vodName 和集名中提取数字进行匹配）
    static func matchEpisodeIndex(vodName: String, episodes: [EpisodeItem]) -> Int {
        guard !episodes.isEmpty else { return -1 }
        
        // 策略1: 精确后缀匹配（vodName 以 " 集名" 结尾）
        for (idx, item) in episodes.enumerated() {
            if vodName.hasSuffix(" \(item.name)") || vodName.hasSuffix("-\(item.name)") {
                return idx
            }
        }
        
        // 策略2: 包含匹配（优先匹配较长的集名，避免 "1" 匹配到 "第10集"）
        let sortedByLength = episodes.enumerated().sorted { $0.element.name.count > $1.element.name.count }
        for (idx, item) in sortedByLength {
            if vodName.contains(item.name), !item.name.isEmpty {
                return idx
            }
        }
        
        // 策略3: 提取数字匹配
        if let targetNum = extractNumber(from: vodName) {
            for (idx, item) in episodes.enumerated() {
                if let epNum = extractNumber(from: item.name), epNum == targetNum {
                    return idx
                }
            }
        }
        
        return -1
    }
    
    /// 从字符串中提取第一个数字
    private static func extractNumber(from text: String) -> Int? {
        let pattern = #"\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return Int(String(text[range]))
    }
    
    /// 通用切集方法（支持所有资源类型）
    func switchToEpisode(index: Int) {
        guard index >= 0, index < episodeItems.count else {
            isSwitchingEpisode = false
            return
        }
        let episode = episodeItems[index]
        currentEpisodeIndex = index
        skipOutroTriggered = false
        skipIntroTriggered = false
        log("[PlayerV2] 切集: \(episode.name) (index=\(index), type=\(episode.sourceType))")
        
        currentTask?.cancel()
        let sessionId = UUID()
        playbackSessionId = sessionId
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            switch episode.sourceType {
            case .normal:
                guard var video = self.currentVideo else {
                    await MainActor.run { self.isSwitchingEpisode = false }
                    return
                }
                if video.engineKey == nil {
                    video.engineKey = episode.engineKey
                }
                // 普通资源：只有明确媒体直链才直接播放；官方平台页/非媒体地址统一走策略调度
                if self.isLikelyDirectMediaUrl(episode.url), let url = URL(string: episode.url) {
                    await MainActor.run {
                        guard self.playbackSessionId == sessionId else { return }
                        // 重置当前时间，避免上一集进度影响
                        self.currentTime = 0
                        self.initPlayer(url: url)
                        // 切集后恢复该集进度
                        if let video = self.currentVideo {
                            self.restorePlaybackProgress(for: video)
                        }
                        // 切集后重新加载弹幕（按集名匹配）
                        if let video = self.currentVideo {
                            self.loadDanmaku(for: video, fileName: episode.name)
                        }
                    }
                } else {
                    // 非媒体直链（官方平台页、自定义协议、占位符等），统一回到播放策略入口
                    log("[PlayerV2] 切集URL非媒体直链，进入播放策略调度: \(episode.url.prefix(60))")
                    await MainActor.run {
                        guard self.playbackSessionId == sessionId else { return }
                        self.isLoading = true
                        self.loadError = nil
                        self.loadingMessage = "正在解析播放地址..."
                    }
                    await self.handlePlayUrl(episode.url, spider: SpiderManager.shared, video: video, sessionId: sessionId)
                }
            case .baidu:
                // 百度网盘：走原有切换逻辑
                if let baiduIdx = episode.baiduFileIndex {
                    await MainActor.run { self.switchBaiduFile(index: baiduIdx) }
                }
            case .quark:
                // 夸克网盘：解析并播放
                await self.playQuarkEpisode(episode: episode)
            case .xunlei:
                // 迅雷云盘：使用专用切集逻辑
                await self.playXunleiEpisode(episode: episode)
            case .ali:
                // 阿里云盘：使用专用切集逻辑
                await self.playAliEpisode(episode: episode)
            case .one15:
                // 115网盘：使用专用切集逻辑
                await self.play115Episode(episode: episode)
            case .pan123:
                // 123云盘：使用专用切集逻辑
                await self.play123Episode(episode: episode)
            case .pan139:
                // 139云盘：使用专用切集逻辑
                await self.play139Episode(episode: episode)
            case .pan189:
                // 天翼云盘：使用专用切集逻辑
                await self.play189Episode(episode: episode)
            case .drive:
                // UC 网盘：使用专用切集逻辑
                if let ucFid = episode.ucFileFid, let ucToken = episode.ucShareFidToken {
                    await self.playUCEpisode(episode: episode)
                } else {
                    // 其他网盘
                    await self.playDriveVideo(url: episode.url, headers: episode.headers)
                }
            case .node:
                // Node 托管网盘（115/123/139/189/迅雷/光鸭/蜗牛）：A1 接缝切集
                await self.playNodeEpisode(episode: episode)
            }
        }
    }
    
    /// 播放夸克网盘指定集数
    private func playQuarkEpisode(episode: EpisodeItem) async {
        guard let quarkIdx = episode.quarkFileIndex,
              quarkIdx < quarkFileList.count else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }
        let file = quarkFileList[quarkIdx]
        let shareURL = quarkShareURL
        guard !shareURL.isEmpty else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }
        
        log("[Quark] 切集播放: \(file.fileName)")
        await MainActor.run { isLoading = true }
        do {
            var resolveParams: [String: String] = ["vbox_fid": file.fid]
            if let route = quarkRoutePreference, !route.isEmpty {
                resolveParams["vbox_route"] = route
            }
            let targetURL = appendVboxFragment(to: shareURL, params: resolveParams)
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: targetURL)
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[Quark] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("夸克切集失败: \(error.localizedDescription)")
            }
        }
    }
    
    /// 播放 UC 网盘指定集数
    private func playUCEpisode(episode: EpisodeItem) async {
        guard let ucFid = episode.ucFileFid,
              let ucShareToken = episode.ucShareFidToken else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }
        
        log("[UC] 切集播放: \(episode.name) (fid=\(ucFid))")
        await MainActor.run { isLoading = true }
        
        guard let token = CloudDriveManager.shared.tokens(for: .uc).first else {
            await MainActor.run { 
                self.failPlayback("未配置UC网盘 Token")
                self.isSwitchingEpisode = false
            }
            return
        }
        
        do {
            let result = try await CloudDriveManager.shared.resolveUCPlayURLForFile(
                shareURL: episode.url,
                cookie: token.value,
                fileFid: ucFid,
                shareFidToken: ucShareToken
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[UC] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("UC切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放迅雷云盘指定集数
    private func playXunleiEpisode(episode: EpisodeItem) async {
        guard let fileId = episode.xunleiFileId else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[Xunlei] 切集播放: \(episode.name) (fileId=\(fileId))")
        await MainActor.run { isLoading = true }

        guard let token = CloudDriveManager.shared.tokens(for: .xunlei).first else {
            await MainActor.run {
                self.failPlayback("未配置迅雷云盘 Cookie")
                self.isSwitchingEpisode = false
            }
            return
        }

        do {
            let result = try await CloudDriveManager.shared.resolveXunleiFilePlayURL(
                shareURL: episode.url,
                cookie: token.value,
                fileId: fileId,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[Xunlei] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("迅雷切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放阿里云盘指定集数
    private func playAliEpisode(episode: EpisodeItem) async {
        guard let fileId = episode.aliFileId else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[Ali] 切集播放: \(episode.name) (fileId=\(fileId))")
        await MainActor.run { isLoading = true }

        do {
            let result = try await CloudDriveManager.shared.resolveAliFilePlayURL(
                shareURL: episode.url,
                fileId: fileId,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[Ali] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("阿里切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放115网盘指定集数
    private func play115Episode(episode: EpisodeItem) async {
        guard let pickCode = episode.one15PickCode else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[115] 切集播放: \(episode.name) (pickCode=\(pickCode))")
        await MainActor.run { isLoading = true }

        guard let token = CloudDriveManager.shared.tokens(for: .one15).first else {
            await MainActor.run {
                self.failPlayback("未配置115网盘 Cookie/CID")
                self.isSwitchingEpisode = false
            }
            return
        }

        do {
            let result = try await CloudDriveManager.shared.resolve115FilePlayURL(
                shareURL: episode.url,
                cid: token.value,
                pickCode: pickCode,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[115] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("115切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放123云盘指定集数
    private func play123Episode(episode: EpisodeItem) async {
        guard let fileId = episode.pan123FileId, let eTag = episode.pan123ETag else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[123] 切集播放: \(episode.name) (fileId=\(fileId))")
        await MainActor.run { isLoading = true }

        guard let token = CloudDriveManager.shared.tokens(for: .pan123).first else {
            await MainActor.run {
                self.failPlayback("未配置123云盘 Cookie")
                self.isSwitchingEpisode = false
            }
            return
        }

        do {
            let result = try await CloudDriveManager.shared.resolve123FilePlayURL(
                shareURL: episode.url,
                token: token.value,
                fileId: fileId,
                eTag: eTag,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[123] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("123切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放139云盘指定集数
    private func play139Episode(episode: EpisodeItem) async {
        guard let contentId = episode.pan139ContentId, let catalogId = episode.pan139CatalogId else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[139] 切集播放: \(episode.name) (contentId=\(contentId))")
        await MainActor.run { isLoading = true }

        guard let token = CloudDriveManager.shared.tokens(for: .pan139).first else {
            await MainActor.run {
                self.failPlayback("未配置139云盘 Cookie")
                self.isSwitchingEpisode = false
            }
            return
        }

        do {
            let result = try await CloudDriveManager.shared.resolve139FilePlayURL(
                shareURL: episode.url,
                cookie: token.value,
                contentId: contentId,
                catalogId: catalogId,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[139] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("139切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放天翼云盘指定集数
    private func play189Episode(episode: EpisodeItem) async {
        guard let fileId = episode.pan189FileId else {
            await MainActor.run { self.isSwitchingEpisode = false }
            return
        }

        log("[189] 切集播放: \(episode.name) (fileId=\(fileId))")
        await MainActor.run { isLoading = true }

        guard let token = CloudDriveManager.shared.tokens(for: .pan189).first else {
            await MainActor.run {
                self.failPlayback("未配置天翼云盘 Cookie")
                self.isSwitchingEpisode = false
            }
            return
        }

        do {
            let result = try await CloudDriveManager.shared.resolve189FilePlayURL(
                shareURL: episode.url,
                cookie: token.value,
                fileId: fileId,
                fileName: episode.name
            )
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[189] 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("天翼切集失败: \(error.localizedDescription)")
            }
        }
    }

    /// 播放 Node 托管网盘指定集数（A1 接缝 /spider/push/4/play）
    private func playNodeEpisode(episode: EpisodeItem) async {
        guard let playID = episode.nodePlayID, !playID.isEmpty else {
            log("[Node] ❌ 切集失败: 缺少 Node playID")
            await MainActor.run {
                self.failPlayback("切集失败: 缺少 Node 播放参数")
            }
            return
        }
        let driveType = episode.nodeDriveType ?? .guangya
        log("[Node] \(driveType.displayName) 切集播放: \(episode.name) (playID 前 24 字符=\(playID.prefix(24)))")
        await MainActor.run { isLoading = true }
        do {
            let result = try await CloudDriveManager.shared.resolveNodePlay(playID: playID, driveType: driveType)
            await MainActor.run {
                currentEpisodeIndex = episode.id
            }
            await playResolvedDriveVideo(result)
        } catch {
            log("[Node] \(driveType.displayName) 切集失败: \(error.localizedDescription)")
            await MainActor.run {
                self.failPlayback("\(driveType.displayName)切集失败: \(error.localizedDescription)")
            }
        }
    }

    private func initPlayer(url: URL, noReferer: Bool = false, customHeaders: [String: String]? = nil) {
        guard !Task.isCancelled else {
            log("[PlayerV2] 已取消的播放任务，跳过播放器初始化")
            return
        }
        if !noReferer { hasRetriedNoReferer = false }
        skipOutroTriggered = false
        skipIntroTriggered = false
        isSwitchingEpisode = false
        log("[PlayerV2] 初始化播放器: \(url.absoluteString.prefix(100))...")
        detectVideoQuality(from: url.absoluteString)

        // 场景恢复保护：延迟 AVPlayer 创建，避免主线程阻塞触发 watchdog
        if isRestoringFromBackground {
            log("[PlayerV2] 场景恢复中，延迟播放器创建(200ms)")
            sceneRestorationTask?.cancel()
            sceneRestorationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run { self?.initPlayer(url: url, noReferer: noReferer, customHeaders: customHeaders) }
            }
            return
        }

        let sessionId = beginPlaybackSession()

        if shouldRouteDirectURLToMPV(url) {
            log("[PlayerV2] 直链资源分流到 MPV-MoltenVK：\(url.pathExtension.lowercased())")
            stopPlaybackWatchdog()
            if let oldObserver = timeObserver {
                player?.removeTimeObserver(oldObserver)
                timeObserver = nil
            }
            cleanupObservers()
            player?.pause()
            player = nil
            compatibilityEngineName = "MPV-MoltenVK"
            compatibilityURL = url
            compatibilityHeaders = [:]
            currentPiPStrategy = compatibilityPiPStrategy(engineName: "MPV-MoltenVK", url: url)
            playbackEngineMode = .compatibility
            compatibilityHint = "MKV / 复杂封装"
            isPlaying = true
            // 修复: 显式禁用自动锁屏（直链 MPV 分流路径）
            UIApplication.shared.isIdleTimerDisabled = true
            isLoading = true
            isSwitchingEpisode = false
            loadingMessage = "正在启动 MPV-MoltenVK..."
            return
        }
        
        // 清理旧的观察者（防止 retry 叠加）
        if let oldObserver = timeObserver {
            player?.removeTimeObserver(oldObserver)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil

        // 修复: 清理兼容内核残留状态，防止 MPV/VLC 视图遮挡 AVPlayer 画面
        // 当用户从 MKV(兼容内核) 切换到普通 m3u8/蜘蛛资源时，
        // 如果 compatibilityURL 未清理，PlayerContainerView 仍渲染兼容内核视图，
        // AVPlayer 在后台播放音频但画面被遮挡，表现为"有声音无画面"
        if compatibilityURL != nil {
            log("[PlayerV2] 清理兼容内核残留状态，切换到 AVPlayer 系统内核")
            compatibilityURL = nil
            compatibilityHeaders = [:]
            compatibilityHint = nil
            currentPiPStrategy = .system
            playbackEngineMode = .system
            NotificationCenter.default.post(name: .vboxMPVStop, object: nil)
            NotificationCenter.default.post(name: .vboxVLCPause, object: nil)
        }

        // 配置Asset选项（针对m3u8切片优化）
        var assetOptions: [String: Any] = [:]
        
        // 本地代理 URL（127.0.0.1）的处理
        // 代理服务器本身不需要 AVPlayer 的 headers（它用自己的存储 headers）
        // 但 m3u8 中的 key URI 和 TS 分片可能需要正确的 headers（如六速社区需要 User-Agent 和 Referer）
        // 当 m3u8 重写只修复 key URI 为绝对路径（不改写为代理 URL）时，
        // AVPlayer 会直接请求 CDN 获取 key 和 TS，需要正确的 headers
        let isLocalProxy = url.host == "127.0.0.1"
        
        if isLocalProxy {
            if let customHeaders, !customHeaders.isEmpty {
                // 本地代理 + 有 customHeaders：使用 customHeaders
                // 代理请求会忽略这些 headers，但 key/TS 直接请求 CDN 时需要
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = customHeaders
                log("[PlayerV2] HTTP头配置 - 本地代理URL，使用customHeaders: \(customHeaders.keys.joined(separator: ","))")
            } else {
                // 本地代理 + 无 customHeaders：清空 headers
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = [:]
                log("[PlayerV2] HTTP头配置 - 本地代理URL，清空headers")
            }
        } else {
            // 设置HTTP头（m3u8播放通常需要正确的User-Agent和Referer）
            var headers: [String: String] = [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                "Accept": "*/*",
                "Accept-Language": "zh-CN,zh;q=0.9"
            ]
            if !noReferer {
                var referer = url.absoluteString
                if let host = url.host {
                    referer = "https://\(host)/"
                }
                headers["Referer"] = referer
                log("[PlayerV2] HTTP头配置 - Referer: \(referer)")
            } else {
                log("[PlayerV2] HTTP头配置 - 不带Referer（重试模式）")
            }
            if let customHeaders {
                // 检查是否启用了"保留Referer"模式（由福利平台 playerRefererMode=keep 触发）
                // 此模式下，即使 Referer 域名与播放域名不匹配，也保留脚本返回的 Referer
                // （直播源等场景：CDN 域名与主站域名不同，但仍需主站 Referer 通过防盗链）
                let keepReferer = (customHeaders["X-VBox-Player-Referer-Mode"] ?? "").lowercased() == "keep"
                for (key, value) in customHeaders {
                    // 跳过内部标记头，不传给 AVPlayer
                    if key.lowercased() == "x-vbox-player-referer-mode" { continue }
                    if key.lowercased() == "referer" && !noReferer {
                        if keepReferer {
                            // keep 模式：直接使用脚本返回的 Referer，不做域名检查
                            headers[key] = value
                            log("[PlayerV2] Referer策略=keep，使用脚本返回的Referer: \(value)")
                        } else {
                            // 默认: 蜘蛛返回的Referer域名与播放URL域名不匹配时，用CDN自身Referer替代
                            // 避免主站Referer导致CDN返回403
                            let customHost = extractHost(from: value)
                            let playHost = url.host ?? ""
                            if !customHost.isEmpty && !playHost.isEmpty && customHost != playHost {
                                log("[PlayerV2] ⚠️ Referer域名不匹配(spider=\(customHost) vs play=\(playHost))，使用CDN自身Referer")
                                // 保留CDN自身Referer，不覆盖
                            } else {
                                headers[key] = value
                            }
                        }
                    } else {
                        headers[key] = value
                    }
                }
                log("[PlayerV2] 已合并自定义HTTP头，Referer=\(headers["Referer"] ?? "nil")")
            }
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        
        // 修复: 捕获最终 HTTP 头，供首帧检测失败时传递给 MPV 兜底
        let finalHeaders = (assetOptions["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String]) ?? [:]
        
        // 创建Asset和PlayerItem
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        
        // 配置PlayerItem（针对HLS/m3u8优化）
        playerItem.preferredForwardBufferDuration = 10.0 // 预缓冲10秒

        // 创建播放器
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        // 监听PlayerItem状态
        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                guard self.playbackSessionId == sessionId else { return }
                switch status {
                case .readyToPlay:
                    self.log("[PlayerV2] PlayerItem 准备就绪")
                    self.isLoading = false
                    self.loadError = nil
                    // 修复: 对普通/蜘蛛资源也执行首帧检测，防止有声音无画面
                    self.scheduleVideoTrackCheck(
                        for: playerItem,
                        startedAt: Date(),
                        isBaiduLocalProxy: false,
                        isQuarkLocalProxy: false,
                        fallbackURL: url,
                        fallbackHeaders: finalHeaders
                    )
                    if self.currentTime > 10 {
                        let resume = self.currentTime
                        self.log("[Progress] 自动跳转到上次进度：\(self.formatDuration(resume))")
                        p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    } else if self.skipIntroEnabled, self.skipIntroSeconds > 0, !self.skipIntroTriggered {
                        self.skipIntroTriggered = true
                        let skip = Double(self.skipIntroSeconds)
                        self.log("[PlayerV2] ⏩ 跳过片头 \(self.formatDuration(skip))")
                        p.seek(to: CMTime(seconds: skip, preferredTimescale: 600))
                        self.currentTime = skip
                    }
                case .failed:
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    let errorCode = (playerItem.error as? NSError)?.code ?? -1
                    let errorDomain = (playerItem.error as? NSError)?.domain ?? ""
                    self.log("[PlayerV2] ❌ PlayerItem 失败: code=\(errorCode) domain=\(errorDomain) desc=\(errorDesc)")
                    if let underlying = (playerItem.error as? NSError)?.userInfo[NSUnderlyingErrorKey] as? Error {
                        self.log("[PlayerV2] ❌ 底层错误: \(underlying.localizedDescription)")
                    }
                    // -11850/-12939 可能是Referer校验失败，尝试不带Referer重试
                    if (errorCode == -11850 || errorCode == -12939) && !self.hasRetriedNoReferer {
                        self.hasRetriedNoReferer = true
                        self.log("[PlayerV2] 🔄 疑似Referer校验失败，尝试不带Referer重试...")
                        self.statusObserver = nil
                        self.failureObserver = nil
                        self.initPlayer(url: url, noReferer: true)
                        return
                    }
                    let errMsg = errorDesc.contains("不能") || errorDesc.contains("format") || errorDesc.contains("Invalid") 
                        ? "播放地址格式不支持" : "播放地址加载失败: \(errorDesc)"
                    Task { @MainActor in
                        self.failPlayback(errMsg)
                    }
                case .unknown:
                    self.log("[PlayerV2] PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }
        statusObserver = localStatusObserver
        
        // 监听播放失败
        failureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard self.playbackSessionId == sessionId else { return }
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self.log("[PlayerV2] ❌ 播放失败: \(error.localizedDescription)")
                    self.failPlayback("播放失败: \(error.localizedDescription)")
                }
            }
        
        // 监听播放结束
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.playbackSessionId == sessionId else { return }
                self.log("[PlayerV2] 播放结束")
                // 普通资源自动播放下一集
                self.playNextEpisodeIfAvailable()
            }
        
        self.player = p
        self.currentPiPStrategy = .system
        self.isPlaying = true
        // 修复: 显式禁用自动锁屏（普通/蜘蛛资源 AVPlayer 路径）
        // isPlaying 初始值为 true，设置 true 不触发 .onChange，须显式设置
        UIApplication.shared.isIdleTimerDisabled = true
        // 修复竞态：await/async 期间 playerItem.status 可能已变为 .readyToPlay，
        // 观察者已在主队列回调中设置了 isLoading=false。
        // 此处若盲目覆盖为 true，status 不再变化，观察者不会再次触发，
        // 界面永久卡在"正在缓冲首帧..."（间歇性问题根因）。
        // 仅在仍未就绪时才设为 loading 状态，与网盘路径（第2757行）保持一致。
        if playerItem.status != .readyToPlay {
            isLoading = true
            loadingMessage = "正在缓冲首帧..."
        }
        startPlaybackWatchdog(for: sessionId)
        
        // 10秒超时保护：如果PlayerItem一直没就绪，显示错误
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self = self else { return }
            // 🔧 修复: 检查 self.player === p，确保超时只销毁当前播放器
            // 旧代码只检查 self.player != nil，当播放器被替换后（重试/后台详情）仍会误杀新播放器
            if await MainActor.run(body: { self.playbackSessionId == sessionId && self.player != nil && self.player === p && self.loadError == nil }) {
                let status = await MainActor.run { p.currentItem?.status }
                let isActuallyPlaying = await MainActor.run { p.rate > 0 || p.timeControlStatus == .playing }
                // 如果视频已经在播放或已就绪，不触发超时
                if status != .readyToPlay && !isActuallyPlaying {
                    await MainActor.run {
                        self.log("[PlayerV2] ⏱️ 播放地址加载超时")
                        self.failPlayback("播放地址加载超时，请检查网络或更换资源")
                    }
                }
            }
        }
        
        // 添加时间观察者
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            guard self.playbackSessionId == sessionId, self.player === p else { return }
            self.currentTime = time.seconds
            self.updateSubtitle(currentTime: time.seconds)
            if let itemDuration = p.currentItem?.duration {
                self.duration = itemDuration.seconds.isFinite ? itemDuration.seconds : 0
            }
            self.updateDanmaku(at: time.seconds)
            self.savePlaybackProgress()
            // 跳过片尾：普通/蜘蛛资源接近结尾时自动播放下一集
            if self.skipOutroEnabled, self.skipOutroSeconds > 0, !self.skipOutroTriggered,
               self.duration > 0, self.currentTime > 0,
               self.currentTime >= self.duration - Double(self.skipOutroSeconds) {
                self.skipOutroTriggered = true
                self.log("[PlayerV2] ⏩ 跳过片尾 \(self.formatDuration(Double(self.skipOutroSeconds)))，自动播放下一集")
                self.playNextEpisode()
            }
        }
        
        // 延迟播放确保UI准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.playbackSessionId == sessionId, self.player === p else { return }
            p.play()
            self.log("[PlayerV2] 播放器开始播放")
        }

        // 安全兜底：播放器已实际播放（有进度/在播放/已就绪）但 isLoading 仍为 true 时，清除 loading 状态。
        // 覆盖 status observer 因极端时序未触发 readyToPlay 回调的边界情况。
        // 正常资源 isLoading 早已被 observer 设为 false，此检查不会触发。
        Task { @MainActor [weak self, weak p] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let p, self.player === p else { return }
            guard self.playbackSessionId == sessionId else { return }
            guard self.isLoading, self.loadError == nil else { return }
            let isPlaying = p.rate > 0 || p.timeControlStatus == .playing
            let seconds = p.currentTime().seconds
            let itemStatus = p.currentItem?.status
            if isPlaying || seconds > 0 || itemStatus == .readyToPlay {
                self.log("[PlayerV2] ⚠️ 播放器已就绪/播放中但 isLoading 仍为 true，自动清除 loading 状态 (rate=\(p.rate), seconds=\(String(format: "%.1f", seconds)), status=\(String(describing: itemStatus)))")
                self.isLoading = false
            }
        }
    }

    private func shouldRouteDirectURLToMPV(_ url: URL) -> Bool {
        guard enginePreference != .system, isMPVBuildAvailable else { return false }
        if enginePreference == .mpv { return true }
        let text = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return false }
        if ext == "m3u8" { return false }
        return ext == "mkv" || text.contains(".mkv") || text.contains("mkv")
    }
    
    private func cleanupObservers() {
        statusObserver?.cancel()
        failureObserver?.cancel()
        endObserver?.cancel()
        statusObserver = nil
        failureObserver = nil
        endObserver = nil
    }

    private func beginPlaybackSession() -> UUID {
        playbackSessionId = UUID()
        isPiPActive = false
        currentPiPStrategy = .system
        return playbackSessionId
    }

    private func startPlaybackWatchdog(for sessionId: UUID) {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.playbackSessionId == sessionId else { return }
                // 修复: 移除 compatibilityURL guard，改为依赖 self.player 检查
                // 原 guard (compatibilityURL == nil) 在 Fix 清理 compatibilityURL 后已不需要
                // 当使用兼容内核时 self.player 为 nil，下一行 guard 会自动跳过
                guard self.isLoading, self.loadError == nil else { continue }
                guard let p = self.player, p.currentItem != nil else { continue }

                let seconds = p.currentTime().seconds
                let isPlaying = p.rate > 0 || p.timeControlStatus == .playing
                let hasProgress = seconds.isFinite && seconds > 0
                let itemStatus = p.currentItem?.status

                if isPlaying || hasProgress || itemStatus == .readyToPlay {
                    self.log("[PlayerV2] ⚠️ watchdog 检测到播放器已就绪/播放中但 isLoading 仍为 true，自动清除 loading 状态")
                    self.isLoading = false
                }
            }
        }
    }

    private func stopPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
    }

    func stopPlaybackForFailure() {
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = nil
        playbackSessionId = UUID()
        stopPlaybackWatchdog()
        // 修复: 清理 seek 超时保护任务
        seekTimeoutTask?.cancel()
        seekTimeoutTask = nil
        cleanupObservers()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        compatibilityURL = nil
        compatibilityHeaders = [:]
        currentPiPStrategy = .system
        isPlaying = false
        // 修复: 显式恢复自动锁屏（失败路径，确保不依赖 .onChange）
        UIApplication.shared.isIdleTimerDisabled = false
        isSeeking = false
        showControls = false
        showSettings = false
        showEpisodePicker = false
        showQualityPicker = false
        showDanmakuSettings = false
        showEnginePicker = false
        showDanmakuInput = false
        showToolsMenu = false
        showSkipSettings = false
        showDanmakuSearch = false
        showLongPressSpeedSettings = false
        showLongPressSpeedHint = false
        showSubtitleSettings = false
        skipOutroTriggered = false
        skipIntroTriggered = false
        isSwitchingEpisode = false
        NotificationCenter.default.post(name: .vboxMPVStop, object: nil)
        NotificationCenter.default.post(name: .vboxVLCPause, object: nil)
    }

    func failPlayback(_ message: String) {
        stopPlaybackForFailure()
        loadError = message
        isLoading = false
        loadingMessage = "播放失败"
        log("[PlayerV2] 已进入失败态并释放播放器: \(message)")
    }
}

// MARK: - 播放器容器视图
struct PlayerContainerView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    // 5秒无触摸自动隐藏控制栏
    @State private var autoHideTask: Task<Void, Never>?
    // 锁定按钮独立自动隐藏（3秒）
    @State private var lockButtonVisible = true
    @State private var lockButtonAutoHideTask: Task<Void, Never>?
    // 弹幕输入文本
    @State private var danmakuInputText: String = ""
    @FocusState private var danmakuInputFocused: Bool

    private var isAliPlayerBuildAvailable: Bool {
        return NSClassFromString("AliPlayer") != nil
    }

    private var isAnyControlPopupPresented: Bool {
        playerState.showSettings ||
        playerState.showEpisodePicker ||
        playerState.showQualityPicker ||
        playerState.showDanmakuSettings ||
        playerState.showEnginePicker ||
        playerState.showDanmakuInput ||
        playerState.showToolsMenu ||
        playerState.showSkipSettings ||
        playerState.showDanmakuSearch ||
        playerState.showLongPressSpeedSettings
    }

    private var hasPlaybackError: Bool {
        playerState.loadError != nil
    }

    private var canAutoHideControls: Bool {
        !hasPlaybackError &&
        !isAnyControlPopupPresented &&
        !playerState.isSeeking &&
        !playerState.isOrientationLocked &&
        !playerState.showLongPressSpeedHint &&
        playerState.showControls &&
        playerState.isPlaying
    }

    private func resetAutoHideTimer() {
        autoHideTask?.cancel()
        guard canAutoHideControls else { return }
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.canAutoHideControls else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.playerState.showControls = false
                }
            }
        }
    }

    /// 锁定按钮独立自动隐藏（3秒），与主控制栏的 autoHideTimer 解耦
    private func resetLockButtonAutoHide() {
        lockButtonAutoHideTask?.cancel()
        lockButtonAutoHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.lockButtonVisible = false
                }
            }
        }
    }

    private func handleControlPopupChange(_ isPresented: Bool) {
        if isPresented {
            autoHideTask?.cancel()
        } else {
            resetAutoHideTimer()
        }
    }
    
    var body: some View {
        ZStack {
            // 视频层（如果有播放器）
            if let url = playerState.compatibilityURL {
                if playerState.compatibilityEngineName.contains("MDK") {
                    #if canImport(swift_mdk)
                    MDKPlayerRepresentable(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    #else
                    CompatibilityUnavailableView(engineName: "MDK", message: "当前构建未包含 MDK，请等待兼容内核构建包")
                    #endif
                } else if playerState.compatibilityEngineName.contains("MPV") {
                    #if canImport(Libmpv)
                    LibmpvMoltenVKPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    #else
                    CompatibilityUnavailableView(engineName: "MPV-MoltenVK", message: "当前构建未包含 Libmpv")
                    #endif
                } else if playerState.compatibilityEngineName.contains("IJK") {
                    #if canImport(IJKMediaFrameworkWithSSL)
                    IJKPlayerRepresentable(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    #else
                    CompatibilityUnavailableView(engineName: "IJKPlayer", message: "当前构建未包含 IJKPlayer")
                    #endif
                } else if playerState.compatibilityEngineName.contains("AliPlayer") {
                    if isAliPlayerBuildAvailable {
                    AliPlayerRepresentable(
                        url: url.absoluteString,
                        headers: playerState.compatibilityHeaders,
                        userAgent: nil as String?,
                        referer: nil as String?,
                        playerState: playerState,
                        onStatusChange: { _ in },
                        onTimeUpdate: { time in playerState.currentTime = time },
                        onDurationChange: { dur in playerState.duration = dur },
                        onBufferUpdate: { _ in },
                        onError: { msg in playerState.failPlayback(msg) },
                        onReady: { playerState.isLoading = false },
                        onSeekDone: { playerState.isSeeking = false }
                    )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    } else {
                    CompatibilityUnavailableView(engineName: "AliPlayer", message: "当前构建未包含 AliyunPlayer")
                    }
                } else {
                #if canImport(MobileVLCKit)
                VLCPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                #else
                CompatibilityUnavailableView(engineName: "VLC", message: "当前构建未包含 VLC，请等待兼容内核构建包")
                #endif
                }
            } else if let player = player {
                AVPlayerControllerRepresentableV2(player: player, videoGravity: playerState.videoGravity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            
            // 加载层：播放器初始化后到首帧出现前也持续显示，避免黑屏无反馈
            if playerState.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(playerState.loadingMessage)
                        .foregroundColor(.white.opacity(0.8))
                        .font(.subheadline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(Color.black.opacity(0.45))
                .cornerRadius(14)
                .allowsHitTesting(false)
                .zIndex(10)
            }
            
            // 弹幕层
            if playerState.showDanmaku {
                DanmakuOverlayViewV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: playerState.danmakuOpacity,
                    fontSize: playerState.danmakuFontSize,
                    area: playerState.danmakuArea,
                    currentTime: playerState.currentTime,
                    items: playerState.danmakuItems
                )
                .allowsHitTesting(false)
                .zIndex(15)
            }
            
            // 手势层：错误弹窗显示时禁用，避免触摸穿透导致控制栏被再次唤出。
            if !hasPlaybackError {
                GestureControlView(playerState: playerState) {
                    guard !playerState.isSeeking else { return }
                    guard !playerState.showLongPressSpeedHint else { return }
                    guard !isAnyControlPopupPresented else { return }
                    if playerState.isOrientationLocked {
                        // 锁定状态：点击屏幕只显示锁定按钮，3秒后自动隐藏
                        withAnimation(.easeInOut(duration: 0.2)) {
                            lockButtonVisible = true
                        }
                        resetLockButtonAutoHide()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            playerState.showControls.toggle()
                        }
                        if playerState.showControls {
                            resetAutoHideTimer()
                        }
                    }
                }
                .ignoresSafeArea()
                .zIndex(20)
            }

            // 控制层：失败态交给错误弹窗接管，不再显示底部控制栏和锁屏按钮。
            if !hasPlaybackError && (playerState.showControls || playerState.isOrientationLocked) {
                PlayerControlsView(
                    player: player,
                    playerState: playerState,
                    video: video,
                    showLockButton: lockButtonVisible
                )
                .zIndex(30)
            }

            
            // 弹窗层 - 独立于控制栏，即使控制栏隐藏也能显示
            // 弹窗 - 倍数（竖屏：固定在右下角进度条上方 / 横屏：居中弹窗）
            Group {
                if playerState.isPortrait && playerState.showSettings {
                    // 竖屏：倍数弹窗固定在进度条上方，屏幕右侧
                    GeometryReader { geo in
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showSettings = false
                                }
                            }

                        PlayerSettingsPanelV2(
                            isPresented: $playerState.showSettings,
                            speed: $playerState.playbackSpeed,
                            onSpeedChange: { speed in
                                playerState.changePlaybackSpeed(speed)
                            }
                        )
                        .environmentObject(settings)
                        .frame(width: 100)
                        // 弹窗放在进度条上方（底部栏约60pt + 进度条约30pt + 间距）
                        .position(x: geo.size.width - 80, y: geo.size.height - 200)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !playerState.isPortrait && playerState.showSettings {
                    // 横屏：小竖条弹窗，固定在底部栏"自动"按钮上方
                    GeometryReader { geo in
                        // 点击空白区域关闭弹窗
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showSettings = false
                                }
                            }

                        PlayerSettingsPanelV2(
                            isPresented: $playerState.showSettings,
                            speed: $playerState.playbackSpeed,
                            isPortrait: false,
                            onSpeedChange: { speed in
                                playerState.changePlaybackSpeed(speed)
                            }
                        )
                        .environmentObject(settings)
                        .frame(width: 50)
                        // 固定在进度条上方
                        .position(x: geo.size.width - 38, y: geo.size.height - 200)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.8)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .zIndex(40)
            // 弹窗 - 选集（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showEpisodePicker {
                    EpisodePickerPopupWrapper(playerState: playerState, isPresented: $playerState.showEpisodePicker)
                } else if !playerState.isPortrait && playerState.showEpisodePicker {
                    // 横屏：小弹窗，带标题栏
                    LandscapeEpisodePickerOverlay(playerState: playerState, isPresented: $playerState.showEpisodePicker)
                }
            }
            .zIndex(40)
            // 侧边栏弹窗 - 清晰度
            Group {
                if playerState.showQualityPicker {
                    if playerState.isPortrait {
                        // 竖屏：清晰度小长条弹窗，固定在倍数弹窗位置（右下角进度条上方）
                        GeometryReader { geo in
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        playerState.showQualityPicker = false
                                    }
                                }

                            QualityPickerPanelV2(
                                selectedQuality: $playerState.selectedQuality,
                                isBaiduSourceMode: !playerState.baiduFileList.isEmpty,
                                isPortrait: true,
                                onQualityChange: { index in
                                    playerState.changeQuality(index: index)
                                }
                            )
                            .environmentObject(settings)
                            .frame(width: 110)
                            .position(x: geo.size.width - 75, y: geo.size.height - 260)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // 横屏：小竖条弹窗，固定在清晰度按键上方
                        GeometryReader { geo in
                            Color.black.opacity(0.3)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        playerState.showQualityPicker = false
                                    }
                                }

                            QualityPickerPanelV2(
                                selectedQuality: $playerState.selectedQuality,
                                isBaiduSourceMode: !playerState.baiduFileList.isEmpty,
                                isPortrait: false,
                                onQualityChange: { index in
                                    playerState.changeQuality(index: index)
                                }
                            )
                            .environmentObject(settings)
                            .frame(width: 100)
                            // 固定在进度条上方（与倍数弹窗同位置区域）
                            .position(x: geo.size.width - 53, y: geo.size.height - 200)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .zIndex(40)
            // 弹窗 - 弹幕设置（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showDanmakuSettings {
                    PortraitPopupView(isPresented: $playerState.showDanmakuSettings, title: "弹幕设置") {
                        DanmakuSettingsPanelV2(
                            showDanmaku: $playerState.showDanmaku,
                            opacity: $playerState.danmakuOpacity,
                            fontSize: $playerState.danmakuFontSize,
                            area: $playerState.danmakuArea,
                            speed: $playerState.danmakuSpeed,
                            colorMode: $playerState.danmakuColorMode,
                            isPortrait: true
                        )
                    }
                } else if !playerState.isPortrait && playerState.showDanmakuSettings {
                    GeometryReader { geo in
                        // 点击空白区域关闭弹窗
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showDanmakuSettings = false
                                }
                            }

                        DanmakuSettingsPanelV2(
                            showDanmaku: $playerState.showDanmaku,
                            opacity: $playerState.danmakuOpacity,
                            fontSize: $playerState.danmakuFontSize,
                            area: $playerState.danmakuArea,
                            speed: $playerState.danmakuSpeed,
                            colorMode: $playerState.danmakuColorMode,
                            isPortrait: false
                        )
                        .frame(width: min(geo.size.width * 0.5, 320), height: min(geo.size.height * 0.55, 350))
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(settings.usesFrostedSkin ? Color(uiColor: .secondarySystemBackground) : Color.black.opacity(0.85))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2 - 40)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .zIndex(40)
            // 弹幕输入弹窗
            Group {
                if playerState.showDanmakuInput {
                    GeometryReader { geo in
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                danmakuInputText = ""
                                danmakuInputFocused = false
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showDanmakuInput = false
                                }
                            }

                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                TextField("发送弹幕...", text: $danmakuInputText)
                                    .font(.system(size: 15))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 20)
                                            .fill(Color.white.opacity(0.15))
                                    )
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .focused($danmakuInputFocused)

                                Button(action: {
                                    let text = danmakuInputText
                                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                    playerState.sendDanmaku(text: text)
                                    danmakuInputText = ""
                                    danmakuInputFocused = false
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        playerState.showDanmakuInput = false
                                    }
                                }) {
                                    Text("发送")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 20)
                                                .fill(Color(hex: "00BE06"))
                                        )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(danmakuInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 16)
                            .background(Color(hex: "1A1A1A"))
                            .cornerRadius(12)
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height - 160)
                        .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .zIndex(40)
            // 弹窗 - 播放内核（竖屏全屏，横屏小弹窗）
            Group {
                if playerState.isPortrait && playerState.showEnginePicker {
                    PortraitPopupView(isPresented: $playerState.showEnginePicker, title: "播放内核") {
                        EnginePickerPanelV2(playerState: playerState, isPortrait: true)
                    }
                } else if !playerState.isPortrait && playerState.showEnginePicker {
                    // 横屏：小方形弹窗，固定在内核按键上方
                    GeometryReader { geo in
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    playerState.showEnginePicker = false
                                }
                            }

                        EnginePickerPanelV2(playerState: playerState, isPortrait: false)
                            .environmentObject(settings)
                            .frame(width: 100, height: 260)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(settings.usesFrostedSkin ? Color(uiColor: .secondarySystemBackground) : Color.black.opacity(0.85))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
                            // 固定在进度条上方（与倍数弹窗同位置区域）
                            .position(x: geo.size.width - 38, y: geo.size.height - 200)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.8)),
                                removal: .opacity.combined(with: .scale(scale: 0.9))
                            ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .zIndex(40)

            // 更多功能竖条菜单（横屏：固定在右上角三点按钮下方）
            if !playerState.isPortrait && playerState.showToolsMenu {
                GeometryReader { geo in
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                playerState.showToolsMenu = false
                            }
                        }
                    ToolsQuickMenuV2(
                        showSkipSettings: $playerState.showSkipSettings,
                        showToolsMenu: $playerState.showToolsMenu,
                        autoPlayNext: $playerState.autoPlayNext,
                        backgroundPlay: $playerState.backgroundPlay,
                        pipEnabled: $playerState.pipEnabled,
                        showDebugOverlay: $playerState.showDebugOverlay,
                        showDanmakuSearch: $playerState.showDanmakuSearch,
                        showLongPressSpeedSettings: $playerState.showLongPressSpeedSettings,
                        showSubtitleSettings: $playerState.showSubtitleSettings
                    )
                    .environmentObject(settings)
                    .position(x: geo.size.width - 70.5, y: 155)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(40)
            }

            // 片头片尾设置面板（横屏：居中显示）
            if !playerState.isPortrait && playerState.showSkipSettings {
                GeometryReader { geo in
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                playerState.showSkipSettings = false
                            }
                        }
                    SkipSettingsPanelV2(
                        isPresented: $playerState.showSkipSettings,
                        skipIntroEnabled: $playerState.skipIntroEnabled,
                        skipIntroSeconds: $playerState.skipIntroSeconds,
                        skipOutroEnabled: $playerState.skipOutroEnabled,
                        skipOutroSeconds: $playerState.skipOutroSeconds
                    )
                    .environmentObject(settings)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .onChange(of: playerState.skipIntroEnabled) { _ in playerState.saveSkipSettings() }
                    .onChange(of: playerState.skipIntroSeconds) { _ in playerState.saveSkipSettings() }
                    .onChange(of: playerState.skipOutroEnabled) { _ in playerState.saveSkipSettings() }
                    .onChange(of: playerState.skipOutroSeconds) { _ in playerState.saveSkipSettings() }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(41)
            }

            // 搜索弹幕面板（居中弹窗，竖屏/横屏均可用）
            if playerState.showDanmakuSearch {
                GeometryReader { geo in
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                playerState.showDanmakuSearch = false
                            }
                        }
                    DanmakuSearchPanel(
                        isPresented: $playerState.showDanmakuSearch,
                        videoTitle: playerState.currentVideoTitle,
                        currentEpisodeIndex: playerState.currentEpisodeIndex,
                        onLoadDanmaku: { episodeId in
                            playerState.manualLoadDanmaku(episodeId: episodeId)
                        }
                    )
                    .environmentObject(settings)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(42)
            }

            // 长按倍速设置面板（居中弹窗，竖屏/横屏均可用）
            if playerState.showLongPressSpeedSettings {
                GeometryReader { geo in
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                playerState.showLongPressSpeedSettings = false
                            }
                        }
                    LongPressSpeedSettingsPanel(
                        isPresented: $playerState.showLongPressSpeedSettings,
                        longPressSpeed: $playerState.longPressSpeed
                    )
                    .environmentObject(settings)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(42)
            }

            // 长按倍速提示浮层（长按屏幕期间显示，顶部小胶囊）
            if playerState.showLongPressSpeedHint {
                VStack {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                        Text(String(format: "%@x", playerState.longPressSpeed == floor(playerState.longPressSpeed) ? String(format: "%.0f", playerState.longPressSpeed) : String(format: "%.1f", playerState.longPressSpeed)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .padding(.top, 50)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    Spacer()
                }
                .zIndex(43)
            }

            // 字幕设置面板
            if playerState.showSubtitleSettings {
                GeometryReader { geo in
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                playerState.showSubtitleSettings = false
                            }
                        }
                    SubtitleSettingsPanel(
                        isPresented: $playerState.showSubtitleSettings,
                        showSubtitle: $playerState.showSubtitle,
                        subtitleFontSize: $playerState.subtitleFontSize,
                        subtitleColorIndex: $playerState.subtitleColorIndex,
                        subtitleFileName: playerState.subtitleFileName,
                        onLoadFile: { url in
                            playerState.loadSubtitle(url: url)
                        },
                        onClear: {
                            playerState.clearSubtitle()
                        }
                    )
                    .environmentObject(settings)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(42)
            }

            // 字幕浮层（播放期间显示，底部居中）
            if playerState.showSubtitle, let text = playerState.currentSubtitleText {
                VStack {
                    Spacer()
                    Text(text)
                        .font(.system(size: playerState.subtitleFontSize, weight: .medium))
                        .foregroundColor(playerState.subtitleColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 40)
                        .padding(.bottom, playerState.isPortrait ? 100 : 80)
                        .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
                }
                .allowsHitTesting(false)
                .zIndex(14)
            }
        }
        .onAppear {
            resetAutoHideTimer()
        }
        .onChange(of: playerState.showControls) { newValue in
            if newValue {
                resetAutoHideTimer()
            } else {
                autoHideTask?.cancel()
            }
        }
        .onChange(of: playerState.isPlaying) { newValue in
            // 播放时禁用自动锁屏，暂停/停止时恢复
            // 统一在此处管理 idle timer，覆盖所有 isPlaying 变更路径
            // （初始加载、自动恢复、前台返回、手动切换、引擎切换等）
            UIApplication.shared.isIdleTimerDisabled = newValue
            if newValue && playerState.showControls {
                resetAutoHideTimer()
            }
        }
        .onChange(of: playerState.loadError) { error in
            if error != nil {
                autoHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.showControls = false
                }
            } else if playerState.showControls {
                resetAutoHideTimer()
            }
        }
        .onChange(of: playerState.showSettings) { handleControlPopupChange($0) }
        .onChange(of: playerState.showEpisodePicker) { handleControlPopupChange($0) }
        .onChange(of: playerState.showQualityPicker) { handleControlPopupChange($0) }
        .onChange(of: playerState.showDanmakuSettings) { handleControlPopupChange($0) }
        .onChange(of: playerState.showEnginePicker) { handleControlPopupChange($0) }
        .onChange(of: playerState.showDanmakuInput) { handleControlPopupChange($0) }
        .onChange(of: playerState.showToolsMenu) { handleControlPopupChange($0) }
        .onChange(of: playerState.showSkipSettings) { handleControlPopupChange($0) }
        .onChange(of: playerState.showDanmakuSearch) { handleControlPopupChange($0) }
        .onChange(of: playerState.showLongPressSpeedSettings) { handleControlPopupChange($0) }
        .onChange(of: playerState.showSubtitleSettings) { handleControlPopupChange($0) }
        .onChange(of: playerState.isSeeking) { isSeeking in
            if isSeeking {
                autoHideTask?.cancel()
            } else {
                resetAutoHideTimer()
            }
        }
        .onChange(of: playerState.isOrientationLocked) { isLocked in
            if isLocked {
                autoHideTask?.cancel()
                lockButtonVisible = true
                resetLockButtonAutoHide()
            } else {
                lockButtonAutoHideTask?.cancel()
                lockButtonVisible = false
                resetAutoHideTimer()
            }
        }
        .onDisappear {
            autoHideTask?.cancel()
            lockButtonAutoHideTask?.cancel()
        }
    }
}

// MARK: - 错误视图
struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isRetryable: Bool {
        let lower = error.lowercased()
        return !lower.contains("已失效") && !lower.contains("已被和谐") && !lower.contains("禁止播放") && !lower.contains("转存返回占位")
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .foregroundColor(.white)
                    .font(.title2)
                Text(error)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 20) {
                    if isRetryable {
                        Button(action: onRetry) {
                            Text("重试")
                                .foregroundColor(.white)
                                .padding(.horizontal, 40)
                                .padding(.vertical, 12)
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                    }

                    Button(action: { dismiss() }) {
                        Text("返回")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.gray)
                            .cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82).ignoresSafeArea())
        .contentShape(Rectangle())
    }
}

// MARK: - 错误视图（简洁版，日志在绿色浮层里看）
struct ErrorViewWithLogs: View {
    let error: String
    let logs: [String]
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isRetryable: Bool {
        let lower = error.lowercased()
        return !lower.contains("已失效") && !lower.contains("已被和谐") && !lower.contains("禁止播放") && !lower.contains("转存返回占位")
    }

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .foregroundColor(.white)
                    .font(.title2)
                Text(error)
                    .foregroundColor(.white.opacity(0.9))
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                HStack(spacing: 20) {
                    if isRetryable {
                        Button(action: onRetry) {
                            Text("重试").foregroundColor(.white)
                                .padding(.horizontal, 40).padding(.vertical, 12)
                                .background(Color.blue).cornerRadius(8)
                        }
                    }
                    Button(action: { dismiss() }) {
                        Text("返回").foregroundColor(.white)
                            .padding(.horizontal, 40).padding(.vertical, 12)
                            .background(Color.gray).cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.82).ignoresSafeArea())
        .contentShape(Rectangle())
    }
}

// MARK: - 播放器控制视图
// MARK: - 播放器顶部栏
struct PlayerTopBarView: View {
    let isPortrait: Bool
    let videoName: String
    @ObservedObject var playerState: PlayerState
    var onTogglePiP: () -> Void
    var onDismiss: () -> Void
    var onTogglePortrait: (() -> Void)?

    // 时间+电量
    @State private var currentDate = Date()
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel
    @State private var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState
    private let timeTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // 名称滚动
    @State private var nameScrollOffset: CGFloat = 0
    @State private var nameNeedsScroll = false
    @State private var nameScrollTask: Task<Void, Never>?

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: currentDate)
    }

    private var batteryString: String {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        return "\(Int(level * 100))%"
    }

    var body: some View {
        if isPortrait {
            HStack {
                Button(action: { onDismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                // 旋转按钮：强制切换到横屏播放器（不受系统屏幕旋转锁定限制）
                Button(action: {
                    OrientationHelper.lockOrientation(.landscape)
                    // 立即更新 UI 状态，不等 orientationDidChangeNotification 回调，
                    // 避免屏幕物理旋转延迟导致横屏功能按键延迟出现
                    playerState.isPortrait = false
                    playerState.showEpisodePicker = false
                    playerState.showSettings = false
                    playerState.showQualityPicker = false
                    playerState.showEnginePicker = false
                    playerState.showToolsMenu = false
                    playerState.showSkipSettings = false
                    playerState.showDanmakuSearch = false
                    // 短暂延迟后恢复允许所有方向，用户可自由旋转回竖屏
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        OrientationHelper.allowAllOrientations()
                    }
                }) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        } else {
            // 横屏状态：返回键 + 资源名称 + 居中时间电量 + 右侧功能按钮
            // 使用 ZStack 让时间电量真正居中，不受左右按钮宽度变化影响
            ZStack {
                // 左侧：返回键 + 资源名称
                HStack(spacing: 0) {
                    if !playerState.isOrientationLocked {
                        Button(action: { onDismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        // 资源名称（自动滚动长名称，固定宽度避免撑破布局）
                        VideoNameScrollingText(name: videoName, maxWidth: 120)
                            .frame(width: 120, alignment: .leading)
                    }
                    Spacer()
                }

                // 居中：时间 + 电量（用 Spacer 强制居中，不受左右按钮宽度变化影响）
                if !playerState.isOrientationLocked {
                    HStack(spacing: 0) {
                        Spacer()
                        HStack(spacing: 6) {
                            Text(timeString)
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))

                            HStack(spacing: 2) {
                                Image(systemName: batteryIcon)
                                    .font(.system(size: 11))
                                if isBatteryCharging {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                Text(batteryString)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(batteryColor)
                        }
                        Spacer()
                    }
                }

                // 右侧：小窗口/投屏/屏幕拉伸/三点菜单
                HStack(spacing: 0) {
                    Spacer()
                    if !playerState.isOrientationLocked {
                        HStack(spacing: 0) {
                        // 切换到竖屏
                        Button(action: {
                            onTogglePortrait?()
                        }) {
                            Image(systemName: "rotate.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        if playerState.pipEnabled {
                            Button(action: { onTogglePiP() }) {
                                Image(systemName: playerState.pipButtonSystemImage)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(playerState.isPiPSupported ? .white : .white.opacity(0.3))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(!playerState.isPiPSupported)
                        }

                        AirPlayViewV2()
                            .frame(width: 44, height: 44)

                        Button(action: {
                            playerState.cycleVideoGravity()
                        }) {
                            Image(systemName: playerState.videoGravity.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: {
                            playerState.showSkipSettings = false
                            playerState.showToolsMenu.toggle()
                        }) {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor((playerState.showToolsMenu || playerState.showSkipSettings) ? Color(hex: "00BE06") : .white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onReceive(timeTimer) { _ in
                currentDate = Date()
                batteryLevel = UIDevice.current.batteryLevel
                batteryState = UIDevice.current.batteryState
            }
            .onAppear {
                UIDevice.current.isBatteryMonitoringEnabled = true
                batteryLevel = UIDevice.current.batteryLevel
                batteryState = UIDevice.current.batteryState
            }
        }
    }

    private var batteryIcon: String {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        if level >= 0.9 { return "battery.100" }
        if level >= 0.6 { return "battery.75" }
        if level >= 0.3 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        let level = batteryLevel < 0 ? 1.0 : batteryLevel
        if level <= 0.1 { return .red.opacity(0.8) }
        if level <= 0.2 { return .orange.opacity(0.8) }
        return .white.opacity(0.7)
    }

    private var isBatteryCharging: Bool {
        batteryState == .charging || batteryState == .full
    }
}

// MARK: - 视频名称自动滚动组件
struct VideoNameScrollingText: View {
    let name: String
    let maxWidth: CGFloat
    @State private var animate = false

    init(name: String, maxWidth: CGFloat = 120) {
        self.name = name
        self.maxWidth = maxWidth
    }

    var body: some View {
        let font = UIFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = (name as NSString).size(withAttributes: [.font: font]).width
        let needsScroll = textWidth > maxWidth

        if needsScroll {
            ZStack(alignment: .leading) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: animate ? -(textWidth + 24) : maxWidth)
            }
            .frame(width: maxWidth, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .animation(
                .linear(duration: max(4.0, textWidth / 30.0))
                    .delay(2)
                    .repeatForever(autoreverses: false),
                value: animate
            )
            .onAppear { animate = true }
            .padding(.leading, 8)
        } else {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.leading, 8)
        }
    }
}

// MARK: - 时间格式化（全局）
private func formatTime(_ time: Double) -> String {
    let hours = Int(time) / 3600
    let minutes = (Int(time) % 3600) / 60
    let seconds = Int(time) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 播放器进度条
struct PlayerProgressBar: View {
    let isPortrait: Bool
    @ObservedObject var playerState: PlayerState

    var body: some View {
        HStack(spacing: 10) {
            Text(formatTime(playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime))
                .font(.system(size: isPortrait ? 10 : 12, weight: .medium))
                .foregroundColor(.white)

            GeometryReader { geometry in
                let displayTime = playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime
                let progress = playerState.duration > 0 ? max(0, min(displayTime / playerState.duration, 1)) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.3))
                        .frame(height: isPortrait ? 3 : 4)

                    if playerState.duration > 0 {
                        ForEach(Array(playerState.baiduCachedTimeRanges.enumerated()), id: \.offset) { _, range in
                            let start = max(0, min(range.start / playerState.duration, 1))
                            let end = max(start, min(range.end / playerState.duration, 1))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "00BEFF").opacity(0.28))
                                .frame(width: CGFloat(end - start) * geometry.size.width, height: isPortrait ? 3 : 4)
                                .offset(x: CGFloat(start) * geometry.size.width)
                        }
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: "00BEFF"))
                            .frame(width: CGFloat(progress) * geometry.size.width, height: isPortrait ? 3 : 4)
                        Circle()
                            .fill(Color(hex: "00BEFF"))
                            .frame(width: isPortrait ? 10 : 14, height: isPortrait ? 10 : 14)
                            .offset(x: max(0, min(CGFloat(progress) * geometry.size.width - (isPortrait ? 5 : 7), geometry.size.width - (isPortrait ? 10 : 14))))
                    }
                }
                .contentShape(Rectangle())
                // 修复: minimumDistance 从 0 改为 5，避免进度条的 DragGesture 在主线程繁忙时
                // 抢占同层级 Button 的 tap 事件（minimumDistance:0 会将任何触摸都识别为拖拽开始）。
                // 5pt 的最小拖拽距离不影响进度条拖拽体验，但给 SwiftUI 足够的判定空间区分 tap 和 drag。
                .highPriorityGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            guard playerState.duration > 0 else { return }
                            let x = max(0, min(value.location.x, geometry.size.width))
                            let target = Double(x / geometry.size.width) * playerState.duration
                            playerState.isSeeking = true
                            playerState.seekPreviewTime = target
                        }
                        .onEnded { value in
                            guard playerState.duration > 0 else { return }
                            let x = max(0, min(value.location.x, geometry.size.width))
                            let target = Double(x / geometry.size.width) * playerState.duration
                            playerState.seek(to: target)
                        }
                )
                // 修复: 补充 onTapGesture 处理点击进度条跳转（原 minimumDistance:0 靠拖拽模拟点击）
                .onTapGesture { location in
                    guard playerState.duration > 0 else { return }
                    let x = max(0, min(location.x, geometry.size.width))
                    let target = Double(x / geometry.size.width) * playerState.duration
                    playerState.seek(to: target)
                }
            }
            .frame(height: isPortrait ? 16 : 20)

            Text(formatTime(playerState.duration))
                .font(.system(size: isPortrait ? 10 : 12, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, isPortrait ? 12 : 16)
        .padding(.vertical, isPortrait ? 6 : 8)
    }
}

// MARK: - 竖屏底部按钮栏
struct PortraitBottomBar: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState

    /// 格式化倍速显示文字（如 "1.0x"）
    private var speedDisplayText: String {
        let s = playerState.playbackSpeed
        let formatted = String(format: "%.2f", s)
        let trimmed = formatted.hasSuffix(".00") ? String(formatted.dropLast(3)) :
                       formatted.hasSuffix("0") ? String(formatted.dropLast(1)) : formatted
        return trimmed + "x"
    }

    /// 当前清晰度显示文字
    private var qualityDisplayText: String {
        let isBaidu = playerState.episodeItems.isEmpty && !playerState.baiduFileList.isEmpty
        if isBaidu {
            return "原画"
        } else {
            let qualities = ["标清", "高清", "蓝光"]
            return qualities.indices.contains(playerState.selectedQuality) ? qualities[playerState.selectedQuality] : "高清"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧功能区 ===

            // 1. 暂停/播放按钮 - 两条竖线风格
            Button(action: { playerState.togglePlayback(player: player) }) {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor((player == nil && playerState.compatibilityURL == nil) ? .gray : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(player == nil && playerState.compatibilityURL == nil)
            .buttonStyle(PlainButtonStyle())

            // 2. 下一集按钮 - 左三角箭头风格
            Button(action: { playerState.playNextEpisode() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(playerState.hasNextEpisode ? .white : .gray)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!playerState.hasNextEpisode)
            .buttonStyle(PlainButtonStyle())

            // 3. 弹幕开关按钮 - "弹"字图标，开启时右下角绿色对勾
            Button(action: { playerState.showDanmaku.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BE06") : .white.opacity(0.6))
                    if playerState.showDanmaku {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color(hex: "00BE06")))
                            .offset(x: 6, y: -2)
                    }
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 弹幕设置按钮 - "弹"字+齿轮小图标
            Button(action: { playerState.showDanmakuSettings = true }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(.white.opacity(0.6))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: 8, y: -2)
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            // === 右侧功能区 ===

            // 1. 倍速按钮 - 文字显示当前倍速值
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.showSettings.toggle()
                }
            }) {
                Text(speedDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.showSettings ? Color(hex: "00BE06") : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 2. 清晰度按钮 - 显示当前分辨率
            Button(action: { playerState.showQualityPicker.toggle() }) {
                Text(qualityDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 3. 选集按钮
            Button(action: { playerState.showEpisodePicker.toggle() }) {
                Text("选集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - 横屏底部按钮栏
struct LandscapeBottomBar: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState

    /// 格式化倍速显示文字（如 "1.0x"）
    private var speedDisplayText: String {
        let s = playerState.playbackSpeed
        let formatted = String(format: "%.2f", s)
        let trimmed = formatted.hasSuffix(".00") ? String(formatted.dropLast(3)) :
                       formatted.hasSuffix("0") ? String(formatted.dropLast(1)) : formatted
        return trimmed + "x"
    }

    /// 当前清晰度显示文字
    private var qualityDisplayText: String {
        let isBaidu = playerState.episodeItems.isEmpty && !playerState.baiduFileList.isEmpty
        if isBaidu {
            return "原画"
        } else {
            let qualities = ["标清", "高清", "蓝光"]
            return qualities.indices.contains(playerState.selectedQuality) ? qualities[playerState.selectedQuality] : "高清"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // === 左侧功能区 ===

            // 1. 暂停/播放按钮 - 两条竖线风格
            Button(action: { playerState.togglePlayback(player: player) }) {
                Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor((player == nil && playerState.compatibilityURL == nil) ? .gray : .white)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(player == nil && playerState.compatibilityURL == nil)

            // 2. 下一集按钮 - 左三角箭头风格
            Button(action: { playerState.playNextEpisode() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(playerState.hasNextEpisode ? .white : .gray)
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!playerState.hasNextEpisode)

            // 3. 弹幕开关按钮 - "弹"字图标，开启时右下角绿色对勾
            Button(action: { playerState.showDanmaku.toggle() }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BE06") : .white.opacity(0.6))
                    if playerState.showDanmaku {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(Color(hex: "00BE06")))
                            .offset(x: 6, y: -2)
                    }
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 弹幕设置按钮 - "弹"字+齿轮小图标
            Button(action: { playerState.showDanmakuSettings = true }) {
                ZStack(alignment: .bottomTrailing) {
                    Text("弹")
                        .font(Font.custom("PingFang SC", size: 15).weight(.bold))
                        .foregroundColor(.white.opacity(0.6))
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(x: 8, y: -2)
                }
                .frame(width: 48, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // === 中间输入框区域 ===
            Spacer(minLength: 12)

            // 弹幕输入框 - 深灰底色长条输入框，点击后弹出输入
            Button(action: { playerState.showDanmakuInput = true }) {
                HStack {
                    Text("请文明发送弹幕")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "00BE06"))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 36)
                .frame(maxWidth: 200)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .buttonStyle(PlainButtonStyle())

            Spacer(minLength: 12)

            // === 右侧功能区 ===

            // 1. 倍速按钮 - 文字显示当前倍速值
            Button(action: { playerState.showSettings.toggle() }) {
                Text(speedDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.showSettings ? Color(hex: "00BE06") : .white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 2. 清晰度按钮 - 显示当前分辨率文字
            Button(action: { playerState.showQualityPicker.toggle() }) {
                Text(qualityDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 3. 选集按钮
            Button(action: { playerState.showEpisodePicker.toggle() }) {
                Text("选集")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 4. 内核按钮
            Button(action: { playerState.showEnginePicker.toggle() }) {
                Text(playerState.currentEngineButtonTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(playerState.playbackEngineMode == .compatibility ? Color(hex: "00BEFF") : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 78, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
}

// MARK: - 播放器控制栏主视图
struct PlayerControlsView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    let showLockButton: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            PlayerTopBarView(
                isPortrait: playerState.isPortrait,
                videoName: playerState.episodeItems.isEmpty ? video.vodName : (playerState.currentEpisodeIndex < playerState.episodeItems.count ? playerState.episodeItems[playerState.currentEpisodeIndex].name : video.vodName),
                playerState: playerState,
                onTogglePiP: { togglePiP() },
                onDismiss: { dismiss() },
                onTogglePortrait: {
                    OrientationHelper.lockOrientation(.portrait)
                    playerState.isPortrait = true
                    playerState.showEpisodePicker = false
                    playerState.showSettings = false
                    playerState.showQualityPicker = false
                    playerState.showEnginePicker = false
                    playerState.showToolsMenu = false
                    playerState.showSkipSettings = false
                    playerState.showDanmakuSearch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        OrientationHelper.allowAllOrientations()
                    }
                }
            )

            Spacer()

            // 锁屏状态下隐藏底部控制栏和进度条
            if !playerState.isOrientationLocked {
                VStack(spacing: 0) {
                    PlayerProgressBar(isPortrait: playerState.isPortrait, playerState: playerState)

                    if playerState.isPortrait {
                        PortraitBottomBar(player: player, playerState: playerState)
                    } else {
                        LandscapeBottomBar(player: player, playerState: playerState)
                    }
                }
                .background(
                    Color.clear
                )
            }
        }
        // 锁定按钮覆盖层（固定在左侧屏幕边缘垂直居中，不受VStack布局影响）
        .overlay(
            Group {
                if !playerState.isPortrait && (!playerState.isOrientationLocked || showLockButton) {
                    GeometryReader { geometry in
                        Button(action: {
                            playerState.isOrientationLocked.toggle()
                            if playerState.isOrientationLocked {
                                OrientationHelper.lockOrientation(.landscape)
                            } else {
                                OrientationHelper.unlockOrientation()
                            }
                        }) {
                            Image(systemName: playerState.isOrientationLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .position(x: 16 + 22, y: geometry.size.height / 2)
                    }
                    .allowsHitTesting(true)
                }
            }
        )
        .onAppear {
            updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // 回到前台时重新检测方向（faceUp 时 UIDevice.orientation 不会变，但 interfaceOrientation 可能是竖屏）
            updateOrientation()
        }
    }

    private func togglePiP() {
        if playerState.isPiPActive {
            // 当前正在画中画：停止
            let engineName = playerState.compatibilityEngineName
            #if canImport(Libmpv)
            MPVPiPManager.shared.stopPiP()
            // 确保 MPV 帧捕获停止（即使 PiP 控制器未完全启动也要停止）
            NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: false)
            #endif
            #if canImport(swift_mdk)
            MDKPipManager.shared.stopPiP()
            // 通知 MDK 引擎停止帧捕获
            if engineName.contains("MDK") {
                NotificationCenter.default.post(name: .vboxMDKRequestStopPiP, object: nil)
            }
            #endif
            // 停止 IJK/VLC/AliPlayer 视图截图 PiP
            ViewCapturePiPManager.shared.stopPiP()
            MPVAVPlayerPiPProxy.shared.stopProxyPiP()
            // 停止 VideoToolbox 硬解码 PiP
            VTPiPManager.shared.stopPiP()
            PiPHelper.shared.stopPiP()
            playerState.isPiPActive = false
        } else {
            // 启动画中画并返回桌面
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()

            guard playerState.isPiPSupported else {
                playerState.log("[PlayerV2] 当前资源不支持画中画或后台播放")
                return
            }

            let engineName = playerState.compatibilityEngineName
            // 判断使用哪种 PiP 等待策略
            var useFrameBridgedPiP = false  // MDK/MPV/视图截图 帧桥接 PiP：需要等待启动
            var useAVPlayerPiP = false      // AVPlayer 代理画中画：需要等待代理 PiP delegate
            var useNativeAVPlayerPiP = false // 原生 AVPlayer 系统画中画：快速进入后台
            var useVTPiP = false            // VideoToolbox 硬解码 PiP：需要等待首帧解码
            var useAudioOnlyBackground = false

            if playerState.compatibilityURL != nil {
                // 兼容内核（网盘资源）：根据引擎类型选择 PiP 方案
                if playerState.currentPiPStrategy == .videoToolbox, let url = playerState.compatibilityURL {
                    // VideoToolbox 硬解码 PiP：独立下载 + 硬件解码 + SampleBuffer PiP
                    // 直接从原始源流下载解码，不依赖 AVPlayer
                    VTPiPManager.shared.startPiP(
                        url: url,
                        headers: playerState.compatibilityHeaders,
                        startTime: playerState.currentTime,
                        provider: "baidu"
                    )
                    useVTPiP = true
                    playerState.log("[PlayerV2] 启动 VideoToolbox 硬解码画中画，起始时间: \(playerState.currentTime)s")
                } else if playerState.currentPiPStrategy == .avPlayerProxy, let url = playerState.compatibilityURL {
                    MPVAVPlayerPiPProxy.shared.startProxyPiP(
                        url: url,
                        headers: playerState.compatibilityHeaders,
                        currentPosition: playerState.currentTime
                    )
                    useAVPlayerPiP = true
                    playerState.log("[PlayerV2] 启动 AVPlayer 代理/转封装画中画")
                } else if playerState.currentPiPStrategy == .backgroundAudioOnly {
                    useAudioOnlyBackground = true
                    playerState.log("[PlayerV2] 当前兼容内核不启动动态 PiP，改为后台声音模式")
                } else if engineName.contains("MDK") {
                    // MDK 依赖后台帧桥接，iOS 后台容易冻结小窗；默认改为后台声音，避免假 PiP 卡死。
                    useAudioOnlyBackground = true
                    playerState.log("[PlayerV2] MDK 兼容内核不默认启动动态 PiP，改为后台声音模式")
                } else if engineName.contains("MPV") {
                    // MPV：优先尝试 AVPlayer 代理 PiP（解决后台 GPU 冻结），
                    // 失败则回退到帧桥接 PiP（AVSampleBufferDisplayLayer）
                    #if canImport(Libmpv)
                    if let url = playerState.compatibilityURL {
                        // P1 修复：使用 AVPlayer 原生 PiP 绕过 iOS 后台 GPU 限制
                        MPVAVPlayerPiPProxy.shared.startProxyPiP(
                            url: url,
                            headers: playerState.compatibilityHeaders,
                            currentPosition: playerState.currentTime
                        )
                        useAVPlayerPiP = true
                        playerState.log("[PlayerV2] MPV 内核启动 AVPlayer 代理画中画")
                    } else {
                        // 无 URL 则回退到帧桥接 PiP
                        useFrameBridgedPiP = true
                        MPVPiPManager.shared.startPiP()
                        NotificationCenter.default.post(name: .vboxPiPStatusChanged, object: true)
                        playerState.log("[PlayerV2] MPV 内核启动帧桥接画中画")
                    }
                    #endif
                } else {
                    // IJK / VLC / AliPlayer 的截图 PiP 后台会停在最后一帧；默认改为后台声音，避免冻屏。
                    useAudioOnlyBackground = true
                    playerState.log("[PlayerV2] \(engineName) 不默认启动截图 PiP，改为后台声音模式")
                }
            } else if let avPlayer = player {
                // 原生 AVPlayer：使用系统画中画
                useNativeAVPlayerPiP = true
                PiPHelper.shared.setupPiP(for: avPlayer)
            }

            playerState.isPiPActive = useFrameBridgedPiP || useAVPlayerPiP || useNativeAVPlayerPiP || useVTPiP

            // 根据引擎类型选择不同的进入后台策略
            if useNativeAVPlayerPiP {
                // 普通切片/M3U8/系统内核的原生 AVPlayer PiP 不走 12 秒轮询。
                // PiPHelper 内部会立即 startPictureInPicture，并在 isPictureInPicturePossible 变 true 时重试。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
                }
            } else if useFrameBridgedPiP || useAVPlayerPiP || useVTPiP {
                // 帧桥接 PiP、AVPlayer 代理 PiP 和 VideoToolbox PiP：都等待 PiP 实际启动后再进入后台
                // 避免 PiP 还没起来 App 就退到后台，导致小窗不显示
                let deadline = Date().addingTimeInterval(12.0)
                waitForPiPAndGoBackground(deadline: deadline, checkAVPlayerProxy: useAVPlayerPiP)
            } else if useAudioOnlyBackground {
                if playerState.backgroundPlay {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
                    }
                } else {
                    playerState.log("[PlayerV2] 后台播放未开启，保持在应用内播放")
                }
            } else {
                // 兜底：固定延迟
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
                }
            }
        }
    }

    /// 轮询等待 PiP 启动后再进入后台，避免 PiP 窗口不出现
    private func waitForPiPAndGoBackground(deadline: Date, checkAVPlayerProxy: Bool = false) {
        // AVPlayer 代理 PiP 检测
        if checkAVPlayerProxy {
            let proxy = MPVAVPlayerPiPProxy.shared
            // isPipActive 由 PiP delegate 回调更新，主线程安全读取
            if proxy.isActive && proxy.isPipActive {
                playerState.log("[PlayerV2] AVPlayer 代理 PiP 已启动，进入后台")
                UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
                return
            }
        }

        #if canImport(swift_mdk)
        if MDKPipManager.shared.isPipActive {
            playerState.log("[PlayerV2] MDK PiP 已启动，进入后台")
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            return
        }
        #endif
        #if canImport(Libmpv)
        if MPVPiPManager.shared.isPipActive {
            playerState.log("[PlayerV2] MPV PiP 已启动，进入后台")
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            return
        }
        #endif
        if ViewCapturePiPManager.shared.isPipActive {
            playerState.log("[PlayerV2] 视图截图 PiP 已启动，进入后台")
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            return
        }

        // VideoToolbox 硬解码 PiP
        if VTPiPManager.shared.isPipActive {
            playerState.log("[PlayerV2] VideoToolbox 硬解码 PiP 已启动，进入后台")
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
            return
        }

        if Date() < deadline {
            // 帧桥接 PiP：强制推一帧（不依赖 display link / render callback）
            // 仅在 MPV 引擎且有活跃播放时才访问 MPV 单例，
            // 避免 MDK 引擎下首次访问触发单例初始化递归死锁
            // （AVPlayer 代理 PiP 不需要推帧，AVPlayer 自己会渲染）
            if !checkAVPlayerProxy {
                #if canImport(Libmpv)
                if playerState.compatibilityEngineName.contains("MPV") && LibmpvMoltenVKPlayerCore.shared.hasActivePlayback {
                    LibmpvMoltenVKPlayerCore.shared.forceCaptureFrame()
                }
                #endif
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.waitForPiPAndGoBackground(deadline: deadline, checkAVPlayerProxy: checkAVPlayerProxy)
            }
        } else {
            // 超时：PiP 启动失败，降级为后台声音模式并进入后台
            playerState.log("[PlayerV2] PiP 启动超时，降级为后台声音模式并进入后台")
            playerState.isPiPActive = false
            if checkAVPlayerProxy {
                MPVAVPlayerPiPProxy.shared.stopProxyPiP()
            }
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
    }

    /// 在 App 视图层级中查找当前播放器视图（兼容 AVPlayerLayer / OpenGL / Metal 等内核）
    private func findCurrentPlayerView() -> UIView? {
        guard let rootView = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .first(where: { $0.isKeyWindow })?.rootViewController?.view else { return nil }

        let candidates = ["Player", "Video", "GL", "Metal", "Render", "AliPlayer", "VLC", "IJK", "MPV", "MDK"]
        /// 播放器容器视图的 tag 标识（VLC/IJK 等使用普通 UIView 作为容器）
        let playerViewTag = 9527
        var result: UIView?

        func search(_ view: UIView) {
            if result != nil { return }
            // 优先通过 tag 标识匹配（适用于 VLC/IJK 等使用普通 UIView 的引擎）
            if view.tag == playerViewTag {
                result = view
                return
            }
            let clsName = String(describing: type(of: view))
            for keyword in candidates {
                if clsName.contains(keyword) {
                    result = view
                    return
                }
            }
            for sub in view.subviews {
                search(sub)
            }
        }

        search(rootView)
        return result
    }

    private func updateOrientation() {
        let newIsPortrait = currentInterfaceOrientation?.isPortrait ?? false
        if newIsPortrait != playerState.isPortrait {
            playerState.isPortrait = newIsPortrait
            // 方向变化时关闭所有弹窗，避免横竖屏弹窗互相干扰
            playerState.showEpisodePicker = false
            playerState.showSettings = false
            playerState.showQualityPicker = false
            playerState.showEnginePicker = false
            playerState.showToolsMenu = false
            playerState.showSkipSettings = false
            playerState.showDanmakuSearch = false
        }
    }

    /// 获取当前 UI 窗口方向（faceUp 时仍返回正确方向，不受物理设备姿态影响）
    private var currentInterfaceOrientation: UIInterfaceOrientation? {
        // 优先使用第一个 foreground active 场景
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            return scene.interfaceOrientation
        }
        // 回退：任意 window scene
        return (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first)?
            .interfaceOrientation
    }
}

// MARK: - 横屏选集弹窗（标题栏 + 排序按钮 + 网格）
struct LandscapeEpisodePickerOverlay: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: AppSettings

    private var panelBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.85)
    }

    var body: some View {
        GeometryReader { geo in
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("选集")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white)
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            playerState.episodesReversed.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: playerState.episodesReversed ? "arrow.up" : "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text(playerState.episodesReversed ? "倒序" : "正序")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(settings.usesFrostedSkin ? Color(uiColor: .tertiarySystemBackground) : Color.white.opacity(0.1))
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)

                Divider()
                    .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.08))

                EpisodePickerPanelV2(
                    playerState: playerState,
                    isPresented: $isPresented,
                    isPortrait: false,
                    isReversed: $playerState.episodesReversed
                )
                .environmentObject(settings)
            }
            .frame(width: min(geo.size.width * 0.5, 320), height: min(geo.size.height * 0.5, 320))
            .background(panelBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 - 40)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 竖屏选集弹窗（排序按钮在标题栏右侧，替代关闭按钮）
struct EpisodePickerPopupWrapper: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        PortraitPopupView(isPresented: $isPresented, title: "选集", content: {
            EpisodePickerPanelV2(
                playerState: playerState,
                isPresented: $isPresented,
                isPortrait: true,
                isReversed: $playerState.episodesReversed
            )
        }, trailing: {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.episodesReversed.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: playerState.episodesReversed ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(playerState.episodesReversed ? "倒序" : "正序")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(settings.usesFrostedSkin ? Color(uiColor: .tertiarySystemBackground) : Color.white.opacity(0.1))
                )
            }
            .buttonStyle(PlainButtonStyle())
        })
    }
}

// MARK: - 竖屏弹窗容器（河马剧场风格：半透明背景+居中面板，自适应皮肤）
struct PortraitPopupView<Content: View, Trailing: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    let trailingView: Trailing?
    @EnvironmentObject private var settings: AppSettings

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
        self.trailingView = trailing()
    }

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
        self.trailingView = nil
    }

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.85)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.75)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    // 半透明遮罩
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }

                    // 小尺寸居中面板（类似河马剧场风格）
                    VStack(spacing: 0) {
                        // 标题栏
                        HStack {
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .label) : .white)
                            Spacer()
                            if let trailing = trailingView {
                                trailing
                            } else {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(settings.usesFrostedSkin ? Color(uiColor: .secondaryLabel) : .white.opacity(0.7))
                                        .frame(width: 28, height: 28)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: min(geometry.size.width * 0.75, 300))
                    .frame(maxHeight: min(geometry.size.height * 0.5, 380))
                    .background(panelBackground)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer
    let videoGravity: PlayerState.VideoGravityMode

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity.avGravity
        // 将 playerLayer 引用保存到 PiPHelper，供画中画使用
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let playerLayer = controller.view.layer.sublayers?.first(where: { $0 is AVPlayerLayer }) as? AVPlayerLayer {
                PiPHelper.shared.setPlayerLayer(playerLayer)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        // 同步画面拉伸模式
        if uiViewController.videoGravity != videoGravity.avGravity {
            uiViewController.videoGravity = videoGravity.avGravity
        }
    }
}

struct CompatibilityUnavailableView: View {
    let engineName: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.85))
            Text("当前资源需要\(engineName)兼容内核")
                .foregroundColor(.white)
                .font(.headline)
            Text(message)
                .foregroundColor(.white.opacity(0.7))
                .font(.subheadline)
        }
    }
}

#if canImport(Libmpv)
// MARK: - Libmpv-MoltenVK 正式播放层 V2
struct LibmpvMoltenVKPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> Coordinator {
        Coordinator(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        // 修复: 先同步移除所有子视图，避免 UIKit 在 CA commit 延迟清理时
        // 触发 UISplitViewControllerPanelImpl → UINavigationController → UIViewController
        // 级联 dealloc 时访问已释放的子视图控制器（Use-After-Free）
        uiView.subviews.forEach { $0.removeFromSuperview() }
        uiView.layoutIfNeeded()
        coordinator.stop()
    }

    final class Coordinator {
        private let core = LibmpvMoltenVKPlayerCore.shared
        private var observers: [NSObjectProtocol] = []
        private weak var playerState: PlayerState?
        private var isStopped = false
        private var initTimeoutWorkItem: DispatchWorkItem?
        var currentURL: URL?

        private static let initTimeoutSeconds: TimeInterval = 15

        init(playerState: PlayerState) {
            self.playerState = playerState
            core.onLog = { [weak playerState] message in
                guard playerState?.compatibilityURL != nil else { return }
                playerState?.log("[MPV-MoltenVK] \(message)")
            }
            core.onStateChange = { [weak self, weak playerState] state in
                guard let self, let playerState else { return }
                // 修复: 增加 playbackEngineMode 双重检查，防止 AVPlayer 播放时 MPV 残留回调干扰状态
                guard playerState.compatibilityURL != nil, playerState.playbackEngineMode == .compatibility else { return }
                playerState.currentTime = state.currentTime
                MPVAVPlayerPiPProxy.shared.syncPosition(state.currentTime)
                if state.duration.isFinite, state.duration > 0 {
                    playerState.duration = state.duration
                }
                playerState.updateDanmaku(at: state.currentTime)
                playerState.savePlaybackProgress()
                playerState.reportBaiduCacheProgressIfNeeded()
                playerState.isLoading = state.isBuffering
                playerState.isPlaying = state.isPlaying

                // 跳过片头：MPV 首次播放且进度极小
                if playerState.skipIntroEnabled, playerState.skipIntroSeconds > 0,
                   !playerState.skipIntroTriggered, !playerState.isSwitchingEpisode,
                   state.currentTime < 2, state.duration > Double(playerState.skipIntroSeconds) {
                    playerState.skipIntroTriggered = true
                    let skip = Double(playerState.skipIntroSeconds)
                    playerState.log("[PlayerV2] ⏩ MPV 跳过片头 \(playerState.formatDuration(skip))")
                    self.core.seek(to: skip)
                }

                // 跳过片尾：接近结尾时自动播放下一集
                if playerState.skipOutroEnabled, playerState.skipOutroSeconds > 0,
                   !playerState.skipOutroTriggered, !playerState.isSwitchingEpisode,
                   state.duration > 0, state.currentTime > 0,
                   state.currentTime >= state.duration - Double(playerState.skipOutroSeconds) {
                    playerState.skipOutroTriggered = true
                    playerState.log("[PlayerV2] ⏩ MPV 跳过片尾 \(playerState.formatDuration(Double(playerState.skipOutroSeconds)))，自动播放下一集")
                    playerState.playNextEpisode()
                }

                // 播放结束：MPV eofReached 事件
                if state.isEnded, !playerState.isSwitchingEpisode {
                    playerState.isPlaying = false
                    playerState.log("[PlayerV2] MPV 播放结束")
                    playerState.playNextEpisodeIfAvailable()
                }

                if let error = state.errorMessage {
                    self.cancelInitTimeout()
                    playerState.failPlayback(error)
                }
                if !state.isBuffering && state.currentTime > 0 {
                    self.cancelInitTimeout()
                }
            }

            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPlay, object: nil, queue: .main) { [weak self] _ in
                self?.core.play()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPause, object: nil, queue: .main) { [weak self] _ in
                self?.core.pause()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSeek, object: nil, queue: .main) { [weak self] note in
                guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                self?.core.seek(to: seconds)
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSpeed, object: nil, queue: .main) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Double else { return }
                self?.core.setRate(speed)
            })

            // 注：不再监听 .vboxMPVStop 通知来主动 teardown MPV。
            // 旧方案在 selectPlaybackEngine 同步调用 teardown()，导致旧内核 GPU 上下文
            // 在新内核 attach() 前就被销毁，Metal/OpenGL ES 上下文竞态 → GPU driver crash。
            // 正确做法：延迟引擎名切换（见 selectPlaybackEngine），让 SwiftUI 分批处理
            // dismantle（旧内核）和 attach（新内核），避免并发 GPU 上下文冲突。
            //
            // .vboxMPVStop 仍由 initPlayer() 和 failPlayback() 使用（用于 AVPlayer 模式时
            // 清理残留的 MPV 实例），MPV Coordinator 的 teardown 仍由 dismantleUIView 自然触发。

            // PiP 帧捕获控制：监听 PiP 状态变化通知，控制 Metal 帧捕获
            observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPStatusChanged, object: nil, queue: .main) { [weak self] note in
                guard let isActive = note.object as? Bool else { return }
                if isActive {
                    self?.core.startPiPCapture()
                } else {
                    self?.core.stopPiPCapture()
                }
            })
            // PiP 跳转控制
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPiPSkip, object: nil, queue: .main) { [weak self] note in
                guard let skipInterval = note.object as? CMTime else { return }
                let seconds = CMTimeGetSeconds(skipInterval)
                let current = self?.core.state.currentTime ?? 0
                self?.core.seek(to: current + seconds)
            })
            // PiP 播放/暂停控制
            observers.append(NotificationCenter.default.addObserver(forName: .vboxPiPTogglePlayPause, object: nil, queue: .main) { [weak self] note in
                guard let playing = note.object as? Bool else { return }
                if playing {
                    self?.core.play()
                } else {
                    self?.core.pause()
                }
            })
        }

        deinit {
            stop()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            guard !isStopped else { return }
            // 是否为首次 attach（进入播放页）。切集时 currentURL 已有值，走 updateUIView → attach。
            let isFirstAttach = (currentURL == nil)
            currentURL = url
            core.attach(to: view)
            // 同步当前画面拉伸模式：setupMPV 完成后 mpv 句柄才可用，
            // 此时 setMPVProperty 才能真正生效（configure() 中的调用因 mpv==nil 被跳过）
            if let mode = playerState?.videoGravity {
                core.setMPVProperty("keepaspect", mode == .resize ? "no" : "yes")
                core.setMPVProperty("panscan", mode == .aspectFill ? "1.0" : "0")
            }
            core.load(url: url, headers: headers, profile: inferredProfile(for: url))
            core.setRate(playerState?.playbackSpeed ?? 1.0)
            core.play()
            // ★ 修复切集跳进度：只在「首次进入播放页」时恢复上次进度。
            // 切集（currentURL 已有值）时 currentTime 残留上一集进度，不应在此 seek。
            if isFirstAttach, let resume = playerState?.currentTime, resume > 10 {
                core.seek(to: resume)
                playerState?.log("[Progress] MPV 自动跳转到上次进度：\(Int(resume))s")
            }
            playerState?.isLoading = true
            playerState?.loadingMessage = "正在启动 MPV-MoltenVK..."
            startInitTimeout()
        }

        private func startInitTimeout() {
            cancelInitTimeout()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped else { return }
                self.playerState?.log("[MPV-MoltenVK] 初始化超时(\(Int(Self.initTimeoutSeconds))s)，停止等待")
                self.playerState?.failPlayback("MPV-MoltenVK 初始化超时，请尝试切换到 VLC 或系统内核")
                self.core.stop()
            }
            initTimeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.initTimeoutSeconds, execute: workItem)
        }

        private func cancelInitTimeout() {
            initTimeoutWorkItem?.cancel()
            initTimeoutWorkItem = nil
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            cancelInitTimeout()
            core.stopPiPCapture()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            core.onLog = nil
            core.onStateChange = nil

            // 如果还在系统画中画，不要销毁 mpv，让播放继续
            if !(playerState?.isPiPActive ?? false) {
                core.stop()
                core.teardown()
            }

            currentURL = nil
            playerState = nil
        }

        private func inferredProfile(for url: URL) -> LibmpvMoltenVKPlayerCore.PlaybackProfile {
            let text = url.absoluteString.lowercased()
            let ext = url.pathExtension.lowercased()
            if text.contains("baidu-stream") || text.contains("quark-stream") { return .httpStream }
            if ext == "mkv" || text.contains("mkv") { return .mkvLarge }
            if ext == "m3u8" { return .hlsFast }
            if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
            return .generic
        }
    }
}
#endif

#if canImport(MobileVLCKit)
// MARK: - VLC 兼容播放内核封装 V2
struct VLCPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> VLCPlayerCoordinatorV2 {
        VLCPlayerCoordinatorV2(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.tag = 9527  // VLC 播放器视图标识，用于 findCurrentPlayerView 查找
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: VLCPlayerCoordinatorV2) {
        coordinator.stop()
    }

    final class VLCPlayerCoordinatorV2 {
        private let mediaPlayer = VLCMediaPlayer()
        private var observers: [NSObjectProtocol] = []
        private var progressTimer: Timer?
        private weak var playerState: PlayerState?
        private var didFinish = false
        private var drawableView: UIView?
        var currentURL: URL?
        /// 上次检测到的视频尺寸（用于检测尺寸变化后重新应用 aspectFill）
        private var lastVideoSize: CGSize = .zero

        init(playerState: PlayerState) {
            self.playerState = playerState
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPlay, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.play()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPause, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.pause()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSeek, object: nil, queue: .main) { [weak self] note in
                    guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                    self?.seek(to: seconds)
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSpeed, object: nil, queue: .main) { [weak self] note in
                    guard let speed = note.userInfo?["speed"] as? Double else { return }
                    self?.mediaPlayer.rate = Float(speed)
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVideoGravityChanged, object: nil, queue: .main) { [weak self] note in
                    guard let mode = note.userInfo?["mode"] as? PlayerState.VideoGravityMode else { return }
                    self?.applyVideoGravity(mode)
                }
            )
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            progressTimer?.invalidate()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            currentURL = url
            drawableView = view
            mediaPlayer.drawable = view
            // 初始化时应用当前拉伸模式
            if let mode = playerState?.videoGravity {
                applyVideoGravity(mode)
            }
            let media = VLCMedia(url: url)
            var options: [AnyHashable: Any] = [:]
            // 增加网络缓存，减少夸克/百度直链播放时的卡顿（默认300ms太小）
            options["network-caching"] = 20000
            options["file-caching"] = 20000
            if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                options["http-user-agent"] = ua
            }
            if let referer = headers.first(where: { $0.key.lowercased() == "referer" })?.value {
                options["http-referrer"] = referer
            }
            if !options.isEmpty {
                media.addOptions(options)
            }
            mediaPlayer.media = media
            mediaPlayer.play()
            mediaPlayer.rate = Float(playerState?.playbackSpeed ?? 1.0)
            didFinish = false
            startProgressTimer()
        }

        private func applyVideoGravity(_ mode: PlayerState.VideoGravityMode) {
            guard let view = drawableView else { return }
            view.clipsToBounds = true
            // VLC 内部使用 OpenGL ES 直接渲染到 layer，UIView.contentMode 无效。
            // 必须通过 VLCMediaPlayer 的 videoAspectRatio 和 scaleFactor 属性控制画面比例。
            switch mode {
            case .aspectFit:
                // 适应：保持宽高比，留黑边（VLC 默认行为）
                mediaPlayer.videoAspectRatio = nil
                mediaPlayer.scaleFactor = 0
            case .aspectFill:
                // 填充：保持宽高比但放大裁剪
                // VLC 的 scaleFactor 是在 aspect-fit 基础上的缩放系数
                // 需要根据视频实际尺寸和视图尺寸计算正确的缩放比
                mediaPlayer.videoAspectRatio = nil
                let viewW = view.bounds.width
                let viewH = max(view.bounds.height, 1)
                let viewAspect = viewW / viewH
                // 尝试从 VLC 获取视频实际尺寸（VLCVideoSize 是 C 结构体，非 NSValue）
                let vlcSize = mediaPlayer.videoSize
                let videoW = CGFloat(vlcSize.width)
                let videoH = CGFloat(vlcSize.height)
                if videoW > 0 && videoH > 0 {
                    let videoAspect = videoW / videoH
                    // 计算填充所需的缩放系数：取宽高比差异的较大值
                    if videoAspect > viewAspect {
                        // 视频比视图宽：需要放大以填满高度，裁剪两侧
                        mediaPlayer.scaleFactor = Float(videoAspect / viewAspect)
                    } else {
                        // 视频比视图高：需要放大以填满宽度，裁剪上下
                        mediaPlayer.scaleFactor = Float(viewAspect / videoAspect)
                    }
                } else {
                    // 视频尺寸未知（尚未开始播放），用视图宽高比做合理估算
                    mediaPlayer.scaleFactor = Float(viewAspect > 1 ? viewAspect : 1.0 / viewAspect)
                }
            case .resize:
                // 拉伸：强制视频适配视图宽高比（不保持宽高比）
                // VLC videoAspectRatio 接受 UnsafeMutablePointer<CChar>，需要手动管理内存
                let w = Int(view.bounds.width)
                let h = max(Int(view.bounds.height), 1)
                let ratioStr = "\(w):\(h)"
                ratioStr.withCString { cStr in
                    // VLC 内部会 strdup，这里传一份可变副本
                    let mutable = strdup(cStr)
                    mediaPlayer.videoAspectRatio = mutable
                }
                mediaPlayer.scaleFactor = 0
            }
            print("[VLC] 屏幕拉伸模式切换为：\(mode.rawValue)")
        }

        func stop() {
            progressTimer?.invalidate()
            progressTimer = nil
            mediaPlayer.stop()
            mediaPlayer.drawable = nil
            drawableView = nil
            currentURL = nil
        }

        private func seek(to seconds: Double) {
            let duration = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
            guard duration.isFinite, duration > 0 else { return }
            mediaPlayer.position = Float(max(0, min(seconds / duration, 1)))
        }

        private func startProgressTimer() {
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard let playerState = self.playerState else { return }
                let current = Double(self.mediaPlayer.time.intValue) / 1000.0
                let total = Double(self.mediaPlayer.media?.length.intValue ?? 0) / 1000.0
                guard current.isFinite, total.isFinite, total > 0 else { return }

                playerState.currentTime = max(0, current)
                playerState.duration = max(0, total)
                playerState.reportBaiduCacheProgressIfNeeded()

                // 跳过片头：VLC 首次播放且进度极小
                if playerState.skipIntroEnabled, playerState.skipIntroSeconds > 0,
                   !playerState.skipIntroTriggered, !playerState.isSwitchingEpisode,
                   current < 2, total > Double(playerState.skipIntroSeconds) {
                    playerState.skipIntroTriggered = true
                    let skip = Double(playerState.skipIntroSeconds)
                    playerState.log("[PlayerV2] ⏩ VLC 跳过片头 \(playerState.formatDuration(skip))")
                    self.seek(to: skip)
                }

                // 跳过片尾：接近结尾时自动播放下一集
                if playerState.skipOutroEnabled, playerState.skipOutroSeconds > 0,
                   !playerState.skipOutroTriggered, !playerState.isSwitchingEpisode,
                   current >= max(0, total - Double(playerState.skipOutroSeconds)) {
                    playerState.skipOutroTriggered = true
                    playerState.log("[PlayerV2] ⏩ VLC 跳过片尾 \(playerState.formatDuration(Double(playerState.skipOutroSeconds)))，自动播放下一集")
                    playerState.playNextEpisode()
                }

                // 播放结束：自然播放到末尾
                if !self.didFinish, current >= max(0, total - 0.8), total > 1 {
                    self.didFinish = true
                    playerState.isPlaying = false
                    playerState.currentTime = total
                    playerState.log("[PlayerV2] VLC 播放结束")
                    playerState.playNextEpisodeIfAvailable()
                }

                // 检测视频尺寸变化，重新应用 aspectFill（首帧到达后 videoSize 才有值）
                let vlcVideoSize = self.mediaPlayer.videoSize
                let currentSize = CGSize(width: CGFloat(vlcVideoSize.width), height: CGFloat(vlcVideoSize.height))
                if currentSize.width > 0 && currentSize.height > 0 && currentSize != self.lastVideoSize {
                    self.lastVideoSize = currentSize
                    if playerState.videoGravity == .aspectFill {
                        self.applyVideoGravity(.aspectFill)
                    }
                }
            }
        }
    }
}
#endif

// MARK: - 弹幕设置视图
struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    @Binding var area: Double
    @Binding var speed: Double
    @Binding var colorMode: Int

    @Environment(\.dismiss) private var dismiss

    private let areaLabels = ["25%", "50%", "75%", "100%"]
    private let areaValues: [Double] = [0.25, 0.5, 0.75, 1.0]
    private let speedLabels = ["0.5x 慢", "0.75x", "1.0x 正常", "1.5x", "2.0x 快"]
    private let speedValues: [Double] = [0.5, 0.75, 1.0, 1.5, 2.0]
    private let colorLabels = ["原始", "白色", "黄色", "绿色", "蓝色", "红色", "粉色", "随机"]
    private let colorValues: [Int] = [0, 1, 2, 3, 4, 5, 6, 7]

    var body: some View {
        NavigationView {
            List {
                Section("弹幕开关") {
                    Toggle("开启弹幕", isOn: $showDanmaku)
                }

                Section("弹幕透明度") {
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                }

                Section("弹幕字体大小") {
                    Slider(value: $fontSize, in: 12...24, step: 2)
                }

                Section("弹幕显示区域") {
                    Picker("显示区域", selection: $area) {
                        ForEach(Array(areaValues.enumerated()), id: \.offset) { idx, val in
                            Text(areaLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("弹幕显示速度") {
                    Picker("显示速度", selection: $speed) {
                        ForEach(Array(speedValues.enumerated()), id: \.offset) { idx, val in
                            Text(speedLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("弹幕颜色") {
                    Picker("颜色", selection: $colorMode) {
                        ForEach(Array(colorValues.enumerated()), id: \.offset) { idx, val in
                            Text(colorLabels[idx]).tag(val)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("弹幕设置")
        }
    }
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层

// MARK: - AirPlay 视图

// MARK: - 播放设置视图
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button("\(s)x") {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
        }
    }
}

// MARK: - 选集选择视图
struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<21, id: \.self) { ep in
                    Button("第\(ep)集") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("选集")
        }
    }
}

// MARK: - 清晰度选择视图
struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(0..<3, id: \.self) { index in
                    Button(["标清", "高清", "蓝光"][index]) {
                        selectedQuality = index
                        onQualityChange(index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("清晰度")
        }
    }
}

// MARK: - 小巧居中弹窗容器（用于选集/倍数）
struct SmallPopupView<Content: View>: View {
    @Binding var isPresented: Bool
    let content: Content

    init(isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }

                    content
                        .frame(width: min(geometry.size.width * 0.5, 300), height: min(geometry.size.height * 0.55, 420))
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isPresented)
        }
    }
}

// MARK: - 侧边栏弹窗容器（用于其他设置）
struct SidePanelView<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content

    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isPresented = false
                            }
                        }

                    HStack {
                        Spacer()

                        VStack(spacing: 0) {
                            HStack {
                                Text(title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)

                                Spacer()

                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.9))

                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(hex: "1A1A1A"))
                        }
                        .frame(width: geometry.size.width * 0.45)
                        .background(Color(hex: "1A1A1A"))
                        .cornerRadius(12, corners: [.topLeft, .bottomLeft])
                        .transition(.move(edge: .trailing))
                    }
                    .ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPresented)
        }
    }
}

// MARK: - 播放设置面板 (竖屏：从按钮上方弹出的紧凑列表)
struct PlayerSettingsPanelV2: View {
    @Binding var isPresented: Bool
    @Binding var speed: Double
    var isPortrait: Bool = true
    var onSpeedChange: (Double) -> Void
    @EnvironmentObject private var settings: AppSettings

    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    /// 自适应皮肤的文字颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .label)
        }
        return .white.opacity(0.85)
    }

    private var textSecondary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondaryLabel)
        }
        return .white.opacity(0.5)
    }

    var body: some View {
        if isPortrait {
            // 竖屏：垂直列表
            portraitLayout
        } else {
            // 横屏：水平一行排列
            landscapeLayout
        }
    }

    // MARK: - 竖屏布局（垂直列表）
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            ForEach(speeds, id: \.self) { s in
                Button(action: {
                    speed = s
                    onSpeedChange(s)
                    isPresented = false
                }) {
                    HStack {
                        let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                        Text(speedText + "x")
                            .font(.system(size: 14, weight: speed == s ? .semibold : .regular))
                            .foregroundColor(speed == s ? Color(hex: "2196F3") : textPrimary)
                        Spacer()
                        if speed == s {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "2196F3"))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        speed == s ? Color(hex: "2196F3").opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if s != speeds.last {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, 16)
                }
            }
        }
        .background(panelBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }

    // MARK: - 横屏布局（小竖条，同竖屏垂直列表但更紧凑）
    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            ForEach(speeds, id: \.self) { s in
                Button(action: {
                    speed = s
                    onSpeedChange(s)
                    isPresented = false
                }) {
                    HStack {
                        let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                        Text(speedText + "x")
                            .font(.system(size: 12, weight: speed == s ? .semibold : .regular))
                            .foregroundColor(speed == s ? Color(hex: "2196F3") : textPrimary)
                        Spacer()
                        if speed == s {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(hex: "2196F3"))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        speed == s ? Color(hex: "2196F3").opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if s != speeds.last {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, 10)
                }
            }
        }
        .frame(width: 90)
        .background(panelBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
    }
}

// MARK: - 长按倍速设置面板
struct LongPressSpeedSettingsPanel: View {
    @Binding var isPresented: Bool
    @Binding var longPressSpeed: Double
    @EnvironmentObject private var settings: AppSettings

    let speeds: [Double] = [1.5, 2.0, 2.5, 3.0]

    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    private var textPrimary: Color {
        settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.85)
    }

    private var textSecondary: Color {
        settings.usesFrostedSkin ? Color(uiColor: .secondaryLabel) : .white.opacity(0.5)
    }

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "2196F3"))
                Text("长按倍速设置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
            }

            // 说明文字
            Text("长按屏幕时以此倍速播放，松手后恢复原速")
                .font(.system(size: 12))
                .foregroundColor(textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 倍速选择网格
            HStack(spacing: 10) {
                ForEach(speeds, id: \.self) { s in
                    Button(action: {
                        longPressSpeed = s
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isPresented = false
                        }
                    }) {
                        let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.1f", s)
                        Text(speedText + "x")
                            .font(.system(size: 16, weight: longPressSpeed == s ? .bold : .medium))
                            .foregroundColor(longPressSpeed == s ? .white : textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(longPressSpeed == s ? Color(hex: "2196F3") : Color.white.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(longPressSpeed == s ? Color.clear : Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(panelBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 4)
    }
}

// MARK: - 选集面板 (侧边栏版本)

// MARK: - 清晰度面板 (侧边栏版本)
struct QualityPickerPanelV2: View {
    @Binding var selectedQuality: Int
    var isBaiduSourceMode: Bool = false
    var isPortrait: Bool = true
    var onQualityChange: (Int) -> Void
    @EnvironmentObject private var settings: AppSettings

    private var qualities: [String] {
        isBaiduSourceMode ? ["原画"] : ["标清", "高清", "蓝光"]
    }

    /// 自适应皮肤颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .label) }
        return .white.opacity(0.85)
    }
    private var selectedColor: Color { Color(hex: "00BEFF") }
    private var unselectedBg: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .tertiarySystemBackground) }
        return Color.white.opacity(0.15)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<qualities.count, id: \.self) { index in
                Button(action: {
                    selectedQuality = index
                    onQualityChange(index)
                }) {
                    HStack {
                        Text(qualities[index])
                            .font(.system(size: isPortrait ? 16 : 13, weight: selectedQuality == index ? .semibold : .regular))
                            .foregroundColor(selectedQuality == index ? selectedColor : textPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer()
                        if selectedQuality == index {
                            Image(systemName: "checkmark")
                                .font(.system(size: isPortrait ? 14 : 11, weight: .semibold))
                                .foregroundColor(selectedColor)
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 10)
                    .padding(.vertical, isPortrait ? 16 : 10)
                    .background(
                        selectedQuality == index ? selectedColor.opacity(0.15) : Color.clear
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if index != qualities.count - 1 {
                    Divider()
                        .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                        .padding(.leading, isPortrait ? 16 : 10)
                }
            }
        }
    }
}

// MARK: - 播放内核面板 (侧边栏版本)
struct EnginePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState
    var isPortrait: Bool = true
    @EnvironmentObject private var settings: AppSettings

    /// 自适应皮肤颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin { return Color(uiColor: .label) }
        return .white.opacity(0.85)
    }
    private var selectedColor: Color { Color(hex: "00BEFF") }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(PlayerState.PlaybackEnginePreference.allCases) { engine in
                    Button(action: {
                        playerState.selectPlaybackEngine(engine)
                    }) {
                        HStack {
                            Text(engine.rawValue)
                                .font(.system(size: isPortrait ? 16 : 13, weight: playerState.enginePreference == engine ? .semibold : .regular))
                                .foregroundColor(playerState.enginePreference == engine ? selectedColor : textPrimary)
                            Spacer()
                            // PiP 支持状态标注（仅竖屏显示，横屏弹窗宽度有限不展示）
                            if isPortrait {
                                if engine == .vlc {
                                    Text("无画中画")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                } else if engine == .mpv || engine == .ali {
                                    Text("画中画")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "00BEFF").opacity(0.7))
                                }
                            }
                            if playerState.enginePreference == engine {
                                Image(systemName: "checkmark")
                                    .font(.system(size: isPortrait ? 14 : 11, weight: .semibold))
                                    .foregroundColor(selectedColor)
                            }
                        }
                        .background(
                            playerState.enginePreference == engine ? selectedColor.opacity(0.15) : Color.clear
                        )
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .padding(.vertical, isPortrait ? 14 : 10)
                    }
                    .buttonStyle(PlainButtonStyle())

                    if engine != PlayerState.PlaybackEnginePreference.allCases.last {
                        Divider()
                            .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.1))
                            .padding(.horizontal, isPortrait ? 16 : 12)
                    }
                }
            }
        }
    }
}

// MARK: - 弹幕设置面板 (侧边栏版本)
struct DanmakuSettingsPanelV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    @Binding var area: Double
    @Binding var speed: Double
    @Binding var colorMode: Int
    var isPortrait: Bool = true
    @EnvironmentObject private var settings: AppSettings

    private let areaOptions: [(Double, String)] = [
        (0.25, "25%"),
        (0.5, "50%"),
        (0.75, "75%"),
        (1.0, "100%")
    ]
    private let speedOptions: [(Double, String)] = [
        (0.5, "0.5x"),
        (0.75, "0.75x"),
        (1.0, "1.0x"),
        (1.5, "1.5x"),
        (2.0, "2.0x")
    ]
    private let colorOptions: [(mode: Int, color: Int, label: String)] = [
        (0, 16777215, "原始"),
        (1, 16777215, "白色"),
        (2, 16776960, "黄色"),
        (3, 65280,    "绿色"),
        (4, 255,      "蓝色"),
        (5, 16711680, "红色"),
        (6, 16761035, "粉色"),
        (7, 0,        "随机")
    ]

    /// 自适应皮肤的面板背景色
    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    /// 自适应皮肤的文字颜色
    private var textPrimary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .label)
        }
        return .white.opacity(0.85)
    }

    private var textSecondary: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondaryLabel)
        }
        return .white.opacity(0.5)
    }

    /// 选中状态颜色
    private var selectedColor: Color {
        Color(hex: "00BEFF")
    }

    /// 未选中按钮背景
    private var unselectedBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .tertiarySystemBackground)
        }
        return Color.white.opacity(0.15)
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: isPortrait ? 24 : 16) {
                // 开启弹幕开关
                HStack {
                    Text("开启弹幕")
                        .font(.system(size: isPortrait ? 16 : 14))
                        .foregroundColor(textPrimary)

                    Spacer()

                    Toggle("弹幕", isOn: $showDanmaku)
                        .labelsHidden()
                        .tint(selectedColor)
                }
                .padding(.horizontal, isPortrait ? 16 : 12)
                .padding(.top, isPortrait ? 16 : 12)

                // 透明度滑块
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕透明度")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    Slider(value: $opacity, in: 0...1, step: 0.1)
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .tint(selectedColor)
                }

                // 字体大小滑块
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕字体大小")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text("\(Int(fontSize))px")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    Slider(value: $fontSize, in: 12...24, step: 1)
                        .padding(.horizontal, isPortrait ? 16 : 12)
                        .tint(selectedColor)
                }

                // 显示区域选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕显示区域")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text(areaOptions.first(where: { $0.0 == area })?.1 ?? "\(Int(area * 100))%")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    HStack(spacing: isPortrait ? 0 : 4) {
                        ForEach(areaOptions, id: \.0) { option in
                            Button {
                                area = option.0
                            } label: {
                                Text(option.1)
                                    .font(.system(size: isPortrait ? 13 : 11))
                                    .foregroundColor(area == option.0 ? .white : textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, isPortrait ? 8 : 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(area == option.0 ? selectedColor : unselectedBackground)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)
                }

                // 速度选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕显示速度")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                        Text(speedOptions.first(where: { $0.0 == speed })?.1 ?? "\(speed)x")
                            .font(.system(size: isPortrait ? 14 : 12))
                            .foregroundColor(textSecondary)
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    HStack(spacing: isPortrait ? 0 : 4) {
                        ForEach(speedOptions, id: \.0) { option in
                            Button {
                                speed = option.0
                            } label: {
                                Text(option.1)
                                    .font(.system(size: isPortrait ? 12 : 11))
                                    .foregroundColor(speed == option.0 ? .white : textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, isPortrait ? 8 : 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(speed == option.0 ? selectedColor : unselectedBackground)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)
                }

                // 颜色选项
                VStack(spacing: 6) {
                    HStack {
                        Text("弹幕颜色")
                            .font(.system(size: isPortrait ? 16 : 14))
                            .foregroundColor(textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, isPortrait ? 16 : 12)

                    // 颜色圆圈 - 横屏时改为2行或缩小
                    if isPortrait {
                        HStack(spacing: 10) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                colorButton(option: option)
                            }
                        }
                        .padding(.horizontal, 16)

                        HStack(spacing: 0) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                Button {
                                    colorMode = option.mode
                                } label: {
                                    Text(option.label)
                                        .font(.system(size: 11))
                                        .foregroundColor(colorMode == option.mode ? textPrimary : textSecondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        // 横屏：颜色选项改为紧凑布局
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(Array(colorOptions.enumerated()), id: \.offset) { _, option in
                                Button {
                                    colorMode = option.mode
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(option.mode == 7 ? AnyShapeStyle(LinearGradient(colors: [.red, .yellow, .green, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(hexRGB: option.color)))
                                            .frame(width: 16, height: 16)
                                        Text(option.label)
                                            .font(.system(size: 11))
                                            .foregroundColor(colorMode == option.mode ? textPrimary : textSecondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(colorMode == option.mode ? selectedColor.opacity(0.2) : unselectedBackground)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(colorMode == option.mode ? selectedColor : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }

                Spacer(minLength: 20)
            }
        }
    }

    @ViewBuilder
    private func colorButton(option: (mode: Int, color: Int, label: String)) -> some View {
        Button {
            colorMode = option.mode
        } label: {
            Circle()
                .fill(option.mode == 7 ? AnyShapeStyle(LinearGradient(colors: [.red, .yellow, .green, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color(hexRGB: option.color)))
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(colorMode == option.mode ? selectedColor : Color.white.opacity(0.3), lineWidth: colorMode == option.mode ? 3 : 1)
                )
                .overlay(
                    Group {
                        if colorMode == option.mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 搜索弹幕面板
struct DanmakuSearchPanel: View {
    @Binding var isPresented: Bool
    let videoTitle: String
    let currentEpisodeIndex: Int
    let onLoadDanmaku: (Int) -> Void
    @EnvironmentObject private var settings: AppSettings

    @State private var keyword: String = ""
    @State private var searchResults: [DanmakuSearchResult] = []
    @State private var selectedAnimeId: Int? = nil
    @State private var selectedEpisodeId: Int? = nil
    @State private var episodes: [DanmakuEpisodeInfo] = []
    @State private var isSearching = false
    @State private var isLoadingEpisodes = false
    @State private var hasSearched = false

    private var panelBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.95)
        }
        return Color.black.opacity(0.88)
    }

    private var textColor: Color {
        settings.usesFrostedSkin ? Color(uiColor: .label) : .white
    }

    private var subtitleColor: Color {
        textColor.opacity(0.6)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textColor)
                Text("搜索弹幕")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(textColor)
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.6))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(textColor.opacity(0.12))

            // 搜索框
            HStack(spacing: 8) {
                TextField("输入资源名称", text: $keyword)
                    .font(.system(size: 13))
                    .foregroundColor(textColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(textColor.opacity(0.08))
                    .cornerRadius(8)
                    .submitLabel(.search)
                    .onSubmit { performSearch() }

                Button(action: { performSearch() }) {
                    Text("搜索")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(hex: "00BE06"))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // 内容区
            if isSearching {
                Spacer()
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: textColor.opacity(0.6)))
                    .scaleEffect(0.9)
                Text("搜索中...")
                    .font(.system(size: 12))
                    .foregroundColor(subtitleColor)
                    .padding(.top, 8)
                Spacer()
            } else if !hasSearched {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 36))
                        .foregroundColor(subtitleColor)
                    Text("输入资源名称搜索弹幕")
                        .font(.system(size: 12))
                        .foregroundColor(subtitleColor)
                }
                Spacer()
            } else if searchResults.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 32))
                        .foregroundColor(subtitleColor)
                    Text("未找到匹配的弹幕源")
                        .font(.system(size: 12))
                        .foregroundColor(subtitleColor)
                }
                Spacer()
            } else {
                // 搜索结果 + 集数列表
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(searchResults) { result in
                            danmakuResultRow(result)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                .frame(maxHeight: 260)

                // 底部操作栏
                if selectedEpisodeId != nil {
                    Divider().background(textColor.opacity(0.12))
                        .padding(.top, 4)

                    HStack(spacing: 12) {
                        Spacer()
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isPresented = false
                            }
                        }) {
                            Text("取消")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(textColor.opacity(0.7))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(PlainButtonStyle())

                        Button(action: {
                            if let epId = selectedEpisodeId {
                                onLoadDanmaku(epId)
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isPresented = false
                                }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "text.bubble.fill")
                                    .font(.system(size: 11))
                                Text("加载弹幕")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(hex: "00BE06"))
                            .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 420)
        .background(panelBackground)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        .onAppear {
            if keyword.isEmpty {
                keyword = videoTitle
            }
        }
    }

    // MARK: - 搜索结果行
    @ViewBuilder
    private func danmakuResultRow(_ result: DanmakuSearchResult) -> some View {
        VStack(spacing: 0) {
            // 番剧标题行
            Button(action: {
                if selectedAnimeId == result.id {
                    // 再次点击折叠
                    selectedAnimeId = nil
                    episodes = []
                    selectedEpisodeId = nil
                } else {
                    selectedAnimeId = result.id
                    selectedEpisodeId = nil
                    episodes = result.episodes
                    // 如果搜索结果不带 episodes，通过 API 获取
                    if episodes.isEmpty {
                        loadEpisodes(animeId: result.id)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: selectedAnimeId == result.id ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(subtitleColor)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.animeTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(textColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if !result.type.isEmpty {
                            Text(result.type)
                                .font(.system(size: 10))
                                .foregroundColor(subtitleColor)
                        }
                    }

                    Spacer()

                    if !result.episodes.isEmpty {
                        Text("\(result.episodes.count)集")
                            .font(.system(size: 10))
                            .foregroundColor(subtitleColor)
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            // 集数列表（选中番剧后展开）
            if selectedAnimeId == result.id {
                if isLoadingEpisodes && episodes.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(height: 20)
                        Text("加载剧集中...")
                            .font(.system(size: 11))
                            .foregroundColor(subtitleColor)
                        Spacer()
                    }
                    .padding(.bottom, 8)
                } else if !episodes.isEmpty {
                    // 集数网格
                    let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(episodes) { ep in
                            Button(action: {
                                selectedEpisodeId = ep.id
                                UISelectionFeedbackGenerator().selectionChanged()
                            }) {
                                Text("\(ep.episodeNumber)")
                                    .font(.system(size: 12, weight: selectedEpisodeId == ep.id ? .bold : .regular))
                                    .foregroundColor(selectedEpisodeId == ep.id ? .white : textColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .background(selectedEpisodeId == ep.id ? Color(hex: "00BE06") : textColor.opacity(0.08))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.bottom, 10)
                }
            }

            Divider().background(textColor.opacity(0.08))
                .padding(.horizontal, 4)
        }
    }

    // MARK: - 搜索
    private func performSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        hasSearched = false
        searchResults = []
        selectedAnimeId = nil
        selectedEpisodeId = nil
        episodes = []

        Task {
            let results = await LogVarDanmakuService.shared.searchAnimeDetailed(keyword: trimmed)
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
                self.hasSearched = true
            }
        }
    }

    // MARK: - 加载剧集列表
    private func loadEpisodes(animeId: Int) {
        isLoadingEpisodes = true
        Task {
            let eps = await LogVarDanmakuService.shared.fetchBangumiEpisodes(animeId: animeId)
            await MainActor.run {
                self.episodes = eps
                self.isLoadingEpisodes = false
                // 自动选中当前集数
                let targetEp = currentEpisodeIndex + 1
                if let match = eps.first(where: { $0.episodeNumber == targetEp }) {
                    self.selectedEpisodeId = match.id
                }
            }
        }
    }
}

// MARK: - 更多功能竖条菜单（横屏，可扩展功能按钮）
struct ToolsQuickMenuV2: View {
    @Binding var showSkipSettings: Bool
    @Binding var showToolsMenu: Bool
    @Binding var autoPlayNext: Bool
    @Binding var backgroundPlay: Bool
    @Binding var pipEnabled: Bool
    @Binding var showDebugOverlay: Bool
    @Binding var showDanmakuSearch: Bool
    @Binding var showLongPressSpeedSettings: Bool
    @Binding var showSubtitleSettings: Bool
    @EnvironmentObject private var settings: AppSettings

    private var menuBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.82)
    }

    private var textColor: Color {
        settings.usesFrostedSkin ? Color(uiColor: .label) : .white
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 0) {
            // 长按倍速（跳转按钮）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolsMenu = false
                    showLongPressSpeedSettings = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.8))
                        .frame(width: 18)
                    Text("长按倍速")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(width: 135, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 搜索弹幕（跳转按钮）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolsMenu = false
                    showDanmakuSearch = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.8))
                        .frame(width: 18)
                    Text("搜索弹幕")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(width: 135, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 加载字幕（跳转按钮）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolsMenu = false
                    showSubtitleSettings = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.8))
                        .frame(width: 18)
                    Text("加载字幕")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(width: 135, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 功能项：片头片尾（横向布局，与其他行统一）
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showToolsMenu = false
                    showSkipSettings = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.8))
                        .frame(width: 18)
                    Text("片头片尾")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                        .frame(width: 28, alignment: .trailing)
                }
                .padding(.horizontal, 8)
                .frame(width: 135, height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 自动播放下一个
            ToolsToggleRow(icon: "play.circle.fill", title: "自动播放", isOn: $autoPlayNext, textColor: textColor)

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 后台播放
            ToolsToggleRow(icon: "speaker.wave.2.fill", title: "后台播放", isOn: $backgroundPlay, textColor: textColor)

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 画中画
            ToolsToggleRow(icon: "pip.fill", title: "画中画", isOn: $pipEnabled, textColor: textColor)

            Divider().background(textColor.opacity(0.15))
                .padding(.horizontal, 8)

            // 调试信息浮层
            ToolsToggleRow(icon: "ladybug.fill", title: "调试浮层", isOn: $showDebugOverlay, textColor: textColor)
        }
        .padding(.vertical, 4)
        }
        .frame(width: 135)
        .fixedSize(horizontal: false, vertical: true)
        .background(menuBackground)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - 菜单内 Toggle 行（图标 + 标题 + 开关）
struct ToolsToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    let textColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(textColor.opacity(0.8))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 2)
            // 自定义紧凑开关：系统 Toggle 的 scaleEffect 不影响布局尺寸，
            // 仍占 ~51pt 导致文字被挤压。用自定义控件真正控制在 28pt。
            // 添加显式 .frame(width: 28) 确保在 HStack 中占据固定宽度，
            // 避免 ZStack 尺寸推导不一致导致开关位置偏移。
            CompactToggle(isOn: $isOn)
                .frame(width: 28, height: 16)
        }
        .padding(.horizontal, 8)
        .frame(width: 135, height: 38)
        .contentShape(Rectangle())
    }
}

// MARK: - 紧凑开关（替代系统 Toggle + scaleEffect）
struct CompactToggle: View {
    @Binding var isOn: Bool

    private let knobSize: CGFloat = 12
    private let trackWidth: CGFloat = 28
    private let trackHeight: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: trackHeight / 2)
                .fill(isOn ? Color(hex: "00BE06") : Color.white.opacity(0.25))
                .frame(width: trackWidth, height: trackHeight)
            Circle()
                .fill(Color.white)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                .offset(x: isOn ? (trackWidth - knobSize) / 2 - 1 : -(trackWidth - knobSize) / 2 + 1)
                .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .onTapGesture { isOn.toggle() }
    }
}

// MARK: - 片头片尾设置面板（横屏，居中弹窗）
struct SkipSettingsPanelV2: View {
    @Binding var isPresented: Bool
    @Binding var skipIntroEnabled: Bool
    @Binding var skipIntroSeconds: Int
    @Binding var skipOutroEnabled: Bool
    @Binding var skipOutroSeconds: Int
    @EnvironmentObject private var settings: AppSettings

    private var panelBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.82)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("片头片尾")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().background(Color.white.opacity(0.1))

            // 菜单项1：跳过片头
            ToolsMenuRow(
                icon: "forward.fill",
                title: "跳过片头",
                isOn: $skipIntroEnabled,
                totalSeconds: $skipIntroSeconds
            )
            Divider().background(Color.white.opacity(0.1))

            // 菜单项2：跳过片尾
            ToolsMenuRow(
                icon: "backward.fill",
                title: "跳过片尾",
                isOn: $skipOutroEnabled,
                totalSeconds: $skipOutroSeconds
            )
        }
        .padding(.vertical, 6)
        .frame(width: 200)
        .background(panelBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: - 单行菜单项（含开关 + 滚轮时间选择器 + 震动反馈）
struct ToolsMenuRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    @Binding var totalSeconds: Int

    private let impactFeedback = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            // 标题行：图标 + 名称 + 开关
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isOn ? Color(hex: "00BE06") : .white.opacity(0.6))
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                Spacer()

                Toggle("", isOn: $isOn)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "00BE06")))
                    .scaleEffect(0.8)
                    .frame(width: 44)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // 滚轮选择器：开关打开时展开
            if isOn {
                HStack(spacing: 0) {
                    Picker("分", selection: Binding(
                        get: { totalSeconds / 60 },
                        set: { totalSeconds = $0 * 60 + totalSeconds % 60 }
                    )) {
                        ForEach(0...10, id: \.self) { m in
                            Text("\(m)分")
                                .foregroundColor(.white)
                                .tag(m)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 70)
                    .colorScheme(.dark)
                    .onChange(of: totalSeconds / 60) { _ in
                        impactFeedback.selectionChanged()
                    }

                    Picker("秒", selection: Binding(
                        get: { totalSeconds % 60 },
                        set: { totalSeconds = (totalSeconds / 60) * 60 + $0 }
                    )) {
                        ForEach(0..<60, id: \.self) { s in
                            Text("\(s)秒")
                                .foregroundColor(.white)
                                .tag(s)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 70)
                    .colorScheme(.dark)
                    .onChange(of: totalSeconds % 60) { _ in
                        impactFeedback.selectionChanged()
                    }
                }
                .frame(height: 100)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - View Extension for Corner Radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - 字幕设置面板
struct SubtitleSettingsPanel: View {
    @Binding var isPresented: Bool
    @Binding var showSubtitle: Bool
    @Binding var subtitleFontSize: CGFloat
    @Binding var subtitleColorIndex: Int
    let subtitleFileName: String
    let onLoadFile: (URL) -> Void
    let onClear: () -> Void
    @EnvironmentObject private var settings: AppSettings

    @State private var showDocumentPicker = false

    private var panelBackground: Color {
        if settings.usesLiquidSkin {
            return Color(hex: "1A1A2E").opacity(0.88)
        } else if settings.usesFrostedSkin {
            return Color(uiColor: .secondarySystemBackground).opacity(0.92)
        }
        return Color.black.opacity(0.8)
    }

    private var textPrimary: Color {
        settings.usesFrostedSkin ? Color(uiColor: .label) : .white.opacity(0.85)
    }

    private var textSecondary: Color {
        settings.usesFrostedSkin ? Color(uiColor: .secondaryLabel) : .white.opacity(0.5)
    }

    private var accentColor: Color {
        Color(hex: "2196F3")
    }

    private let colorOptions: [(String, Color)] = [
        ("白色", .white),
        ("黄色", .yellow),
        ("青色", .cyan)
    ]

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentColor)
                Text("字幕设置")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textPrimary)
                Spacer()
            }

            // 当前字幕状态
            if subtitleFileName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                    Text("暂未加载字幕")
                        .font(.system(size: 12))
                        .foregroundColor(textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text(subtitleFileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 上传本地字幕按钮
            Button(action: {
                showDocumentPicker = true
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("上传本地字幕文件")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())

            // 支持格式说明
            Text("支持 SRT / VTT / ASS / SSA 格式")
                .font(.system(size: 11))
                .foregroundColor(textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()
                .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12))

            // 字幕开关
            if !subtitleFileName.isEmpty {
                HStack {
                    Text("显示字幕")
                        .font(.system(size: 14))
                        .foregroundColor(textPrimary)
                    Spacer()
                    Toggle("", isOn: $showSubtitle)
                        .labelsHidden()
                        .tint(accentColor)
                }

                Divider()
                    .background(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12))
            }

            // 字号设置
            VStack(spacing: 8) {
                HStack {
                    Text("字幕字号")
                        .font(.system(size: 14))
                        .foregroundColor(textPrimary)
                    Spacer()
                    Text("\(Int(subtitleFontSize))")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(accentColor)
                }
                Slider(value: $subtitleFontSize, in: 12...32, step: 1)
                    .tint(accentColor)
            }

            // 颜色选择
            HStack(spacing: 10) {
                Text("字幕颜色")
                    .font(.system(size: 14))
                    .foregroundColor(textPrimary)
                ForEach(0..<colorOptions.count, id: \.self) { idx in
                    Button(action: {
                        subtitleColorIndex = idx
                    }) {
                        Circle()
                            .fill(colorOptions[idx].1)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .stroke(subtitleColorIndex == idx ? accentColor : Color.white.opacity(0.2), lineWidth: subtitleColorIndex == idx ? 2.5 : 0.5)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }

            // 清除字幕按钮
            if !subtitleFileName.isEmpty {
                Button(action: {
                    onClear()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                        Text("清除字幕")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.red.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.1))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(panelBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 4)
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { url in
                onLoadFile(url)
                showDocumentPicker = false
            }
        }
    }
}

// MARK: - 文档选择器（用于选择本地字幕文件）
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 使用字符串 UTI 方式，避免依赖 UniformIdentifiers 模块
        // 支持选择文本类文件（SRT/VTT/ASS/SSA 均属于 public.plain-text 子类型）
        let picker = UIDocumentPickerViewController(documentTypes: ["public.plain-text"], in: .open)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

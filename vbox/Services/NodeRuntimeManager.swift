import Foundation
import Combine
import UIKit
import CommonCrypto
#if canImport(NodeMobile)
import NodeMobile
#endif

// MARK: - Node 运行时通知
extension Notification.Name {
    /// Node 常驻系统状态变化（isSystemReady / statusInfo）
    static let nodeRuntimeStatus = Notification.Name("nodeRuntimeStatus")
    /// Node 崩溃检测事件（携带 message）
    static let nodeRuntimeCrash = Notification.Name("nodeRuntimeCrash")
}

// MARK: - Node 运行时管理器
//
// P1-01/02/03/13/14/18 核心服务：
//   - App 启动时在后台线程拉起 nodejs-mobile 常驻引擎
//   - 监听 127.0.0.1:58080（kstore bundle）/ 2333（catpaw bundle），健康端口 58082
//   - 运行时文件（main.js / polyfill / bundle / 配置）从 App Bundle 首次复制到 Documents
//   - bundle 完整性：manifest(MD5) 校验，损坏自动回退 App Bundle 资源（P1-03）
//   - 崩溃检测：周期 HTTP 心跳，连续失败判定崩溃（S1-2）
//   - iOS 挂起恢复：.relisten 文件握手协议（S1-3）
//   - 内存告警降级（S1-7）
//
// 铁律：本服务只负责 Node 常驻系统，不触碰百度/夸克/UC/阿里原生代码。

final class NodeRuntimeManager: ObservableObject {

    static let shared = NodeRuntimeManager()

    // MARK: - 端口常量（P1-18 对齐）

    /// kstore bundle 主端口（网盘系统默认）
    let mainPort: Int = 58080
    /// catpaw bundle 端口（远程源阶段可选启用）
    let catpawPort: Int = 2333
    /// 健康探测端口（供崩溃检测使用，与 main.js HEALTH_PORT 对齐）
    let healthPort: Int = 58082
    /// lx-music 桥接服务端口（P1-A3，与 kstore 主端口隔离）
    let lxPort: Int = 58083
    /// lx-music 桥接健康端口（P1-A3）
    let lxHealthPort: Int = 58084

    /// 当前生效端口（按部署 bundle 决定，默认 kstore）
    @Published private(set) var activePort: Int = 58080

    /// Node 系统是否就绪（启动 ack 通过 + 首次健康检查成功）
    @Published private(set) var isSystemReady = false

    /// lx-music 桥接是否就绪（lx 健康端口探活通过）
    @Published private(set) var isLXReady = false

    /// 状态描述（状态胶囊展示）
    @Published private(set) var statusInfo: String = "node-stopped"

    /// 崩溃检测状态
    @Published private(set) var isCrashed = false

    /// 启动失败原因（供 UI 提示）
    @Published private(set) var lastError: String?

    // MARK: - 运行时目录（Documents 可写，P1-02）

    /// Node 运行时根目录（Documents/noderuntime）
    var runtimeDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("noderuntime", isDirectory: true)
    }

    /// bundle 落盘目录（Documents/noderuntime/bundles）
    var bundleDir: URL {
        runtimeDir.appendingPathComponent("bundles", isDirectory: true)
    }

    /// 当前 bundle 文件（kstore_index.js）
    var activeBundleURL: URL {
        bundleDir.appendingPathComponent("kstore_index.js")
    }

    /// bundle 版本清单（记录 MD5，用于完整性校验，P1-03）
    var bundleManifestPath: URL {
        runtimeDir.appendingPathComponent("bundle.manifest.json")
    }

    /// 配置文件目录（bundle 自带的 db.json / wexfnwconfig.json 从资源复制）
    var configDir: URL { runtimeDir }

    // MARK: - 文件握手路径（与 main.js 协议对齐）

    var startupAckPath: URL { runtimeDir.appendingPathComponent(".startup.ack") }
    var relistenPath: URL { runtimeDir.appendingPathComponent(".relisten") }
    var relistenAckPath: URL { runtimeDir.appendingPathComponent(".relisten.ack") }
    /// lx 插件落盘目录（Documents/noderuntime/plugins/lx，P1-A4 / A6 备份还原写此）
    var lxPluginsDir: URL { runtimeDir.appendingPathComponent("plugins").appendingPathComponent("lx") }
    /// lx 桥接握手文件
    var lxAckPath: URL { runtimeDir.appendingPathComponent(".lx.ack") }
    /// lx 桥接基址
    var lxBaseURL: String { "http://127.0.0.1:\(lxPort)" }

    // MARK: - 私有状态

    private var healthTimer: Timer?
    private var consecutiveHealthFailures = 0
    private let maxHealthFailures = 3
    private let healthInterval: TimeInterval = 30.0
    // lx-music 桥接健康监控（P1-A3）
    private var lxHealthTimer: Timer?
    private var isStarting = false
    private var hasStartedOnce = false

    /// 启动时是否要求从网络刷新 bundle（P1-03；断网回退本地缓存）
    private var bundleRefreshURL: URL?

    private init() {
        // 监听内存告警（P1-19）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        // 监听前后台切换（挂起恢复 P1-14）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    // MARK: - 生命周期

    /// 启动 Node 常驻系统（App.init 调用）
    /// - Parameter bundleRefreshURL: 可选 bundle 远端地址（P1-03 拉取校验）
    func start(bundleRefreshURL: URL? = nil) {
        guard !isStarting, !hasStartedOnce else { return }
        isStarting = true
        self.bundleRefreshURL = bundleRefreshURL
        statusInfo = "node-starting"
        postStatus()

        Task {
            do {
                // 1) 部署运行时文件（首次从 Bundle 资源复制到 Documents，P1-02）
                try prepareRuntimeFiles()

                // 2) bundle 完整性校验（manifest MD5），损坏自动回退资源（P1-03）
                try verifyBundleIntegrity()

                // 3) 若有远端 bundle 且网络可用，拉取校验 MD5 后落盘
                if let url = bundleRefreshURL {
                    try? await refreshBundleIfNeeded(from: url)
                }

                // 4) 设置环境变量并启动 Node 引擎（P1-18 端口一致性）
                launchNodeEngine()

                // 5) 等待启动 ack（超时 45s，对齐 TVS 的启动等待策略；此时 ack 必为本次真实写入）
                let ackOK = await waitForStartupAck(timeout: 45)
                guard ackOK else {
                    failStart("Node 启动 ack 超时或失败")
                    return
                }

                // 6) HTTP 探活确认（真实可用的最终依据）
                let probeOK = await probeHealth()
                guard probeOK else {
                    failStart("Node 启动后 HTTP 探活失败")
                    return
                }

                isSystemReady = true
                isCrashed = false
                statusInfo = "node-ready(\(activePort))"
                postStatus()
                startHealthMonitor()
                startLXHealthMonitor()
            } catch {
                failStart(error.localizedDescription)
            }
            isStarting = false
        }
    }

    /// 停止 Node 系统（App 退出前可调用；当前 nodejs-mobile 单实例不支持优雅停止后重启）
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        lxHealthTimer?.invalidate()
        lxHealthTimer = nil
        isSystemReady = false
        isLXReady = false
        statusInfo = "node-stopped"
        postStatus()
    }

    // MARK: - 运行时文件部署（P1-02）

    /// 将 App Bundle 内的 noderuntime 资源复制到 Documents 可写目录。
    ///
    /// 文件按性质分两类处理：
    ///   - 代码文件（main.js / node-intl-polyfill.js / bundle）：App 升级时以资源为准覆盖；
    ///   - 数据文件（db.json / default.db.json / wexfnwconfig.json）：仅首次复制。
    ///     db.json 登录后由 Node 侧写入网盘凭据，升级覆盖会导致用户数据丢失，严禁覆盖。
    private func prepareRuntimeFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundleDir, withIntermediateDirectories: true)

        // 清除上次运行残留的握手文件（.startup.ack / .relisten.ack）。
        // 若不清理，waitForStartupAck 会在 1ms 内读到陈旧 "ok" 而误判启动成功，
        // 随后单次探活必然失败，导致"有时能启动、有时不能"的竞态。
        for handshakeFile in [startupAckPath, relistenAckPath] {
            if fm.fileExists(atPath: handshakeFile.path) {
                try? fm.removeItem(at: handshakeFile)
                nodeLog(.info, "🧹 清除残留握手文件: \(handshakeFile.lastPathComponent)")
            }
        }

        // 资源来源：Bundle.main 的 noderuntime 目录（由 pbxproj folder 引用打包）
        guard let srcDir = Bundle.main.resourceURL?
            .appendingPathComponent("noderuntime", isDirectory: true) else {
            throw NodeRuntimeError.bundleResourceMissing("noderuntime")
        }

        // 代码文件：资源更新即覆盖（App 升级携带修复）
        let codeFiles = [
            "main.js",
            "node-intl-polyfill.js",
        ]
        for name in codeFiles {
            let src = srcDir.appendingPathComponent(name)
            let dst = runtimeDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) || isResourceNewer(src: src, dst: dst) {
                guard fm.fileExists(atPath: src.path) else {
                    throw NodeRuntimeError.bundleResourceMissing(name)
                }
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }

        // lx-music 桥接（P1-A3/A4）：随 App 升级覆盖代码，插件按需补齐
        let lxSrc = srcDir.appendingPathComponent("lx", isDirectory: true)
        if fm.fileExists(atPath: lxSrc.path) {
            let lxBridgeSrc = lxSrc.appendingPathComponent("lx-bridge.js")
            let lxBridgeDst = runtimeDir.appendingPathComponent("lx").appendingPathComponent("lx-bridge.js")
            if fm.fileExists(atPath: lxBridgeSrc.path)
                && (!fm.fileExists(atPath: lxBridgeDst.path) || isResourceNewer(src: lxBridgeSrc, dst: lxBridgeDst)) {
                try? fm.createDirectory(at: lxBridgeDst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: lxBridgeDst)
                try fm.copyItem(at: lxBridgeSrc, to: lxBridgeDst)
            }
            // lx-music 桥接框架随 App 升级部署（lx-bridge.js 是桥接层，不属于第三方插件）。
            // 插件即服务（P1-A6）：刀源 / 念心插件脚本由远程源仓库经
            // RemoteSourceConfigManager.syncNow 下发到 lxPluginsDir，App 不再内置插件种子。
            // 此处仅确保插件目录存在；插件内容以远程同步为准。
            try? fm.createDirectory(at: lxPluginsDir, withIntermediateDirectories: true)
        }

        // 数据文件：仅首次复制；已存在则跳过（保护网盘凭据等用户数据）
        let dataFiles = [
            "db.json",
            "default.db.json",
            "wexfnwconfig.json",
        ]
        for name in dataFiles {
            let src = srcDir.appendingPathComponent(name)
            let dst = runtimeDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) {
                guard fm.fileExists(atPath: src.path) else {
                    throw NodeRuntimeError.bundleResourceMissing(name)
                }
                try fm.copyItem(at: src, to: dst)
                nodeLog(.info, "📄 首次部署数据文件: \(name)")
            }
        }

        // bundle（kstore_index.js 6.3MB）：此处只保证"资源存在"，完整性走 manifest 校验
        let bundleSrc = srcDir.appendingPathComponent("bundles/kstore_index.js")
        if !fm.fileExists(atPath: bundleSrc.path) {
            throw NodeRuntimeError.bundleResourceMissing("bundles/kstore_index.js")
        }

        nodeLog(.info, "✅ 运行时文件就绪: \(runtimeDir.path)")
    }

    private func isResourceNewer(src: URL, dst: URL) -> Bool {
        guard let srcDate = try? FileManager.default.attributesOfItem(atPath: src.path)[.modificationDate] as? Date,
              let dstDate = try? FileManager.default.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date else {
            return false
        }
        return srcDate > dstDate
    }

    // MARK: - Bundle 完整性校验（P1-03）

    /// 校验落盘 bundle 与 manifest 记录的 MD5 是否一致。
    /// - 无 manifest 或 MD5 不匹配：判定损坏/未登记，从 App Bundle 资源回退复制并重建 manifest。
    /// - 资源也不可用：抛错，由 start 流程 failStart。
    private func verifyBundleIntegrity() throws {
        let fm = FileManager.default
        let manifest = readBundleManifest()

        // 情况 A：manifest 存在且 MD5 一致 → 完整，直接放行
        if let manifest,
           let manifestMD5 = manifest.md5,
           let local = try? Data(contentsOf: activeBundleURL),
           local.md5Hex == manifestMD5 {
            nodeLog(.info, "✅ bundle 完整性校验通过 MD5=\(manifestMD5.prefix(8))")
            return
        }

        // 情况 B：bundle 缺失或与 manifest 不符 → 回退 App Bundle 资源
        nodeLog(.warn, "⚠️ bundle 与 manifest 不符或未登记，回退资源副本")
        try restoreBundleFromResource()

        // 回退后重建 manifest（标记来源 bundled）
        if let restored = try? Data(contentsOf: activeBundleURL) {
            writeBundleManifest(md5: restored.md5Hex, source: "bundled", version: nil)
            nodeLog(.info, "✅ bundle 已从资源恢复 MD5=\(restored.md5Hex.prefix(8))")
        }
    }

    /// 从 App Bundle 资源复制 bundle 到 Documents（覆盖损坏副本）
    private func restoreBundleFromResource() throws {
        guard let srcDir = Bundle.main.resourceURL?
            .appendingPathComponent("noderuntime", isDirectory: true) else {
            throw NodeRuntimeError.bundleResourceMissing("noderuntime")
        }
        let bundleSrc = srcDir.appendingPathComponent("bundles/kstore_index.js")
        guard FileManager.default.fileExists(atPath: bundleSrc.path) else {
            throw NodeRuntimeError.bundleResourceMissing("bundles/kstore_index.js")
        }
        try? FileManager.default.removeItem(at: activeBundleURL)
        try FileManager.default.copyItem(at: bundleSrc, to: activeBundleURL)
    }

    /// bundle manifest 结构
    private struct BundleManifest: Codable {
        var fileName: String
        var md5: String?
        var version: String?
        var source: String?
        var updatedAt: TimeInterval?
    }

    private func readBundleManifest() -> BundleManifest? {
        guard let data = try? Data(contentsOf: bundleManifestPath),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    private func writeBundleManifest(md5: String, source: String, version: String?) {
        let manifest = BundleManifest(
            fileName: activeBundleURL.lastPathComponent,
            md5: md5,
            version: version,
            source: source,
            updatedAt: Date().timeIntervalSince1970
        )
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: bundleManifestPath, options: .atomic)
        }
    }

    // MARK: - Bundle 远端刷新 + MD5 校验（P1-03）

    private func refreshBundleIfNeeded(from url: URL) async throws {
        let fm = FileManager.default
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            nodeLog(.warn, "⚠️ bundle 拉取失败，回退本地缓存")
            return
        }
        // 合理性校验：bundle 至少 1MB，防止下载到错误页/空包
        guard data.count > 1_000_000 else {
            nodeLog(.warn, "⚠️ bundle 拉取异常（\(data.count)B），丢弃")
            return
        }
        let md5 = data.md5Hex
        // 与本地缓存比对：一致则跳过写盘
        if let local = try? Data(contentsOf: activeBundleURL), local.md5Hex == md5 {
            nodeLog(.info, "✅ bundle MD5 一致，无需更新")
            return
        }
        // 原子写盘（先写临时文件再替换，避免写一半损坏）
        let tmpURL = activeBundleURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        try? fm.removeItem(at: activeBundleURL)
        try fm.moveItem(at: tmpURL, to: activeBundleURL)
        // 更新 manifest
        writeBundleManifest(md5: md5, source: "remote", version: nil)
        nodeLog(.info, "✅ bundle 已更新 MD5=\(md5)")
    }

    // MARK: - Node 引擎启动（P1-01）

    private func launchNodeEngine() {
        // 环境变量注入（P1-18：kstore=58080 / catpaw=2333，健康端口 58082）
        activePort = mainPort
        setenv("PORT", String(activePort), 1)
        setenv("DEV_HTTP_PORT", String(activePort), 1)
        setenv("DART_PORT", String(activePort + 1), 1)
        setenv("HEALTH_PORT", String(healthPort), 1)
        setenv("NODE_PATH", runtimeDir.path, 1)
        setenv("BUNDLE_PATH", activeBundleURL.path, 1)
        // lx-music 桥接（P1-A3）：独立端口 + 插件目录 + 握手文件
        setenv("LX_PORT", String(lxPort), 1)
        setenv("LX_HEALTH_PORT", String(lxHealthPort), 1)
        setenv("LX_PLUGINS_DIR", lxPluginsDir.path, 1)
        setenv("LX_ACK_PATH", lxAckPath.path, 1)
        // 移除可能导致父进程看门狗退出的变量
        unsetenv("TVS_PARENT_PID")

        nodeLog(.info, "🚀 启动 Node 引擎 PORT=\(activePort) NODE_PATH=\(runtimeDir.path)")
        nodeLog(.info, "📦 BUNDLE_PATH=\(activeBundleURL.path)")

        #if canImport(NodeMobile)
        // 在独立线程启动 Node（官方要求 2MB 栈空间）
        let thread = Thread {
            NodeRunner.startEngine(withArguments: ["node", self.runtimeDir.appendingPathComponent("main.js").path])
        }
        thread.name = "com.vbox.noderuntime"
        thread.stackSize = 2 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
        #else
        nodeLog(.warn, "⚠️ NodeMobile 未集成，Node 系统不可用（降级）")
        #endif
    }

    // MARK: - 启动 ack 等待

    private func waitForStartupAck(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: startupAckPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                if status == "ok" {
                    nodeLog(.info, "✅ startup ack ok")
                    return true
                } else {
                    let err = json["error"] as? String ?? "unknown"
                    nodeLog(.error, "❌ startup ack error: \(err)")
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - 健康检查（P1-13 崩溃检测）

    private func startHealthMonitor() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthInterval, repeats: true) { [weak self] _ in
            Task { await self?.runHealthCheck() }
        }
    }

    private func runHealthCheck() async {
        // 崩溃后（isSystemReady=false）保持心跳探测，便于自愈：
        // Node 实际存活但曾因网络抖动误判崩溃时，探测恢复后重新标记就绪。
        guard isSystemReady || isCrashed else { return }
        let ok = await probeHealth()
        if ok {
            consecutiveHealthFailures = 0
            if isCrashed || !isSystemReady {
                isCrashed = false
                isSystemReady = true
                statusInfo = "node-ready(\(activePort))"
                postStatus()
                nodeLog(.info, "✅ Node 自愈：心跳恢复，系统重新就绪")
            } else if statusInfo == "node-memory-warning" {
                // 内存告警仅提示，健康恢复后还原就绪状态
                statusInfo = "node-ready(\(activePort))"
                postStatus()
            }
        } else {
            consecutiveHealthFailures += 1
            nodeLog(.warn, "⚠️ 心跳失败 \(consecutiveHealthFailures)/\(maxHealthFailures)")
            if consecutiveHealthFailures >= maxHealthFailures {
                handleNodeCrash()
            }
        }
    }

    /// HTTP 探活：优先健康端口，回退主端口（/website/api/status）。
    /// 带重试等待服务就绪：ack 确认后服务可能仍在收尾监听，单次探测会误报失败，
    /// 因此按 500ms 间隔最多重试 retries 次（对齐 TVS 的"轮询等待"策略）。
    private func probeHealth(retries: Int = 12, retryDelay: TimeInterval = 0.5) async -> Bool {
        let attemptCount = max(retries, 1)
        for attempt in 0..<attemptCount {
            let endpoints = [
                "http://127.0.0.1:\(healthPort)/health",
                "http://127.0.0.1:\(activePort)/website/api/status",
            ]
            for endpoint in endpoints {
                guard let url = URL(string: endpoint) else { continue }
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                        if attempt > 0 {
                            nodeLog(.info, "✅ 探活成功（第 \(attempt + 1) 次尝试）")
                        }
                        return true
                    }
                } catch {
                    // 服务未就绪，进入下一次重试
                }
            }
            if attempt < attemptCount - 1 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        return false
    }

    // MARK: - lx-music 桥接健康监控（P1-A3）

    private func startLXHealthMonitor() {
        lxHealthTimer?.invalidate()
        lxHealthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.runLXHealthCheck() }
        }
        // 启动后立即探一次
        Task { await self?.runLXHealthCheck() }
    }

    private func runLXHealthCheck() async {
        let ok = await probeLXHealth()
        let needPost = ok != isLXReady
        if ok {
            if isSystemReady && !isLXReady {
                nodeLog(.info, "✅ lx-music 桥接就绪（127.0.0.1:\(lxPort)）")
            }
        } else {
            if isLXReady {
                nodeLog(.warn, "⚠️ lx-music 桥接探活失败，标记不可用（kstore 主链路不受影响）")
            }
        }
        isLXReady = ok
        if needPost { postStatus() }
    }

    private func probeLXHealth(retries: Int = 8, retryDelay: TimeInterval = 0.4) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(lxHealthPort)/health") else { return false }
        for attempt in 0..<retries {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return true
                }
            } catch {
                // fallthrough retry
            }
            if attempt < retries - 1 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        return false
    }

    /// 崩溃处理（S1-2）：nodejs-mobile 单实例不可进程内重启，
    /// 按计划策略提示用户重启 App + 状态胶囊标记
    private func handleNodeCrash() {
        guard !isCrashed else { return }
        isCrashed = true
        isSystemReady = false
        statusInfo = "node-crashed"

        // 崩溃后清理握手文件，防止下次启动读到本次残留的 ack 而误判成功
        let fm = FileManager.default
        for handshakeFile in [startupAckPath, relistenAckPath] {
            if fm.fileExists(atPath: handshakeFile.path) {
                try? fm.removeItem(at: handshakeFile)
            }
        }
        let message = "Node 常驻服务已停止（连续 \(maxHealthFailures) 次心跳失败）。请重启 App 恢复。"
        lastError = message
        nodeLog(.error, "❌ \(message)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .nodeRuntimeCrash, object: message)
        }
        postStatus()
    }

    // MARK: - iOS 挂起恢复（P1-14 relisten 协议）

    @objc private func handleAppBecameActive() {
        // 崩溃后回到前台：先探活一次，Node 实际存活则立即自愈，不再等 30s 心跳周期
        if isCrashed {
            Task {
                let ok = await probeHealth()
                if ok {
                    consecutiveHealthFailures = 0
                    isCrashed = false
                    isSystemReady = true
                    statusInfo = "node-ready(\(activePort))"
                    postStatus()
                    nodeLog(.info, "✅ 前台恢复探测成功，Node 自愈")
                }
            }
            return
        }
        guard isSystemReady else { return }
        Task { await performRelisten() }
    }

    @objc private func handleAppWillResignActive() {
        // 预留：退后台时无需额外动作，恢复时走 relisten
    }

    /// 写入 .relisten 文件触发 Node 侧安全重监听，等待 ack
    private func performRelisten() async {
        let token = UUID().uuidString
        let command: [String: Any] = ["token": token, "dartPort": activePort + 1]
        guard let data = try? JSONSerialization.data(withJSONObject: command) else { return }
        try? data.write(to: relistenPath, options: .atomic)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ackData = try? Data(contentsOf: relistenAckPath),
               let ack = try? JSONSerialization.jsonObject(with: ackData) as? [String: Any],
               let ackToken = ack["token"] as? String,
               ackToken == token,
               let status = ack["status"] as? String {
                if status == "ok" {
                    nodeLog(.info, "✅ relisten ok token=\(token)")
                } else {
                    nodeLog(.warn, "⚠️ relisten error: \(ack["error"] ?? "unknown")")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        nodeLog(.warn, "⚠️ relisten ack 超时（HTTP 探活为准）")
        // ack 超时后做一次 HTTP 探活确认
        let ok = await probeHealth()
        if !ok {
            handleNodeCrash()
        }
    }

    // MARK: - 内存告警（P1-19）

    @objc private func handleMemoryWarning() {
        nodeLog(.warn, "🧹 内存告警：Node 常驻进程占用较大，建议重启 App 释放")
        // 降级：不主动杀 Node（会丢失网盘会话），仅提示 + 状态标记
        statusInfo = "node-memory-warning"
        postStatus()
    }

    // MARK: - 工具

    /// Node 统一日志：控制台 + 写入 AppLogStore（category .node，导出时生成 node.txt）
    private func nodeLog(_ level: LogLevel, _ message: String) {
        print("[NodeRuntime] \(message)")
        AppLogStore.shared.log(level, .node, message)
    }

    private func failStart(_ message: String) {
        isSystemReady = false
        isCrashed = true
        lastError = message
        statusInfo = "node-failed"
        nodeLog(.error, "❌ 启动失败: \(message)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .nodeRuntimeCrash, object: message)
        }
        postStatus()
    }

    private func postStatus() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .nodeRuntimeStatus, object: self.statusInfo)
        }
    }

    // MARK: - 对外查询

    /// 当前 Node HTTP base（供 NodePanResolver / NodeSpiderEngine 使用）
    var baseURL: String {
        "http://127.0.0.1:\(activePort)"
    }

    /// 供状态胶囊读取的摘要
    var statusSummary: String {
        statusInfo
    }
}

// MARK: - 错误类型

enum NodeRuntimeError: LocalizedError {
    case bundleResourceMissing(String)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing(let name):
            return "Node 资源缺失: \(name)"
        }
    }
}

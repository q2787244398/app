import Foundation
import Combine
import CommonCrypto
import AVFoundation

// MARK: - 下载类型枚举

enum DownloadType {
    case m3u8
    case directFile
    case unsupported
}

// MARK: - DownloadManager

/// 下载管理器：负责接收下载任务、解析真实下载地址、执行文件下载、上报进度
/// 网盘资源统一调用 CloudDriveManager.resolvePlayURL(from:) 动态入口
/// 后期优化其他网盘解析链路后，下载功能自动支持，零改动
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadRecord] = []
    @Published var capsuleMessage: DownloadCapsuleMessage?  // 胶囊通知消息
    @Published var isFloatingButtonManuallyHidden: Bool = false  // 用户手动隐藏悬浮按键

    @Published var pausedDownloadIds: Set<Int> = []  // 已暂停的下载 ID

    private var downloadTasks: [Int: Task<Void, Never>] = [:]  // recordId → Task
    private let maxConcurrent = 2  // 最大并发下载数
    private var pendingQueue: [DownloadRecord] = []
    private var lastStatusMap: [Int: String] = [:]  // 跟踪状态变化：recordId → 旧状态

    private init() {}

    // MARK: - 入队

    func enqueueDownload(record: DownloadRecord) {
        DatabaseManager.shared.addDownload(record)
        reloadActiveDownloads()

        // addDownload 按值传递，record.id 不会被回填
        // 需要重新查询获取数据库分配的 id
        guard let savedRecord = findMatchingRecord(record) else {
            print("[DownloadManager] 无法找到刚插入的下载记录")
            return
        }

        // 发送胶囊通知：正在下载
        postCapsule(
            text: "已添加「\(savedRecord.name)」到下载",
            icon: "arrow.down.circle.fill",
            type: .info
        )

        // 新任务入队时恢复悬浮按键显示
        isFloatingButtonManuallyHidden = false

        if downloadTasks.count < maxConcurrent {
            startDownload(record: savedRecord)
        } else {
            pendingQueue.append(savedRecord)
        }
    }

    // MARK: - 胶囊通知

    /// 发送胶囊通知（UI 组件统一管理 5 秒自动消失，此处只负责设置消息）
    private func postCapsule(text: String, icon: String, type: DownloadCapsuleMessage.CapsuleType) {
        let msg = DownloadCapsuleMessage(text: text, icon: icon, type: type)
        DispatchQueue.main.async { [weak self] in
            self?.capsuleMessage = msg
        }
    }

    /// 根据名称和添加时间查找刚插入的记录，获取数据库分配的 id
    private func findMatchingRecord(_ record: DownloadRecord) -> DownloadRecord? {
        let all = DatabaseManager.shared.queryDownloads()
        // 按名称+播放地址匹配，取最新一条
        return all.first(where: { $0.name == record.name && $0.playurl == record.playurl })
    }

    // MARK: - 刷新列表

    func reloadActiveDownloads() {
        activeDownloads = DatabaseManager.shared.queryDownloads()
        checkStatusChanges()
    }

    /// 检测下载状态变化，自动发送胶囊通知
    private func checkStatusChanges() {
        for record in activeDownloads {
            guard let recordId = record.id else { continue }
            let oldStatus = lastStatusMap[recordId]
            let newStatus = record.status

            // 状态未变化或首次记录（跳过首次，避免初始化时误报）
            if oldStatus == newStatus { continue }
            if oldStatus == nil {
                lastStatusMap[recordId] = newStatus
                continue
            }

            // 状态发生变化
            switch newStatus {
            case "completed":
                postCapsule(
                    text: "「\(record.name)」下载完成",
                    icon: "checkmark.circle.fill",
                    type: .success
                )
            case "failed":
                // 区分网络失败和普通失败
                let isNetworkError = record.downloadedSize == 0
                postCapsule(
                    text: "「\(record.name)」\(isNetworkError ? "网络失败" : "下载失败")",
                    icon: isNetworkError ? "wifi.slash" : "xmark.circle.fill",
                    type: isNetworkError ? .network : .failure
                )
            default:
                break
            }

            lastStatusMap[recordId] = newStatus
        }

        // 清理已删除记录的状态跟踪
        let currentIds = Set(activeDownloads.compactMap { $0.id })
        lastStatusMap = lastStatusMap.filter { currentIds.contains($0.key) }
    }

    // MARK: - 启动下载

    private func startDownload(record: DownloadRecord) {
        let taskId = record.id ?? 0
        let task = Task { [weak self] in
            await self?.executeDownload(record: record)
            await MainActor.run {
                self?.downloadTasks.removeValue(forKey: taskId)
                self?.startNextPending()
            }
        }
        downloadTasks[taskId] = task
    }

    private func startNextPending() {
        guard downloadTasks.count < maxConcurrent, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        startDownload(record: next)
    }

    // MARK: - 核心执行

    private func executeDownload(record: DownloadRecord) async {
        let recordId = record.id ?? 0
        guard recordId > 0 else { return }

        // 步骤1: 更新状态为 downloading
        DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "downloading")
        await MainActor.run { reloadActiveDownloads() }

        // 步骤2: 解析真实下载地址
        let resolved = await resolveDownloadURL(record: record)

        switch resolved.type {
        case .m3u8:
            await downloadM3U8(record: record, url: resolved.url, headers: resolved.headers)
        case .directFile:
            await downloadDirectFile(record: record, url: resolved.url, headers: resolved.headers)
        case .unsupported:
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
        }
    }

    // MARK: - 地址解析（按 sourceType 分发）
    // 网盘资源统一走 resolvePlayURL(from:) 动态入口，无需按类型硬编码

    private func resolveDownloadURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let sourceType = record.sourceType ?? "normal"

        if sourceType == "cloud" {
            return await resolveCloudDriveURL(record: record)
        } else {
            return await resolveNormalURL(record: record)
        }
    }

    // MARK: - 普通资源解析

    private func resolveNormalURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let url = record.playurl

        // 解析 record.headers（JSON 编码的自定义请求头）
        var savedHeaders: [String: String] = [:]
        if let headersJson = record.headers,
           let data = headersJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            savedHeaders = decoded
        }

        // 1. 如果是媒体直链，直接返回（保留自定义 headers）
        if isDirectMediaURL(url) {
            let type: DownloadType = url.lowercased().contains("m3u8") ? .m3u8 : .directFile
            return (url, savedHeaders, type)
        }

        // 2. 调用 SpiderManager.getPlayerContent（JS 蜘蛛 playerContent）
        if let engineKey = record.engineKey, !engineKey.isEmpty,
           let vodId = record.vodId, !vodId.isEmpty {
            // 福利资源 engineKey 以 __fuli_welfare__ 开头，URL 已是直链，跳过 getPlayerContent
            if !engineKey.hasPrefix("__fuli_welfare__") {
                if let pr = await SpiderManager.shared.getPlayerContent(
                    vodId: vodId, flag: "play", url: url, engineKey: engineKey) {
                    // 与播放链路一致：playUrl 优先，否则从 urls 数组取首个 http(s) 直链
                    // （node bundle play 返回 [画质名, MPD地址, ...] 成对数组，url 首元素是画质名不是地址）
                    let resolvedUrl = pr.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? SpiderManager.firstPlayableURL(in: pr) ?? ""
                    if !resolvedUrl.isEmpty {
                        let type: DownloadType = resolvedUrl.lowercased().contains("m3u8") ? .m3u8 : .directFile
                        return (resolvedUrl, pr.header ?? [:], type)
                    }
                }
            }
        }

        // 3. 调用解析器兜底
        if let parsed = await SpiderManager.shared.parsePlayUrl(from: url) {
            let type: DownloadType = parsed.lowercased().contains("m3u8") ? .m3u8 : .directFile
            return (parsed, savedHeaders, type)
        }

        return ("", savedHeaders, .unsupported)
    }

    // MARK: - 网盘资源解析（动态统一入口）

    /// 一行调用 resolvePlayURL(from:)，复用播放器的全部网盘解析能力
    /// 自动完成：网盘类型检测 → Token 获取 → 多 Token 遍历 → vbox 参数解析 → 失败标记
    /// 后期优化其他网盘解析链路后，下载自动支持，零改动
    private func resolveCloudDriveURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let shareURL = record.playurl

        do {
            let playResult = try await CloudDriveManager.shared.resolvePlayURL(from: shareURL)
            let type: DownloadType = playResult.url.lowercased().contains("m3u8")
                                     ? .m3u8 : .directFile
            return (playResult.url, playResult.headers, type)
        } catch {
            print("[DownloadManager] 网盘解析失败: \(error.localizedDescription)")
            return ("", [:], .unsupported)
        }
    }

    // MARK: - 直链文件下载器

    private func downloadDirectFile(record: DownloadRecord, url: String,
                                     headers: [String: String]) async {
        let recordId = record.id ?? 0
        guard let downloadURL = URL(string: url) else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        var request = URLRequest(url: downloadURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        // 创建下载目录
        let downloadsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        // 清理文件名中的非法字符
        let safeName = record.name.replacingOccurrences(of: "[/\\:*?\"<>|]", with: "_", options: .regularExpression)

        // 确定文件扩展名
        let ext = downloadURL.pathExtension.isEmpty
            ? "mp4" : downloadURL.pathExtension

        let outputURL = downloadsDir.appendingPathComponent("\(safeName).\(ext)")
        let tempURL = downloadsDir.appendingPathComponent("\(safeName)_temp.\(ext)")

        // 如果文件已存在，先删除
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: tempURL)

        do {
            // 使用 URLSession.bytes 流式下载，支持实时进度回调
            let (bytes, response) = try await URLSession.shared.bytes(for: request)

            // 从响应头获取总大小
            let expectedContentLength = Int64(response.expectedContentLength)

            // 流式写入文件
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else {
                throw NSError(domain: "DownloadManager", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建文件"])
            }

            var downloadedSize: Int64 = 0
            var lastReportTime = Date()
            var buffer = Data()
            let bufferSize = 64 * 1024  // 64KB 缓冲区

            // 逐块读取写入
            for try await byte in bytes {
                if Task.isCancelled {
                    try? fileHandle.close()
                    try? FileManager.default.removeItem(at: tempURL)
                    return
                }

                buffer.append(byte)
                if buffer.count >= bufferSize {
                    fileHandle.write(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                downloadedSize += 1

                // 每 0.5 秒上报一次进度，避免频繁刷新 UI
                let now = Date()
                if now.timeIntervalSince(lastReportTime) > 0.5 {
                    lastReportTime = now
                    let progress = expectedContentLength > 0
                        ? Double(downloadedSize) / Double(expectedContentLength)
                        : 0
                    DatabaseManager.shared.updateDownloadProgress(
                        id: recordId, progress: progress,
                        downloadedSize: downloadedSize, status: "downloading")
                    await MainActor.run { reloadActiveDownloads() }
                }
            }

            // 写入缓冲区剩余数据
            if !buffer.isEmpty {
                fileHandle.write(buffer)
            }

            try? fileHandle.close()

            // 下载完成，重命名临时文件为最终文件
            try FileManager.default.moveItem(at: tempURL, to: outputURL)

            // 如果是 TS 文件，转 MP4
            if ext.lowercased() == "ts" {
                let mp4URL = downloadsDir.appendingPathComponent("\(safeName).mp4")
                try? FileManager.default.removeItem(at: mp4URL)

                // 优先用 AVMutableComposition 方式
                let composeSuccess = await convertTSToMP4ViaComposition(from: outputURL, to: mp4URL)
                if composeSuccess {
                    try? FileManager.default.removeItem(at: outputURL)
                    let fileSize = (try? FileManager.default.attributesOfItem(
                        atPath: mp4URL.path)[.size] as? Int64) ?? 0
                    DatabaseManager.shared.updateDownloadPath(
                        id: recordId, path: mp4URL.path,
                        fileSize: fileSize, status: "completed")
                } else {
                    let conversionSuccess = await convertTSToMP4(from: outputURL, to: mp4URL)
                    if conversionSuccess {
                        try? FileManager.default.removeItem(at: outputURL)
                        let fileSize = (try? FileManager.default.attributesOfItem(
                            atPath: mp4URL.path)[.size] as? Int64) ?? 0
                        DatabaseManager.shared.updateDownloadPath(
                            id: recordId, path: mp4URL.path,
                            fileSize: fileSize, status: "completed")
                    } else {
                        // 最终兜底：用 TS 文件
                        let fileSize = (try? FileManager.default.attributesOfItem(
                            atPath: outputURL.path)[.size] as? Int64) ?? 0
                        DatabaseManager.shared.updateDownloadPath(
                            id: recordId, path: outputURL.path,
                            fileSize: fileSize, status: "completed")
                    }
                }
            } else {
                let fileSize = (try? FileManager.default.attributesOfItem(
                    atPath: outputURL.path)[.size] as? Int64) ?? 0
                DatabaseManager.shared.updateDownloadPath(
                    id: recordId, path: outputURL.path,
                    fileSize: fileSize, status: "completed")
            }
            await MainActor.run { reloadActiveDownloads() }

        } catch {
            print("[DownloadManager] 直链下载失败: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempURL)
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
        }
    }

    // MARK: - M3U8 下载器

    private func downloadM3U8(record: DownloadRecord, url: String,
                               headers: [String: String]) async {
        let recordId = record.id ?? 0

        // 1. 下载 m3u8 播放列表
        guard let m3u8Content = await fetchString(url: url, headers: headers) else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        // 2. 处理 master playlist（多码率）→ 取第一个 media playlist
        let mediaPlaylistURL = resolveMediaPlaylist(from: m3u8Content, baseURL: url)
        let finalContent: String
        let finalBaseURL: String

        if mediaPlaylistURL != url {
            guard let content = await fetchString(url: mediaPlaylistURL, headers: headers) else {
                DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
                await MainActor.run { reloadActiveDownloads() }
                return
            }
            finalContent = content
            finalBaseURL = mediaPlaylistURL
        } else {
            finalContent = m3u8Content
            finalBaseURL = url
        }

        // 3. 解析 TS 分片 URL 列表
        let tsURLs = parseTSSegments(from: finalContent, baseURL: finalBaseURL)
        guard !tsURLs.isEmpty else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        // 4. 处理 AES-128 加密
        let keyInfo = extractAESKeyInfo(from: finalContent, baseURL: finalBaseURL)
        var aesKey: Data? = nil
        if let keyURL = keyInfo?.url {
            aesKey = await fetchData(url: keyURL, headers: headers)
        }

        // 5. 创建临时目录（清理旧数据，支持暂停后重新下载）
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbox_dl_\(recordId)")
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 6. 逐个下载 TS 分片
        for (index, tsURL) in tsURLs.enumerated() {
            if Task.isCancelled { return }

            guard let tsData = await fetchData(url: tsURL, headers: headers) else { continue }

            // 异步操作后再次检查取消状态（暂停时避免覆盖 paused 状态）
            if Task.isCancelled { return }

            let finalData: Data
            if let key = aesKey, let iv = keyInfo?.iv {
                finalData = decryptTS(data: tsData, key: key, iv: iv)
            } else if let key = aesKey {
                // 默认 IV = 序号
                let ivBytes = withUnsafeBytes(of: UInt64(index).bigEndian) { Data($0) }
                let ivData = Data(repeating: 0, count: 8) + ivBytes
                finalData = decryptTS(data: tsData, key: key, iv: ivData)
            } else {
                finalData = tsData
            }

            let tsPath = tempDir.appendingPathComponent(
                "seg_\(String(format: "%05d", index)).ts")
            try? finalData.write(to: tsPath)

            // 7. 上报进度
            let progress = Double(index + 1) / Double(tsURLs.count)
            let currentSize = dirSize(tempDir)
            DatabaseManager.shared.updateDownloadProgress(
                id: recordId, progress: progress,
                downloadedSize: currentSize, status: "downloading")
            await MainActor.run { reloadActiveDownloads() }
        }

        // 8. 用 AVMutableComposition 合并 TS 分片并导出为 MP4
        let downloadsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = record.name.replacingOccurrences(of: "[/\\:*?\"<>|]", with: "_", options: .regularExpression)
        let outputURL = downloadsDir.appendingPathComponent("\(safeName).mp4")

        // 尝试用 AVMutableComposition 合并分片（最可靠的方式）
        let composeSuccess = await composeSegmentsToMP4(segmentsDir: tempDir, to: outputURL)

        if composeSuccess {
            // 清理临时分片目录
            try? FileManager.default.removeItem(at: tempDir)
            let fileSize = (try? FileManager.default.attributesOfItem(
                atPath: outputURL.path)[.size] as? Int64) ?? 0
            DatabaseManager.shared.updateDownloadPath(
                id: recordId, path: outputURL.path,
                fileSize: fileSize, status: "completed")
            await MainActor.run { reloadActiveDownloads() }
        } else {
            // Composition 失败，尝试传统合并+转码兜底
            let tempTSURL = downloadsDir.appendingPathComponent("\(safeName)_temp.ts")
            mergeTSSegments(in: tempDir, to: tempTSURL)
            // 清理临时分片目录（已合并到 tempTSURL）
            try? FileManager.default.removeItem(at: tempDir)
            let conversionSuccess = await convertTSToMP4(from: tempTSURL, to: outputURL)

            if conversionSuccess {
                try? FileManager.default.removeItem(at: tempTSURL)
                let fileSize = (try? FileManager.default.attributesOfItem(
                    atPath: outputURL.path)[.size] as? Int64) ?? 0
                DatabaseManager.shared.updateDownloadPath(
                    id: recordId, path: outputURL.path,
                    fileSize: fileSize, status: "completed")
            } else {
                // 最终兜底：用 TS 文件
                try? FileManager.default.removeItem(at: outputURL)
                let tsOutput = downloadsDir.appendingPathComponent("\(safeName).ts")
                try? FileManager.default.moveItem(at: tempTSURL, to: tsOutput)
                let fileSize = (try? FileManager.default.attributesOfItem(
                    atPath: tsOutput.path)[.size] as? Int64) ?? 0
                DatabaseManager.shared.updateDownloadPath(
                    id: recordId, path: tsOutput.path,
                    fileSize: fileSize, status: "completed")
            }
            await MainActor.run { reloadActiveDownloads() }
        }
    }

    // MARK: - 暂停/继续/删除

    /// 暂停下载：取消 Task，标记状态为 paused
    func pauseDownload(id: Int) {
        downloadTasks[id]?.cancel()
        downloadTasks.removeValue(forKey: id)
        pausedDownloadIds.insert(id)
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "paused")
        reloadActiveDownloads()
        // 暂停后尝试启动队列中等待的任务
        startNextPending()
    }

    /// 继续下载：从数据库恢复记录，重新启动下载
    func resumeDownload(id: Int) {
        let records = DatabaseManager.shared.queryDownloads()
        guard let record = records.first(where: { $0.id == id }) else { return }
        pausedDownloadIds.remove(id)
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "pending")
        reloadActiveDownloads()
        if downloadTasks.count < maxConcurrent {
            startDownload(record: record)
        } else {
            pendingQueue.append(record)
        }
    }

    func cancelDownload(id: Int) {
        downloadTasks[id]?.cancel()
        downloadTasks.removeValue(forKey: id)
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "failed")
        reloadActiveDownloads()
    }

    func retryDownload(id: Int) {
        let records = DatabaseManager.shared.queryDownloads()
        guard let record = records.first(where: { $0.id == id }) else { return }
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "pending")
        DatabaseManager.shared.updateDownloadProgress(id: id, progress: 0, downloadedSize: 0, status: "pending")
        reloadActiveDownloads()
        startDownload(record: record)
    }

    func clearCompleted() {
        let records = DatabaseManager.shared.queryDownloads()
        for record in records where record.status == "completed" {
            if !record.filePath.isEmpty {
                try? FileManager.default.removeItem(atPath: record.filePath)
            }
            DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
        }
        reloadActiveDownloads()
    }

    // MARK: - 辅助方法

    private func isDirectMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let mediaExts = [".m3u8", ".mp4", ".mkv", ".flv", ".avi", ".mov", ".ts", ".m4a", ".mp3"]
        // 包含媒体扩展名，或者是 http(s) 开头且不含网盘域名
        if mediaExts.contains(where: { lower.contains($0) }) { return true }
        // 非网盘 URL 且是 http(s) 直链
        if lower.hasPrefix("http") {
            let cloudDomains = ["pan.baidu.com", "pan.quark.cn", "aliyundrive.com", "alipan.com",
                                "uc.cn", "ucloud.cn", "115.com", "123pan.com", "123cloud.cn",
                                "yun.139.com", "139.com", "cloud.189.cn", "189.cn",
                                "pan.xunlei.com"]
            if !cloudDomains.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func fetchString(url: String, headers: [String: String]) async -> String? {
        guard let fetchURL = URL(string: url) else { return nil }
        var request = URLRequest(url: fetchURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[DownloadManager] fetchString 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchData(url: String, headers: [String: String]) async -> Data? {
        guard let fetchURL = URL(string: url) else { return nil }
        var request = URLRequest(url: fetchURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            print("[DownloadManager] fetchData 失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - M3U8 解析辅助

    private func resolveMediaPlaylist(from content: String, baseURL: String) -> String {
        // 如果包含 #EXT-X-STREAM-INF（master playlist），取第一个子 playlist
        let lines = content.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            if line.contains("#EXT-X-STREAM-INF") {
                // 下一行是子 playlist URL
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    return resolveURL(nextLine, baseURL: baseURL)
                }
            }
        }
        return baseURL
    }

    private func parseTSSegments(from content: String, baseURL: String) -> [String] {
        var segments: [String] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            segments.append(resolveURL(trimmed, baseURL: baseURL))
        }
        return segments
    }

    private struct AESKeyInfo {
        let url: String?
        let iv: Data?
    }

    private func extractAESKeyInfo(from content: String, baseURL: String) -> AESKeyInfo? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("#EXT-X-KEY") {
                // 解析 URI="..." 和 IV=0x...
                var keyURL: String?
                var iv: Data?

                if let uriRange = line.range(of: "URI=\"") {
                    let start = uriRange.upperBound
                    if let endRange = line[start...].range(of: "\"") {
                        let uri = String(line[start..<endRange.lowerBound])
                        keyURL = resolveURL(uri, baseURL: baseURL)
                    }
                }

                if let ivRange = line.range(of: "IV=0x") {
                    let start = ivRange.upperBound
                    let hexStr = String(line[start...]).trimmingCharacters(in: .whitespaces)
                    if let data = dataFromHex(hexStr) {
                        iv = data
                    }
                }

                return AESKeyInfo(url: keyURL, iv: iv)
            }
        }
        return nil
    }

    private func resolveURL(_ relative: String, baseURL: String) -> String {
        if relative.hasPrefix("http://") || relative.hasPrefix("https://") {
            return relative
        }
        guard let base = URL(string: baseURL) else { return relative }
        if let resolved = URL(string: relative, relativeTo: base) {
            return resolved.absoluteString
        }
        return relative
    }

    private func dataFromHex(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(cleaned[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data.isEmpty ? nil : data
    }

    private func decryptTS(data: Data, key: Data, iv: Data) -> Data {
        // AES-128-CBC 一次性解密（每个 TS 分片独立解密）
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesWritten = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr -> CCCryptorStatus in
            data.withUnsafeBytes { dataPtr -> CCCryptorStatus in
                key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress!, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress!, data.count,
                            bufferPtr.baseAddress!, bufferSize,
                            &bytesWritten
                        )
                    }
                }
            }
        }

        if status == kCCSuccess && bytesWritten > 0 {
            return buffer.prefix(bytesWritten)
        }
        return data
    }

    private func mergeTSSegments(in tempDir: URL, to outputURL: URL) {
        // 简单合并：按序号拼接所有 TS 文件
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil) else { return }

        let sortedFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: outputURL) else { return }

        for file in sortedFiles {
            if let data = try? Data(contentsOf: file) {
                fileHandle.write(data)
            }
        }
        try? fileHandle.close()
    }

    /// 使用 AVMutableComposition 将 TS 分片逐个插入并导出为 MP4
    /// 这是 iOS 上最可靠的 TS→MP4 转换方式：AVFoundation 逐个解析分片，正确处理时间轴
    private func composeSegmentsToMP4(segmentsDir: URL, to mp4URL: URL) async -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: segmentsDir, includingPropertiesForKeys: nil) else {
            return false
        }

        let sortedFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sortedFiles.isEmpty else { return false }

        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            print("[DownloadManager] 无法创建 composition track")
            return false
        }

        var currentTime = CMTime.zero
        var hasVideo = false
        var hasAudio = false

        for file in sortedFiles {
            if Task.isCancelled { return false }

            let asset = AVAsset(url: file)

            // iOS 16+ async API
            let duration: CMTime
            let videoTracks: [AVAssetTrack]
            let audioTracks: [AVAssetTrack]

            do {
                duration = try await asset.load(.duration)
                videoTracks = try await asset.loadTracks(withMediaType: .video)
                audioTracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                print("[DownloadManager] 无法加载分片轨道: \(error.localizedDescription)")
                continue
            }

            let timeRange = CMTimeRange(start: .zero, duration: duration)

            if let vTrack = videoTracks.first {
                do {
                    try videoTrack.insertTimeRange(timeRange, of: vTrack, at: currentTime)
                    hasVideo = true
                } catch {
                    print("[DownloadManager] 视频轨道插入失败: \(error.localizedDescription)")
                }
            }

            if let aTrack = audioTracks.first {
                do {
                    try audioTrack.insertTimeRange(timeRange, of: aTrack, at: currentTime)
                    hasAudio = true
                } catch {
                    print("[DownloadManager] 音频轨道插入失败: \(error.localizedDescription)")
                }
            }

            currentTime = CMTimeAdd(currentTime, duration)
        }

        guard hasVideo else {
            print("[DownloadManager] 没有找到视频轨道，composition 失败")
            return false
        }

        // 导出为 MP4
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            // Passthrough 不支持时尝试 HighestQuality
            guard let exporter2 = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                return false
            }
            return await exportComposition(exporter: exporter2, to: mp4URL)
        }

        return await exportComposition(exporter: exporter, to: mp4URL)
    }

    /// 执行 AVAssetExportSession 导出
    private func exportComposition(exporter: AVAssetExportSession, to mp4URL: URL) async -> Bool {
        try? FileManager.default.removeItem(at: mp4URL)

        exporter.outputURL = mp4URL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true

        return await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                let success = exporter.status == .completed
                if !success {
                    print("[DownloadManager] Composition 导出失败: \(exporter.error?.localizedDescription ?? "unknown") status=\(exporter.status.rawValue)")
                }
                continuation.resume(returning: success)
            }
        }
    }

    /// 使用 AVMutableComposition 将单个 TS 文件转为 MP4
    /// 比 AVAssetExportSession 直接转更可靠：AVFoundation 正确解析 TS 容器
    private func convertTSToMP4ViaComposition(from tsURL: URL, to mp4URL: URL) async -> Bool {
        let asset = AVAsset(url: tsURL)

        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]

        do {
            duration = try await asset.load(.duration)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            print("[DownloadManager] 无法加载 TS 文件轨道: \(error.localizedDescription)")
            return false
        }

        guard !videoTracks.isEmpty else {
            print("[DownloadManager] TS 文件无视频轨道")
            return false
        }

        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return false
        }

        let compAudioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let timeRange = CMTimeRange(start: .zero, duration: duration)

        do {
            try compVideoTrack.insertTimeRange(timeRange, of: videoTracks.first!, at: .zero)
        } catch {
            print("[DownloadManager] 视频轨道插入失败: \(error.localizedDescription)")
            return false
        }

        if let aTrack = audioTracks.first, let compAudio = compAudioTrack {
            try? compAudio.insertTimeRange(timeRange, of: aTrack, at: .zero)
        }

        // 导出为 MP4
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            guard let exporter2 = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                return false
            }
            return await exportComposition(exporter: exporter2, to: mp4URL)
        }

        return await exportComposition(exporter: exporter, to: mp4URL)
    }

    /// 将合并后的 TS 文件转换为 MP4 格式
    /// 使用 Passthrough 预设（仅重封装不重编码），兼容性最好
    private func convertTSToMP4(from tsURL: URL, to mp4URL: URL) async -> Bool {
        let asset = AVAsset(url: tsURL)

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return false
        }

        // 如果目标文件已存在，先删除
        try? FileManager.default.removeItem(at: mp4URL)

        exporter.outputURL = mp4URL
        exporter.outputFileType = .mp4

        return await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                let success = exporter.status == .completed
                if !success {
                    print("[DownloadManager] TS→MP4 转码失败: \(exporter.error?.localizedDescription ?? "unknown")")
                }
                continuation.resume(returning: success)
            }
        }
    }

    private func dirSize(_ url: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var size: Int64 = 0
        for file in files {
            if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
}

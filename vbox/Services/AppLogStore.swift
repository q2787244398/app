//
//  AppLogStore.swift
//  vbox
//
//  统一应用日志系统
//  - 支持级别 (verbose/info/warn/error) + 模块分类
//  - 内存环形缓冲 + 异步持久化 (保留最近 3 天)
//  - 崩溃捕获 (信号处理器，崩溃前刷盘)
//  - 筛选 / 搜索 / 导出
//

import Foundation
import UIKit

// MARK: - 日志级别

@objc enum LogLevel: Int, CaseIterable, Comparable {
    case verbose = 0
    case info = 1
    case warn = 2
    case error = 3
    
    var displayName: String {
        switch self {
        case .verbose: return "详细"
        case .info:    return "信息"
        case .warn:    return "警告"
        case .error:   return "错误"
        }
    }
    
    var shortName: String {
        switch self {
        case .verbose: return "V"
        case .info:    return "I"
        case .warn:    return "W"
        case .error:   return "E"
        }
    }
    
    var icon: String {
        switch self {
        case .verbose: return "·"
        case .info:    return "ℹ"
        case .warn:    return "⚠"
        case .error:   return "✕"
        }
    }
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - 日志模块分类

@objc enum LogCategory: Int, CaseIterable {
    case app = 0
    case spider = 1
    case player = 2
    case cloud = 3
    case proxy = 4
    case network = 5
    case db = 6
    case download = 7
    case welfare = 8
    case node = 9
    case music = 10
    
    var displayName: String {
        switch self {
        case .app:      return "应用"
        case .spider:   return "爬虫"
        case .player:   return "播放器"
        case .cloud:    return "网盘"
        case .proxy:    return "代理"
        case .network:  return "网络"
        case .db:       return "数据库"
        case .download: return "下载"
        case .welfare:  return "福利区"
        case .node:     return "Node 常驻系统"
        case .music:    return "音乐"
        }
    }
    
    var codeName: String {
        switch self {
        case .app:      return "app"
        case .spider:   return "spider"
        case .player:   return "player"
        case .cloud:    return "cloud"
        case .proxy:    return "proxy"
        case .network:  return "network"
        case .db:       return "db"
        case .download: return "download"
        case .welfare:  return "welfare"
        case .node:     return "node"
        case .music:    return "music"
        }
    }
}

// MARK: - 日志条目

@objcMembers final class LogEntry: NSObject {
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let thread: String
    
    init(timestamp: Date = Date(), level: LogLevel, category: LogCategory, message: String, thread: String = "main") {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.thread = thread
        super.init()
    }
    
    /// 时间格式: HH:mm:ss.SSS
    var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: timestamp)
    }
    
    /// 完整日期格式: yyyy-MM-dd HH:mm:ss.SSS
    var fullTimeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return fmt.string(from: timestamp)
    }
    
    /// 日志行文本 (用于写入文件 / 导出)
    var logLine: String {
        "[\(fullTimeString)] [\(level.shortName)] [\(category.codeName)] [\(thread)] \(message)"
    }
}

// MARK: - AppLogStore

@objc
final class AppLogStore: NSObject, ObservableObject {
    
    // MARK: - 单例
    
    static let shared = AppLogStore()
    
    // MARK: - 配置
    
    /// 内存最大条数 (环形缓冲)
    private let maxMemoryEntries = 5000
    
    /// 持久化保留天数
    private let persistDays = 1
    
    /// 刷盘间隔 (秒)
    private let flushInterval: TimeInterval = 10
    
    /// 最低记录级别 (低于此级别的日志直接丢弃)
    var minLevel: LogLevel = .info {
        didSet {
            UserDefaults.standard.set(minLevel.rawValue, forKey: Self.minLevelKey)
            configLock.lock()
            logMinLevel = minLevel
            configLock.unlock()
            notifyUI()
        }
    }
    
    /// 总开关
    var enabled: Bool = false {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            configLock.lock()
            logEnabled = enabled
            configLock.unlock()
            if enabled {
                startFlushTimer()
                logAppLifecycle("日志记录已开启")
            } else {
                stopFlushTimer()
                logAppLifecycle("日志记录已关闭")
                flushToDisk()
            }
            notifyUI()
        }
    }
    
    /// 上次是否异常退出 (启动时检测)
    var lastRunCrashed = false {
        didSet { notifyUI() }
    }
    
    // MARK: - 存储
    
    /// 内存中的日志 (最新的在末尾)
    private var entries: [LogEntry] = []
    
    /// 待写入文件的缓冲
    private var pendingLines: [String] = []
    
    /// 后台串行队列 (写文件用)
    private let ioQueue = DispatchQueue(label: "com.vbox.applog.io", qos: .utility)
    
    /// 刷盘定时器
    private var flushTimer: Timer?
    
    /// 锁 (保护 entries / pendingLines)
    private let lock = NSLock()
    
    /// 配置锁 (保护 logEnabled / logMinLevel，供任意线程读取)
    private let configLock = NSLock()
    private var logEnabled: Bool = false
    private var logMinLevel: LogLevel = .info
    
    // MARK: - UI 通知
    
    private func notifyUI() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    // MARK: - 文件路径
    
    private var logsDirectory: URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDir = docs.appendingPathComponent("AppLogs", isDirectory: true)
        if !fm.fileExists(atPath: logsDir.path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir
    }
    
    private func logFileURL(for date: Date = Date()) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let fileName = "\(fmt.string(from: date)).log"
        return logsDirectory.appendingPathComponent(fileName)
    }
    
    // MARK: - UserDefaults Keys
    
    private static let enabledKey = "app_log_enabled"
    private static let minLevelKey = "app_log_min_level"
    private static let crashMarkerKey = "app_log_crash_marker"
    
    // MARK: - 初始化
    
    private override init() {
        let savedEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        let savedLevelRaw = UserDefaults.standard.integer(forKey: Self.minLevelKey)
        let savedLevel = LogLevel(rawValue: savedLevelRaw) ?? .info
        
        // 先检查崩溃标记
        self.lastRunCrashed = UserDefaults.standard.bool(forKey: Self.crashMarkerKey)
        if self.lastRunCrashed {
            // 清除标记
            UserDefaults.standard.removeObject(forKey: Self.crashMarkerKey)
            UserDefaults.standard.synchronize()
        }
        
        self.enabled = savedEnabled
        self.minLevel = savedLevel

        super.init()

        // Phase 1 期间 didSet 不会触发，手动同步内部缓存
        self.logEnabled = savedEnabled
        self.logMinLevel = savedLevel

        if savedEnabled {
            // 启动时加载今天的历史日志到内存
            loadTodayLogsFromDisk()
            startFlushTimer()
            installCrashHandler()
            logAppLifecycle("应用启动，日志系统就绪")
        }
        
        // 监听 ObjC 桥接的日志通知 (PythonBridge 等)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppLogBridgeDidAddLogNotification"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let info = note.userInfo,
                  let levelRaw = info["level"] as? Int,
                  let catRaw = info["category"] as? Int,
                  let message = info["message"] as? String,
                  let level = LogLevel(rawValue: levelRaw),
                  let category = LogCategory(rawValue: catRaw) else { return }
            
            let thread = info["thread"] as? String ?? "bg"
            let ts = info["timestamp"] as? Date ?? Date()
            
            let entry = LogEntry(timestamp: ts, level: level, category: category, message: message, thread: thread)
            
            guard self.isEnabled() else { return }
            guard level >= self.currentMinLevel() else { return }
            
            self.lock.lock()
            self.entries.append(entry)
            self.pendingLines.append(entry.logLine)
            if self.entries.count > self.maxMemoryEntries {
                self.entries.removeFirst(self.entries.count - self.maxMemoryEntries)
            }
            self.lock.unlock()
            
            self.objectWillChange.send()
        }
    }
    
    // MARK: - 公共 API
    
    /// 记录一条日志 (线程安全，可从任意线程调用)
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        // 快速检查配置 (用配置锁)
        configLock.lock()
        let en = logEnabled
        let minLvl = logMinLevel
        configLock.unlock()
        
        guard en else { return }
        guard level >= minLvl else { return }
        
        let thread = Thread.isMainThread ? "main" : "bg"
        let entry = LogEntry(level: level, category: category, message: message, thread: thread)
        
        lock.lock()
        entries.append(entry)
        pendingLines.append(entry.logLine)
        
        // 环形缓冲
        if entries.count > maxMemoryEntries {
            entries.removeFirst(entries.count - maxMemoryEntries)
        }
        lock.unlock()
        
        // 通知 UI 更新 (主线程)
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    // 便捷方法 (线程安全)
    func verbose(_ category: LogCategory, _ message: String) {
        log(.verbose, category, message)
    }
    
    func info(_ category: LogCategory, _ message: String) {
        log(.info, category, message)
    }
    
    func warn(_ category: LogCategory, _ message: String) {
        log(.warn, category, message)
    }
    
    func error(_ category: LogCategory, _ message: String) {
        log(.error, category, message)
    }
    
    /// 线程安全地读取当前是否开启 (供非主线程调用)
    func isEnabled() -> Bool {
        configLock.lock()
        let val = logEnabled
        configLock.unlock()
        return val
    }
    
    /// 线程安全地读取当前最低级别 (供非主线程调用)
    func currentMinLevel() -> LogLevel {
        configLock.lock()
        let val = logMinLevel
        configLock.unlock()
        return val
    }
    
    /// 当前日志条数
    var count: Int {
        lock.lock()
        let c = entries.count
        lock.unlock()
        return c
    }
    
    /// 获取全部日志 (最新的在末尾)
    func allEntries() -> [LogEntry] {
        lock.lock()
        let copy = entries
        lock.unlock()
        return copy
    }
    
    /// 筛选日志
    func filterEntries(level: LogLevel? = nil, category: LogCategory? = nil, keyword: String? = nil) -> [LogEntry] {
        lock.lock()
        let copy = entries
        lock.unlock()
        
        return copy.filter { entry in
            if let level, entry.level < level { return false }
            if let category, entry.category != category { return false }
            if let kw = keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
               !kw.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(kw) {
                return false
            }
            return true
        }
    }
    
    /// 清空内存日志 (不删磁盘文件)
    func clearMemory() {
        lock.lock()
        entries.removeAll()
        pendingLines.removeAll()
        lock.unlock()
        notifyUI()
    }
    
    /// 清空所有日志 (内存 + 磁盘)
    func clearAll() {
        lock.lock()
        entries.removeAll()
        pendingLines.removeAll()
        lock.unlock()
        
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let dir = self.logsDirectory
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "log" {
                    try? fm.removeItem(at: file)
                }
            }
        }
        
        notifyUI()
    }
    
    // MARK: - 导出
    
    /// 导出全部日志 (zip 包，按模块分文件)
    /// 返回 zip 文件路径
    func exportAll() -> URL? {
        let all = allEntries()
        guard !all.isEmpty else { return nil }
        
        // 按模块分组
        var grouped: [String: [LogEntry]] = [:]
        for entry in all {
            let key = entry.category.codeName
            if grouped[key] == nil { grouped[key] = [] }
            grouped[key]?.append(entry)
        }
        
        let fm = FileManager.default
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applog_export_\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            
            // 写每个模块的 txt
            for (catCode, catEntries) in grouped {
                let content = catEntries.map { $0.logLine }.joined(separator: "\n")
                let fileURL = tmpDir.appendingPathComponent("\(catCode).txt")
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            
            // 也写一个汇总文件
            let allContent = all.map { $0.logLine }.joined(separator: "\n")
            let allURL = tmpDir.appendingPathComponent("all.txt")
            try allContent.write(to: allURL, atomically: true, encoding: .utf8)
            
            // 打包 zip
            let zipURL = logsDirectory.appendingPathComponent("logs_export.zip")
            try? fm.removeItem(at: zipURL)
            
            let coordinator = NSFileCoordinator()
            var error: NSError?
            var success = false
            
            coordinator.coordinate(readingItemAt: tmpDir, options: .forUploading, error: &error) { zipItemURL in
                do {
                    try fm.copyItem(at: zipItemURL, to: zipURL)
                    success = true
                } catch {
                    print("AppLogStore: zip copy failed - \(error)")
                }
            }
            
            // 清理临时目录
            try? fm.removeItem(at: tmpDir)
            
            return success ? zipURL : nil
        } catch {
            print("AppLogStore: export failed - \(error)")
            return nil
        }
    }
    
    /// 导出筛选后的日志 (单个 txt)
    func exportFiltered(level: LogLevel? = nil, category: LogCategory? = nil, keyword: String? = nil) -> URL? {
        let filtered = filterEntries(level: level, category: category, keyword: keyword)
        guard !filtered.isEmpty else { return nil }
        
        let content = filtered.map { $0.logLine }.joined(separator: "\n")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "logs_\(fmt.string(from: Date())).txt"
        let fileURL = logsDirectory.appendingPathComponent(fileName)
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }
    
    // MARK: - 持久化
    
    private func startFlushTimer() {
        stopFlushTimer()
        DispatchQueue.main.async {
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flushToDisk()
            }
        }
    }
    
    private func stopFlushTimer() {
        DispatchQueue.main.async {
            self.flushTimer?.invalidate()
            self.flushTimer = nil
        }
    }
    
    /// 把待写入的日志行追加到当天日志文件
    private func flushToDisk() {
        lock.lock()
        let lines = pendingLines
        pendingLines.removeAll()
        lock.unlock()
        
        guard !lines.isEmpty else { return }
        
        let content = lines.joined(separator: "\n") + "\n"
        let fileURL = logFileURL()
        
        ioQueue.async {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                // 追加
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    if let data = content.data(using: .utf8) {
                        handle.write(data)
                    }
                    handle.closeFile()
                }
            } else {
                // 新建
                try? content.write(to: fileURL, atomically: true, encoding: .utf8)
            }
            
            // 清理过期日志文件
            self.cleanupOldLogs()
        }
    }
    
    /// 加载今天的日志到内存 (启动时调用)
    private func loadTodayLogsFromDisk() {
        let fileURL = logFileURL()
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8),
              !content.isEmpty else { return }
        
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        // 最多加载最后 maxMemoryEntries 条
        let recentLines = Array(lines.suffix(maxMemoryEntries))
        
        var parsed: [LogEntry] = []
        for line in recentLines {
            if let entry = parseLogLine(line) {
                parsed.append(entry)
            }
        }
        
        lock.lock()
        entries = parsed
        lock.unlock()
    }
    
    /// 解析日志行文本 -> LogEntry
    private func parseLogLine(_ line: String) -> LogEntry? {
        // 格式: [2026-08-30 14:23:05.123] [I] [spider] [main] message...
        let pattern = #"^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] \[([VIWE])\] \[(\w+)\] \[(\w+)\] (.*)$"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 6 else { return nil }
        
        let nsLine = line as NSString
        
        guard let tsRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let catRange = Range(match.range(at: 3), in: line),
              let threadRange = Range(match.range(at: 4), in: line),
              let msgRange = Range(match.range(at: 5), in: line) else { return nil }
        
        let tsStr = String(line[tsRange])
        let levelStr = String(line[levelRange])
        let catStr = String(line[catRange])
        let threadStr = String(line[threadRange])
        let msgStr = String(line[msgRange])
        
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        guard let ts = fmt.date(from: tsStr) else { return nil }
        
        let level: LogLevel
        switch levelStr {
        case "V": level = .verbose
        case "I": level = .info
        case "W": level = .warn
        case "E": level = .error
        default: return nil
        }
        
        let category: LogCategory
        switch catStr {
        case "app":      category = .app
        case "spider":   category = .spider
        case "player":   category = .player
        case "cloud":    category = .cloud
        case "proxy":    category = .proxy
        case "network":  category = .network
        case "db":       category = .db
        case "download": category = .download
        case "welfare":  category = .welfare
        case "node":     category = .node
        case "music":    category = .music
        default:         return nil
        }
        
        let entry = LogEntry(timestamp: ts, level: level, category: category, message: msgStr, thread: threadStr)
        return entry
    }
    
    /// 清理 N 天前的日志文件
    private func cleanupOldLogs() {
        let fm = FileManager.default
        let dir = logsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -persistDays, to: Date()) ?? Date.distantPast
        
        for file in files where file.pathExtension == "log" {
            let fileName = file.deletingPathExtension().lastPathComponent
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            if let fileDate = fmt.date(from: fileName), fileDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
    
    // MARK: - 崩溃捕获
    
    private func installCrashHandler() {
        // 设置崩溃标记 (启动时写入，正常退出时清除)
        UserDefaults.standard.set(true, forKey: Self.crashMarkerKey)
        UserDefaults.standard.synchronize()
        
        // 注册信号处理器
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig) { sigNum in
                // 崩溃时立即刷盘
                AppLogStore.handleCrash(signal: sigNum)
                // 重新触发默认处理 (让 App 真正退出)
                signal(sigNum, SIG_DFL)
                raise(sigNum)
            }
        }
        
        // 监听正常退出通知
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 正常退出，清除崩溃标记
            UserDefaults.standard.removeObject(forKey: Self.crashMarkerKey)
            UserDefaults.standard.synchronize()
            // 最后刷一次盘
            self.flushToDisk()
        }
    }
    
    /// 崩溃时的处理 (C 函数，只能做最基础的操作)
    private static func handleCrash(signal: Int32) {
        // 这里不能用 Swift 的类方法/属性太多，直接通过 shared 刷盘
        // 简化：把 pendingLines 写到崩溃日志文件
        let store = AppLogStore.shared
        
        store.lock.lock()
        let lines = store.pendingLines
        store.pendingLines.removeAll()
        store.lock.unlock()
        
        guard !lines.isEmpty else { return }
        
        let content = lines.joined(separator: "\n") + "\n" + "--- CRASH (signal \(signal)) ---\n"
        
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let crashFile = docs.appendingPathComponent("AppLogs/crash.log")
        
        if fm.fileExists(atPath: crashFile.path) {
            if let handle = try? FileHandle(forWritingTo: crashFile) {
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
        } else {
            try? content.write(to: crashFile, atomically: true, encoding: .utf8)
        }
    }
    
    // MARK: - 内部便捷方法
    
    private func logAppLifecycle(_ message: String) {
        log(.info, .app, message)
    }
}

// MARK: - 便捷全局函数 (方便各处调用，线程安全)

func AppLogVerbose(_ category: LogCategory, _ message: String) {
    AppLogStore.shared.verbose(category, message)
}

func AppLogInfo(_ category: LogCategory, _ message: String) {
    AppLogStore.shared.info(category, message)
}

func AppLogWarn(_ category: LogCategory, _ message: String) {
    AppLogStore.shared.warn(category, message)
}

func AppLogError(_ category: LogCategory, _ message: String) {
    AppLogStore.shared.error(category, message)
}

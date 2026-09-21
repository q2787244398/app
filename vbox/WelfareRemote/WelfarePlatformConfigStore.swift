//
//  WelfarePlatformConfigStore.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：福利平台远程配置的全局仓库。
//        - 单例 WelfarePlatformConfigStore.shared
//        - 内存缓存 + 磁盘缓存（JSON 文件存到 Documents/remote_sources/welfare_platforms.json）
//        - 顶部 Toggle 开关状态持久化（默认开）
//        - 与 RemoteSourceConfigManager 协同：监听其 loadState
//        - 不修改 RemoteSourceConfigManager / AppSettings / WelfareSettingsView 任何代码
//
//  使用示例：
//    let store = WelfarePlatformConfigStore.shared
//    store.bootstrap()                // App 启动时调用
//    store.refresh { result in ... }  // 手动刷新
//    let platforms = store.platforms(in: .video)
//

import Foundation
import Combine
import SwiftUI

// MARK: - 仓库加载状态

/// 配置仓库的加载状态
enum WelfareConfigLoadState: Equatable {
    case idle                    // 未启动
    case loading                 // 加载中
    case loaded(platformCount: Int, version: String?)   // 成功
    case failed(message: String) // 失败
}

// MARK: - 开关默认值

/// 福利远程源 Toggle 默认值（默认开 = 使用远程源）
/// 关闭时：UI 隐藏远程平台列表，复用现有 WelfareHomeView（内置资源）
enum WelfareRemoteSourceSwitch {
    static let `default`: Bool = true
}

// MARK: - UserDefaults Keys

/// 独立命名空间，不与现有 key 冲突
private enum WelfareRemoteDefaultsKey {
    /// 顶部 Toggle 状态
    static let switchEnabled = "fuli_remote_source_enabled"
    /// 最后成功加载时间
    static let lastSuccessTime = "fuli_remote_source_last_success_time"
    /// 最后一次已知配置版本号
    static let lastConfigVersion = "fuli_remote_source_last_config_version"
}

// MARK: - 仓库主类

@MainActor
final class WelfarePlatformConfigStore: ObservableObject {

    // MARK: 单例

    static let shared = WelfarePlatformConfigStore()

    private init() {
        // 从 UserDefaults 恢复开关状态
        if UserDefaults.standard.object(forKey: WelfareRemoteDefaultsKey.switchEnabled) == nil {
            self.switchEnabled = WelfareRemoteSourceSwitch.default
        } else {
            self.switchEnabled = UserDefaults.standard.bool(forKey: WelfareRemoteDefaultsKey.switchEnabled)
        }
    }

    // MARK: 发布属性

    /// 顶部 Toggle：是否启用福利远程源（默认开）
    @Published var switchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(switchEnabled, forKey: WelfareRemoteDefaultsKey.switchEnabled)
        }
    }

    /// 当前加载状态
    @Published private(set) var loadState: WelfareConfigLoadState = .idle

    /// 内存中的配置（加载成功后填充）
    @Published private(set) var config: WelfarePlatformConfig?

    /// 最后成功加载时间
    @Published private(set) var lastSuccessTime: Date? = {
        let t = UserDefaults.standard.object(forKey: WelfareRemoteDefaultsKey.lastSuccessTime) as? Date
        return t
    }()

    // MARK: 内部状态

    private var bootstrapped = false
    private var inFlightTask: Task<Void, Never>?

    // MARK: - 公开 API

    /// App 启动时调用一次，幂等
    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        // 1. 先尝试从磁盘缓存恢复
        loadFromDiskCache()

        // 2. 触发后台刷新（不阻塞启动）
        Task { await self.refreshAsync() }
    }

    /// 主动刷新（用户点击刷新按钮或解锁后调用）
    /// - Parameter completion: 主线程回调
    func refresh(completion: ((Result<Int, Error>) -> Void)? = nil) {
        inFlightTask?.cancel()
        inFlightTask = Task { [weak self] in
            guard let self = self else { return }
            let result = await self.refreshAsync()
            await MainActor.run {
                switch result {
                case .success(let count):
                    completion?(.success(count))
                case .failure(let error):
                    completion?(.failure(error))
                }
            }
        }
    }

    /// 异步刷新
    @discardableResult
    func refreshAsync() async -> Result<Int, Error> {
        await MainActor.run { self.loadState = .loading }

        // 1. 从远端拉取 welfare_platforms.json
        //    优先走 RemoteSourceConfigManager 的 allSources 缓存（一次请求拿到全部数据）
        //    失败再回退到直接拉 welfarePlatforms URL
        do {
            let config = try await fetchWelfarePlatformConfig()
            await MainActor.run {
                self.config = config
                let count = config.platforms.count
                self.loadState = .loaded(platformCount: count, version: config.meta?.version)
                self.lastSuccessTime = Date()
                UserDefaults.standard.set(self.lastSuccessTime, forKey: WelfareRemoteDefaultsKey.lastSuccessTime)
                UserDefaults.standard.set(config.meta?.version, forKey: WelfareRemoteDefaultsKey.lastConfigVersion)
                self.saveToDiskCache(jsonData: config)
                print("[WelfareRemote] 福利远程源加载成功：\(count) 个平台，version=\(config.meta?.version ?? "nil")")
            }
            return .success(config.platforms.count)
        } catch {
            await MainActor.run {
                self.loadState = .failed(message: error.localizedDescription)
                print("[WelfareRemote] 福利远程源加载失败：\(error.localizedDescription)")
            }
            return .failure(error)
        }
    }

    // MARK: - 查询 API

    /// 获取指定分类下的所有平台（按 sortOrder 升序）
    func platforms(in category: RemoteWelfareCategory) -> [WelfarePlatform] {
        guard let config = config else { return [] }
        return config.platforms
            .filter { $0.category == category.rawValue }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 获取指定 platformKey 的平台元数据
    func platform(forKey key: String) -> WelfarePlatform? {
        guard let config = config else { return nil }
        return config.platforms.first { $0.platformKey == key }
    }

    /// 所有平台总数
    var totalPlatformCount: Int {
        config?.platforms.count ?? 0
    }

    // MARK: - 私有：远端拉取

    /// 拉取福利平台配置
    /// 策略：
    ///   1. 优先尝试从 RemoteSourceConfigManager 的缓存文件中读取（已包含 welfarePlatforms 字段）
    ///   2. 失败回退到直接拉取 manifest 中的 welfarePlatforms URL
    private func fetchWelfarePlatformConfig() async throws -> WelfarePlatformConfig {
        // 策略 1：从 RemoteSourceConfigManager 缓存的 all_sources.json 提取
        if let config = try? await fetchFromAllSourcesCache() {
            return config
        }

        // 策略 2：直接拉取 welfare_platforms.json
        return try await fetchFromDirectURL()
    }

    /// 策略 1：读 Documents/remote_sources/all_sources.json 中的 welfarePlatforms 字段
    private func fetchFromAllSourcesCache() async throws -> WelfarePlatformConfig {
        let cacheURL = cacheDirectory.appendingPathComponent("all_sources.json")
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            throw NSError(
                domain: "WelfareRemote", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "all_sources.json 缓存不存在"]
            )
        }
        let data = try Data(contentsOf: cacheURL)

        // 用 JSONSerialization 直接提取 welfarePlatforms 字段，避免 AnyCodable 冲突
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wpObject = json["welfarePlatforms"] else {
            throw NSError(
                domain: "WelfareRemote", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "all_sources.json 中无 welfarePlatforms 字段"]
            )
        }
        let wpData = try JSONSerialization.data(withJSONObject: wpObject, options: [])
        return try JSONDecoder().decode(WelfarePlatformConfig.self, from: wpData)
    }

    /// 策略 2：直接拉 manifest 中的 welfarePlatforms URL
    private func fetchFromDirectURL() async throws -> WelfarePlatformConfig {
        // 1. 拉 manifest（使用用户可配置的默认源地址，而非内置静态常量）
        let manifestURL = URL(string: RemoteSourceConfigManager.shared.defaultManifestURL)!
        let manifestData = try await fetchData(from: manifestURL)

        struct Manifest: Decodable {
            struct Files: Decodable {
                let welfarePlatforms: String?
            }
            let files: Files
        }

        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard let wpURLString = manifest.files.welfarePlatforms,
              let wpURL = URL(string: wpURLString) else {
            throw NSError(
                domain: "WelfareRemote", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "manifest 中未配置 welfarePlatforms URL"]
            )
        }

        // 2. 拉 welfare_platforms.json
        let wpData = try await fetchData(from: wpURL)
        return try JSONDecoder().decode(WelfarePlatformConfig.self, from: wpData)
    }

    /// 通用 GET 请求（15s timeout，失败时按 RemoteSourceConfigManager 的代理链回退）
    private func fetchData(from url: URL) async throws -> Data {
        var lastError: Error?

        // 构造候选 URL 列表（与 RemoteSourceConfigManager 的代理链一致：ghfast.top → gh-proxy.com → 直连）
        let candidates = proxyCandidateURLs(for: url)

        for candidate in candidates {
            do {
                var req = URLRequest(url: candidate, timeoutInterval: 15)
                req.setValue("Dart/3.4 (dart:io)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode) else {
                    throw NSError(
                        domain: "WelfareRemote", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(response)"]
                    )
                }
                return data
            } catch {
                lastError = error
                print("[WelfareRemote] 拉取失败 \(candidate.absoluteString)：\(error.localizedDescription)，尝试下一个")
                continue
            }
        }

        throw lastError ?? NSError(
            domain: "WelfareRemote", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "所有代理 URL 均失败"]
        )
    }

    /// 构造代理候选 URL 列表
    /// - 远端 URL 如果是 github.io / raw.githubusercontent.com，则尝试 ghfast.top / gh-proxy.com
    /// - 否则直接返回原 URL
    private func proxyCandidateURLs(for url: URL) -> [URL] {
        let original = url.absoluteString
        guard let host = url.host,
              host.contains("github.io") || host.contains("githubusercontent.com") else {
            return [url]
        }
        var candidates: [URL] = []
        // 代理 1：ghfast.top
        if let u = URL(string: "https://ghfast.top/" + original) {
            candidates.append(u)
        }
        // 代理 2：gh-proxy.com
        if let u = URL(string: "https://gh-proxy.com/" + original) {
            candidates.append(u)
        }
        // 直连
        candidates.append(url)
        return candidates
    }

    // MARK: - 私有：磁盘缓存

    /// Documents/remote_sources/ 目录
    private var cacheDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("remote_sources", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 缓存文件名
    private var cacheFileURL: URL {
        cacheDirectory.appendingPathComponent("welfare_platforms.json")
    }

    /// 加载磁盘缓存
    private func loadFromDiskCache() {
        let url = cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return
        }
        do {
            let cfg = try JSONDecoder().decode(WelfarePlatformConfig.self, from: data)
            self.config = cfg
            self.loadState = .loaded(platformCount: cfg.platforms.count, version: cfg.meta?.version)
            print("[WelfareRemote] 从磁盘缓存恢复：\(cfg.platforms.count) 个平台")
        } catch {
            print("[WelfareRemote] 磁盘缓存解析失败：\(error.localizedDescription)")
        }
    }

    /// 保存到磁盘缓存
    private func saveToDiskCache(jsonData: WelfarePlatformConfig) {
        do {
            let data = try JSONEncoder().encode(jsonData)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            print("[WelfareRemote] 写入磁盘缓存失败：\(error.localizedDescription)")
        }
    }

    /// 清空所有缓存（调试用）
    func clearAllCache() {
        try? FileManager.default.removeItem(at: cacheFileURL)
        self.config = nil
        self.loadState = .idle
        self.lastSuccessTime = nil
    }
}


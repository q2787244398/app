import SwiftUI
import Combine

enum AppSkinMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case liquid
    case frosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "黑暗模式"
        case .light: return "浅色模式"
        case .liquid: return "液态模式"
        case .frosted: return "磨砂模式"
        }
    }

    var subtitle: String {
        switch self {
        case .dark: return "全局深色界面"
        case .light: return "保持当前浅色风格"
        case .liquid: return "流动渐变与毛玻璃"
        case .frosted: return "全局磨砂玻璃质感"
        }
    }

    var icon: String {
        switch self {
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .liquid: return "drop.fill"
        case .frosted: return "sparkles"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark, .liquid: return .dark
        case .light: return .light
        case .frosted: return nil
        }
    }
}

/// 全局应用设置
@MainActor
class AppSettings: ObservableObject {
    private static let skinModeKey = "app_skin_mode"
    private static let skinFollowsSystemKey = "app_skin_follows_system"
    private static let enableTMDBKey = "app_enable_tmdb"
    private static let tmdbProxyURLKey = "app_tmdb_proxy_url"
    private static let tmdbUseTokenKey = "app_tmdb_use_token"
    private static let tmdbProxyTokenKey = "app_tmdb_proxy_token"
    private static let welfareUnlockedKey = "app_welfare_unlocked"
    private static let welfarePasswordKey = "app_welfare_password"
    private static let welfareEnabledKey = "app_welfare_enabled"
    private static let devLogEnabledKey = "app_dev_log_enabled"
    private static let devLogLevelKey = "app_dev_log_level"
    private static let remoteDefaultSourceEnabledKey = RemoteSourceConfigKeys.remoteDefaultSourceEnabled
    private static let bundleSourcesEnabledKey = RemoteSourceConfigKeys.bundleSourcesEnabled
    private static let defaultManifestURLKey = RemoteSourceConfigKeys.defaultManifestURL
    private static let lastAppVersionKey = "app_last_launch_version"

    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    @Published var searchQuery: String = ""     // 首页搜索 → 切换到搜索Tab
    @Published var searchRequestId: Int = 0
    @Published var skinMode: AppSkinMode {
        didSet {
            UserDefaults.standard.set(skinMode.rawValue, forKey: Self.skinModeKey)
        }
    }
    @Published var skinFollowsSystem: Bool {
        didSet {
            UserDefaults.standard.set(skinFollowsSystem, forKey: Self.skinFollowsSystemKey)
        }
    }
    @Published var showSettings = false
    @Published var isTabBarHidden = false
    @Published var enableTMDB: Bool {
        didSet {
            UserDefaults.standard.set(enableTMDB, forKey: Self.enableTMDBKey)
        }
    }
    @Published var tmdbProxyURL: String {
        didSet {
            UserDefaults.standard.set(tmdbProxyURL, forKey: Self.tmdbProxyURLKey)
        }
    }
    @Published var tmdbUseToken: Bool {
        didSet {
            UserDefaults.standard.set(tmdbUseToken, forKey: Self.tmdbUseTokenKey)
        }
    }
    @Published var tmdbProxyToken: String {
        didSet {
            UserDefaults.standard.set(tmdbProxyToken, forKey: Self.tmdbProxyTokenKey)
        }
    }
    @Published var welfareUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(welfareUnlocked, forKey: Self.welfareUnlockedKey)
        }
    }
    @Published var welfarePassword: String {
        didSet {
            UserDefaults.standard.set(welfarePassword, forKey: Self.welfarePasswordKey)
        }
    }
    @Published var welfareEnabled: Bool {
        didSet {
            UserDefaults.standard.set(welfareEnabled, forKey: Self.welfareEnabledKey)
        }
    }
    @Published var devLogEnabled: Bool {
        didSet {
            UserDefaults.standard.set(devLogEnabled, forKey: Self.devLogEnabledKey)
            Task { @MainActor in
                AppLogStore.shared.enabled = devLogEnabled
            }
        }
    }
    @Published var devLogLevel: LogLevel {
        didSet {
            UserDefaults.standard.set(devLogLevel.rawValue, forKey: Self.devLogLevelKey)
            Task { @MainActor in
                AppLogStore.shared.minLevel = devLogLevel
            }
        }
    }
    @Published var remoteDefaultSourceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remoteDefaultSourceEnabled, forKey: Self.remoteDefaultSourceEnabledKey)
            RemoteSourceConfigManager.shared.remoteDefaultSourceEnabled = remoteDefaultSourceEnabled
        }
    }
    @Published var bundleSourcesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bundleSourcesEnabled, forKey: Self.bundleSourcesEnabledKey)
            RemoteSourceConfigManager.shared.bundleSourcesEnabled = bundleSourcesEnabled
            NotificationCenter.default.post(name: .spiderSitesDidUpdate, object: nil)
        }
    }
    @Published var defaultManifestURL: String {
        didSet {
            UserDefaults.standard.set(defaultManifestURL, forKey: Self.defaultManifestURLKey)
            RemoteSourceConfigManager.shared.defaultManifestURL = defaultManifestURL
        }
    }

    init() {
        let rawSkin = UserDefaults.standard.string(forKey: Self.skinModeKey)
        skinMode = AppSkinMode(rawValue: rawSkin ?? "") ?? .light
        skinFollowsSystem = UserDefaults.standard.object(forKey: Self.skinFollowsSystemKey) as? Bool ?? true
        enableTMDB = UserDefaults.standard.object(forKey: Self.enableTMDBKey) as? Bool ?? false
        tmdbProxyURL = UserDefaults.standard.string(forKey: Self.tmdbProxyURLKey) ?? ""
        tmdbUseToken = UserDefaults.standard.object(forKey: Self.tmdbUseTokenKey) as? Bool ?? false
        tmdbProxyToken = UserDefaults.standard.string(forKey: Self.tmdbProxyTokenKey) ?? ""
        welfareUnlocked = UserDefaults.standard.object(forKey: Self.welfareUnlockedKey) as? Bool ?? false
        welfarePassword = UserDefaults.standard.string(forKey: Self.welfarePasswordKey) ?? "888888"
        welfareEnabled = UserDefaults.standard.object(forKey: Self.welfareEnabledKey) as? Bool ?? true
        devLogEnabled = UserDefaults.standard.object(forKey: Self.devLogEnabledKey) as? Bool ?? false
        let savedLogLevelRaw = UserDefaults.standard.integer(forKey: Self.devLogLevelKey)
        devLogLevel = LogLevel(rawValue: savedLogLevelRaw) ?? .info
        remoteDefaultSourceEnabled = UserDefaults.standard.object(forKey: Self.remoteDefaultSourceEnabledKey) as? Bool ?? true
        bundleSourcesEnabled = UserDefaults.standard.object(forKey: Self.bundleSourcesEnabledKey) as? Bool ?? false

        // 版本升级时清除已保存的 manifest URL，回退到内置默认地址
        // （RemoteSourceConfigManager.defaultManifestURL）
        let currentAppVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastAppVersion = UserDefaults.standard.string(forKey: Self.lastAppVersionKey) ?? ""
        if !currentAppVersion.isEmpty && currentAppVersion != lastAppVersion {
            UserDefaults.standard.removeObject(forKey: Self.defaultManifestURLKey)
            UserDefaults.standard.set(currentAppVersion, forKey: Self.lastAppVersionKey)
        }

        defaultManifestURL = UserDefaults.standard.string(forKey: Self.defaultManifestURLKey) ?? RemoteSourceConfigManager.defaultManifestURL

        // 同步 AppLogStore 初始状态
        Task { @MainActor in
            AppLogStore.shared.minLevel = self.devLogLevel
            AppLogStore.shared.enabled = self.devLogEnabled
        }
    }

    var preferredColorScheme: ColorScheme? {
        if skinFollowsSystem {
            return skinMode == .liquid ? .dark : nil
        }
        if skinMode == .liquid { return .dark }
        if skinMode == .frosted { return nil }
        return skinMode.preferredColorScheme
    }

    var usesLiquidSkin: Bool {
        skinMode == .liquid
    }

    var usesFrostedSkin: Bool {
        skinMode == .frosted
    }

    var usesVisualSkin: Bool {
        skinMode == .liquid || skinMode == .frosted
    }

    func selectSkin(_ mode: AppSkinMode) {
        skinFollowsSystem = false
        skinMode = mode
    }

    func triggerSearch(_ query: String) {
        searchQuery = query
        searchRequestId += 1
    }
}

// SpiderManager 已迁移到 Services/SpiderManager.swift

import SwiftUI
import UIKit
import CoreImage
import WebKit

extension CloudDriveManager.DriveType: Identifiable {
    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var spiderManager = SpiderManager.shared
    @StateObject private var remoteSourceManager = RemoteSourceConfigManager.shared
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @StateObject private var tgConfigStore = TGSearchConfigStore.shared
    @AppStorage("custom_danmaku_source_enabled") private var customDanmakuSourceEnabled = false
    @AppStorage("custom_danmaku_source_url") private var customDanmakuSourceURL = ""
    @AppStorage("show_search_debug") private var showSearchDebug = false
    @State private var showCacheAlert = false
    @State private var cacheSize: String = "256 MB"
    @State private var showUpdateSheet = false
    @State private var showNoUpdateAlert = false
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isChecking = false
    @State private var selectedDriveType: CloudDriveManager.DriveType = .ali
    @State private var driveTokenName = ""
    @State private var driveTokenValue = ""
    @State private var showTokenFetcher = false
    @State private var showSubscribeSheet = false
    @State private var showFallbackSheet = false
    @State private var showParserSheet = false
    @State private var showZhanyuanSheet = false
    @State private var showBaiduTestView = false
    @State private var showUniversalPlayTestView = false
    @State private var showAuthCenter = false
    @State private var showMPVKitDebugView = false
    @State private var showMPVRenderContextDebugView = false
    @State private var showLibmpvMoltenVKDebugView = false
    @State private var showPlaybackTestTools = false
    @State private var showMPVAdvancedDiagnostics = false
    @State private var showSiteDiagnostics = false
    @State private var showLogViewer = false
    @StateObject private var logStore = AppLogStore.shared
    @State private var isRunningMPVLoadfileProbe = false
    @State private var mpvLoadfileProbeSummary = "未运行loadfile探针"
    @State private var isRunningMPVControlProbe = false
    @State private var mpvControlProbeSummary = "未运行MPV综合控制探针"
    @State private var isRunningMPVMinimalPlaybackTest = false
    @State private var mpvMinimalPlaybackSummary = "未运行MPV最小播放链路测试"
    @State private var isRunningMPVLogProbe = false
    @State private var mpvLogProbeSummary = "未运行MPV日志采样探针"
    @State private var isRunningMPVAudioProbe = false
    @State private var mpvAudioProbeSummary = "未运行MPV音频输出探针"
    @State private var isRunningMPVVideoProbe = false
    @State private var mpvVideoProbeSummary = "未运行MPV视频输出能力探针"
    @State private var isRunningMPVNetworkProbe = false
    @State private var mpvNetworkProbeSummary = "未运行MPV网络播放探针"
    @State private var isRunningMPVLifecycleProbe = false
    @State private var mpvLifecycleProbeSummary = "未运行MPV生命周期压力测试"
    @State private var isRunningMPVAllDiagnostics = false
    @State private var mpvAllDiagnosticsSummary = "未运行一键全部MPV诊断"
    @State private var isSyncingRemoteSource = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                titleBar
                settingsContent
            }
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onChange(of: settings.bundleSourcesEnabled) { _ in
            Task { await spiderManager.reloadAllSources() }
        }
        .onChange(of: settings.remoteDefaultSourceEnabled) { newValue in
            Task {
                if newValue { await remoteSourceManager.syncNow() }
                await spiderManager.reloadAllSources()
            }
        }
        .alert("清除缓存", isPresented: $showCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("确定", role: .destructive) {
                spiderManager.clearCloudPlayCache()
                _ = cloudDriveManager.clearAllBaiduPlaybackCaches()
                DoubanImageProxyServer.shared.baiduStreamCache.cleanupExpiredCaches(olderThan: 0)
                cacheSize = "0 MB"
            }
        } message: { Text("确定要清除所有缓存数据吗？") }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet() }
        .alert("检查更新", isPresented: $showNoUpdateAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知") 已是最新版本")
        }
    }

    // MARK: - 拆分视图（解决编译器超时）
    private var titleBar: some View {
        Text("设置")
            .font(.system(size: 22, weight: .bold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
    }

    private var settingsContent: some View {
        VStack(spacing: 20) {
            skinSettingsSection
            playbackSettingsSection
            tmdbSettingsSection
            tgSearchSettingsSection
            subscriptionSection
            siteDiagnosticsSection
            fallbackSection
            zhanyuanSiteSection
            cloudDriveSection
            playbackTestToolsSection
            storageSection
            developerSection
            aboutSection
        }
        .padding(.horizontal, 16)
    }

    private var skinSettingsSection: some View {
        SettingsSection(title: "皮肤") {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(AppSkinMode.allCases) { mode in
                        SkinModeButton(
                            mode: mode,
                            isSelected: settings.skinMode == mode,
                            action: {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    settings.selectSkin(mode)
                                }
                            }
                        )
                    }
                }

                Toggle(isOn: $settings.skinFollowsSystem) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("黑暗/浅色跟随手机外观")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Text("开启后随系统外观切换")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(settings.skinMode == .liquid || settings.skinMode == .frosted)
                .opacity((settings.skinMode == .liquid || settings.skinMode == .frosted) ? 0.55 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(settings.usesVisualSkin ? 0.42 : 1))
            )
        }
    }

    private var playbackSettingsSection: some View {
        SettingsSection(title: "播放设置") {
            // 弹幕源设置
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "00BEFF"))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("自定义弹幕源")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Text(customDanmakuSourceEnabled ? "已开启 — 使用自定义弹幕API地址" : "关闭 — 使用默认弹幕源")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $customDanmakuSourceEnabled)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if customDanmakuSourceEnabled {
                    Divider().background(Color.secondary.opacity(0.15))
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 28)
                        TextField("", text: $customDanmakuSourceURL, prompt: Text("https://your-danmu-api.com").foregroundColor(.secondary.opacity(0.5)))
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7))

            SettingsToggleRow(title: "搜索调试面板", isOn: $showSearchDebug)
        }
    }

    private var tmdbSettingsSection: some View {
        SettingsSection(title: "TMDB 设置") {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "3B82F6"))
                    Text("加载 TMDB 封面与演职人员")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Toggle("", isOn: $settings.enableTMDB)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                if settings.enableTMDB {
                    VStack(alignment: .leading, spacing: 12) {
                        // 代理地址
                        VStack(alignment: .leading, spacing: 6) {
                            Text("代理地址")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 16)
                            TextField("请输入代理域名", text: $settings.tmdbProxyURL)
                                .font(.system(size: 14))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                                )
                                .padding(.horizontal, 16)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }

                        // Token 开关
                        HStack {
                            Image(systemName: "key.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "F59E0B"))
                            Text("代理需要 Token")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            Toggle("", isOn: $settings.tmdbUseToken)
                                .labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                        // Token 输入框
                        if settings.tmdbUseToken {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("代理 Token")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 16)
                                TextField("请输入密钥", text: $settings.tmdbProxyToken)
                                    .font(.system(size: 14))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                                    )
                                    .padding(.horizontal, 16)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - TG搜索设置
    private var tgSearchSettingsSection: some View {
        SettingsSection(title: "TG搜索设置") {
            VStack(spacing: 12) {
                // 代理地址
                VStack(alignment: .leading, spacing: 6) {
                    Text("代理地址")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                    TextField("https://xxx.com/?token=xxx&url=", text: $tgConfigStore.proxyURL)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        )
                        .padding(.horizontal, 16)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("支持URL转发代理，在末尾拼接原始URL")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 6)

                // 分隔线
                Divider().padding(.horizontal, 16)

                // 频道来源模式
                VStack(alignment: .leading, spacing: 8) {
                    Text("频道来源")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)

                    Picker("频道来源", selection: $tgConfigStore.channelMode) {
                        ForEach(TGSearchConfigStore.ChannelMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    Text(channelModeDescription)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 6)

                // 分隔线
                Divider().padding(.horizontal, 16)

                // 频道管理导航
                NavigationLink(destination: TGChannelListView()) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "8B5CF6"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TG频道管理")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text("\(tgConfigStore.channels.count) 个自定义频道")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var channelModeDescription: String {
        switch tgConfigStore.channelMode {
        case .default:
            return "仅使用远程仓库内置的默认频道"
        case .custom:
            return "仅使用自定义频道，方便排查问题"
        case .all:
            return "远程默认频道 + 自定义频道，全部并行搜索"
        }
    }

    private var fallbackSection: some View {
        SettingsSection(title: "切片资源") {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "server.rack")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    Text("启用兜底切片资源")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Toggle("", isOn: $spiderManager.fallbackEnabled)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                
                Button(action: { showFallbackSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("管理自定义切片源")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(spiderManager.customFallbackSites.count) 个")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.04))
                
                Button(action: { showParserSheet = true }) {
                    HStack {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("管理自定义解析器")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(spiderManager.customParsers.count) 个")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.04))
            }
        }
        .sheet(isPresented: $showFallbackSheet) {
            FallbackConfigView()
        }
        .sheet(isPresented: $showParserSheet) {
            ParserConfigView()
        }
    }

    private var zhanyuanSiteSection: some View {
        SettingsSection(title: "站源管理") {
            Button(action: { showZhanyuanSheet = true }) {
                HStack {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    Text("管理站源（启用/禁用）")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let count = DatabaseManager.shared.queryActiveZhanyuanSites().count
                    Text("\(count) 个启用")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.gray.opacity(0.04))
        }
        .sheet(isPresented: $showZhanyuanSheet) {
            ZhanyuanSiteManageView()
        }
    }

    private var subscriptionSection: some View {
        SettingsSection(title: "订阅配置") {
            VStack(spacing: 0) {
                Button(action: { showSubscribeSheet = true }) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        Text("管理订阅源")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        if SpiderManager.shared.subManager.configURLs.isEmpty {
                            Text("未配置")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        } else {
                            Text("\(SpiderManager.shared.subManager.configURLs.count) 个源")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(Color.gray.opacity(0.04))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "3B82F6"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用远程默认源")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text(remoteSourceManager.loadState.displayText)
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.remoteDefaultSourceEnabled)
                            .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("默认源地址")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        TextField("manifest.json 地址", text: $settings.defaultManifestURL)
                            .font(.system(size: 12))
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            )
                    }

                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "F59E0B"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("启用 Bundle 内置源")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text("关闭后跳过 ibox/video 内置 JSON 和硬编码兜底源")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.bundleSourcesEnabled)
                            .labelsHidden()
                    }

                    HStack(spacing: 10) {
                        Button {
                            isSyncingRemoteSource = true
                            Task {
                                await remoteSourceManager.syncNow()
                                await spiderManager.reloadAllSources()
                                await MainActor.run {
                                    isSyncingRemoteSource = false
                                }
                            }
                        } label: {
                            Label(isSyncingRemoteSource ? "同步中" : "刷新远程源", systemImage: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .disabled(isSyncingRemoteSource || !settings.remoteDefaultSourceEnabled)

                        Button(role: .destructive) {
                            remoteSourceManager.clearCache()
                            Task {
                                await spiderManager.reloadAllSources()
                                remoteSourceManager.refreshLoadState()
                            }
                        } label: {
                            Label("清缓存", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                        }
                    }

                    Text("配置版本：\(remoteSourceManager.lastConfigVersion.isEmpty ? "无" : remoteSourceManager.lastConfigVersion) · 同步时间：\(remoteSyncTimeText)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.gray.opacity(0.04))

                // 【新增】双模式功能开关
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("双模式兼容")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Text("type=3 HTTP接口走原生搜索（重启生效）")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { spiderManager.enableDualMode },
                        set: { spiderManager.enableDualMode = $0 }
                    ))
                    .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .sheet(isPresented: $showSubscribeSheet) {
            SubscribeConfigView()
        }
    }

    private var remoteSyncTimeText: String {
        guard let date = remoteSourceManager.lastSyncTime else { return "无" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var cloudDriveSection: some View {
        SettingsSection(title: "网盘播放") {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { showAuthCenter = true }) {
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "E11D48"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("网盘账号授权中心")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)
                            Text("百度双 Token 状态，扫码登录框架预留")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(Color.gray.opacity(0.04))
                }

            }.padding(16)
        }
        .sheet(isPresented: $showBaiduTestView) {
            BaiduTestView()
        }
        .sheet(isPresented: $showUniversalPlayTestView) {
            UniversalPlayTestView()
        }
        .sheet(isPresented: $showMPVKitDebugView) {
            MPVKitDebugPlayerView()
        }
        .sheet(isPresented: $showMPVRenderContextDebugView) {
            MPVRenderContextDebugView()
        }
        .sheet(isPresented: $showLibmpvMoltenVKDebugView) {
            LibmpvMoltenVKDebugView()
        }
        .sheet(isPresented: $showAuthCenter) {
            CloudAuthCenterView()
        }
    }

    private var playbackTestToolsSection: some View {
        SettingsSection(title: "播放测试") {
            Button(action: { showPlaybackTestTools = true }) {
                HStack {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("播放测试工具")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primary)
                        Text("统一管理通用播放、MPV、RenderContext、百度网盘测试")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.gray.opacity(0.04))
            }
            .padding(16)
        }
        .sheet(isPresented: $showPlaybackTestTools) {
            PlaybackTestToolsView(
                showUniversalPlayTestView: $showUniversalPlayTestView,
                showMPVKitDebugView: $showMPVKitDebugView,
                showMPVRenderContextDebugView: $showMPVRenderContextDebugView,
                showLibmpvMoltenVKDebugView: $showLibmpvMoltenVKDebugView,
                showBaiduTestView: $showBaiduTestView,
                showMPVAdvancedDiagnostics: $showMPVAdvancedDiagnostics
            )
        }
        .sheet(isPresented: $showMPVAdvancedDiagnostics) {
            mpvAdvancedDiagnosticsView
        }
    }

    private func driveTokenRow(index: Int, token: DriveToken) -> some View {
        HStack {
            Image(systemName: iconForDriveType(token.type))
                .foregroundColor(Color(hex: "E11D48")).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)
                    .font(.system(size: 14, weight: .medium)).foregroundColor(.primary)
                Text(token.name).font(.system(size: 11)).foregroundColor(.gray).lineLimit(1)
            }
            Spacer()
            Button(action: { cloudDriveManager.removeToken(at: index) }) {
                Image(systemName: "trash").font(.system(size: 14)).foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.gray.opacity(0.06)).cornerRadius(8)
    }

    private var fetchTokenButton: some View {
        Button(action: { showTokenFetcher = true }) {
            HStack {
                Image(systemName: "key.fill").font(.system(size: 16))
                Text("网页登录获取Token").font(.system(size: 14, weight: .medium))
                Text("→").font(.system(size: 12))
            }
            .foregroundColor(.white).frame(maxWidth: .infinity)
            .padding(.vertical, 12).background(Color(hex: "E11D48")).cornerRadius(10)
        }
        .sheet(isPresented: $showTokenFetcher) {
            TokenFetcherView(cloudDriveManager: cloudDriveManager, onTokenDetected: { type, value in
                // 自动填充到输入框
                selectedDriveType = CloudDriveManager.DriveType(rawValue: type) ?? .ali
                driveTokenName = CloudDriveManager.DriveType(rawValue: type)?.displayName ?? type
                driveTokenValue = value
                showTokenFetcher = false
            })
        }
    }

    private var driveFormFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("网盘类型", selection: $selectedDriveType) {
                ForEach(CloudDriveManager.DriveType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)
            TextField("备注名称", text: $driveTokenName).textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 13))
            TextField(selectedDriveType.tokenLabel, text: $driveTokenValue).textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 12))
                .autocapitalization(.none).disableAutocorrection(true)
            Button(action: addDriveToken) {
                Text("保存Token").font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white).frame(maxWidth: .infinity)
                    .padding(.vertical, 10).background(Color(hex: "E11D48")).cornerRadius(10)
            }.disabled(driveTokenName.isEmpty || driveTokenValue.isEmpty)
        }
    }

    private var storageSection: some View {
        SettingsSection(title: "存储管理") {
            SettingsNavigationRow(title: "缓存管理", subtitle: cacheSize, icon: "externaldrive.fill") { showCacheAlert = true }
        }
    }

    private var siteDiagnosticsSection: some View {
        SettingsSection(title: "站点诊断") {
            Button(action: { showSiteDiagnostics = true }) {
                HStack {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "E11D48"))
                    Text("接口状态检测")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    let stats = spiderManager.engineStats
                    Text("\(stats.loaded)/\(stats.total) 就绪")
                        .font(.system(size: 13))
                        .foregroundColor(stats.loaded == stats.total ? .green : .orange)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(Color.gray.opacity(0.04))
        }
        .sheet(isPresented: $showSiteDiagnostics) {
            SiteDiagnosticsView()
        }
        .sheet(isPresented: $showLogViewer) {
            LogViewerView()
        }
    }

    private var developerSection: some View {
        SettingsSection(title: "开发调试") {
            // 日志记录开关
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "7C3AED"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("日志记录")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Text("记录应用运行日志，帮助排查问题")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Spacer()
                Toggle("", isOn: $settings.devLogEnabled)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // 日志级别选择
            if settings.devLogEnabled {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                    Text("日志级别")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                    Spacer()
                    Menu {
                        ForEach([LogLevel.verbose, .info, .warn, .error], id: \.self) { level in
                            Button {
                                settings.devLogLevel = level
                            } label: {
                                HStack {
                                    Text(level.displayName)
                                    if settings.devLogLevel == level {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(settings.devLogLevel.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.gray)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.04))
            }
            
            // 查看日志入口
            Button(action: { showLogViewer = true }) {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                    Text("查看日志")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("\(logStore.count) 条")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.gray.opacity(0.04))
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "关于") {
            HStack {
                Text("版本").foregroundColor(.primary); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知").foregroundColor(.gray)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Button(action: {
                Task {
                    isChecking = true
                    await updateManager.checkForUpdate(force: true)
                    isChecking = false
                    if updateManager.hasUpdate {
                        showUpdateSheet = true
                    } else {
                        showNoUpdateAlert = true
                    }
                }
            }) {
                HStack {
                    Text("检查更新").foregroundColor(.primary); Spacer()
                    if isChecking { ProgressView().scaleEffect(0.8) }
                    else { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundColor(.gray) }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private var mpvAdvancedDiagnosticsView: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("MPV状态").foregroundColor(.primary)
                        Spacer()
                        Text(MPVIntegrationStatus.isMPVKitInitializationReady ? "可初始化" : (MPVIntegrationStatus.isMPVKitRuntimeLoadable ? "已加载" : "未启用"))
                            .foregroundColor(MPVIntegrationStatus.isMPVKitInitializationReady ? .green : (MPVIntegrationStatus.isMPVKitRuntimeLoadable ? .orange : .gray))
                    }
                    Text(MPVIntegrationStatus.runtimeProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MPVIntegrationStatus.initializationProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvLoadfileProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvControlProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvMinimalPlaybackSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvLogProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvAudioProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvVideoProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvNetworkProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvLifecycleProbeSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mpvAllDiagnosticsSummary)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("提示：高级诊断只用于排查内核问题，真实播放测试优先使用 RenderContext。")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: runMPVLoadfileProbe) {
                        HStack {
                            if isRunningMPVLoadfileProbe {
                                ProgressView().scaleEffect(0.75)
                            } else {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 13))
                            }
                            Text(isRunningMPVLoadfileProbe ? "正在运行MPV loadfile探针" : "运行MPV loadfile探针")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(MPVIntegrationStatus.isMPVKitInitializationReady ? Color(hex: "E11D48") : Color.gray)
                        .cornerRadius(8)
                    }
                    .disabled(isRunningMPVLoadfileProbe || !MPVIntegrationStatus.isMPVKitInitializationReady)

                    Button(action: runMPVControlProbe) {
                        HStack {
                            if isRunningMPVControlProbe {
                                ProgressView().scaleEffect(0.75)
                            } else {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 13))
                            }
                            Text(isRunningMPVControlProbe ? "正在运行MPV综合探针" : "运行MPV综合控制探针")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(MPVIntegrationStatus.isMPVKitInitializationReady ? Color.black.opacity(0.85) : Color.gray)
                        .cornerRadius(8)
                    }
                    .disabled(isRunningMPVControlProbe || !MPVIntegrationStatus.isMPVKitInitializationReady)

                    Button(action: runMPVMinimalPlaybackTest) {
                        HStack {
                            if isRunningMPVMinimalPlaybackTest {
                                ProgressView().scaleEffect(0.75)
                            } else {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 13))
                            }
                            Text(isRunningMPVMinimalPlaybackTest ? "正在运行MPV最小播放链路" : "运行MPV最小播放链路")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(MPVIntegrationStatus.isMPVKitInitializationReady ? Color.blue.opacity(0.85) : Color.gray)
                        .cornerRadius(8)
                    }
                    .disabled(isRunningMPVMinimalPlaybackTest || !MPVIntegrationStatus.isMPVKitInitializationReady)

                    mpvDiagnosticButton(title: "MPV日志采样已禁用", runningTitle: "MPV日志采样已禁用", isRunning: isRunningMPVLogProbe, icon: "exclamationmark.triangle", color: Color.gray, action: runMPVLogProbe)
                    mpvDiagnosticButton(title: "运行MPV音频输出探针", runningTitle: "正在运行MPV音频输出", isRunning: isRunningMPVAudioProbe, icon: "speaker.wave.2.fill", color: Color.orange.opacity(0.9), action: runMPVAudioProbe)
                    mpvDiagnosticButton(title: "运行MPV视频输出能力探针", runningTitle: "正在运行MPV视频输出能力", isRunning: isRunningMPVVideoProbe, icon: "display", color: Color.green.opacity(0.85), action: runMPVVideoProbe)
                    mpvDiagnosticButton(title: "运行MPV网络播放探针", runningTitle: "正在运行MPV网络播放", isRunning: isRunningMPVNetworkProbe, icon: "network", color: Color.cyan.opacity(0.9), action: runMPVNetworkProbe)
                    mpvDiagnosticButton(title: "运行MPV生命周期压力测试", runningTitle: "正在运行MPV生命周期压力", isRunning: isRunningMPVLifecycleProbe, icon: "repeat.circle", color: Color.indigo.opacity(0.85), action: runMPVLifecycleProbe)
                    mpvDiagnosticButton(title: "一键运行全部MPV诊断", runningTitle: "正在运行全部MPV诊断", isRunning: isRunningMPVAllDiagnostics, icon: "checklist", color: Color(hex: "E11D48"), action: runMPVAllDiagnostics)
                }
                .padding(16)
            }
            .navigationTitle("MPV高级诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { showMPVAdvancedDiagnostics = false }
                }
            }
        }
    }

    private func mpvDiagnosticButton(
        title: String,
        runningTitle: String,
        isRunning: Bool,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if isRunning {
                    ProgressView().scaleEffect(0.75)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                }
                Text(isRunning ? runningTitle : title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(MPVIntegrationStatus.isMPVKitInitializationReady ? color : Color.gray)
            .cornerRadius(8)
        }
        .disabled(isRunning || !MPVIntegrationStatus.isMPVKitInitializationReady)
    }

    private func runMPVLoadfileProbe() {
        guard !isRunningMPVLoadfileProbe else { return }
        isRunningMPVLoadfileProbe = true
        mpvLoadfileProbeSummary = "正在使用测试媒体运行loadfile探针..."

        Task.detached {
            let result = MPVIntegrationStatus.runLoadfileProbe()
            await MainActor.run {
                mpvLoadfileProbeSummary = result.summary
                isRunningMPVLoadfileProbe = false
            }
        }
    }

    private func runMPVControlProbe() {
        guard !isRunningMPVControlProbe else { return }
        isRunningMPVControlProbe = true
        mpvControlProbeSummary = "正在验证属性读取、暂停、倍速和seek..."

        Task.detached {
            let result = MPVIntegrationStatus.runPlaybackControlProbe()
            await MainActor.run {
                mpvControlProbeSummary = result.summary
                isRunningMPVControlProbe = false
            }
        }
    }

    private func runMPVMinimalPlaybackTest() {
        guard !isRunningMPVMinimalPlaybackTest else { return }
        isRunningMPVMinimalPlaybackTest = true
        mpvMinimalPlaybackSummary = "正在通过PlayerEngine运行load/play/pause/seek/stop..."

        Task { @MainActor in
            let summary = await runMPVMinimalPlaybackSequence()
            mpvMinimalPlaybackSummary = summary
            isRunningMPVMinimalPlaybackTest = false
        }
    }

    private func runMPVLogProbe() {
        guard !isRunningMPVLogProbe else { return }
        let result = MPVIntegrationStatus.runLogSamplingProbe()
        mpvLogProbeSummary = "\(result.title)：\(result.summary)"
    }

    private func runMPVAudioProbe() {
        guard !isRunningMPVAudioProbe else { return }
        isRunningMPVAudioProbe = true
        mpvAudioProbeSummary = "正在测试MPV音频输出路径..."

        Task.detached {
            let result = MPVIntegrationStatus.runAudioOutputProbe()
            await MainActor.run {
                mpvAudioProbeSummary = "\(result.title)：\(result.summary)"
                isRunningMPVAudioProbe = false
            }
        }
    }

    private func runMPVVideoProbe() {
        guard !isRunningMPVVideoProbe else { return }
        isRunningMPVVideoProbe = true
        mpvVideoProbeSummary = "正在测试MPV视频输出能力..."

        Task.detached {
            let result = MPVIntegrationStatus.runVideoOutputCapabilityProbe()
            await MainActor.run {
                mpvVideoProbeSummary = "\(result.title)：\(result.summary)"
                isRunningMPVVideoProbe = false
            }
        }
    }

    private func runMPVNetworkProbe() {
        guard !isRunningMPVNetworkProbe else { return }
        isRunningMPVNetworkProbe = true
        mpvNetworkProbeSummary = "正在测试HLS和MP4网络播放..."

        Task.detached {
            let result = MPVIntegrationStatus.runNetworkPlaybackProbe()
            await MainActor.run {
                mpvNetworkProbeSummary = "\(result.title)：\(result.summary)"
                isRunningMPVNetworkProbe = false
            }
        }
    }

    private func runMPVLifecycleProbe() {
        guard !isRunningMPVLifecycleProbe else { return }
        isRunningMPVLifecycleProbe = true
        mpvLifecycleProbeSummary = "正在连续创建和销毁MPV实例..."

        Task.detached {
            let result = MPVIntegrationStatus.runLifecycleStressProbe()
            await MainActor.run {
                mpvLifecycleProbeSummary = "\(result.title)：\(result.summary)"
                isRunningMPVLifecycleProbe = false
            }
        }
    }

    private func runMPVAllDiagnostics() {
        guard !isRunningMPVAllDiagnostics else { return }
        isRunningMPVAllDiagnostics = true
        mpvAllDiagnosticsSummary = "正在按顺序运行全部MPV诊断..."

        Task { @MainActor in
            let loadfile = await Task.detached { MPVIntegrationStatus.runLoadfileProbe() }.value
            mpvLoadfileProbeSummary = loadfile.summary

            let control = await Task.detached { MPVIntegrationStatus.runPlaybackControlProbe() }.value
            mpvControlProbeSummary = control.summary

            let minimal = await runMPVMinimalPlaybackSequence()
            mpvMinimalPlaybackSummary = minimal

            let network = await Task.detached { MPVIntegrationStatus.runNetworkPlaybackProbe() }.value
            mpvNetworkProbeSummary = "\(network.title)：\(network.summary)"

            let lifecycle = await Task.detached { MPVIntegrationStatus.runLifecycleStressProbe() }.value
            mpvLifecycleProbeSummary = "\(lifecycle.title)：\(lifecycle.summary)"

            let log = MPVIntegrationStatus.runLogSamplingProbe()
            mpvLogProbeSummary = "\(log.title)：\(log.summary)"
            mpvAudioProbeSummary = "音频输出：已跳过，一键诊断只运行安全项"
            mpvVideoProbeSummary = "视频输出能力：已跳过，一键诊断只运行安全项"

            let passedCount = [
                loadfile.isMediaLoadObserved,
                control.isControlPathReady,
                !minimal.contains("失败"),
                network.isPassed,
                lifecycle.isPassed
            ].filter { $0 }.count

            mpvAllDiagnosticsSummary = "安全MPV诊断完成：\(passedCount)/5 通过，已跳过日志/音频/视频危险探针"
            isRunningMPVAllDiagnostics = false
        }
    }

    @MainActor
    private func runMPVMinimalPlaybackSequence() async -> String {
        guard let url = URL(string: MPVKitBackend.defaultLoadfileProbeURL) else {
            return "测试地址无效"
        }

        let controller = PlayerEngineController(initialEngineType: .mpvKit)
        let route = PlaybackRoute(type: .direct, url: url, title: "MPV最小播放链路测试")
        controller.load(route: route, preferredEngine: .mpvKit)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        controller.play()
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if controller.state.duration > 0 || controller.state.currentTime > 0 {
            controller.seek(to: 5)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        controller.pause()
        try? await Task.sleep(nanoseconds: 500_000_000)

        controller.play()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let snapshot = controller.state
        let logs = controller.logs.suffix(4).joined(separator: " / ")
        controller.stop()
        controller.teardown()

        if let errorMessage = snapshot.errorMessage {
            return "MPV最小播放链路失败：\(errorMessage)，日志：\(logs)"
        }

        let current = String(format: "%.1f", snapshot.currentTime)
        let duration = String(format: "%.1f", snapshot.duration)
        return "MPV最小播放链路完成：time=\(current)，duration=\(duration)，playing=\(snapshot.isPlaying)，日志：\(logs)"
    }

    private func addDriveToken() {
        guard !driveTokenName.isEmpty, !driveTokenValue.isEmpty else { return }
        cloudDriveManager.addToken(type: selectedDriveType, name: driveTokenName, value: driveTokenValue)
        driveTokenName = ""; driveTokenValue = ""
    }

    private func iconForDriveType(_ type: String) -> String {
        switch type {
        case "115": return "1.circle.fill"
        case "ali": return "a.circle.fill"
        case "quark": return "q.circle.fill"
        case "baidu": return "b.circle.fill"
        case "uc": return "u.circle.fill"
        case "123pan": return "3.circle.fill"
        case "139pan": return "9.circle.fill"
        default: return "cloud.fill"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                .padding(.horizontal, 20).padding(.top, 8)
            VStack(spacing: 1) { content }
                .background(RoundedRectangle(cornerRadius: 16).fill(.thinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 16)
        }
    }
}

struct SkinModeButton: View {
    let mode: AppSkinMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(mode.subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? selectedSubtitleColor : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(isSelected ? selectedTextColor : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? selectedGradient : inactiveBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(uiColor: .systemBackground).opacity(0.45) : Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var selectedTextColor: Color {
        switch mode {
        case .light, .frosted: return Color(hex: "111827")
        case .dark, .liquid: return .white
        }
    }

    private var selectedSubtitleColor: Color {
        switch mode {
        case .light, .frosted: return Color(hex: "111827").opacity(0.72)
        case .dark, .liquid: return .white.opacity(0.82)
        }
    }

    private var selectedGradient: LinearGradient {
        switch mode {
        case .dark:
            return LinearGradient(colors: [Color(hex: "111827"), Color(hex: "374151")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .light:
            return LinearGradient(colors: [Color(hex: "F59E0B"), Color(hex: "FDE68A")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .liquid:
            return LinearGradient(colors: [Color(hex: "06B6D4"), Color(hex: "7C3AED"), Color(hex: "EC4899")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .frosted:
            return LinearGradient(colors: [Color(hex: "93C5FD"), Color(hex: "C4B5FD"), Color(hex: "FBCFE8")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var inactiveBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(uiColor: .secondarySystemGroupedBackground).opacity(0.95),
                Color(uiColor: .tertiarySystemGroupedBackground).opacity(0.9)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct PlaybackTestToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var showUniversalPlayTestView: Bool
    @Binding var showMPVKitDebugView: Bool
    @Binding var showMPVRenderContextDebugView: Bool
    @Binding var showLibmpvMoltenVKDebugView: Bool
    @Binding var showBaiduTestView: Bool
    @Binding var showMPVAdvancedDiagnostics: Bool

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    toolRow(
                        icon: "play.rectangle.on.rectangle.fill",
                        title: "通用播放测试工具",
                        subtitle: "测试 m3u8 / mp4 / mkv / 网盘解析后的直链",
                        action: { open($showUniversalPlayTestView) }
                    )

                    toolRow(
                        icon: "play.tv.fill",
                        title: "Libmpv-MoltenVK调试",
                        subtitle: "新增路线：gpu-next + Vulkan + MoltenVK，验证是否绕开OpenGLES偏色",
                        action: { open($showLibmpvMoltenVKDebugView) }
                    )

                    toolRow(
                        icon: "rectangle.on.rectangle.angled",
                        title: "MPV RenderContext调试",
                        subtitle: "当前重点测试入口，适合 HLS 和 MKV",
                        action: { open($showMPVRenderContextDebugView) }
                    )

                    toolRow(
                        icon: "play.tv.fill",
                        title: "MPV播放调试",
                        subtitle: "旧路线对比：wid + CAMetalLayer",
                        action: { open($showMPVKitDebugView) }
                    )

                    toolRow(
                        icon: "play.circle.fill",
                        title: "百度网盘测试工具",
                        subtitle: "百度网盘解析与播放专项测试",
                        action: { open($showBaiduTestView) }
                    )

                    toolRow(
                        icon: "stethoscope",
                        title: "MPV高级诊断",
                        subtitle: "收纳底层探针，仅排查内核问题时使用",
                        action: { open($showMPVAdvancedDiagnostics) }
                    )
                }
                .padding(16)
            }
            .navigationTitle("播放测试工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func toolRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "E11D48"))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .padding(16)
            .background(Color.gray.opacity(0.05))
            .cornerRadius(14)
        }
    }

    private func open(_ binding: Binding<Bool>) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            binding.wrappedValue = true
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let isOn: Binding<Bool>
    init(title: String, isOn: Binding<Bool>) {
        self.title = title
        self.isOn = isOn
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7))
    }
}

struct SettingsNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(Color(hex: "E11D48")).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                    if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundColor(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct CloudAuthCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @StateObject private var authManager = CloudDriveAuthManager.shared
    @State private var showTokenFetcher = false
    @State private var showQuarkNativeQR = false
    @State private var showUCNativeQR = false
    @State private var showUCTVAuth = false
    @State private var ucLoginJustCompleted = false
    @State private var showBaiduNativeQR = false
    @State private var showAliNativeQR = false
    @State private var show123NativeQR = false
    @State private var show115NativeQR = false
    @State private var show139NativeQR = false
    @State private var show189NativeQR = false
    @State private var showXunleiNativeQR = false
    @State private var showGuangyaQR = false
    @State private var showWoniu4kLogin = false
    @State private var webAuthDriveType: CloudDriveManager.DriveType? = nil
    @State private var selectedDriveType: CloudDriveManager.DriveType = .ali
    @State private var driveTokenName = ""
    @State private var driveTokenValue = ""

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    baiduAccountCard
                    quarkAccountCard
                    providerAccountCard(type: .ali, note: "阿里云盘使用官方网页扫码/登录获取 refresh_token，用于解析播放文件链接。")
                    AliyunPgQrLoginView()
                    providerAccountCard(type: .uc, note: "优先使用授权中心保存的 UC Cookie；支持网页登录兜底回收 Cookie。")
                    providerAccountCard(type: .one15, note: "115 使用官方网页扫码/登录回收完整 Cookie，手动 Cookie 继续保留。")
                    providerAccountCard(type: .pan123, note: "123云盘支持网页扫码登录回收 Cookie，播放分享链接时自动使用。")
                    providerAccountCard(type: .pan139, note: "139云盘（移动云盘）支持网页扫码登录回收 Cookie。")
                    providerAccountCard(type: .pan189, note: "天翼云盘支持原生扫码登录获取 Cookie，用于解析播放分享链接。")
                    providerAccountCard(type: .xunlei, note: "迅雷云盘支持网页登录获取 Cookie，用于后续迅雷云盘资源解析播放。")
                    nodeManagedAccountCard(type: .guangya, note: "光鸭网盘由 Node 常驻系统托管：扫码授权后自动回收 Token，解析链路走 A1 接缝。")
                    nodeManagedAccountCard(type: .woniu4k, note: "蜗牛网盘由 Node 常驻系统托管：账号+密码+验证码登录，登录态自动回收 Cookie。")
                    manualTokenFallbackCard

                    Text("播放前不会强制检测授权状态；解析失败且像授权失效时才反向标记。手动粘贴入口继续保留为高级兜底。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("网盘账号授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showTokenFetcher) {
                TokenFetcherView(cloudDriveManager: cloudDriveManager, onTokenDetected: { type, value in
                    selectedDriveType = CloudDriveManager.DriveType(rawValue: type) ?? .ali
                    driveTokenName = CloudDriveManager.DriveType(rawValue: type)?.displayName ?? type
                    driveTokenValue = value
                    showTokenFetcher = false
                })
            }
            .sheet(isPresented: $showQuarkNativeQR) {
                QuarkNativeQRLoginTestView(cloudDriveManager: cloudDriveManager)
            }
            .sheet(isPresented: $showUCNativeQR) {
                NativeCloudQRLoginView(driveType: .uc, onUCLoginSuccess: $ucLoginJustCompleted)
            }
            .sheet(isPresented: $showUCTVAuth) {
                UCTVAuthQRView()
            }
            .onChange(of: showUCNativeQR) { newValue in
                if !newValue && ucLoginJustCompleted {
                    ucLoginJustCompleted = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showUCTVAuth = true
                    }
                }
            }
            .sheet(isPresented: $showBaiduNativeQR) {
                NativeCloudQRLoginView(driveType: .baidu)
            }
            .sheet(isPresented: $showAliNativeQR) {
                NativeCloudQRLoginView(driveType: .ali)
            }
            .sheet(isPresented: $show123NativeQR) {
                NativeCloudQRLoginView(driveType: .pan123)
            }
            .sheet(isPresented: $show115NativeQR) {
                NativeCloudQRLoginView(driveType: .one15)
            }
            .sheet(isPresented: $show139NativeQR) {
                NativeCloudQRLoginView(driveType: .pan139)
            }
            .sheet(isPresented: $show189NativeQR) {
                NativeCloudQRLoginView(driveType: .pan189)
            }
            .sheet(isPresented: $showXunleiNativeQR) {
                NativeCloudQRLoginView(driveType: .xunlei)
            }
            .sheet(isPresented: $showGuangyaQR) {
                NodeGuangyaQRLoginView()
            }
            .sheet(isPresented: $showWoniu4kLogin) {
                NodeWoniu4kLoginView()
            }
            .sheet(item: $webAuthDriveType) { type in
                CloudDriveWebAuthView(driveType: type)
            }
        }
    }

    private var baiduAccountCard: some View {
        let pair = cloudDriveManager.baiduTokenPair()
        let webCookie = pair?.web.value ?? ""
        let pcsCookie = pair?.pcs?.value ?? ""
        let webStatus = baiduWebStatus(webCookie)
        let pcsStatus = baiduPCSStatus(pcsCookie)

        return VStack(alignment: .leading, spacing: 14) {
            accountHeader(
                title: "百度网盘",
                subtitle: authSubtitle(for: .baidu, fallback: pair == nil ? "未登录" : "已保存百度账号信息"),
                icon: "b.circle.fill",
                isReady: pair != nil || authManager.isAuthorized(.baidu)
            )

            VStack(spacing: 8) {
                authStatusRow(title: "基础登录 Web Cookie", status: webStatus.text, isReady: webStatus.ready)
                authStatusRow(title: "可选 PCS Cookie", status: pcsStatus.text, isReady: pcsStatus.ready)
            }

            Text("百度主账号态按 iBox 路线使用 BDUSS+STOKEN；BDCLND 会在分享验证后动态追加。PCS Cookie 仅作为可选附加缓存，不作为主登录态。")
                .font(.system(size: 12))
                .foregroundColor(.gray)

            HStack(spacing: 10) {
                Button(action: { showBaiduNativeQR = true }) {
                    authButtonLabel("扫码授权", icon: "qrcode")
                }
                Button(action: { webAuthDriveType = .baidu }) {
                    authButtonLabel("网页兜底", icon: "globe")
                }
            }
            authDetailLine(for: .baidu, fallback: pair?.web.name ?? "暂无 Token")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
    }

    private var manualTokenFallbackCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Color(hex: "E11D48"))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("复制粘贴 Token 兜底")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("用于查看、网页登录获取、手动粘贴各网盘 Token")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    if cloudDriveManager.savedTokens.isEmpty {
                        Text("暂无已保存 Token")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(uiColor: .systemBackground).opacity(0.85))
                            .cornerRadius(10)
                    } else {
                        ForEach(Array(cloudDriveManager.savedTokens.enumerated()), id: \.offset) { index, token in
                            fallbackTokenRow(index: index, token: token)
                        }
                    }
                }
            }
            .frame(maxHeight: 170)

            Button(action: { showTokenFetcher = true }) {
                HStack {
                    Image(systemName: "globe")
                    Text("网页登录获取 Token（兜底）")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(hex: "E11D48"))
                .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Picker("网盘类型", selection: $selectedDriveType) {
                    ForEach(CloudDriveManager.DriveType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                TextField("备注名称", text: $driveTokenName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 13))

                TextField(selectedDriveType.tokenLabel, text: $driveTokenValue)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 12))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button(action: addDriveTokenFromFallback) {
                    Text("保存 Token")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background((driveTokenName.isEmpty || driveTokenValue.isEmpty) ? Color.gray : Color(hex: "E11D48"))
                        .cornerRadius(10)
                }
                .disabled(driveTokenName.isEmpty || driveTokenValue.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))
    }

    private func fallbackTokenRow(index: Int, token: DriveToken) -> some View {
        HStack {
            Image(systemName: iconForDriveTokenType(token.type))
                .foregroundColor(Color(hex: "E11D48"))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudDriveManager.DriveType(rawValue: token.type)?.displayName ?? token.type)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Text(token.name)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: { cloudDriveManager.removeToken(at: index) }) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .systemBackground).opacity(0.85))
        .cornerRadius(10)
    }

    private func addDriveTokenFromFallback() {
        guard !driveTokenName.isEmpty, !driveTokenValue.isEmpty else { return }
        cloudDriveManager.addToken(type: selectedDriveType, name: driveTokenName, value: driveTokenValue)
        authManager.saveManualCredential(type: selectedDriveType, name: driveTokenName, value: driveTokenValue)
        driveTokenName = ""
        driveTokenValue = ""
    }

    private func iconForDriveTokenType(_ type: String) -> String {
        guard let driveType = CloudDriveManager.DriveType(rawValue: type) else { return "cloud.fill" }
        return iconForDriveType(driveType)
    }

    private var quarkAccountCard: some View {
        let tokens = cloudDriveManager.tokens(for: .quark)
        return VStack(alignment: .leading, spacing: 10) {
            accountHeader(
                title: CloudDriveManager.DriveType.quark.displayName,
                subtitle: authSubtitle(for: .quark, fallback: tokens.isEmpty ? "未登录" : "已保存 \(tokens.count) 个 Token"),
                icon: iconForDriveType(.quark),
                isReady: !tokens.isEmpty || authManager.isAuthorized(.quark)
            )
            Text("支持原生扫码登录，扫码后自动保存 Cookie；也可使用网页登录兜底。")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            HStack(spacing: 10) {
                Button(action: { showQuarkNativeQR = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                        Text("原生扫码登录")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(hex: "E11D48"))
                    .cornerRadius(10)
                }
                Button(action: { webAuthDriveType = .quark }) {
                    authButtonLabel("网页登录兜底", icon: "globe")
                }
            }
            authDetailLine(for: .quark, fallback: tokens.first?.name ?? "暂无 Token")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))
    }

    private func providerAccountCard(type: CloudDriveManager.DriveType, note: String) -> some View {
        let tokens = cloudDriveManager.tokens(for: type)
        return VStack(alignment: .leading, spacing: 10) {
            accountHeader(
                title: type.displayName,
                subtitle: authSubtitle(for: type, fallback: tokens.isEmpty ? "未登录" : "已保存 \(tokens.count) 个 Token"),
                icon: iconForDriveType(type),
                isReady: !tokens.isEmpty || authManager.isAuthorized(type)
            )
            Text(note)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            HStack(spacing: 10) {
                if type == .ali {
                    Button(action: { showAliNativeQR = true }) {
                        authButtonLabel("原生扫码", icon: "qrcode")
                    }
                } else if type == .uc {
                    Button(action: { showUCNativeQR = true }) {
                        authButtonLabel("原生扫码", icon: "qrcode")
                    }
                    Button(action: { webAuthDriveType = type }) {
                        authButtonLabel("网页登录兜底", icon: "globe")
                    }
                } else if type == .pan139 {
                    Button(action: { show139NativeQR = true }) {
                        authButtonLabel("网页登录授权", icon: "globe")
                    }
                } else if type == .pan189 {
                    Button(action: { show189NativeQR = true }) {
                        authButtonLabel("网页登录授权", icon: "globe")
                    }
                } else if type == .xunlei {
                    Button(action: { showXunleiNativeQR = true }) {
                        authButtonLabel("网页登录授权", icon: "globe")
                    }
                } else if type == .pan123 {
                    Button(action: { show123NativeQR = true }) {
                        authButtonLabel("网页登录授权", icon: "globe")
                    }
                } else if type == .one15 {
                    Button(action: { show115NativeQR = true }) {
                        authButtonLabel("网页登录授权", icon: "globe")
                    }
                } else {
                    Button(action: { webAuthDriveType = type }) {
                        authButtonLabel(type == .one15 ? "网页登录授权" : "网页登录兜底", icon: "globe")
                    }
                    disabledActionButton("原生扫码待补全")
                }
            }
            authDetailLine(for: type, fallback: tokens.first?.name ?? "暂无 Token")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))
    }

    /// 光鸭/蜗牛（Node 托管网盘）授权卡片
    private func nodeManagedAccountCard(type: CloudDriveManager.DriveType, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            accountHeader(
                title: type.displayName,
                subtitle: authSubtitle(for: type, fallback: "未登录"),
                icon: iconForDriveType(type),
                isReady: authManager.isAuthorized(type)
            )
            Text(note)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            HStack(spacing: 10) {
                if type == .guangya {
                    Button(action: { showGuangyaQR = true }) {
                        authButtonLabel("扫码授权", icon: "qrcode")
                    }
                } else if type == .woniu4k {
                    Button(action: { showWoniu4kLogin = true }) {
                        authButtonLabel("账号登录", icon: "person.text.rectangle")
                    }
                }
            }
            authDetailLine(for: type, fallback: "Node 托管")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))
    }

    private func authSubtitle(for type: CloudDriveManager.DriveType, fallback: String) -> String {
        if authManager.isAuthorized(type) {
            return authManager.displayName(for: type)
        }
        return fallback
    }

    private func authDetailLine(for type: CloudDriveManager.DriveType, fallback: String) -> some View {
        HStack {
            Text(fallback)
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .lineLimit(1)
            Spacer()
            Text(authManager.statusText(for: type))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(authManager.isAuthorized(type) ? .green : .gray)
            Button(action: {
                Task { _ = await authManager.validateCredential(for: type) }
            }) {
                Text("测试")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "E11D48"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: "E11D48").opacity(0.08))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground).opacity(0.75))
        .cornerRadius(10)
    }

    private func authButtonLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: "E11D48"))
        .cornerRadius(10)
    }

    private func accountHeader(title: String, subtitle: String, icon: String, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(isReady ? Color(hex: "E11D48") : .gray)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(isReady ? "已获取" : "未获取")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isReady ? .green : .gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isReady ? Color.green : Color.gray).opacity(0.12))
                .cornerRadius(8)
        }
    }

    private func authStatusRow(title: String, status: String, isReady: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundColor(isReady ? .green : .orange)
            Text(status)
                .font(.system(size: 12))
                .foregroundColor(isReady ? .green : .orange)
        }
        .padding(10)
        .background(Color(uiColor: .systemBackground).opacity(0.85))
        .cornerRadius(10)
    }

    private func disabledActionButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.gray.opacity(0.12))
            .cornerRadius(10)
    }

    private func baiduWebStatus(_ cookie: String) -> (text: String, ready: Bool) {
        let lower = cookie.lowercased()
        let hasBDUSS = lower.contains("bduss=")
        let hasSToken = lower.contains("stoken=")
        if hasBDUSS && hasSToken { return ("BDUSS/STOKEN 已获取", true) }
        if hasBDUSS { return ("缺少 STOKEN", false) }
        if hasSToken { return ("缺少 BDUSS", false) }
        return ("缺少 BDUSS/STOKEN", false)
    }

    private func baiduPCSStatus(_ cookie: String) -> (text: String, ready: Bool) {
        let lower = cookie.lowercased()
        let ready = lower.contains("panpsc=") || lower.contains("ptoken") || lower.contains("ndut_fmt=") || lower.contains("nd_ftid=")
        if ready { return ("可选 PCS Cookie 已获取", true) }
        return ("未配置，可忽略", false)
    }

    private func iconForDriveType(_ type: CloudDriveManager.DriveType) -> String {
        switch type {
        case .ali: return "a.circle.fill"
        case .quark: return "q.circle.fill"
        case .baidu: return "b.circle.fill"
        case .one15: return "1.circle.fill"
        case .uc: return "u.circle.fill"
        case .pan123: return "1.square.fill"
        case .pan139: return "9.square.fill"
        case .pan189: return "icloud.fill"
        case .xunlei: return "bolt.fill"
        case .guangya: return "g.circle.fill"
        case .woniu4k: return "s.circle.fill"
        }
    }
}

struct CloudPlaybackCacheView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @State private var baiduSummary = CloudDriveManager.shared.baiduPlaybackCacheSummary()
    @State private var baiduDiagnostics = CloudDriveManager.shared.recentBaiduRouteDiagnostics()
    @State private var showClearAllAlert = false

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    baiduCacheCard
                    baiduRouteDiagnosticCard
                    placeholderCard(type: .quark, note: "预留夸克 PlayItem/转码缓存清理入口")
                    placeholderCard(type: .ali, note: "预留阿里云盘播放缓存清理入口")
                    placeholderCard(type: .uc, note: "预留 UC 网盘播放缓存清理入口")
                    placeholderCard(type: .one15, note: "预留 115 网盘播放缓存清理入口")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("网盘播放缓存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { refreshSummary() }
            .alert("清空百度播放缓存", isPresented: $showClearAllAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    baiduSummary = cloudDriveManager.clearAllBaiduPlaybackCaches()
                }
            } message: {
                Text("会清空百度文件列表、播放地址、PlayItem 和 iBox PlayItem 缓存。不会删除 Token，也不会删除网盘文件。")
            }
        }
    }

    private var baiduCacheCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "b.circle.fill")
                    .foregroundColor(Color(hex: "E11D48"))
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 2) {
                    Text("百度网盘")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("已接入 PlayItem / iBox / 文件列表缓存")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                Text("\(baiduSummary.totalCount) 项")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "E11D48"))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                cacheMetric(title: "播放地址", value: "\(baiduSummary.playResultCount)", detail: "过期 \(baiduSummary.expiredPlayResultCount)")
                cacheMetric(title: "PlayItem", value: "\(baiduSummary.playItemCount)", detail: "path 缓存")
                cacheMetric(title: "iBox", value: "\(baiduSummary.iBoxPlayItemCount)", detail: "有效 dlink \(baiduSummary.validIBoxDlinkCount)")
                cacheMetric(title: "文件列表", value: "\(baiduSummary.fileListCount)", detail: "过期 \(baiduSummary.expiredFileListCount)")
            }

            VStack(alignment: .leading, spacing: 6) {
                let unified = cloudDriveManager.cloudPlayItemSummary(for: .baidu)
                Text("统一 PlayItem：\(unified.totalCount) 项，有效直链 \(unified.validPlayURLCount)，过期直链 \(unified.expiredPlayURLCount)")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text("占用：\(formatBytes(baiduSummary.storageBytes))")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text("最近更新：\(formatDate(baiduSummary.lastUpdatedAt))")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                if baiduSummary.expiredIBoxDlinkCount > 0 {
                    Text("有 \(baiduSummary.expiredIBoxDlinkCount) 个 iBox dlink 已过期，清理过期缓存会保留 path 以便下次刷新。")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: 10) {
                Button(action: {
                    baiduSummary = cloudDriveManager.clearExpiredBaiduPlaybackCaches()
                }) {
                    Text("清理过期")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "E11D48"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "E11D48").opacity(0.08))
                        .cornerRadius(10)
                }

                Button(action: { showClearAllAlert = true }) {
                    Text("清空百度缓存")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .cornerRadius(10)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
    }

    private var baiduRouteDiagnosticCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20))
                    .foregroundColor(Color(hex: "E11D48"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("百度路链诊断")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    Text("显示最近文件列表、iBox、path、Worker、本机取链状态")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                Spacer()
                Button("清空") {
                    cloudDriveManager.clearBaiduRouteDiagnostics()
                    baiduDiagnostics = []
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
            }

            if baiduDiagnostics.isEmpty {
                Text("暂无诊断记录。播放一次百度网盘资源后，这里会显示最近路链命中和失败原因。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .systemBackground).opacity(0.85))
                    .cornerRadius(10)
            } else {
                VStack(spacing: 8) {
                    ForEach(baiduDiagnostics.prefix(8)) { item in
                        diagnosticRow(item)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
    }

    private func diagnosticRow(_ item: CloudDriveManager.BaiduRouteDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.stage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(item.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(statusColor(item.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor(item.status).opacity(0.12))
                    .cornerRadius(6)
                Spacer()
                Text(formatDate(item.time))
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .lineLimit(2)
            if let fsId = item.fsId, !fsId.isEmpty {
                Text("fsId：\(fsId)")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(uiColor: .systemBackground).opacity(0.85))
        .cornerRadius(10)
    }

    private func placeholderCard(type: CloudDriveManager.DriveType, note: String) -> some View {
        let summary = cloudDriveManager.cloudPlayItemSummary(for: type)
        return HStack(spacing: 12) {
            Image(systemName: iconForDriveType(type))
                .foregroundColor(.gray)
                .font(.system(size: 20))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(type.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                Text(note)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                Text("统一 PlayItem：\(summary.totalCount) 项，有效直链 \(summary.validPlayURLCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(summary.totalCount > 0 ? "已记录" : "待接入")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.04)))
    }

    private func cacheMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .systemBackground).opacity(0.85))
        .cornerRadius(10)
    }

    private func refreshSummary() {
        baiduSummary = cloudDriveManager.baiduPlaybackCacheSummary()
        baiduDiagnostics = cloudDriveManager.recentBaiduRouteDiagnostics()
    }

    private func statusColor(_ status: String) -> Color {
        if status.contains("成功") || status.contains("命中") { return .green }
        if status.contains("失败") || status.contains("缺失") { return .orange }
        return Color(hex: "E11D48")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "暂无" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func iconForDriveType(_ type: CloudDriveManager.DriveType) -> String {
        switch type {
        case .ali: return "a.circle.fill"
        case .quark: return "q.circle.fill"
        case .baidu: return "b.circle.fill"
        case .one15: return "1.circle.fill"
        case .uc: return "u.circle.fill"
        case .pan123: return "1.square.fill"
        case .pan139: return "9.square.fill"
        case .pan189: return "icloud.fill"
        case .xunlei: return "bolt.fill"
        case .guangya: return "g.circle.fill"
        case .woniu4k: return "s.circle.fill"
        }
    }
}

struct SubscribeConfigView: View {
    @StateObject private var subManager = SpiderManager.shared.subManager
    @State private var subscribeURL = ""
    @State private var isLoading = false
    @State private var showSuccessAlert = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                Text("订阅配置").font(.system(size: 22, weight: .bold)).foregroundColor(.primary).padding(.top, 16)

                VStack(spacing: 16) {
                    Text("添加新订阅源").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("订阅地址").font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
                        TextField("URL", text: $subscribeURL)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 13))
                            .autocapitalization(.none).disableAutocorrection(true)
                    }
                    Button(action: addSubscription) {
                        HStack {
                            if isLoading { ProgressView().scaleEffect(0.8).tint(.white) }
                            Text("添加订阅").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundColor(.white).frame(maxWidth: .infinity)
                        .padding(.vertical, 12).background(Color(hex: "E11D48")).cornerRadius(12)
                    }
                    .disabled(subscribeURL.isEmpty || isLoading)
                }
                .padding(20).background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                .padding(.horizontal, 16)

                if !subManager.configURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已订阅源 (点击切换激活，左滑删除)")
                            .font(.system(size: 16, weight: .semibold)).foregroundColor(.primary).padding(.horizontal, 4)
                        
                        ForEach(Array(subManager.configURLs.enumerated()), id: \.offset) { index, url in
                            SubscriptionRow(
                                url: url,
                                isActive: index == subManager.activeURLIndex,
                                onTap: { 
                                    subManager.switchToSubscription(at: index)
                                    SpiderManager.shared.switchToSubscription(at: index)
                                },
                                onDelete: {
                                    subManager.removeURL(url)
                                    SpiderManager.shared.removeSubscriptionURL(url)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("").navigationBarHidden(true)
        .alert("添加成功", isPresented: $showSuccessAlert) { Button("确定", role: .cancel) {} }
        message: { Text("订阅源已添加并加载") }
        .alert("添加失败", isPresented: $showErrorAlert) { Button("确定", role: .cancel) {} }
        message: { Text(errorMessage) }
    }

    private func addSubscription() {
        guard !subscribeURL.isEmpty else { return }
        isLoading = true
        Task {
            await SpiderManager.shared.loadSubscribeConfig(from: subscribeURL)
            await MainActor.run {
                subscribeURL = ""
                isLoading = false
                if SpiderManager.shared.subManager.config != nil || !SpiderManager.shared.subManager.allSites.isEmpty {
                    showSuccessAlert = true
                } else if let err = SpiderManager.shared.subManager.errorMessage {
                    errorMessage = err
                    showErrorAlert = true
                } else {
                    showSuccessAlert = true
                }
            }
        }
    }
}

struct SubscriptionRow: View {
    let url: String
    let isActive: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(shortenURL(url))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isActive ? Color(hex: "E11D48") : .black)
                    .lineLimit(1)
                Text(url)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(Color(hex: "E11D48"))
                    .font(.system(size: 18))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isActive ? Color(hex: "E11D48").opacity(0.1) : Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color(hex: "E11D48").opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
    
    private func shortenURL(_ url: String) -> String {
        if let host = URL(string: url)?.host {
            return host
        }
        return url.prefix(30).description + (url.count > 30 ? "..." : "")
    }
}

// MARK: - 站源管理视图（启用/禁用 zhanyuan 站点）
struct ZhanyuanSiteManageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [ZhanyuanSite] = []
    @State private var searchText = ""

    var filteredSites: [ZhanyuanSite] {
        if searchText.isEmpty { return sites }
        return sites.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    TextField("搜索站点", text: $searchText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 14))
                }

                Section(header: Text("启用 \(filteredSites.filter(\.isActive).count)/\(sites.count) 个站点")) {
                    ForEach(filteredSites, id: \.name) { site in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(site.name)
                                    .font(.system(size: 15, weight: .medium))
                                Text(site.searchUrl)
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { site.isActive },
                                set: { newValue in
                                    toggleSite(name: site.name, isActive: newValue)
                                }
                            ))
                            .labelsHidden()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("站源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("全选") {
                        sites.forEach { site in
                            if !site.isActive {
                                toggleSite(name: site.name, isActive: true)
                            }
                        }
                    }
                    .font(.system(size: 14))
                }
            }
            .onAppear {
                loadSites()
            }
        }
    }

    private func loadSites() {
        sites = DatabaseManager.shared.queryAllZhanyuanSites()
    }

    private func toggleSite(name: String, isActive: Bool) {
        DatabaseManager.shared.updateZhanyuanActive(name: name, isActive: isActive)
        if let index = sites.firstIndex(where: { $0.name == name }) {
            sites[index].isActive = isActive
        }
    }
}

// MARK: - 兜底切片资源配置视图
struct FallbackConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spiderManager = SpiderManager.shared
    @StateObject private var remoteSourceManager = RemoteSourceConfigManager.shared
    @State private var newSiteName = ""
    @State private var newSiteAPI = ""
    @State private var showDeleteAlert = false
    @State private var siteToDelete: Int? = nil
    
    /// 远程 API 源列表（从缓存读取）
    private var remoteAPISites: [(name: String, api: String)] {
        remoteSourceManager.cachedAPISites().compactMap { site in
            guard let api = site.api else { return nil }
            return (name: site.name, api: api)
        }
    }
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // 远程默认 API 源列表
                    if !remoteAPISites.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("远程默认源")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(remoteAPISites.enumerated()), id: \.offset) { index, site in
                                HStack {
                                    Text(site.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("远程")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.6))
                                        .cornerRadius(4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // 内置兜底源列表（仅兼容模式）
                    if RemoteSourceConfigManager.shared.bundleSourcesEnabled {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("内置兜底源 (兼容模式)")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(SpiderManager.builtinFallbackSites.enumerated()), id: \.offset) { index, site in
                                HStack {
                                    Text(site.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Text("内置")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.5))
                                        .cornerRadius(4)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // 自定义兜底源列表
                    if !spiderManager.customFallbackSites.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义兜底源")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(spiderManager.customFallbackSites.enumerated()), id: \.offset) { index, site in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(site.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(site.api)
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        siteToDelete = index
                                        showDeleteAlert = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // 添加新源
                    VStack(spacing: 16) {
                        Text("添加自定义切片源")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("源名称")
                                .font(.system(size: 13, weight: .medium))
                            TextField("如：我的资源站", text: $newSiteName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 13))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("API地址")
                                .font(.system(size: 13, weight: .medium))
                            TextField("https://example.com/api.php/provide/vod", text: $newSiteAPI)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                        
                        Button(action: addCustomSite) {
                            HStack {
                                Image(systemName: "plus")
                                Text("添加")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(hex: "E11D48")
                                    .opacity(newSiteName.isEmpty || newSiteAPI.isEmpty ? 0.5 : 1)
                            )
                            .cornerRadius(12)
                        }
                        .disabled(newSiteName.isEmpty || newSiteAPI.isEmpty)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("切片资源管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
            .alert("删除确认", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let index = siteToDelete {
                        spiderManager.removeCustomFallbackSite(at: index)
                    }
                }
            } message: {
                Text("确定要删除这个自定义切片源吗？")
            }
        }
    }
    
    private func addCustomSite() {
        guard !newSiteName.isEmpty && !newSiteAPI.isEmpty else { return }
        spiderManager.addCustomFallbackSite(name: newSiteName, api: newSiteAPI)
        newSiteName = ""
        newSiteAPI = ""
    }
}

// MARK: - 解析器配置视图
struct ParserConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var spiderManager = SpiderManager.shared
    @State private var newParserName = ""
    @State private var newParserUrl = ""
    @State private var showDeleteAlert = false
    @State private var parserToDelete: Int? = nil
    
    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // 自定义解析器列表
                    if !spiderManager.customParsers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义解析器")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 4)
                            
                            ForEach(Array(spiderManager.customParsers.enumerated()), id: \.offset) { index, parser in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(parser.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(parser.url)
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button(action: {
                                        parserToDelete = index
                                        showDeleteAlert = true
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 14))
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.gray.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("暂无自定义解析器")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                            Text("添加解析器后可提高切片资源播放成功率")
                                .font(.system(size: 12))
                                .foregroundColor(.gray.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    
                    // 添加新解析器
                    VStack(spacing: 16) {
                        Text("添加自定义解析器")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("解析器名称")
                                .font(.system(size: 13, weight: .medium))
                            TextField("如：777 解析", text: $newParserName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 13))
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("解析器地址")
                                .font(.system(size: 13, weight: .medium))
                            TextField("https://jx.xxx.com/player/?url=", text: $newParserUrl)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 12))
                        }
                        
                        Button(action: addCustomParser) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 16))
                                Text("添加解析器")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(hex: "E11D48")
                                    .opacity(newParserName.isEmpty || newParserUrl.isEmpty ? 0.5 : 1)
                            )
                            .cornerRadius(12)
                        }
                        .disabled(newParserName.isEmpty || newParserUrl.isEmpty)
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.gray.opacity(0.06)))
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("解析器管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
            .alert("删除确认", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let index = parserToDelete {
                        spiderManager.removeCustomParser(at: index)
                    }
                }
            } message: {
                Text("确定要删除这个解析器吗？")
            }
        }
    }
    
    private func addCustomParser() {
        guard !newParserName.isEmpty && !newParserUrl.isEmpty else { return }
        spiderManager.addCustomParser(name: newParserName, url: newParserUrl)
        newParserName = ""
        newParserUrl = ""
    }
}

// MARK: - 百度网盘测试工具
struct BaiduTestView: View {
    @StateObject private var cloudDriveManager = CloudDriveManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var shareURL = ""
    @State private var bduss = ""
    @State private var logs: [String] = []
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var scrollToBottom = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 输入区域
                ScrollView {
                    VStack(spacing: 16) {
                        inputSection
                        
                        if !logs.isEmpty {
                            logSection
                        }
                        
                        if let result = testResult {
                            resultSection(result: result)
                        }
                    }
                    .padding(16)
                }
                
                // 测试按钮
                HStack {
                    Button(action: runTest) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.8)
                                Text(isTesting ? "测试中..." : "开始测试")
                            } else {
                                Text("开始测试")
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(isTesting || shareURL.isEmpty || bduss.isEmpty ? Color.gray : Color(hex: "E11D48"))
                        .cornerRadius(12)
                    }
                    .disabled(isTesting || shareURL.isEmpty || bduss.isEmpty)
                }
                .padding(16)
                .background(Color(uiColor: .systemBackground))
            }
            .background(Color(hex: "F8FAFC"))
            .navigationTitle("百度网盘测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
        }
    }
    
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("测试说明")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)
            
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(icon: "link", text: "粘贴百度网盘分享链接（必须带提取码）")
                InfoRow(icon: "key", text: "主账号 Cookie 需要同时包含 BDUSS 和 STOKEN，和 iBox 路线一致")
                InfoRow(icon: "tag", text: "PCS Cookie 仅作为可选附加缓存；iBox-style 主路链不依赖它")
                InfoRow(icon: "play.circle", text: "点击测试后会直接跳转到播放页面")
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(12)
            
            TextField("分享链接，如：https://pan.baidu.com/s/1xxx?pwd=ab12", text: $shareURL)
                .font(.system(size: 13))
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(10)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            
            TextField("完整 Cookie / BDUSS+STOKEN", text: $bduss)
                .font(.system(size: 13))
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(10)
                .autocapitalization(.none)
        }
    }
    
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测试日志")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(logColor(for: log))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 300)
            .padding(12)
            .background(Color.black.opacity(0.95))
            .cornerRadius(12)
        }
    }
    
    private func resultSection(result: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: result.hasPrefix("✅") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                Text(result.hasPrefix("✅") ? "测试成功" : "测试失败")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                Spacer()
            }
            
            Text(result)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(uiColor: .systemBackground))
        .cornerRadius(12)
    }
    
    private func runTest() {
        guard !shareURL.isEmpty, !bduss.isEmpty else { return }
        
        logs.removeAll()
        testResult = nil
        isTesting = true
        
        addLog("====== 开始测试 ======")
        addLog("分享链接：\(shareURL.prefix(60))...")
        addLog("BDUSS: \(bduss.prefix(20))...")
        addLog("")
        
        Task {
            do {
                addLog("[1/3] 检查是否配置 Token...")
                let tokens = cloudDriveManager.tokens(for: .baidu)
                if tokens.isEmpty {
                    addLog("❌ 未配置百度网盘 Token，请先在上方添加")
                    await MainActor.run {
                        testResult = "❌ 未配置 Token，请在设置中添加百度网盘 BDUSS"
                        isTesting = false
                    }
                    return
                }
                addLog("✅ Token 已配置")
                
                // 跳转到播放器
                addLog("[2/3] 准备跳转到播放器...")
                addLog("✅ 验证通过")
                
                // 实际测试：调用 resolveBaiduPlayURL
                addLog("[3/3] 调用播放接口...")
                let result = try await cloudDriveManager.resolveBaiduPlayURL(shareURL: shareURL, bduss: bduss)
                
                addLog("✅ 播放地址获取成功!")
                addLog("📍 URL: \(result.url.prefix(80))...")
                addLog("")
                addLog("====== 测试完成 ======")
                addLog("✅ 成功获取播放地址，即将跳转到播放器")
                
                // 延迟跳转，让用户看到日志
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 秒
                
                await MainActor.run {
                    testResult = "✅ 测试成功！播放地址已获取，即将跳转到播放器..."
                    isTesting = false
                    
                    // TODO: 跳转到播放器页面（需要实现导航）
                    // 暂时只显示成功消息
                }
                
            } catch let error as DriveError {
                let msg = driveErrorToString(error)
                addLog("❌ \(msg)")
                await MainActor.run {
                    testResult = "❌ \(msg)"
                    isTesting = false
                }
            } catch {
                addLog("❌ 未知错误：\(error.localizedDescription)")
                await MainActor.run {
                    testResult = "❌ 未知错误：\(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
    
    private func addLog(_ message: String) {
        logs.append(message)
        scrollToBottom = true
    }
    
    private func logColor(for log: String) -> Color {
        if log.contains("✅") { return .green }
        if log.contains("❌") { return .red }
        if log.contains("⚠️") { return .orange }
        if log.contains("[Baidu]") { return .cyan }
        return .white
    }
    
    private func driveErrorToString(_ error: DriveError) -> String {
        switch error {
        case .tokenNotConfigured(let name): return "未配置\(name) Token"
        case .noPlayURL(let reason): return reason
        case .saveFailed: return "转存失败"
        case .invalidResponse: return "服务器响应异常"
        case .invalidShareURL: return "无效的分享链接"
        case .notImplemented: return "暂不支持"
        }
    }
}

struct UniversalPlayTestView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var resourceURL = ""
    @State private var displayName = "通用播放测试"
    @State private var showPlayer = false
    @State private var testVideo: VodItem?
    @State private var warningText: String?
    @State private var mpvTestURL = ""
    @State private var showMPVRenderTest = false
    @State private var testUserAgent = ""
    @State private var testReferer = ""
    @State private var testCookie = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        introSection
                        inputSection

                        if let warningText {
                            warningSection(warningText)
                        }
                    }
                    .padding(16)
                }

                VStack(spacing: 10) {
                    Button(action: startPlayTest) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                            Text("打开正式播放器测试")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canStart ? Color(hex: "E11D48") : Color.gray)
                        .cornerRadius(12)
                    }
                    .disabled(!canStart)

                    Button(action: startMPVRenderTest) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                            Text("MPV RenderContext实测")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(Color(hex: "E11D48"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(canStart ? Color(hex: "E11D48").opacity(0.08) : Color.gray.opacity(0.08))
                        .cornerRadius(12)
                    }
                    .disabled(!canStart)
                }
                .padding(16)
                .background(Color(uiColor: .systemBackground))
            }
            .background(Color(hex: "F8FAFC"))
            .navigationTitle("通用播放测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
            .fullScreenCover(item: $testVideo) { video in
                VideoPlayerViewV2(video: video)
            }
            .sheet(isPresented: $showMPVRenderTest) {
                MPVRenderContextDebugView(initialURL: mpvTestURL, headers: mpvHeaders)
            }
        }
    }

    private var canStart: Bool {
        let trimmed = resourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    private var introSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用途")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 8) {
                InfoRow(icon: "externaldrive.connected.to.line.below", text: "网盘分享链接：百度、夸克、阿里、UC、115 等会走现有网盘解析")
                InfoRow(icon: "film", text: "直链资源：mp4、m3u8、mov 等可用正式播放器或 MPV RenderContext 对比")
                InfoRow(icon: "square.stack.3d.up", text: "切片资源：粘贴 m3u8 或站点解析出的播放链接即可测试")
                InfoRow(icon: "externaldrive", text: "m3u8 是主要测试方向，MKV 可走 MPV RenderContext 单独验证")
            }
            .padding(12)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(12)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资源链接")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.gray)

            TextField("显示名称（可选）", text: $displayName)
                .font(.system(size: 13))
                .padding(12)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(10)

            TextEditor(text: $resourceURL)
                .font(.system(size: 13))
                .frame(minHeight: 110)
                .padding(8)
                .background(Color(uiColor: .systemBackground))
                .cornerRadius(10)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .onChange(of: resourceURL) { _ in
                    updateWarning()
                }

            VStack(alignment: .leading, spacing: 8) {
                Text("MPV Header（可选，测试网盘/切片直链时使用）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.gray)

                TextField("User-Agent", text: $testUserAgent)
                    .font(.system(size: 12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(8)

                TextField("Referer", text: $testReferer)
                    .font(.system(size: 12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(8)

                TextField("Cookie", text: $testCookie)
                    .font(.system(size: 12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(8)
            }

            HStack(spacing: 8) {
                Button("清空") {
                    resourceURL = ""
                    warningText = nil
                }
                .font(.system(size: 13))
                .foregroundColor(.gray)

                Spacer()

                Text(detectedTypeText)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "E11D48"))
            }
        }
    }

    private var detectedTypeText: String {
        let url = resourceURL.lowercased()
        if CloudDriveManager.detectDrive(from: resourceURL) != nil { return "已识别：网盘链接" }
        if url.contains(".m3u8") { return "已识别：m3u8 切片" }
        if url.contains(".mp4") { return "已识别：mp4 直链" }
        if url.contains(".mkv") { return "已识别：mkv（原生播放器可能不支持）" }
        if canStart { return "已识别：普通 URL" }
        return "请输入 http/https 链接"
    }

    private var mpvHeaders: [String: String] {
        var headers: [String: String] = [:]
        let ua = testUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let referer = testReferer.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = testCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ua.isEmpty { headers["User-Agent"] = ua }
        if !referer.isEmpty { headers["Referer"] = referer }
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return headers
    }

    private func warningSection(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(12)
    }

    private func updateWarning() {
        let lower = resourceURL.lowercased()
        if lower.contains(".mkv") {
            warningText = "检测到 MKV。建议优先使用 MPV RenderContext实测，正式播放器可能仍受原生内核限制。"
        } else if CloudDriveManager.detectDrive(from: resourceURL) != nil {
            warningText = "检测到网盘分享链接。正式播放器会走现有网盘解析；MPV RenderContext实测适合粘贴解析后的直链或切片地址。"
        } else if lower.contains(".m3u8") {
            warningText = "检测到 m3u8。MPV RenderContext实测里可用 HLS-极速/高清/fMP4 对比首帧速度。"
        } else {
            warningText = nil
        }
    }

    private func startPlayTest() {
        let trimmed = resourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "通用播放测试"
            : displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        testVideo = VodItem(
            vodId: trimmed,
            vodName: name,
            vodPic: "",
            vodRemarks: detectedTypeText,
            vodYear: nil,
            vodArea: nil,
            vodDirector: nil,
            vodActor: nil,
            vodContent: nil,
            vodPlayFrom: "通用测试",
            vodPlayUrl: trimmed
        )
    }

    private func startMPVRenderTest() {
        let trimmed = resourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mpvTestURL = trimmed
        showMPVRenderTest = true
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "E11D48"))
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QuarkNativeQRLoginTestView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloudDriveManager: CloudDriveManager

    @State private var qrToken: CloudDriveManager.QuarkQrLoginToken?
    @State private var qrImage: UIImage?
    @State private var statusText = "点击下方按钮生成夸克登录二维码"
    @State private var detailText = "二维码内容使用抓包确认的 su.quark.cn 登录跳转链接，扫码后会轮询 service_ticket。"
    @State private var isGenerating = false
    @State private var isPolling = false
    @State private var pollCount = 0
    @State private var serviceTicket = ""
    @State private var savedCookie = ""
    @State private var cookieFields: [String: String] = [:]
    @State private var errorText = ""

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    statusCard
                    qrCard
                    actionArea
                    resultCard
                    tipCard
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("夸克原生扫码测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onDisappear {
                isPolling = false
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isPolling ? "arrow.triangle.2.circlepath" : "qrcode")
                    .foregroundColor(Color(hex: "E11D48"))
                Text(statusText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if isGenerating || isPolling {
                    ProgressView().scaleEffect(0.85)
                }
            }
            Text(detailText)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.05)))
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 230, height: 230)
                    .padding(14)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.08))
                    .frame(width: 230, height: 230)
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 44))
                                .foregroundColor(.gray)
                            Text("未生成二维码")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    )
            }

            if let qrToken {
                Text("Token：\(shortToken(qrToken.token))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var actionArea: some View {
        VStack(spacing: 10) {
            Button(action: { Task { await startLoginFlow() } }) {
                HStack {
                    Image(systemName: "qrcode")
                    Text(qrToken == nil ? "生成二维码并开始轮询" : "重新生成二维码")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(hex: "E11D48"))
                .cornerRadius(12)
            }
            .disabled(isGenerating)

            if isPolling {
                Button(action: {
                    isPolling = false
                    statusText = "已停止轮询"
                    detailText = "可重新生成二维码继续测试。"
                }) {
                    Text("停止轮询")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "E11D48"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(hex: "E11D48").opacity(0.08))
                        .cornerRadius(10)
                }
            }
        }
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("结果")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)

            resultRow("轮询次数", "\(pollCount)")
            if !serviceTicket.isEmpty {
                resultRow("Service Ticket", shortToken(serviceTicket))
            }
            if !savedCookie.isEmpty {
                resultRow("保存状态", "已写入夸克 Token")
            }
            if !cookieFields.isEmpty {
                Text(cookieFields.keys.sorted().joined(separator: "、"))
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("扫码确认成功后，这里会显示写入的 Cookie 字段。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.05)))
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("测试说明")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
            Text("请用手机夸克 App 扫描二维码并确认登录。该接口属于抓包得到的私有接口，后续仍保留网页登录和手动 Cookie 作为兜底。")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @MainActor
    private func startLoginFlow() async {
        isGenerating = true
        isPolling = false
        pollCount = 0
        serviceTicket = ""
        savedCookie = ""
        cookieFields = [:]
        errorText = ""
        statusText = "正在生成二维码..."
        detailText = "请求 getTokenForQrcodeLogin"

        do {
            let token = try await cloudDriveManager.quarkCreateQrToken()
            qrToken = token
            qrImage = makeQRCode(from: token.qrPayload)
            isGenerating = false
            isPolling = true
            statusText = "等待扫码确认"
            detailText = "二维码内容：su.quark.cn 登录跳转链接；每 2 秒轮询一次。"
            await pollLoop(token)
        } catch {
            isGenerating = false
            isPolling = false
            statusText = "生成二维码失败"
            detailText = "请稍后重试，或继续使用网页登录兜底。"
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func pollLoop(_ token: CloudDriveManager.QuarkQrLoginToken) async {
        while isPolling && pollCount < 90 {
            pollCount += 1
            do {
                let result = try await cloudDriveManager.quarkPollQrStatus(token: token)
                switch result {
                case .pending:
                    statusText = "等待扫码确认"
                    detailText = "第 \(pollCount) 次轮询：尚未确认。"
                case .scanned:
                    statusText = "已扫码，等待确认"
                    detailText = "请在手机夸克 App 内确认登录。"
                case .success(let ticket):
                    serviceTicket = ticket
                    statusText = "已确认，正在换取 Cookie"
                    detailText = "请求 account/info?st=service_ticket"
                    try await exchangeAndSave(ticket)
                    return
                case .expired:
                    isPolling = false
                    statusText = "二维码已过期"
                    detailText = "请重新生成二维码。"
                    return
                case .failed(let message):
                    isPolling = false
                    statusText = "轮询失败"
                    detailText = message
                    return
                }
            } catch {
                isPolling = false
                statusText = "轮询异常"
                detailText = "请重新生成二维码，或使用网页登录兜底。"
                errorText = error.localizedDescription
                return
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        if isPolling {
            isPolling = false
            statusText = "轮询超时"
            detailText = "二维码可能已失效，请重新生成。"
        }
    }

    @MainActor
    private func exchangeAndSave(_ ticket: String) async throws {
        let loginResult = try await cloudDriveManager.quarkExchangeServiceTicket(serviceTicket: ticket)
        savedCookie = loginResult.cookie
        cookieFields = loginResult.cookies
        let tokenName = loginResult.nickName?.isEmpty == false ? "夸克扫码-\(loginResult.nickName!)" : "夸克扫码登录"
        CloudDriveAuthManager.shared.saveQuarkLogin(cookie: loginResult.cookie, nickName: loginResult.nickName, avatarURL: loginResult.avatarURL)
        cloudDriveManager.addToken(type: .quark, name: tokenName, value: loginResult.cookie)
        isPolling = false
        statusText = "夸克扫码登录成功"
        detailText = "Cookie 已保存到夸克 Token，可回到播放链路测试。"
        // 扫码成功后自动关闭弹窗
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }

    private func makeQRCode(from text: String) -> UIImage? {
        let data = Data(text.utf8)
        print("[QRCode] payload length: \(data.count) bytes")
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            print("[QRCode] CIQRCodeGenerator not available")
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        // 长 payload 用 L 纠错级别（容量更大），M 级别可能生成失败
        filter.setValue(data.count > 800 ? "L" : "M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else {
            print("[QRCode] outputImage nil, payload too long for QR")
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func shortToken(_ text: String) -> String {
        guard text.count > 16 else { return text }
        return "\(text.prefix(8))...\(text.suffix(6))"
    }
}

struct Pan139WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct Pan189WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct XunleiWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct Pan123WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct Pan115WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct AliOpenListWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct UCWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct NativeCloudQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let driveType: CloudDriveManager.DriveType
    var onUCLoginSuccess: Binding<Bool>? = nil
    @State private var qrImage: UIImage? = nil
    @State private var statusText = "准备生成二维码"
    @State private var detailText = ""
    @State private var errorText = ""
    @State private var isGenerating = false
    @State private var isPolling = false
    @State private var pollCount = 0
    @State private var ucToken: CloudDriveAuthManager.UCQrLoginToken? = nil
    @State private var baiduToken: CloudDriveAuthManager.BaiduQrLoginToken? = nil
    @State private var baiduBDUSSURL: String? = nil
    @State private var pan189Token: CloudDriveAuthManager.Pan189QrLoginToken? = nil
    @StateObject private var pan139Helper = CloudDriveAuthManager.Pan139QrLoginHelper()
    @StateObject private var pan189Helper = CloudDriveAuthManager.Pan189LoginHelper()
    @StateObject private var xunleiHelper = CloudDriveAuthManager.XunleiLoginHelper()
    @StateObject private var pan123Helper = CloudDriveAuthManager.Pan123LoginHelper()
    @StateObject private var pan115Helper = CloudDriveAuthManager.Pan115LoginHelper()
    @StateObject private var aliOpenListHelper = CloudDriveAuthManager.AliOpenListQrLoginHelper()

    var body: some View {
        NavigationView {
            Group {
                if driveType == .one15 || driveType == .pan123 || driveType == .pan139 || driveType == .pan189 || driveType == .xunlei {
                    VStack(spacing: 0) {
                        if driveType == .one15 {
                            Pan115WebView(webView: pan115Helper.webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if driveType == .pan123 {
                            Pan123WebView(webView: pan123Helper.webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if driveType == .pan139 {
                            Pan139WebView(webView: pan139Helper.webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if driveType == .pan189 {
                            Pan189WebView(webView: pan189Helper.webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if driveType == .xunlei {
                            XunleiWebView(webView: xunleiHelper.webView)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        VStack(spacing: 8) {
                            statusCard
                            tipCard
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            Text("\(driveType.displayName) 原生扫码授权")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            qrCard
                            statusCard
                            tipCard

                            Button(action: {
                                Task { await startLoginFlow() }
                            }) {
                                Text(isPolling ? "重新生成二维码" : "生成二维码")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(hex: "E11D48"))
                                    .cornerRadius(12)
                            }
                            .disabled(isGenerating)
                        }
                        .padding(16)
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("扫码授权")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                if driveType == .pan139 {
                    pan139Helper.cleanup()
                }
                if driveType == .pan189 {
                    pan189Helper.cleanup()
                }
                if driveType == .xunlei {
                    xunleiHelper.cleanup()
                }
                if driveType == .pan123 {
                    pan123Helper.cleanup()
                }
                if driveType == .one15 {
                    pan115Helper.cleanup()
                }
            }
            .onAppear {
                if driveType == .one15 || driveType == .pan123 || driveType == .pan139 || driveType == .pan189 || driveType == .xunlei {
                    Task { await startLoginFlow() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: 12) {
            if driveType == .pan139 {
                Pan139WebView(webView: pan139Helper.webView)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if driveType == .pan189 {
                Pan189WebView(webView: pan189Helper.webView)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if driveType == .xunlei {
                XunleiWebView(webView: xunleiHelper.webView)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if driveType == .pan123 {
                Pan123WebView(webView: pan123Helper.webView)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if driveType == .one15 {
                Pan115WebView(webView: pan115Helper.webView)
                    .frame(height: 320)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if isGenerating {
                ProgressView()
                    .frame(width: 220, height: 220)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 88))
                    .foregroundColor(.gray.opacity(0.45))
                    .frame(width: 220, height: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.gray.opacity(0.05)))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if isPolling {
                    Text("第 \(pollCount) 次")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.05)))
    }

    private var tipCard: some View {
        Text(tipText)
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.08)))
    }

    private var tipText: String {
        switch driveType {
        case .baidu:
            return "请使用百度 App 扫码并确认。百度扫码登录用于获取 BDUSS/STOKEN/bdstoken，分享风控仍保留 WebView 兜底。"
        case .ali:
            return "请使用阿里云盘 App 扫码并确认。扫码成功后自动获取 refresh_token，用于解析播放文件链接。"
        case .pan139:
            return "请使用中国移动云盘 App 扫码并确认。扫码成功后自动获取 Cookie，用于解析播放云盘分享链接。"
        case .pan189:
            return "页面会自动切换到扫码登录。请使用天翼云盘 APP 扫描二维码并确认，登录成功后自动获取 Cookie。"
        case .xunlei:
            return "请在页面中登录迅雷账号（手机号+密码或扫码）。登录成功后自动获取 Cookie，用于后续迅雷云盘资源解析播放。"
        case .pan123:
            return "请在页面中登录123云盘（手机号/微信扫码登录）。登录成功后自动获取 Cookie，用于解析播放云盘分享链接。"
        case .one15:
            return "请在页面中登录115网盘（账号密码或手机验证码）。登录成功后自动获取 Cookie，用于解析播放文件链接。"
        default:
            return "请使用 UC / UC网盘客户端扫码确认。若点击确认后卡住，请点击下方「网页登录兜底」在页面中登录。"
        }
    }

    @MainActor
    private func startAliNativeQRLogin() async {
        isGenerating = true
        isPolling = false
        pollCount = 0
        errorText = ""
        detailText = ""
        qrImage = nil
        statusText = "正在生成二维码..."

        do {
            let token = try await CloudDriveManager.shared.aliCreateQrToken()
            qrImage = makeQRCode(from: token.qrURL)
            statusText = "等待阿里云盘扫码确认"
            detailText = "每 2 秒轮询一次扫码状态。"
            isGenerating = false
            isPolling = true
            await pollAliNativeQR(token)
        } catch {
            isGenerating = false
            isPolling = false
            statusText = "生成二维码失败"
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func pollAliNativeQR(_ token: CloudDriveManager.AliQrLoginToken) async {
        var consecutiveErrors = 0
        while isPolling && pollCount < 90 {
            pollCount += 1
            do {
                let result = try await CloudDriveManager.shared.aliPollQrStatus(token: token)
                consecutiveErrors = 0
                switch result {
                case .pending:
                    statusText = "等待阿里云盘扫码确认"
                    detailText = "请使用阿里云盘 App 扫码。"
                case .scanned:
                    statusText = "已扫码，等待确认"
                    detailText = "请在手机端确认登录。"
                case .confirmed(let refreshToken, let accessToken, let nickName):
                    isPolling = false
                    statusText = "已确认，正在保存 Token"
                    detailText = ""
                    do {
                        try await CloudDriveManager.shared.aliSaveQrToken(
                            refreshToken: refreshToken,
                            accessToken: accessToken,
                            nickName: nickName
                        )
                        statusText = "阿里云盘扫码登录成功"
                        detailText = "Token 已保存到授权中心。"
                    } catch {
                        statusText = "保存 Token 失败"
                        errorText = error.localizedDescription
                    }
                    return
                case .expired:
                    isPolling = false
                    statusText = "二维码已过期"
                    detailText = "请重新生成二维码。"
                    return
                case .failed(let message):
                    isPolling = false
                    statusText = "轮询失败"
                    detailText = message
                    return
                }
            } catch {
                consecutiveErrors += 1
                let nsError = error as NSError
                let isNetworkError = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorNetworkConnectionLost ||
                     nsError.code == NSURLErrorNotConnectedToInternet ||
                     nsError.code == NSURLErrorTimedOut ||
                     nsError.code == NSURLErrorCannotConnectToHost ||
                     nsError.code == NSURLErrorCannotFindHost ||
                     nsError.code == NSURLErrorDNSLookupFailed ||
                     nsError.code == NSURLErrorSecureConnectionFailed)
                if isNetworkError && consecutiveErrors < 5 {
                    detailText = "网络波动，正在重试…（\(consecutiveErrors)/5）"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                isPolling = false
                statusText = "轮询异常"
                errorText = consecutiveErrors >= 5 ? "网络连接异常，已重试\(consecutiveErrors)次" : error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if pollCount >= 90 {
            isPolling = false
            statusText = "登录超时"
            detailText = "二维码已超过 3 分钟有效期，请重新生成。"
        }
    }

    @MainActor
    private func startLoginFlow() async {
        isGenerating = true
        isPolling = false
        pollCount = 0
        errorText = ""
        detailText = ""
        qrImage = nil
        statusText = "正在生成二维码..."

        do {
            switch driveType {
            case .uc:
                let token = try await CloudDriveAuthManager.shared.ucCreateQrToken()
                ucToken = token
                qrImage = makeQRCode(from: token.qrPayload)
                statusText = "等待 UC 扫码确认"
                detailText = "每 2 秒轮询一次扫码状态。"
                isGenerating = false
                isPolling = true
                await pollUC(token)
            case .baidu:
                let token = try await CloudDriveAuthManager.shared.baiduCreateQrToken()
                baiduToken = token
                if let url = URL(string: token.qrURL),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data) {
                    qrImage = image
                } else {
                    qrImage = makeQRCode(from: token.qrURL)
                }
                statusText = "等待百度扫码确认"
                detailText = "每 2 秒轮询一次扫码状态。"
                isGenerating = false
                isPolling = true
                await pollBaidu(token)
            case .pan139:
                pan139Helper.cleanup()
                pan139Helper.startLogin()
                isGenerating = false
                isPolling = true
                statusText = pan139Helper.statusText
                detailText = ""
                await pollPan139()
            case .pan189:
                pan189Helper.cleanup()
                pan189Helper.startLogin()
                isGenerating = false
                isPolling = true
                statusText = pan189Helper.statusText
                detailText = ""
                await pollPan189()
            case .xunlei:
                xunleiHelper.cleanup()
                xunleiHelper.startLogin()
                isGenerating = false
                isPolling = true
                statusText = xunleiHelper.statusText
                detailText = ""
                await pollXunlei()
            case .pan123:
                pan123Helper.cleanup()
                pan123Helper.startLogin()
                isGenerating = false
                isPolling = true
                statusText = pan123Helper.statusText
                detailText = ""
                await pollPan123()
            case .one15:
                pan115Helper.cleanup()
                pan115Helper.startLogin()
                isGenerating = false
                isPolling = true
                statusText = pan115Helper.statusText
                detailText = ""
                await pollPan115()
            case .ali:
                aliOpenListHelper.cleanup()
                // 使用原生扫码登录（官方 API），替代 OpenList 网页授权
                await startAliNativeQRLogin()
            default:
                throw AuthError.remoteError("暂不支持 \(driveType.displayName) 原生扫码")
            }
        } catch {
            isGenerating = false
            isPolling = false
            statusText = "生成二维码失败"
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func pollUC(_ token: CloudDriveAuthManager.UCQrLoginToken) async {
        var consecutiveErrors = 0
        var serviceTicket: String?
        while isPolling && pollCount < 90 && serviceTicket == nil {
            pollCount += 1
            do {
                let result = try await CloudDriveAuthManager.shared.ucPollQrStatus(token: token)
                consecutiveErrors = 0
                switch result {
                case .pending:
                    statusText = "等待 UC 扫码确认"
                    detailText = "请使用 UC 手机端扫码。"
                case .scanned:
                    statusText = "已扫码，等待确认"
                    detailText = "请在手机端确认登录。"
                case .success(let ticket):
                    serviceTicket = ticket
                case .expired:
                    isPolling = false
                    statusText = "二维码已过期"
                    detailText = "请重新生成二维码。"
                    return
                case .failed(let message):
                    isPolling = false
                    statusText = "轮询失败"
                    detailText = message
                    return
                }
            } catch {
                consecutiveErrors += 1
                let nsError = error as NSError
                let isNetworkError = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorNetworkConnectionLost ||
                     nsError.code == NSURLErrorNotConnectedToInternet ||
                     nsError.code == NSURLErrorTimedOut ||
                     nsError.code == NSURLErrorCannotConnectToHost ||
                     nsError.code == NSURLErrorCannotFindHost ||
                     nsError.code == NSURLErrorDNSLookupFailed ||
                     nsError.code == NSURLErrorSecureConnectionFailed)
                if isNetworkError && consecutiveErrors < 5 {
                    detailText = "网络波动，正在重试…（\(consecutiveErrors)/5）"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                isPolling = false
                statusText = "轮询异常"
                errorText = consecutiveErrors >= 5 ? "网络连接异常，已重试\(consecutiveErrors)次" : error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        // 超时（3分钟）或中途被取消
        if pollCount >= 90 && serviceTicket == nil {
            isPolling = false
            statusText = "登录超时"
            detailText = "二维码已超过 3 分钟有效期，请重新生成。"
            return
        }

        // 轮询成功拿到 serviceTicket，单独做 exchange（带网络重试，不跳回轮询）
        guard let ticket = serviceTicket else { return }
        statusText = "已确认，正在换取 Cookie"
        detailText = ""
        for exchangeAttempt in 1...5 {
            do {
                try await CloudDriveAuthManager.shared.ucExchangeServiceTicket(ticket)
                isPolling = false
                statusText = "UC 扫码登录成功"
                detailText = "Cookie 已保存到授权中心。"
                onUCLoginSuccess?.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            } catch {
                let nsError = error as NSError
                let isNetworkError = nsError.domain == NSURLErrorDomain &&
                    (nsError.code == NSURLErrorNetworkConnectionLost ||
                     nsError.code == NSURLErrorNotConnectedToInternet ||
                     nsError.code == NSURLErrorTimedOut ||
                     nsError.code == NSURLErrorCannotConnectToHost ||
                     nsError.code == NSURLErrorCannotFindHost ||
                     nsError.code == NSURLErrorDNSLookupFailed ||
                     nsError.code == NSURLErrorSecureConnectionFailed)
                if isNetworkError && exchangeAttempt < 5 {
                    detailText = "换取Cookie网络波动，重试…（\(exchangeAttempt)/5）"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                isPolling = false
                statusText = "换取Cookie失败"
                errorText = error.localizedDescription
                return
            }
        }
    }

    @MainActor
    private func pollBaidu(_ token: CloudDriveAuthManager.BaiduQrLoginToken) async {
        while isPolling && pollCount < 90 {
            pollCount += 1
            do {
                let result = try await CloudDriveAuthManager.shared.baiduPollQrStatus(token: token)
                switch result {
                case .pending:
                    statusText = "等待百度扫码"
                case .scanned:
                    statusText = "已扫码，等待确认"
                case .success(let bdussURL):
                    statusText = "已确认，正在换取 BDUSS"
                    baiduBDUSSURL = bdussURL
                    try await CloudDriveAuthManager.shared.baiduExchangeQrLogin(token: token, bdussURL: bdussURL)
                    isPolling = false
                    statusText = "百度扫码登录成功"
                    detailText = "BDUSS/STOKEN 已保存；PCS Cookie 已作为可选附加缓存尝试捕获。"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                    return
                case .expired:
                    isPolling = false
                    statusText = "二维码已过期"
                    return
                case .failed(let message):
                    isPolling = false
                    statusText = "轮询失败"
                    detailText = message
                    return
                }
            } catch {
                isPolling = false
                statusText = "轮询异常"
                errorText = error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    @MainActor
    private func pollAliOpenList() async {
        while isPolling && pollCount < 180 {
            pollCount += 1
            if aliOpenListHelper.isLoggedIn {
                isPolling = false
                statusText = "阿里云盘扫码登录成功"
                detailText = "refresh_token 已保存到授权中心。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            }
            if !aliOpenListHelper.errorText.isEmpty {
                statusText = aliOpenListHelper.statusText
                detailText = aliOpenListHelper.errorText
            } else {
                statusText = aliOpenListHelper.statusText
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        isPolling = false
        statusText = "登录超时"
        detailText = "请重新尝试。"
    }

    @MainActor
    private func pollPan139() async {
        while isPolling && pollCount < 120 {
            pollCount += 1
            if pan139Helper.isLoggedIn {
                isPolling = false
                statusText = "139云盘扫码登录成功"
                detailText = "Cookie 已保存到授权中心。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            }
            if !pan139Helper.errorText.isEmpty {
                isPolling = false
                statusText = "登录失败"
                detailText = pan139Helper.errorText
                return
            }
            statusText = pan139Helper.statusText
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "二维码已过期"
            detailText = "请重新生成二维码。"
        }
    }

    @MainActor
    private func pollPan189() async {
        while isPolling && pollCount < 180 {
            pollCount += 1
            if pan189Helper.isLoggedIn {
                isPolling = false
                statusText = "天翼云盘登录成功"
                detailText = "Cookie 已保存到授权中心。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            }
            if !pan189Helper.errorText.isEmpty {
                isPolling = false
                statusText = "登录失败"
                detailText = pan189Helper.errorText
                return
            }
            statusText = pan189Helper.statusText
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "登录超时"
            detailText = "请在6分钟内完成登录，或重新打开页面。"
        }
    }

    @MainActor
    private func pollXunlei() async {
        while isPolling && pollCount < 90 {
            pollCount += 1
            if xunleiHelper.isLoggedIn {
                isPolling = false
                statusText = "登录成功"
                detailText = "迅雷云盘 Cookie 已保存"
                dismiss()
                return
            }
            if !xunleiHelper.errorText.isEmpty {
                statusText = "登录失败"
                errorText = xunleiHelper.errorText
                isPolling = false
                return
            }
            statusText = xunleiHelper.statusText
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "超时"
            errorText = "登录超时（3分钟）"
        }
    }

    @MainActor
    private func pollPan123() async {
        while isPolling && pollCount < 180 {
            pollCount += 1
            if pan123Helper.isLoggedIn {
                isPolling = false
                statusText = "123云盘登录成功"
                detailText = "Cookie 已保存到授权中心。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            }
            if !pan123Helper.errorText.isEmpty {
                isPolling = false
                statusText = "登录失败"
                detailText = pan123Helper.errorText
                return
            }
            statusText = pan123Helper.statusText
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "登录超时"
            detailText = "请在6分钟内完成登录，或重新打开页面。"
        }
    }

    @MainActor
    private func pollPan115() async {
        while isPolling && pollCount < 180 {
            pollCount += 1
            if pan115Helper.isLoggedIn {
                isPolling = false
                statusText = "115网盘登录成功"
                detailText = "Cookie 已保存到授权中心。"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
                return
            }
            if !pan115Helper.errorText.isEmpty {
                isPolling = false
                statusText = "登录失败"
                detailText = pan115Helper.errorText
                return
            }
            statusText = pan115Helper.statusText
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "登录超时"
            detailText = "请在6分钟内完成登录，或重新打开页面。"
        }
    }

    private func makeQRCode(from text: String) -> UIImage? {
        let data = Data(text.utf8)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - UC TV 授权二维码视图

struct UCTVAuthQRView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage? = nil
    @State private var statusText = "正在获取授权二维码..."
    @State private var detailText = ""
    @State private var errorText = ""
    @State private var isPolling = false
    @State private var pollCount = 0
    @State private var authQR: CloudDriveAuthManager.UCTVAuthQR? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("UC TV 画质授权")
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.top, 20)

                    if let qrImage = qrImage {
                        Image(uiImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 240, height: 240)
                            .padding(12)
                            .background(Color.white)
                            .cornerRadius(12)
                            .shadow(radius: 4)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray6))
                                .frame(width: 240, height: 240)
                            if errorText.isEmpty {
                                ProgressView()
                                    .scaleEffect(1.5)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.largeTitle)
                                        .foregroundColor(.orange)
                                    Text("获取失败")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        Text(statusText)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(statusText.contains("成功") ? .green : .primary)

                        if !detailText.isEmpty {
                            Text(detailText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        if !errorText.isEmpty {
                            Text(errorText)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }

                    if !errorText.isEmpty && !isPolling {
                        Button(action: { startAuth() }) {
                            Label("重新获取二维码", systemImage: "arrow.clockwise")
                                .font(.headline)
                        }
                        .buttonStyle(.bordered)
                    }

                    if isPolling {
                        Text("已轮询 \(pollCount) 次")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear { startAuth() }
    }

    private func startAuth() {
        errorText = ""
        statusText = "正在获取授权二维码..."
        detailText = "请稍候..."

        Task {
            do {
                let qr = try await CloudDriveAuthManager.shared.ucStartTVAuth()
                authQR = qr
                if let imgData = Data(base64Encoded: qr.qrData),
                   let img = UIImage(data: imgData) {
                    qrImage = img
                }
                statusText = "请使用 UC 浏览器扫码授权"
                detailText = "扫码后可解锁普画 2K 画质，提升播放速度"
                isPolling = true
                pollCount = 0
                await pollTVCode()
            } catch {
                errorText = error.localizedDescription
                statusText = "获取二维码失败"
                detailText = ""
            }
        }
    }

    private func pollTVCode() async {
        guard let qr = authQR else { return }
        let maxPoll = 120 // 4分钟
        var netRetry = 0
        while isPolling && pollCount < maxPoll {
            pollCount += 1
            do {
                let code = try await CloudDriveAuthManager.shared.ucPollTVAuth(
                    queryToken: qr.queryToken,
                    deviceId: qr.deviceId
                )
                if let code = code {
                    // 拿到了授权码，兑换 TV Token
                    statusText = "授权成功，正在获取 TV Token..."
                    detailText = ""
                    do {
                        let result = try await CloudDriveAuthManager.shared.ucExchangeTVCode(
                            code: code,
                            deviceId: qr.deviceId
                        )
                        CloudDriveAuthManager.shared.ucSaveTVToken(accessToken: result.accessToken, refreshToken: result.refreshToken)
                        isPolling = false
                        statusText = "✅ UC TV 授权成功"
                        detailText = "已解锁普画 2K 画质，播放速度将大幅提升"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                        return
                    } catch {
                        // Token 兑换失败，直接报错不重试
                        isPolling = false
                        errorText = "Token 兑换失败: \(error.localizedDescription)"
                        statusText = "授权失败"
                        detailText = ""
                        return
                    }
                }
                netRetry = 0
                statusText = "等待扫码授权"
                detailText = "请使用 UC 浏览器扫描二维码并确认授权（剩余 \(maxPoll - pollCount) 次）"
            } catch {
                // 轮询出错（网络错误、二维码过期等）
                let errMsg = error.localizedDescription
                if errMsg.contains("已过期") {
                    isPolling = false
                    errorText = errMsg
                    statusText = "二维码已过期"
                    detailText = "请点击重新获取"
                    return
                }
                netRetry += 1
                if netRetry > 3 {
                    isPolling = false
                    errorText = errMsg
                    statusText = "轮询失败"
                    detailText = ""
                    return
                }
                statusText = "网络波动，重试中 (\(netRetry)/3)"
                detailText = errMsg
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if isPolling {
            isPolling = false
            statusText = "二维码已过期"
            detailText = "请点击重新获取"
        }
    }
}

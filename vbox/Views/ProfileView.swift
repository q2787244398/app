import SwiftUI
import PhotosUI
import AVKit
import Photos

// MARK: - 福利观看记录播放桥接

/// 用于从观看记录/收藏点击播放福利视频时，携带平台定位信息
struct WelfareHistoryItem: Identifiable {
    let id = UUID()
    let platformKey: String
    let vodId: String
    let vodName: String
    let vodPic: String
}

/// 福利视频播放桥接包装视图，添加关闭按钮
struct WelfareBridgeContainer: View {
    let platformKey: String
    let vodId: String
    let vodName: String
    let vodPic: String
    @Binding var item: WelfareHistoryItem?

    var body: some View {
        Group {
            if let bridgeView = WelfarePlatformRouter.shared.makeVideoBridgeView(
                platformKey: platformKey,
                vodId: vodId,
                vodName: vodName,
                vodPic: vodPic
            ) {
                bridgeView
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("该福利平台已下线或不可用")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { item = nil }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }
}

// MARK: - ProfileView

struct ProfileView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var updateManager = UpdateManager.shared
    @State private var isLoggedIn: Bool = false
    @State private var username: String = ""
    @State private var account: String = ""        // 登录账号（本地账号体系的标识，不可改）
    @State private var avatarImage: Image? = nil
    @State private var showLoginSheet: Bool = false
    @State private var showEditNickname: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showPhotoPicker: Bool = false
    @State private var historyRecords: [HistoryRecord] = []
    @State private var showWatchHistory: Bool = false
    @State private var showFavorites: Bool = false
    @State private var showDownloads: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var selectedVideoItem: VodItem? = nil
    @State private var welfareHistoryItem: WelfareHistoryItem? = nil
    @State private var showWelfareSheet: Bool = false
    @State private var showWelfareSettings: Bool = false
    @State private var welfarePasswordInput: String = ""
    @State private var welfarePasswordError: Bool = false
    @State private var isRefreshingRemoteSource: Bool = false
    @State private var showPushPlay: Bool = false
    @State private var showCloudDriveSort: Bool = false
    @State private var showFeedbackSheet: Bool = false
    @State private var feedbackTitle: String = ""
    @State private var feedbackBody: String = ""
    @StateObject private var feedbackService = FeedbackService.shared

    var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var backgroundColor: Color {
        return Color.clear
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: 头部登录区
                    loginSection

                    // MARK: 观看记录模块
                    watchHistorySection

                    // MARK: 三大功能入口
                    featureEntriesSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .background(backgroundColor)
            .onAppear {
                loadInitialState()
                reloadHistory()
            }
            .sheet(isPresented: $showLoginSheet) {
                LoginSheetView(
                    isLoggedIn: $isLoggedIn,
                    username: $username,
                    account: $account,
                    isPresented: $showLoginSheet
                )
            }
            .sheet(isPresented: $showEditNickname) {
                EditNicknameSheet(currentName: username) { newName in
                    username = newName
                    DatabaseManager.shared.setSetting(key: "username", value: newName)
                }
            }
            .sheet(isPresented: $showWatchHistory) {
                NavigationView {
                    WatchHistoryView()
                }
            }
            .sheet(isPresented: $showFavorites) {
                NavigationView {
                    FavoriteView()
                }
            }
            .sheet(isPresented: $showDownloads) {
                NavigationView {
                    DownloadView()
                }
            }
            .onChange(of: selectedPhotoItem) { _ in
                handlePhotoSelection()
            }
            .onChange(of: settings.welfareEnabled) { newValue in
                reloadHistory()
                // 关闭福利时重置解锁状态，下次打开需要重新输入密码
                if !newValue { settings.welfareUnlocked = false }
            }

            // 右上角设置入口
            Button(action: {
                showSettingsSheet = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18))
                    .foregroundColor(accentColor)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.top, 8)

            if showCloudDriveSort {
                CloudDriveSortPopup {
                    showCloudDriveSort = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(10)
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationView {
                SettingsView()
            }
        }
        .sheet(isPresented: $showWelfareSheet) {
            welfareUnlockSheet
        }
        .sheet(isPresented: $showPushPlay) {
            PushPlayView()
        }
        .fullScreenCover(item: $selectedVideoItem) { video in
            VideoDetailView(video: video)
        }
        .fullScreenCover(item: $welfareHistoryItem) { item in
            NavigationView {
                WelfareBridgeContainer(
                    platformKey: item.platformKey,
                    vodId: item.vodId,
                    vodName: item.vodName,
                    vodPic: item.vodPic,
                    item: $welfareHistoryItem
                )
            }
            .navigationViewStyle(.stack)
        }
        .sheet(isPresented: $showFeedbackSheet) {
            feedbackSheet
        }
    }

    // MARK: - 头部登录区

    /// 读取当前软件图标（Info.plist CFBundleIcons 优先，兜底 AppIcon 资源）
    private var appIconImage: UIImage? {
        if let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            if let img = UIImage(named: name) { return img }
        }
        return UIImage(named: "AppIcon")
    }

    private var loginSection: some View {
        VStack(spacing: 12) {
            // 头像
            Button(action: {
                showPhotoPicker = true
            }) {
                ZStack {
                    if let avatarImage = avatarImage {
                        avatarImage
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    } else if isLoggedIn && !username.isEmpty {
                        ZStack {
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 80, height: 80)
                            Text(String(username.prefix(1)))
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.gray)
                        }
                    } else {
                        // 未登录：默认头像使用软件图标（读取失败时回退原 person.circle）
                        if let appIcon = appIconImage {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 80, height: 80)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray.opacity(0.4))
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            // 用户名（登录后点击可修改）
            Button(action: {
                if isLoggedIn { showEditNickname = true }
            }) {
                HStack(spacing: 6) {
                    Text(isLoggedIn ? username : "未登录")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(textColor)
                    if isLoggedIn {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            // 账号说明（登录后展示，与可修改的用户名区分开）
            if isLoggedIn {
                Text("账号：\(account)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // 登录按钮
            if !isLoggedIn {
                Button(action: {
                    showLoginSheet = true
                }) {
                    Text("点击登录")
                        .font(.system(size: 15))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
    }

    // MARK: - 观看记录模块

    private var watchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题行
            HStack {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: 3, height: 16)
                        .cornerRadius(2)
                    Text("观看记录")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(textColor)
                }

                Spacer()

                Button(action: {
                    showWatchHistory = true
                }) {
                    Text("查看更多 >")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }

            // 横向滚动封面列表
            if historyRecords.isEmpty {
                Text("暂无观看记录")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(historyRecords) { record in
                            VStack(spacing: 4) {
                                coverImage(urlString: record.imgurl)
                                    .frame(width: 100, height: 140)
                                    .cornerRadius(8)
                                    .clipped()

                                Text(record.name)
                                    .font(.system(size: 12))
                                    .foregroundColor(textColor)
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }
                            .onTapGesture {
                                if record.laiyuan.hasPrefix("[福利]"), !record.detailua.isEmpty {
                                    welfareHistoryItem = WelfareHistoryItem(
                                        platformKey: record.detailua,
                                        vodId: record.detailurl,
                                        vodName: record.name,
                                        vodPic: record.imgurl
                                    )
                                } else {
                                    selectedVideoItem = makeVodItem(from: record)
                                }
                            }
                        }
                    }
                }
            }

            }
    }

    // MARK: - 功能入口

    private var featureEntriesSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // 福利专区
                featureButton(icon: "gift.fill", title: "福利专区") {
                    welfarePasswordInput = ""
                    welfarePasswordError = false
                    showWelfareSheet = true
                }

                // 我的收藏
                featureButton(icon: "star.fill", title: "我的收藏") {
                    showFavorites = true
                }

                // 推送播放
                featureButton(icon: "play.rectangle.on.rectangle.fill", title: "推送播放") {
                    showPushPlay = true
                }
            }

            HStack(spacing: 12) {
                // 分享vbox
                ShareLink(item: updateManager.shareURL) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 24))
                            .foregroundColor(accentColor)
                        Text("分享vbox")
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                }
                .buttonStyle(.plain)

                // 下载管理
                featureButton(icon: "arrow.down.circle.fill", title: "下载管理") {
                    showDownloads = true
                }

                // 网盘排序
                featureButton(icon: "arrow.up.arrow.down", title: "网盘排序") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showCloudDriveSort = true
                    }
                }
            }

            // Bug 反馈
            featureButton(icon: "ladybug.fill", title: "Bug反馈") {
                feedbackTitle = ""
                feedbackBody = ""
                feedbackService.reset()
                showFeedbackSheet = true
            }
        }
    }

    // 功能按钮构建器
    private func featureButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(accentColor)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 福利解锁弹窗（含功能开关）

    private var welfareUnlockSheet: some View {
        VStack(spacing: 24) {
            // 标题 + 左上角刷新 + 右上角设置
            ZStack {
                // 标题居中
                VStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 44))
                        .foregroundColor(accentColor)
                    Text("福利专区")
                        .font(.system(size: 22, weight: .bold))
                    Text(settings.welfareUnlocked ? "管理福利功能" : "输入密码解锁福利内容")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                // 左上角刷新按钮（仅解锁后可操作）
                if settings.welfareUnlocked {
                    HStack {
                        Button(action: refreshRemoteSource) {
                            if isRefreshingRemoteSource {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(accentColor)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 20))
                                    .foregroundColor(accentColor)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isRefreshingRemoteSource)
                        .accessibilityLabel("刷新远程源")
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.top, -40)
                }

                // 右上角设置按钮（仅解锁后可操作）
                if settings.welfareUnlocked {
                    HStack {
                        Spacer()
                        Button(action: { showWelfareSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 20))
                                .foregroundColor(accentColor)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                    }
                    .padding(.top, -40)
                }
            }
            .padding(.top, 26)

            if !settings.welfareUnlocked {
                // === 阶段一：密码输入 ===
                SecureField("请输入解锁密码", text: $welfarePasswordInput)
                    .font(.system(size: 18))
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 30)
                    .keyboardType(.numberPad)

                if welfarePasswordError {
                    Text("密码错误，请重试")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .transition(.opacity)
                }

                Button {
                    if welfarePasswordInput == settings.welfarePassword {
                        settings.welfareUnlocked = true
                    } else {
                        welfarePasswordError = true
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                    }
                } label: {
                    Text("确认解锁")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 30)
            } else {
                // === 阶段二：功能开关 ===
                VStack(spacing: 16) {
                    // 福利Tab开关
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("启用福利专区")
                                .font(.system(size: 16, weight: .medium))
                            Text("关闭后福利Tab和播放记录将隐藏")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $settings.welfareEnabled)
                            .labelsHidden()
                            .tint(accentColor)
                    }
                    .padding(.horizontal, 30)

                    Divider()
                        .padding(.horizontal, 30)

                    // 修改密码（后续可用）
                    HStack {
                        Text("密码")
                            .font(.system(size: 16, weight: .medium))
                        Spacer()
                        Text("******")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 30)
                }
                .padding(.vertical, 8)

                // 完成按钮
                Button {
                    showWelfareSheet = false
                } label: {
                    Text("完成")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 30)
            }

            Spacer()
        }
        .presentationDetents([.medium])
        .sheet(isPresented: $showWelfareSettings) {
            NavigationView {
                WelfareSettingsView()
            }
        }
    }

    /// 手动刷新福利远程源
    private func refreshRemoteSource() {
        guard !isRefreshingRemoteSource else { return }
        isRefreshingRemoteSource = true
        WelfarePlatformConfigStore.shared.refresh { _ in
            isRefreshingRemoteSource = false
        }
    }

    // MARK: - Bug 反馈弹窗

    private var feedbackSheet: some View {
        VStack(spacing: 20) {
            // 标题
            HStack {
                Text("Bug 反馈")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button(action: { showFeedbackSheet = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.gray.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)

            if feedbackService.submitSuccess {
                // 提交成功
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("提交成功")
                        .font(.system(size: 18, weight: .semibold))
                    Text("感谢你的反馈！")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Button("关闭") {
                        showFeedbackSheet = false
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(accentColor)
                    .cornerRadius(10)
                }
                .padding(.top, 20)
            } else {
                // 问题标题
                VStack(alignment: .leading, spacing: 6) {
                    Text("问题标题")
                        .font(.system(size: 14, weight: .medium))
                    TextField("简要描述问题", text: $feedbackTitle)
                        .font(.system(size: 15))
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(8)
                }

                // 问题描述
                VStack(alignment: .leading, spacing: 6) {
                    Text("详细描述")
                        .font(.system(size: 14, weight: .medium))
                    ZStack(alignment: .topLeading) {
                        if feedbackBody.isEmpty {
                            Text("请详细描述问题发生的场景、操作步骤等...")
                                .font(.system(size: 15))
                                .foregroundColor(.gray.opacity(0.5))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                        }
                        TextEditor(text: $feedbackBody)
                            .font(.system(size: 15))
                            .padding(8)
                            .frame(minHeight: 120)
                            .scrollContentBackground(.hidden)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .cornerRadius(8)
                    }
                }

                // 错误提示
                if let error = feedbackService.submitError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                }

                // 提交按钮
                Button(action: {
                    Task {
                        await feedbackService.submit(title: feedbackTitle, body: feedbackBody)
                    }
                }) {
                    HStack(spacing: 8) {
                        if feedbackService.isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(feedbackService.isSubmitting ? "提交中..." : "提交反馈")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        feedbackTitle.trimmingCharacters(in: .whitespaces).isEmpty || feedbackService.isSubmitting
                            ? accentColor.opacity(0.4)
                            : accentColor
                    )
                    .cornerRadius(12)
                }
                .disabled(feedbackTitle.trimmingCharacters(in: .whitespaces).isEmpty || feedbackService.isSubmitting)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Helper Methods

    private func coverImage(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }

    private func loadInitialState() {
        // 账号（登录标识）：新版独立存储；旧版本没有 account 时，用老 username 兜底迁移
        if let savedAccount = DatabaseManager.shared.getSetting(key: "account"),
           !savedAccount.isEmpty {
            account = savedAccount
        }
        if let savedUsername = DatabaseManager.shared.getSetting(key: "username"),
           !savedUsername.isEmpty {
            username = savedUsername
            if account.isEmpty { account = savedUsername }
        }
        if let savedLoggedIn = DatabaseManager.shared.getSetting(key: "isLoggedIn"),
           savedLoggedIn == "true" {
            isLoggedIn = true
        }
        // 恢复已保存的头像
        if let base64 = DatabaseManager.shared.getSetting(key: "avatar_image"),
           let data = Data(base64Encoded: base64),
           let uiImage = UIImage(data: data) {
            avatarImage = Image(uiImage: uiImage)
        }
    }

    private func reloadHistory() {
        var allHistory = DatabaseManager.shared.queryHistory()
        if !settings.welfareEnabled {
            allHistory = allHistory.filter { !($0.laiyuan.hasPrefix("[福利]")) }
        }
        historyRecords = Array(allHistory.prefix(20))
    }

    private func handlePhotoSelection() {
        guard let item = selectedPhotoItem else { return }
        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                if case .success(let data) = result, let data = data, let uiImage = UIImage(data: data) {
                    // 压缩并持久化头像
                    let resized = Self.resizeImage(uiImage, maxSide: 200)
                    avatarImage = Image(uiImage: resized)
                    if let pngData = resized.pngData() {
                        let base64 = pngData.base64EncodedString()
                        DatabaseManager.shared.setSetting(key: "avatar_image", value: base64)
                    }
                }
            }
        }
    }

    private static func resizeImage(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let maxDim = max(size.width, size.height)
        guard maxDim > maxSide else { return image }
        let scale = maxSide / maxDim
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }

    private func makeVodItem(from record: HistoryRecord) -> VodItem {
        VodItem(vodId: record.detailurl, vodName: record.name, vodPic: record.imgurl, vodRemarks: record.laiyuan)
    }

    private func makeVodItem(from record: FavoriteRecord) -> VodItem {
        VodItem(vodId: record.detailurl, vodName: record.name, vodPic: record.imgurl, vodRemarks: record.laiyuan)
    }
}

// MARK: - LoginSheetView

struct LoginSheetView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var isLoggedIn: Bool
    @Binding var username: String
    @Binding var account: String
    @Binding var isPresented: Bool
    @State private var inputUsername: String = ""
    @State private var inputPassword: String = ""
    @State private var showPassword: Bool = false
    @State private var isLoading: Bool = false
    @State private var loginError: String? = nil

    private let gradientColors: [Color] = [Color(hex: "3B82F6"), Color(hex: "2563EB"), Color(hex: "1D4ED8")]

    /// 读取当前软件图标（Info.plist CFBundleIcons 优先，兜底 AppIcon 资源）
    private var appIconImage: UIImage? {
        if let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last {
            if let img = UIImage(named: name) { return img }
        }
        return UIImage(named: "AppIcon")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 12)

                // App 图标（使用软件图标，读取失败时回退原渐变闪电样式）
                ZStack {
                    if let appIcon = appIconImage {
                        Image(uiImage: appIcon)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 72, height: 72)
                            .shadow(color: Color(hex: "3B82F6").opacity(0.4), radius: 16, y: 6)

                        Image(systemName: "bolt.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                }
                .padding(.bottom, 20)

                // 标题
                Text("欢迎回来")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.primary)

                Text("登录你的账号继续使用")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)

                Spacer().frame(height: 28)

                // 登录卡片
                VStack(spacing: 16) {
                    // 账号输入框（登录标识）
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "3B82F6"))
                            .frame(width: 22)

                        TextField("账号", text: $inputUsername)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(12)

                    // 密码输入框
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "3B82F6"))
                            .frame(width: 22)

                        if showPassword {
                            TextField("密码", text: $inputPassword)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        } else {
                            SecureField("密码", text: $inputPassword)
                        }

                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.fill" : "eye.slash.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.gray)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(12)

                    // 错误提示
                    if let error = loginError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    // 登录/注册按钮
                    Button(action: { performLogin() }) {
                        Group {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(isRegistered ? "登录" : "登录 / 注册")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(14)
                        .shadow(color: Color(hex: "3B82F6").opacity(0.35), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(inputUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    .opacity(inputUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.6 : 1)

                    // 上级用户
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text("上级用户：没有上级用户")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 14)
                    .background(Color(uiColor: .systemGray6).opacity(0.6))
                    .cornerRadius(20)
                    .padding(.top, 6)

                    // 取消按钮
                    Button(action: { isPresented = false }) {
                        Text("取消")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: Color.black.opacity(0.08), radius: 20, y: 4)
                )
                .padding(.horizontal, 24)

                Spacer().frame(height: 20)
            }
        }
        .background(
            Color(uiColor: .systemGroupedBackground).opacity(0.5).ignoresSafeArea()
        )
    }

    private var isRegistered: Bool {
        let trimmed = inputUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let savedPassword = DatabaseManager.shared.getSetting(key: "password_\(trimmed)")
        return savedPassword != nil && !savedPassword!.isEmpty
    }

    private func performLogin() {
        let trimmed = inputUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPassword = inputPassword.trimmingCharacters(in: .whitespaces)

        guard !trimmed.isEmpty else {
            loginError = "请输入用户名"
            return
        }

        guard !trimmedPassword.isEmpty else {
            loginError = "请输入密码"
            return
        }

        isLoading = true
        loginError = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let savedPassword = DatabaseManager.shared.getSetting(key: "password_\(trimmed)")

            if let saved = savedPassword, !saved.isEmpty {
                // 已注册，验证密码
                if saved == trimmedPassword {
                    loginSuccess(name: trimmed)
                } else {
                    loginError = "密码错误，请重试"
                    isLoading = false
                }
            } else {
                // 未注册，直接注册
                DatabaseManager.shared.setSetting(key: "password_\(trimmed)", value: trimmedPassword)
                loginSuccess(name: trimmed)
            }
        }
    }

    private func loginSuccess(name: String) {
        account = name
        // 首次登录时用户名默认取账号；已有用户名则保留（账号与用户名分离）
        if username.isEmpty { username = name }
        isLoggedIn = true
        DatabaseManager.shared.setSetting(key: "account", value: name)
        DatabaseManager.shared.setSetting(key: "username", value: username)
        DatabaseManager.shared.setSetting(key: "isLoggedIn", value: "true")
        isLoading = false
        isPresented = false
    }
}

// MARK: - EditNicknameSheet（修改用户名：仅改展示名，不影响登录账号）

struct EditNicknameSheet: View {
    @Environment(\.presentationMode) private var presentationMode
    let currentName: String
    let onSave: (String) -> Void

    @State private var input: String = ""
    @State private var errorText: String? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                TextField("输入新的用户名", text: $input)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .systemGray6))
                    .cornerRadius(12)

                if let errorText = errorText {
                    Text(errorText)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                Button(action: save) {
                    Text("保存")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "3B82F6"))
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)

                Text("修改的是展示用户名，登录账号保持不变")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                Spacer()
            }
            .padding(24)
            .navigationTitle("修改用户名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear { input = currentName }
        }
        .accentColor(Color(hex: "3B82F6"))
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "用户名不能为空"
            return
        }
        guard trimmed.count <= 16 else {
            errorText = "用户名最长 16 个字符"
            return
        }
        if trimmed == currentName {
            presentationMode.wrappedValue.dismiss()
            return
        }
        onSave(trimmed)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - WatchHistoryView

struct WatchHistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode
    @State private var historyRecords: [HistoryRecord] = []
    @State private var selectedVideo: VodItem? = nil
    @State private var welfareHistoryItem: WelfareHistoryItem? = nil

    var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var body: some View {
        List {
            if historyRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("暂无观看记录")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(historyRecords) { record in
                    HStack(spacing: 12) {
                        coverThumbnail(urlString: record.imgurl)
                            .frame(width: 60, height: 80)
                            .cornerRadius(6)
                            .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(textColor)
                                .lineLimit(1)

                            if !record.laiyuan.isEmpty {
                                Text(record.laiyuan)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }

                            Text(formatDate(record.lastPlayedAt))
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if record.laiyuan.hasPrefix("[福利]"), !record.detailua.isEmpty {
                            welfareHistoryItem = WelfareHistoryItem(
                                platformKey: record.detailua,
                                vodId: record.detailurl,
                                vodName: record.name,
                                vodPic: record.imgurl
                            )
                        } else {
                            selectedVideo = VodItem(vodId: record.detailurl, vodName: record.name, vodPic: record.imgurl, vodRemarks: record.laiyuan)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            if let id = record.id {
                                DatabaseManager.shared.deleteHistory(id: id)
                                historyRecords.removeAll { $0.id == id }
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("观看记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)
            }

            if !historyRecords.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        DatabaseManager.shared.clearHistory()
                        historyRecords = []
                    }) {
                        Text("清空")
                            .foregroundColor(accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            var allHistory = DatabaseManager.shared.queryHistory()
            if !settings.welfareEnabled {
                allHistory = allHistory.filter { !($0.laiyuan.hasPrefix("[福利]")) }
            }
            historyRecords = allHistory
        }
        .onChange(of: settings.welfareEnabled) { _ in
            var allHistory = DatabaseManager.shared.queryHistory()
            if !settings.welfareEnabled {
                allHistory = allHistory.filter { !($0.laiyuan.hasPrefix("[福利]")) }
            }
            historyRecords = allHistory
        }
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video)
        }
        .fullScreenCover(item: $welfareHistoryItem) { item in
            NavigationView {
                WelfareBridgeContainer(
                    platformKey: item.platformKey,
                    vodId: item.vodId,
                    vodName: item.vodName,
                    vodPic: item.vodPic,
                    item: $welfareHistoryItem
                )
            }
            .navigationViewStyle(.stack)
        }
    }

    private func coverThumbnail(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }

    private func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - FavoriteView

struct FavoriteView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode
    @State private var favorites: [FavoriteRecord] = []
    @State private var selectedVideo: VodItem? = nil
    @State private var welfareHistoryItem: WelfareHistoryItem? = nil

    var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var body: some View {
        List {
            if favorites.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Text("暂无收藏")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(favorites) { record in
                    HStack(spacing: 12) {
                        coverThumbnail(urlString: record.imgurl)
                            .frame(width: 60, height: 80)
                            .cornerRadius(6)
                            .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(textColor)
                                .lineLimit(1)

                            if !record.laiyuan.isEmpty {
                                Text(record.laiyuan)
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if record.laiyuan.hasPrefix("[福利]"), !record.detailua.isEmpty {
                            welfareHistoryItem = WelfareHistoryItem(
                                platformKey: record.detailua,
                                vodId: record.detailurl,
                                vodName: record.name,
                                vodPic: record.imgurl
                            )
                        } else {
                            selectedVideo = VodItem(vodId: record.detailurl, vodName: record.name, vodPic: record.imgurl, vodRemarks: record.laiyuan)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            if let id = record.id {
                                DatabaseManager.shared.removeFavorite(id: id)
                                favorites.removeAll { $0.id == id }
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("我的收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)
            }

            if !favorites.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        for record in favorites {
                            if let id = record.id {
                                DatabaseManager.shared.removeFavorite(id: id)
                            }
                        }
                        favorites = []
                    }) {
                        Text("清空")
                            .foregroundColor(accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            favorites = DatabaseManager.shared.queryFavorites()
        }
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video)
        }
        .fullScreenCover(item: $welfareHistoryItem) { item in
            NavigationView {
                WelfareBridgeContainer(
                    platformKey: item.platformKey,
                    vodId: item.vodId,
                    vodName: item.vodName,
                    vodPic: item.vodPic,
                    item: $welfareHistoryItem
                )
            }
            .navigationViewStyle(.stack)
        }
    }

    private func coverThumbnail(urlString: String) -> some View {
        Group {
            if urlString.isEmpty {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            } else {
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                    }
                }
            }
        }
    }
}

// MARK: - DownloadView

struct DownloadView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.presentationMode) private var presentationMode
    @State private var downloadRecords: [DownloadRecord] = []
    @State private var playingRecord: DownloadRecord?
    @State private var showSaveTip = false
    @State private var saveTipMessage = ""

    var textColor: Color {
        if settings.usesVisualSkin { return .white }
        return Color(uiColor: .label)
    }

    var body: some View {
        List {
            if downloadRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer().frame(height: 100)
                    Text("暂无下载内容")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            } else {
                // 正在下载
                let downloading = downloadRecords.filter { $0.status == "downloading" || $0.status == "pending" }
                if !downloading.isEmpty {
                    Section("下载中 (\(downloading.count))") {
                        ForEach(downloading) { record in
                            DownloadProgressRow(record: record, textColor: textColor)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let record = downloading[index]
                                if record.status == "downloading" {
                                    DownloadManager.shared.cancelDownload(id: record.id ?? 0)
                                }
                                DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
                            }
                            reloadDownloads()
                        }
                    }
                }

                // 已完成
                let completed = downloadRecords.filter { $0.status == "completed" }
                if !completed.isEmpty {
                    Section("已完成 (\(completed.count))") {
                        ForEach(completed) { record in
                            DownloadCompletedRow(
                                record: record,
                                textColor: textColor,
                                onPlay: { playingRecord = record },
                                onSaveToFiles: { saveToFiles(record: record) },
                                onSaveToPhotos: { saveToPhotos(record: record) }
                            )
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let record = completed[index]
                                if !record.filePath.isEmpty {
                                    try? FileManager.default.removeItem(atPath: record.filePath)
                                }
                                DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
                            }
                            reloadDownloads()
                        }
                    }
                }

                // 失败
                let failed = downloadRecords.filter { $0.status == "failed" }
                if !failed.isEmpty {
                    Section("下载失败 (\(failed.count))") {
                        ForEach(failed) { record in
                            DownloadFailedRow(record: record, textColor: textColor) {
                                DownloadManager.shared.retryDownload(id: record.id ?? 0)
                                reloadDownloads()
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let record = failed[index]
                                DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
                            }
                            reloadDownloads()
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(settings.usesVisualSkin ? .dark : nil, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(textColor)
                }
                .buttonStyle(.plain)
            }
            if !downloadRecords.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("清空已完成", role: .destructive) {
                            DownloadManager.shared.clearCompleted()
                            reloadDownloads()
                        }
                        Button("清空全部", role: .destructive) {
                            DatabaseManager.shared.clearDownloads()
                            reloadDownloads()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(textColor)
                    }
                }
            }
        }
        .onAppear {
            reloadDownloads()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // 正在下载时每秒刷新进度
            if downloadRecords.contains(where: { $0.status == "downloading" || $0.status == "pending" }) {
                reloadDownloads()
            }
        }
        .fullScreenCover(item: $playingRecord) { record in
            if let vodItem = createLocalVodItem(from: record) {
                VideoPlayerViewV2(video: vodItem, preParsedEpisodes: [(name: record.name, url: "file://\(record.filePath)")])
            } else {
                LocalVideoPlayerView(filePath: record.filePath, title: record.name)
            }
        }
        .overlay {
            if showSaveTip {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(saveTipMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, 30)
                }
                .transition(.opacity)
                .animation(.easeInOut, value: showSaveTip)
            }
        }
    }

    private func reloadDownloads() {
        downloadRecords = DatabaseManager.shared.queryDownloads()
    }

    // MARK: - 保存到文件 App

    private func saveToFiles(record: DownloadRecord) {
        guard !record.filePath.isEmpty,
              FileManager.default.fileExists(atPath: record.filePath) else {
            showSaveTipMessage("文件不存在，无法保存")
            return
        }

        let fileURL = URL(fileURLWithPath: record.filePath)
        let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        documentPicker.shouldShowFileExtensions = true

        if let topVC = topMostViewController() {
            topVC.present(documentPicker, animated: true)
        }
    }

    // MARK: - 保存到相册

    private func saveToPhotos(record: DownloadRecord) {
        guard !record.filePath.isEmpty,
              FileManager.default.fileExists(atPath: record.filePath) else {
            showSaveTipMessage("文件不存在，无法保存")
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            performSaveToPhotos(record: record)
        } else {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        performSaveToPhotos(record: record)
                    } else {
                        showSaveTipMessage("相册权限被拒绝，无法保存")
                    }
                }
            }
        }
    }

    private func performSaveToPhotos(record: DownloadRecord) {
        let videoPath = record.filePath
        let ext = (videoPath as NSString).pathExtension.lowercased()

        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            UISaveVideoAtPathToSavedPhotosAlbum(videoPath, nil, nil, nil)
            showSaveTipMessage("已保存到相册")
        } else {
            convertAndSaveToPhotos(filePath: videoPath)
        }
    }

    private func convertAndSaveToPhotos(filePath: String) {
        let asset = AVAsset(url: URL(fileURLWithPath: filePath))
        guard asset.tracks(withMediaType: .video).first != nil else {
            showSaveTipMessage("该格式不支持保存到相册，请使用保存到文件")
            return
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            showSaveTipMessage("视频转换失败")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbox_export_\(UUID().uuidString).mp4")
        exporter.outputURL = tempURL
        exporter.outputFileType = .mp4

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    UISaveVideoAtPathToSavedPhotosAlbum(tempURL.path, nil, nil, nil)
                    try? FileManager.default.removeItem(at: tempURL)
                    showSaveTipMessage("已转换并保存到相册")
                default:
                    showSaveTipMessage("视频转换失败")
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }
    }

    private func showSaveTipMessage(_ message: String) {
        saveTipMessage = message
        withAnimation(.easeInOut(duration: 0.25)) { showSaveTip = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.25)) { showSaveTip = false }
        }
    }

    private func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else { return nil }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

// MARK: - 下载行视图

private struct DownloadProgressRow: View {
    let record: DownloadRecord
    let textColor: Color

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.laiyuan)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    if let st = record.sourceType, !st.isEmpty {
                        Text(st == "cloud" ? "网盘" : "普通")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                if record.status == "downloading" {
                    ProgressView(value: record.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .frame(height: 3)
                    HStack(spacing: 4) {
                        Text("\(Int(record.progress * 100))%")
                        if record.downloadedSize > 0 {
                            Text("· \(formatSize(record.downloadedSize))")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                } else {
                    Text("等待下载")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadCompletedRow: View {
    let record: DownloadRecord
    let textColor: Color
    let onPlay: () -> Void
    let onSaveToFiles: () -> Void
    let onSaveToPhotos: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 播放按钮
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Text(record.laiyuan)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                if record.fileSize > 0 {
                    Text(formatSize(record.fileSize))
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }
            Spacer()

            // 操作菜单
            Menu {
                Button(action: onPlay) {
                    Label("播放", systemImage: "play.fill")
                }
                Button(action: onSaveToFiles) {
                    Label("保存到文件", systemImage: "folder.badge.plus")
                }
                Button(action: onSaveToPhotos) {
                    Label("保存到相册", systemImage: "photo.badge.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private struct DownloadFailedRow: View {
    let record: DownloadRecord
    let textColor: Color
    let onRetry: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Text(record.laiyuan)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Text("下载失败")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            Spacer()
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

private func formatSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
}

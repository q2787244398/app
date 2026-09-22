import SwiftUI
import AVKit
import Combine
import UIKit
import UniformTypeIdentifiers
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif
import MediaPlayer

// MARK: - 直播源选择视图
struct LiveSourcePickerView: View {
    let sources: [LiveSourceType]
    let currentSource: LiveSourceType
    let onSelect: (LiveSourceType) -> Void
    let onAddCustom: (String, String) -> Void
    let onRemoveCustom: (Int) -> Void
    var onImportLocal: (() -> Void)? = nil
    var onExportCustom: ((Int, String, String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showAddAlert = false
    @State private var customName = ""
    @State private var customURL = ""

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("可用直播源")) {
                    ForEach(sources) { source in
                        SourceRowView(
                            source: source,
                            isSelected: source.id == currentSource.id
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelect(source)
                            dismiss()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if isCustomSource(source) {
                                if let index = customSourceIndex(of: source) {
                                    if let onExport = onExportCustom {
                                        Button {
                                            if case .custom(let name, let url) = source {
                                                onExport(index, name, url)
                                            }
                                        } label: {
                                            Label("导出", systemImage: "square.and.arrow.up")
                                        }
                                        .tint(.blue)
                                    }
                                    Button(role: .destructive) {
                                        onRemoveCustom(index)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button(action: { showAddAlert = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.orange)
                            Text("添加自定义源")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }

                    if let onImportLocal = onImportLocal {
                        Button(action: {
                            // 先关闭 sheet，再弹出 fileImporter
                            dismiss()
                            // 延迟后弹出文件选择器
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                onImportLocal()
                            }
                        }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text("导入本地直播文件")
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Text("添加源")
                } footer: {
                    Text("支持导入 M3U、TXT、JSON 等格式的直播源文件")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择直播源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .alert("添加自定义源", isPresented: $showAddAlert) {
                TextField("源名称", text: $customName)
                TextField("M3U/TXT URL", text: $customURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Button("取消", role: .cancel) {
                    customName = ""
                    customURL = ""
                }
                Button("添加") {
                    if !customName.isEmpty && !customURL.isEmpty {
                        onAddCustom(customName, customURL)
                        customName = ""
                        customURL = ""
                    }
                }
            } message: {
                Text("请输入直播源名称和订阅地址（M3U或TXT格式）")
            }
        }
    }

    private func isCustomSource(_ source: LiveSourceType) -> Bool {
        if case .custom = source { return true }
        return false
    }

    private func customSourceIndex(of source: LiveSourceType) -> Int? {
        let customList = sources.filter {
            if case .custom = $0 { return true }
            return false
        }
        return customList.firstIndex(where: { $0.id == source.id })
    }
}

// MARK: - 源列表行视图
struct SourceRowView: View {
    let source: LiveSourceType
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: typeIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(source.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Text(typeLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.orange)
            } else {
                Image(systemName: "circle")
                    .font(.system(size: 22))
                    .foregroundColor(Color(.systemGray4))
            }
        }
        .padding(.vertical, 4)
        .background(isSelected ? Color.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
    }

    private var typeIcon: String {
            switch source {
            case .defaultM3U, .defaultIPTV2:
                return "tv"
            case .subscribe:
                return "doc.text"
            case .custom:
                return "link"
            }
        }

        private var typeColor: Color {
            switch source {
            case .defaultM3U, .defaultIPTV2:
                return .blue
            case .subscribe:
                return .green
            case .custom:
                return .orange
            }
        }

        private var typeLabel: String {
            switch source {
            case .defaultM3U, .defaultIPTV2:
                return "默认源"
            case .subscribe:
                return "订阅源"
            case .custom:
                return "自定义源"
            }
        }
}

// MARK: - 主视图
struct LiveTVView: View {
    @StateObject private var service = LiveTVService.shared
    @State private var channelsCache: [String: [LiveChannel]] = [:]
    @State private var isLoading = false
    @State private var currentCategory: String = ""
    @State private var selectedChannel: LiveChannel?
    @State private var showPlayer = false
    @State private var showEPGSheet = false
    @State private var selectedChannelForEPG: LiveChannel?
    @State private var errorMessage: String?
    @State private var showError = false

    // 新增状态变量
    @State private var showSourcePicker = false
    @State private var sourcePickerOffset: CGFloat = 0

    // 浮动按钮自动隐藏/显示
    @State private var isFloatingButtonVisible = true
    @State private var hideTimer: Timer?
    @State private var lastInteractionTime = Date()

    // 当前大分类下的小分类（子分组）
    @State private var subCategories: [String] = []
    @State private var currentSubCategory: String = ""

    // 本地文件导入
    @State private var showFileImporter = false

    // 导出自定义源
    @State private var showExportShare = false
    @State private var exportFileURL: URL?

    private var currentCategories: [LiveCategory] {
        return service.dynamicCategories
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 分类标签栏
                    categoryTabs

                    // 小分类标签栏（如果有子分组）
                    if !subCategories.isEmpty {
                        subCategoryTabs
                    }

                    // 频道列表
                    channelList
                }

                // 右下角浮动按钮（自动隐藏/显示）
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 16))
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showSourcePicker = true
                                resetHideTimer()
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 80)
                            .opacity(isFloatingButtonVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: isFloatingButtonVisible)
                    }
                }
                .allowsHitTesting(isFloatingButtonVisible)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EmptyView()
                }
            }
            .sheet(isPresented: $showFileImporter) {
                DocumentPickerView { url in
                    handleDocumentPick(url: url)
                }
            }
            .sheet(isPresented: $showSourcePicker) {
                LiveSourcePickerView(
                    sources: service.availableSources,
                    currentSource: service.currentSource,
                    onSelect: { source in
                        service.switchSource(to: source)
                        showSourcePicker = false
                        channelsCache.removeAll()
                        loadChannelsIfNeeded(for: currentCategory)
                    },
                    onAddCustom: { name, url in
                        service.addCustomSource(name: name, url: url)
                    },
                    onRemoveCustom: { index in
                        service.removeCustomSource(at: index)
                    },
                    onImportLocal: {
                        showFileImporter = true
                    },
                    onExportCustom: { index, name, url in
                        // 先关闭源选择器 sheet，再弹出导出分享 sheet
                        showSourcePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            exportCustomSource(name: name, url: url)
                        }
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(item: $selectedChannel) { channel in
                LivePlayerSheet(channel: channel, service: service)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showEPGSheet) {
                if let channel = selectedChannelForEPG {
                    EPGSheetView(channel: channel, service: service)
                }
            }
            .alert("错误", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .sheet(isPresented: $showExportShare) {
                if let fileURL = exportFileURL {
                    ActivityShareSheet(activityItems: [fileURL])
                }
            }
            .onAppear {
                // 主动触发默认源加载（defaultM3U 也改为远程拉取，走统一路径）
                if service.dynamicCategories.isEmpty && service.subscribeChannels.isEmpty {
                    if let url = service.currentSource.sourceURL {
                        Task {
                            await service.fetchSubscribeChannels(url: url)
                        }
                    }
                }
                if currentCategory.isEmpty, let first = currentCategories.first {
                    currentCategory = first.tid
                }
                loadChannelsIfNeeded(for: currentCategory)
                startHideTimer()
            }
            .onDisappear {
                hideTimer?.invalidate()
                hideTimer = nil
            }
            .onChange(of: service.currentSource) { _ in
                channelsCache.removeAll()
                subCategories = []
                currentSubCategory = ""
                if let first = currentCategories.first {
                    currentCategory = first.tid
                    loadChannelsIfNeeded(for: first.tid)
                }
            }
            .onChange(of: service.dynamicCategories.map(\.id)) { _ in
                if !currentCategories.contains(where: { $0.tid == currentCategory }) {
                    if let first = currentCategories.first {
                        currentCategory = first.tid
                        loadChannelsIfNeeded(for: first.tid)
                    }
                }
            }
            .onChange(of: service.dynamicCategories.map(\.id)) { _ in
                channelsCache.removeAll()
                if let first = currentCategories.first {
                    currentCategory = first.tid
                    loadChannelsIfNeeded(for: first.tid)
                }
            }
        }
    }

    // MARK: - 浮动按钮自动隐藏/显示逻辑
    private func startHideTimer() {
        hideTimer?.invalidate()
        lastInteractionTime = Date()
        isFloatingButtonVisible = true
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(lastInteractionTime)
            if elapsed >= 10.0 && isFloatingButtonVisible {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isFloatingButtonVisible = false
                    }
                }
            }
        }
    }

    private func resetHideTimer() {
        lastInteractionTime = Date()
        if !isFloatingButtonVisible {
            withAnimation(.easeInOut(duration: 0.3)) {
                isFloatingButtonVisible = true
            }
        }
    }

    // MARK: - 处理本地文件导入（DocumentPicker）
    private func handleDocumentPick(url: URL?) {
        guard let url = url else {
            print("[LiveTV] 没有选中文件")
            return
        }
        print("[LiveTV] 选中文件: \(url)")

        let accessGranted = url.startAccessingSecurityScopedResource()
        print("[LiveTV] 安全域访问权限: \(accessGranted)")
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content: String
            if let utf8Content = try? String(contentsOf: url, encoding: .utf8) {
                content = utf8Content
            } else {
                let data = try Data(contentsOf: url)
                content = String(data: data, encoding: .ascii) ?? ""
            }

            let fileName = url.deletingPathExtension().lastPathComponent
            print("[LiveTV] 文件名: \(fileName), 内容长度: \(content.count)")

            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed: [SubscribeChannel]
            if trimmed.hasPrefix("#EXTM3U") {
                print("[LiveTV] 检测到 M3U 格式")
                parsed = service.parseM3U(content: content)
            } else {
                print("[LiveTV] 按 TXT 格式解析")
                parsed = service.parseTXT(content: content)
            }

            print("[LiveTV] 解析到 \(parsed.count) 个频道")

            if !parsed.isEmpty {
                service.addLocalChannels(name: fileName, channels: parsed)
                // addLocalChannels 内部已按 id 去重追加名为 fileName 的本地源，
                // 此处不再重复 addCustomSource，否则同一文件会被加入两份。
                let urlString = "local://\(fileName)"
                let customSource = LiveSourceType.custom(name: fileName, url: urlString)
                service.switchSource(to: customSource)
                // 依赖 onChange(of: service.currentSource) 自动刷新分类和频道
                print("[LiveTV] 导入成功，已切换到源: \(fileName)")
            } else {
                print("[LiveTV] 文件内容解析为空")
            }
        } catch {
            print("[LiveTV] 读取文件失败: \(error)")
        }
    }

    // MARK: - 导出自定义源
    private func exportCustomSource(name: String, url: String) {
        print("[LiveTV] 导出自定义源: \(name), URL: \(url)")
        
        // 本地导入的源，直接从缓存中导出
        if url.hasPrefix("local://") {
            let localName = String(url.dropFirst(8))
            if let channels = service.localChannelsMap[localName], !channels.isEmpty {
                exportChannelsToFile(name: localName, channels: channels)
                return
            } else {
                errorMessage = "本地源已失效，请重新导入"
                showError = true
                return
            }
        }
        
        // 网络源：从 URL 获取内容
        Task {
            do {
                var request = URLRequest(url: URL(string: url)!)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    print("[LiveTV] 导出失败: HTTP 状态码异常")
                    await MainActor.run {
                        errorMessage = "无法获取直播源内容，请检查网络连接"
                        showError = true
                    }
                    return
                }

                guard let content = String(data: data, encoding: .utf8),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    print("[LiveTV] 导出失败: 内容为空")
                    await MainActor.run {
                        errorMessage = "直播源内容为空"
                        showError = true
                    }
                    return
                }

                // 确定文件扩展名（M3U 或 TXT）
                let isM3U = content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
                let ext = isM3U ? "m3u" : "txt"
                let safeName = name.replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: " ", with: "_")
                let fileName = "\(safeName).\(ext)"

                // 写入临时文件
                let tempDir = FileManager.default.temporaryDirectory
                let fileURL = tempDir.appendingPathComponent(fileName)

                try content.write(to: fileURL, atomically: true, encoding: .utf8)

                await MainActor.run {
                    exportFileURL = fileURL
                    showExportShare = true
                    print("[LiveTV] 导出成功: \(fileURL.path)")
                }
            } catch {
                print("[LiveTV] 导出失败: \(error.localizedDescription)")
                await MainActor.run {
                    errorMessage = "导出失败: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
    
    /// 本地频道导出为 M3U 文件
    private func exportChannelsToFile(name: String, channels: [SubscribeChannel]) {
        var m3uContent = "#EXTM3U\n"
        for channel in channels {
            let groupTag = channel.group.map { " group-title=\"\($0)\"" } ?? ""
            let logoTag = channel.logo.map { " tvg-logo=\"\($0)\"" } ?? ""
            m3uContent += "#EXTINF:-1\(groupTag)\(logoTag),\(channel.name)\n"
            m3uContent += "\(channel.url)\n"
        }
        
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let fileName = "\(safeName).m3u"
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try m3uContent.write(to: fileURL, atomically: true, encoding: .utf8)
            exportFileURL = fileURL
            showExportShare = true
            print("[LiveTV] 本地源导出成功: \(fileURL.path)")
        } catch {
            errorMessage = "导出失败: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - 分类标签栏
    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(currentCategories) { category in
                    CategoryTabButton(
                        category: category,
                        isSelected: currentCategory == category.tid
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentCategory = category.tid
                            currentSubCategory = ""
                        }
                        loadChannelsIfNeeded(for: category.tid)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 小分类标签栏
    private var subCategoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // "全部"选项
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentSubCategory = ""
                    }
                }) {
                    Text("全部")
                        .font(.system(size: 13, weight: currentSubCategory.isEmpty ? .semibold : .regular))
                        .foregroundColor(currentSubCategory.isEmpty ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(currentSubCategory.isEmpty ? Color.accentColor : Color(.systemGray5))
                        )
                }
                .buttonStyle(PlainButtonStyle())

                ForEach(subCategories, id: \.self) { sub in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentSubCategory = sub
                        }
                    }) {
                        Text(sub)
                            .font(.system(size: 13, weight: currentSubCategory == sub ? .semibold : .regular))
                            .foregroundColor(currentSubCategory == sub ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(currentSubCategory == sub ? Color.accentColor : Color(.systemGray5))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 频道列表（2列网格）
    private var channelList: some View {
        Group {
            if isLoading {
                LoadingView()
            } else if let channels = channelsCache[currentCategory] {
                let filteredChannels = filteredChannelsBySubCategory(channels)
                ScrollView {
                    if filteredChannels.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(channels.isEmpty ? "该分类暂无频道" : "当前筛选条件下暂无频道")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(filteredChannels) { channel in
                                ChannelGridItem(channel: channel, service: service)
                                    .onTapGesture {
                                        selectedChannel = channel
                                    }
                                    .contextMenu {
                                        Button {
                                            selectedChannelForEPG = channel
                                            showEPGSheet = true
                                        } label: {
                                            Label("节目单", systemImage: "list.bullet.rectangle")
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            resetHideTimer()
                        }
                )
                .simultaneousGesture(
                    TapGesture()
                        .onEnded { _ in
                            resetHideTimer()
                        }
                )
            } else {
                EmptyStateView {
                    loadChannelsIfNeeded(for: currentCategory)
                }
            }
        }
    }

    // MARK: - 按小分类过滤频道
    private func filteredChannelsBySubCategory(_ channels: [LiveChannel]) -> [LiveChannel] {
        guard !currentSubCategory.isEmpty else { return channels }
        // 从频道的 sources 或名称中匹配子分组
        // 由于 LiveChannel 没有直接的 group 字段，我们从 service.subscribeChannels 中查找匹配
        // 这里用频道名称的模糊匹配：如果频道名包含子分类名，则归入该子分类
        return channels.filter { channel in
            channel.name.contains(currentSubCategory)
        }
    }

    // MARK: - 提取当前分类下的子分组
    private func extractSubCategories(from channels: [LiveChannel]) {
        // 从 subscribeChannels 中查找属于当前分类的频道，提取它们的 group 作为子分组
        let categoryGroups = service.subscribeChannels.compactMap { ch -> String? in
            guard let group = ch.group, !group.isEmpty else { return nil }
            // 判断该频道是否属于当前大分类
            // 通过频道名匹配
            return group
        }

        // 去重并排序
        let uniqueGroups = Array(Set(categoryGroups)).sorted()
        // 只保留出现次数 >= 2 的分组（避免孤立的分组）
        let groupCounts = Dictionary(grouping: categoryGroups, by: { $0 })
        subCategories = uniqueGroups.filter { (groupCounts[$0]?.count ?? 0) >= 2 }

        if !subCategories.isEmpty && !subCategories.contains(currentSubCategory) {
            currentSubCategory = ""
        }
    }

    // MARK: - 加载频道
    private func loadChannelsIfNeeded(for categoryId: String, forceReload: Bool = false) {
        guard !categoryId.isEmpty else { return }
        guard channelsCache[categoryId] == nil || forceReload else { return }
        isLoading = true

        Task {
            let channels = await service.fetchChannels(tid: categoryId)
            await MainActor.run {
                channelsCache[categoryId] = channels
                isLoading = false
                // 提取子分组
                extractSubCategories(from: channels)
            }
        }
    }
}

// MARK: - 分类标签按钮
struct CategoryTabButton: View {
    let category: LiveCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let logo = category.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    } placeholder: {
                        Image(systemName: category.icon)
                            .font(.system(size: 14, weight: .medium))
                    }
                } else {
                    Image(systemName: category.icon)
                        .font(.system(size: 14, weight: .medium))
                }
                Text(category.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(isSelected ? .white : category.tintColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? category.backgroundColor : category.tintColor.opacity(0.1))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 频道网格卡片
struct ChannelGridItem: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @State private var isResolving = false
    @State private var routeCount = 1

    var body: some View {
        VStack(spacing: 0) {
            // 封面图（固定 16:9 比例）
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))

                if let logo = channel.logo, let url = URL(string: logo) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .scaleEffect(0.8)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "tv.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.orange.opacity(0.6))
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.orange.opacity(0.6))
                }
            }
            .aspectRatio(16/9, contentMode: .fit)
            .clipped()

            // 频道名称 + 线路数
            HStack {
                Text("\(routeCount)条线路")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .leading)
                Spacer()
                Text(channel.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("")
                    .frame(width: 50)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            Task {
                isResolving = true
                let sources = await service.resolveAllSources(channel: channel)
                await MainActor.run {
                    routeCount = max(1, sources.count)
                    isResolving = false
                }
            }
        }
    }
}

// MARK: - 加载中视图
struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在加载频道...")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 空状态视图
struct EmptyStateView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tv.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("暂无频道")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.primary)

            Text("该分类下暂无可用频道")
                .font(.system(size: 15))
                .foregroundColor(.secondary)

            Button(action: onRetry) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新加载")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.orange.opacity(0.08))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 100)
    }
}

// MARK: - AVPlayerLayer 封装（解决有声音无画面问题）
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.backgroundColor = .black
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        view.playerLayer = playerLayer
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer?.player = player
        uiView.playerLayer?.frame = uiView.bounds
        uiView.layoutIfNeeded()
    }
}

class PlayerLayerUIView: UIView {
    var playerLayer: AVPlayerLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
        print("[PlayerLayer] layoutSubviews bounds=\(bounds)")
    }

    override var frame: CGRect {
        didSet {
            playerLayer?.frame = bounds
        }
    }
}

// MARK: - 小窗口播放器（VLC 内核 + 自定义控制条）
struct MiniPlayerView: View {
    let url: URL
    @State private var isPlaying = true
    @State private var showControls = false
    @State private var isMuted = false
    @State private var showFullScreen = false

    // 控制条自动隐藏计时器
    @State private var hideTimer: Timer?

    var body: some View {
        ZStack {
            // VLC 播放器
            MiniVLCPlayerContainer(
                url: url,
                isPlaying: $isPlaying,
                volume: .constant(isMuted ? 0 : 1),
                isMuted: $isMuted
            )

            // 点击区域显示/隐藏控制条
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    resetHideTimer()
                }

            // 控制条叠加层
            if showControls {
                VStack(spacing: 0) {
                    // 顶部：全屏按钮
                    HStack {
                        Spacer()
                        Button(action: {
                            showFullScreen = true
                        }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(4)
                    }

                    Spacer()

                    // 底部：控制按钮行
                    HStack(spacing: 20) {
                        // 播放/暂停
                        Button(action: {
                            isPlaying.toggle()
                            resetHideTimer()
                        }) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        // 静音
                        Button(action: {
                            isMuted.toggle()
                            resetHideTimer()
                        }) {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenPlayerView(url: url)
        }
        .onDisappear {
            hideTimer?.invalidate()
            hideTimer = nil
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = false
            }
        }
    }
}

// MARK: - 全屏播放器视图（SwiftUI）
struct FullScreenPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var playbackRate: Double = 1.0
    @State private var isPlaying = true
    @State private var isMuted = false
    @State private var showControls = true
    @State private var seekTarget: TimeInterval? = nil
    @State private var rateTarget: Double? = nil
    @State private var isSeeking = false
    @State private var seekPreviewTime: TimeInterval = 0

    @State private var hideTimer: Timer?

    // 横屏/竖屏状态：进入全屏默认横屏
    @State private var isLandscape = true

    private let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MiniVLCPlayerContainer(
                url: url,
                isPlaying: $isPlaying,
                volume: .constant(1),
                isMuted: $isMuted,
                seekRequest: $seekTarget,
                rateRequest: $rateTarget,
                onTimeUpdate: { time, dur, rate in
                    if !isSeeking {
                        currentTime = time
                    }
                    duration = dur
                },
                onPlayStateChange: { playing in
                    isPlaying = playing
                }
            )

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showControls.toggle()
                    }
                    if showControls { resetHideTimer() }
                }

            if showControls {
                VStack(spacing: 0) {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer()
                        // 横屏/竖屏切换按钮
                        Button(action: {
                            if isLandscape {
                                OrientationHelper.lockOrientation(.portrait)
                                isLandscape = false
                            } else {
                                OrientationHelper.rotateToLandscape()
                                isLandscape = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    OrientationHelper.allowAllOrientations()
                                }
                            }
                            resetHideTimer()
                        }) {
                            Image(systemName: isLandscape ? "rectangle.portrait" : "rectangle")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.top, 50)
                    .padding(.horizontal, 12)

                    Spacer()

                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text(formatTime(currentTime))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 48, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.25))
                                        .frame(height: 4)
                                        .clipShape(Capsule())

                                    if duration > 0 {
                                        Rectangle()
                                            .fill(Color.white)
                                            .frame(width: geo.size.width * CGFloat(isSeeking ? seekPreviewTime / duration : currentTime / duration), height: 4)
                                            .clipShape(Capsule())
                                    }

                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 14, height: 14)
                                        .position(x: geo.size.width * CGFloat(isSeeking ? seekPreviewTime / duration : (duration > 0 ? currentTime / duration : 0)), y: 7)
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            isSeeking = true
                                            let ratio = max(0, min(1, value.location.x / geo.size.width))
                                            seekPreviewTime = ratio * duration
                                        }
                                        .onEnded { value in
                                            let ratio = max(0, min(1, value.location.x / geo.size.width))
                                            let target = ratio * duration
                                            seekTarget = target
                                            currentTime = target
                                            isSeeking = false
                                            resetHideTimer()
                                        }
                                )
                            }
                            .frame(height: 20)

                            Text(formatTime(duration))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 48, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)

                        HStack(spacing: 24) {
                            Spacer()

                            Button(action: {
                                seekTarget = max(0, currentTime - 10)
                                currentTime = max(0, currentTime - 10)
                                resetHideTimer()
                            }) {
                                Image(systemName: "gobackward.10")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: {
                                isPlaying.toggle()
                                resetHideTimer()
                            }) {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Button(action: {
                                let target = min(duration > 0 ? duration : currentTime + 10, currentTime + 10)
                                seekTarget = target
                                currentTime = target
                                resetHideTimer()
                            }) {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 22))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Menu {
                                ForEach(speedOptions, id: \.self) { speed in
                                    Button(action: {
                                        rateTarget = speed
                                        playbackRate = speed
                                        resetHideTimer()
                                    }) {
                                        HStack {
                                            Text(speed == 1.0 ? "\(String(format: "%.2f", speed))x 正常" : "\(String(format: "%.2f", speed))x")
                                            if abs(speed - playbackRate) < 0.01 {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Text(String(format: "%.2f", playbackRate) + "x")
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                            }

                            Button(action: {
                                isMuted.toggle()
                                resetHideTimer()
                            }) {
                                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Spacer()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 36)
                }
                .transition(.opacity)
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            resetHideTimer()
            // 进入全屏：强制横屏，随后允许自动跟随设备方向
            OrientationHelper.rotateToLandscape()
            isLandscape = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                OrientationHelper.allowAllOrientations()
            }
        }
        .onDisappear {
            hideTimer?.invalidate()
            // 退出全屏：恢复竖屏
            OrientationHelper.lockOrientation(.portrait)
        }
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite && t >= 0 else { return "00:00" }
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - VLC 播放器容器
struct MiniVLCPlayerContainer: UIViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var volume: Double
    @Binding var isMuted: Bool
    var seekRequest: Binding<TimeInterval?>
    var rateRequest: Binding<Double?>
    var onTimeUpdate: ((TimeInterval, TimeInterval, Double) -> Void)?
    var onPlayStateChange: ((Bool) -> Void)?

    init(url: URL,
         isPlaying: Binding<Bool>,
         volume: Binding<Double>,
         isMuted: Binding<Bool>,
         seekRequest: Binding<TimeInterval?> = .constant(nil),
         rateRequest: Binding<Double?> = .constant(nil),
         onTimeUpdate: ((TimeInterval, TimeInterval, Double) -> Void)? = nil,
         onPlayStateChange: ((Bool) -> Void)? = nil) {
        self.url = url
        self._isPlaying = isPlaying
        self._volume = volume
        self._isMuted = isMuted
        self.seekRequest = seekRequest
        self.rateRequest = rateRequest
        self.onTimeUpdate = onTimeUpdate
        self.onPlayStateChange = onPlayStateChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTimeUpdate: onTimeUpdate, onPlayStateChange: onPlayStateChange)
    }

    func makeUIView(context: Context) -> MiniVLCPlayerView {
        let view = MiniVLCPlayerView()
        view.load(url: url)
        context.coordinator.playerView = view
        context.coordinator.startPolling()
        return view
    }

    func updateUIView(_ uiView: MiniVLCPlayerView, context: Context) {
        context.coordinator.onTimeUpdate = onTimeUpdate
        context.coordinator.onPlayStateChange = onPlayStateChange
        if isPlaying {
            uiView.play()
        } else {
            uiView.pause()
        }
        uiView.setVolume(isMuted ? 0 : volume)
        if let seekTo = seekRequest.wrappedValue {
            uiView.seek(to: seekTo)
            seekRequest.wrappedValue = nil
        }
        if let rateTo = rateRequest.wrappedValue {
            uiView.setRate(rateTo)
            rateRequest.wrappedValue = nil
        }
    }

    static func dismantleUIView(_ uiView: MiniVLCPlayerView, coordinator: Coordinator) {
        coordinator.stopPolling()
        uiView.stop()
    }

    class Coordinator: NSObject {
        weak var playerView: MiniVLCPlayerView?
        private var timer: Timer?
        var onTimeUpdate: ((TimeInterval, TimeInterval, Double) -> Void)?
        var onPlayStateChange: ((Bool) -> Void)?

        init(onTimeUpdate: ((TimeInterval, TimeInterval, Double) -> Void)?, onPlayStateChange: ((Bool) -> Void)?) {
            self.onTimeUpdate = onTimeUpdate
            self.onPlayStateChange = onPlayStateChange
        }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let view = self.playerView else { return }
                self.onTimeUpdate?(view.currentPlayTime, view.mediaDuration, view.currentRate)
                self.onPlayStateChange?(view.isCurrentlyPlaying)
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - VLC 小窗口播放器视图
class MiniVLCPlayerView: UIView {
    #if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
    #endif
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupPlayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPlayer()
    }

    private func setupPlayer() {
        backgroundColor = .black
        #if canImport(MobileVLCKit)
        mediaPlayer.drawable = self
        #endif
    }

    func load(url: URL) {
        guard currentURL != url else { return }
        currentURL = url

        #if canImport(MobileVLCKit)
        let media = VLCMedia(url: url)
        media.addOptions([
            "http-user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
        ])
        mediaPlayer.media = media
        mediaPlayer.play()
        #endif
    }

    func play() {
        #if canImport(MobileVLCKit)
        mediaPlayer.play()
        #endif
    }

    func pause() {
        #if canImport(MobileVLCKit)
        mediaPlayer.pause()
        #endif
    }

    func stop() {
        #if canImport(MobileVLCKit)
        mediaPlayer.stop()
        #endif
        currentURL = nil
    }

    func setVolume(_ volume: Double) {
        #if canImport(MobileVLCKit)
        let vol = Int32(volume * 100)
        mediaPlayer.audio?.volume = max(0, min(200, vol))
        #endif
    }

    var position: Float {
        #if canImport(MobileVLCKit)
        return mediaPlayer.position
        #else
        return 0
        #endif
    }

    var currentPlayTime: TimeInterval {
        #if canImport(MobileVLCKit)
        return TimeInterval(mediaPlayer.time.value?.doubleValue ?? 0) / 1000.0
        #else
        return 0
        #endif
    }

    var mediaDuration: TimeInterval {
        #if canImport(MobileVLCKit)
        return TimeInterval(mediaPlayer.media?.length.value?.doubleValue ?? 0) / 1000.0
        #else
        return 0
        #endif
    }

    var isCurrentlyPlaying: Bool {
        #if canImport(MobileVLCKit)
        return mediaPlayer.isPlaying
        #else
        return false
        #endif
    }

    var currentRate: Double {
        #if canImport(MobileVLCKit)
        return Double(mediaPlayer.rate)
        #else
        return 1.0
        #endif
    }

    func seek(to time: TimeInterval) {
        #if canImport(MobileVLCKit)
        let vlctime = VLCTime(int: Int32(time * 1000))
        mediaPlayer.time = vlctime
        #endif
    }

    func setRate(_ rate: Double) {
        #if canImport(MobileVLCKit)
        mediaPlayer.rate = Float(rate)
        #endif
    }

    func jumpForward(_ seconds: Int32 = 10) {
        #if canImport(MobileVLCKit)
        mediaPlayer.jumpForward(seconds)
        #endif
    }

    func jumpBackward(_ seconds: Int32 = 10) {
        #if canImport(MobileVLCKit)
        mediaPlayer.jumpBackward(seconds)
        #endif
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        #if canImport(MobileVLCKit)
        mediaPlayer.drawable = self
        #endif
    }

    deinit {
        stop()
    }
}

// MARK: - 系统播放器（AVPlayerViewController 封装）
struct SystemPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 直播频道详情Sheet（小窗口预览 + 线路切换 + 全屏）
struct LivePlayerSheet: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var currentPlayerURL: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var availableRoutes: [String] = []
    @State private var currentRouteIndex = 0
    @State private var supportsCatchup = false
    @State private var showEPGSheet = false

    // 线路选择菜单
    @State private var showRouteMenu = false

    // 回看：是否支持回看（基于当前源URL格式）
    private var catchupSupported: Bool {
        guard let url = availableRoutes.first else { return false }
        // 运营商IPTV源通常支持回看（URL不含.m3u8后缀且包含数字ID）
        let hasM3U8 = url.hasSuffix(".m3u8") || url.contains(".m3u8?")
        let isOperatorSource = !hasM3U8 && url.contains("http") && url.split(separator: "/").last?.allSatisfy({ $0.isNumber }) == true
        return isOperatorSource
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部工具栏（在视频上方，不遮挡视频）
                HStack {
                    // 线路切换
                    if !availableRoutes.isEmpty {
                        Menu {
                            ForEach(0..<availableRoutes.count, id: \.self) { index in
                                Button(action: {
                                    switchRoute(to: index)
                                }) {
                                    HStack {
                                        Text("线路 \(index + 1)")
                                        if index == currentRouteIndex {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 12))
                                Text("线路 \(currentRouteIndex + 1)/\(availableRoutes.count)")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color(.systemGray5))
                            )
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // 小视频预览窗口（使用VLC内核）
                ZStack {
                    Color.black
                        .aspectRatio(16/9, contentMode: .fit)

                    if let url = currentPlayerURL {
                        MiniPlayerView(url: url)
                            .aspectRatio(16/9, contentMode: .fit)
                    } else if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.white)
                            Text("正在解析播放地址...")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    } else if let error = errorMessage {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                            Button("重试") {
                                loadPlayer()
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                        }
                    }
                }

                // 回看按钮（放在小窗口外面左下角，不遮挡视频）
                if supportsCatchup {
                    HStack {
                        Button(action: {
                            showEPGSheet = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 12))
                                Text("回看")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(Color(.systemGray5))
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // 下半部分：频道信息和线路列表
                VStack(spacing: 16) {
                    // 频道名称区域（仅保留线路数量信息，移除频道名称显示）
                    HStack {
                        Spacer()

                        Text("共 \(availableRoutes.count) 条线路")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color(.systemGray5)))
                    }
                    .padding(.horizontal, 16)

                    Divider()
                        .padding(.horizontal, 16)

                    // 线路列表
                    if availableRoutes.isEmpty && !isLoading {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("暂无可用线路")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(0..<availableRoutes.count, id: \.self) { index in
                                    Button(action: {
                                        switchRoute(to: index)
                                    }) {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Circle()
                                                    .fill(index == currentRouteIndex ? Color.accentColor : Color(.systemGray4))
                                                    .frame(width: 32, height: 32)
                                                Text("\(index + 1)")
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(.white)
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("线路 \(index + 1)")
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundColor(.primary)

                                                Text(truncateURL(availableRoutes[index]))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer()

                                            if index == currentRouteIndex {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.accentColor)
                                            } else {
                                                Image(systemName: "play.circle")
                                                    .font(.system(size: 24))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(12)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(index == currentRouteIndex ? Color.accentColor.opacity(0.08) : Color(.systemBackground))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(index == currentRouteIndex ? Color.accentColor.opacity(0.3) : Color(.systemGray4), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                .padding(.top, 16)
            }
            .navigationTitle(channel.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadPlayer()
            }
            .onDisappear {
                player?.pause()
                player = nil
                currentPlayerURL = nil
            }
            .sheet(isPresented: $showEPGSheet) {
                EPGSheetView(channel: channel, service: service)
            }
        }
    }

    // MARK: - 切换线路
    private func switchRoute(to index: Int) {
        guard index != currentRouteIndex && index < availableRoutes.count else { return }
        currentRouteIndex = index

        let urlString = availableRoutes[index]
        guard let url = URL(string: urlString) else { return }

        // 使用最简单的 AVPlayerItem 创建方式
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 3000000

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        self.currentPlayerURL = url
        self.player = avPlayer
        self.supportsCatchup = catchupSupported
        avPlayer.play()
    }

    private func truncateURL(_ url: String) -> String {
        if url.count > 50 {
            let start = url.prefix(25)
            let end = url.suffix(20)
            return "\(start)...\(end)"
        }
        return url
    }

    private func enterFullScreen() {
        guard let player = player else { return }
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.exitsFullScreenWhenPlaybackEnds = false

        // 找到当前 window 的 rootViewController 并 present
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // 找到最顶层的 presentedViewController
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(controller, animated: true)
        }
    }

    private func loadPlayer() {
        isLoading = true
        errorMessage = nil

        Task {
            let routes = await service.resolveAllSources(channel: channel)
            print("[LivePlayer] 解析到 \(routes.count) 个线路")

            await MainActor.run {
                availableRoutes = routes
            }

            guard !routes.isEmpty else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "无法获取播放地址"
                }
                return
            }

            let urlString = routes[min(currentRouteIndex, routes.count - 1)]
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "播放地址格式无效"
                }
                return
            }

            print("[LivePlayer] 预览播放: \(urlString)")

            // 使用最简单的 AVPlayerItem 创建方式，避免复杂配置导致兼容性问题
            let item = AVPlayerItem(url: url)
            item.preferredPeakBitRate = 3000000

            let avPlayer = AVPlayer(playerItem: item)
            avPlayer.automaticallyWaitsToMinimizeStalling = false

            await MainActor.run {
                self.currentPlayerURL = url
                self.player = avPlayer
                self.isLoading = false
                self.supportsCatchup = self.catchupSupported
                avPlayer.play()
            }
        }
    }
}

// MARK: - 节目单Sheet
struct EPGSheetView: View {
    let channel: LiveChannel
    @ObservedObject var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [(time: String, title: String)] = []
    @State private var isLoading = true
    @State private var selectedDay = "today"

    private var dayOptions: [(String, String)] {
        [
            ("today", "今天"),
            ("yesterday", "昨天"),
            ("beforeyesterday", "前天")
        ]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("日期", selection: $selectedDay) {
                    ForEach(dayOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                .onChange(of: selectedDay) { _ in
                    loadEPG()
                }

                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if programs.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("暂无节目单")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List(programs, id: \.time) { program in
                        HStack(spacing: 16) {
                            Text(program.time)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.orange)
                                .frame(width: 50, alignment: .leading)

                            Text(program.title)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("\(channel.name) 节目单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadEPG()
            }
        }
    }

    private func loadEPG() {
        isLoading = true
        Task {
            let result = await service.fetchEPG(channel: channel, day: selectedDay)
            await MainActor.run {
                programs = result
                isLoading = false
            }
        }
    }
}

// MARK: - 文件选择器（UIDocumentPickerViewController 封装）
struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, dismiss: dismiss)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        let dismiss: DismissAction

        init(onPick: @escaping (URL?) -> Void, dismiss: DismissAction) {
            self.onPick = onPick
            self.dismiss = dismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.onPick(urls.first)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            dismiss()
        }
    }
}

// MARK: - 分享 Sheet（UIActivityViewController 封装）
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview
struct LiveTVView_Previews: PreviewProvider {
    static var previews: some View {
        LiveTVView()
    }
}

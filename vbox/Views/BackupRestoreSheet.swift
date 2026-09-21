import SwiftUI
import UniformTypeIdentifiers

// MARK: - 备份与还原弹窗

struct BackupRestoreSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentAccount: String

    private enum Mode: String, CaseIterable, Identifiable {
        case backup = "备份"
        case restore = "还原"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .backup

    // 备份态
    @State private var selectedCategories: Set<BackupCategory> = Set(BackupCategory.allCases.filter(\.defaultOn))
    @State private var password: String = ""
    @State private var confirmPassword: String = ""

    // 还原态
    @State private var importedEnvelope: BackupFileEnvelope? = nil
    @State private var importedData: Data? = nil
    @State private var restorePassword: String = ""
    @State private var strategy: ConflictStrategy = .merge

    // 状态
    @State private var isWorking = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // UIKit 文档选择器协调器
    @State private var importPickerDelegate: ImportPickerDelegate?
    @State private var exportPickerDelegate: ExportPickerDelegate?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 14) {
                        if mode == .backup {
                            backupSection
                        } else {
                            restoreSection
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("备份与还原")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    // MARK: - 备份面板

    private var backupSection: some View {
        VStack(spacing: 14) {
            infoCard(
                icon: "externaldrive.fill",
                title: "导出为单一 JSON 文件",
                subtitle: "选择要备份的类目；福利数据已纳入备份，需设置口令保护。文件保存在本地，可拷贝到其他设备还原"
            )

            categoryList

            // 口令设置
            VStack(spacing: 10) {
                SecureField("自定义口令（留空则不加密）", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                if !password.isEmpty {
                    SecureField("再次输入确认口令", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                }
                Text("口令仅用于加密这份备份文件，跨设备还原时输入相同口令即可；忘记口令将无法解密。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: performBackup) {
                HStack {
                    if isWorking { ProgressView().tint(.white) }
                    Text(isWorking ? "正在生成..." : "导出备份")
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(selectedCategories.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(isWorking || selectedCategories.isEmpty)
        }
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(BackupCategory.allCases) { category in
                HStack(spacing: 12) {
                    Image(systemName: category.icon)
                        .font(.system(size: 18))
                        .foregroundColor(.accentColor)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(category.title)
                                .font(.system(size: 15, weight: .medium))
                            if category.isSensitive {
                                Text("敏感")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange)
                                    .cornerRadius(4)
                            }
                        }
                        Text(category.subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { selectedCategories.contains(category) },
                        set: { on in
                            if on {
                                selectedCategories.insert(category)
                            } else {
                                selectedCategories.remove(category)
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(.accentColor)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)

                if category != BackupCategory.allCases.last {
                    Divider().padding(.leading, 50)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 还原面板

    private var restoreSection: some View {
        VStack(spacing: 14) {
            infoCard(
                icon: "arrow.down.doc.fill",
                title: "从备份文件还原",
                subtitle: "选择 vbox 备份 JSON 文件，按类目还原到本机；网盘凭据仅在备份账号与当前账号一致时还原"
            )

            if let envelope = importedEnvelope {
                // 备份文件信息
                VStack(spacing: 10) {
                    fileInfoRow(label: "备份账号", value: envelope.meta.account.isEmpty ? "（无）" : envelope.meta.account)
                    fileInfoRow(label: "用户名", value: envelope.meta.username.isEmpty ? "（无）" : envelope.meta.username)
                    fileInfoRow(label: "备份时间", value: Self.dateString(envelope.meta.createdAt))
                    fileInfoRow(label: "App 版本", value: envelope.meta.appVersion.isEmpty ? "（未知）" : envelope.meta.appVersion)
                    fileInfoRow(label: "格式版本", value: "v\(envelope.schemaVersion)")
                    HStack(spacing: 6) {
                        Text("加密状态")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(envelope.encrypted ? "已加密" : "未加密")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(envelope.encrypted ? .orange : .green)
                    }
                }
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)

                if envelope.encrypted {
                    SecureField("输入备份口令", text: $restorePassword)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                }

                // 冲突策略
                VStack(spacing: 8) {
                    ForEach(ConflictStrategy.allCases) { s in
                        Button(action: { strategy = s }) {
                            HStack {
                                Image(systemName: strategy == s ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(strategy == s ? .accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.rawValue)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(s.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(strategy == s ? Color.accentColor.opacity(0.1) : Color(.secondarySystemBackground))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button(action: performRestore) {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text(isWorking ? "正在还原..." : "开始还原")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isWorking)
            } else {
                Button(action: presentImportPicker) {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 34))
                            .foregroundColor(.accentColor)
                        Text("选择备份文件")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                        Text("支持 .json 格式的 vbox 备份文件")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fileInfoRow(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func infoCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - 动作

    private func performBackup() {
        guard !password.isEmpty || confirmPassword.isEmpty else { return }
        if !password.isEmpty && password != confirmPassword {
            showAlert(title: "口令不一致", message: "两次输入的口令不一致，请重新确认")
            return
        }
        isWorking = true
        // 采集与加密为异步执行（加密移到后台执行器），避免阻塞主线程
        Task { @MainActor in
            do {
                let data = try await BackupManager.shared.createBackup(
                    categories: Array(selectedCategories),
                    password: password.isEmpty ? nil : password
                )
                let stamp = Self.stampString()
                let name = currentAccount.isEmpty
                    ? "vbox备份_\(stamp).json"
                    : "vbox备份_\(currentAccount)_\(stamp).json"
                isWorking = false
                presentExportPicker(data: data, filename: name)
            } catch {
                isWorking = false
                showAlert(title: "备份失败", message: error.localizedDescription)
            }
        }
    }

    private func performRestore() {
        guard let data = importedData, let envelope = importedEnvelope else { return }
        if envelope.encrypted && restorePassword.isEmpty {
            showAlert(title: "需要口令", message: "这份备份已加密，请输入口令后再还原")
            return
        }
        isWorking = true
        // 在后台结构化并发中执行还原，避免阻塞主线程；还原内部含异步探测（远程源版本），
        // 用 await 挂起而非信号量阻塞，否则主线程卡死被系统看门狗终止
        Task { @MainActor in
            do {
                let result = try await BackupManager.shared.restore(
                    backupData: data,
                    categories: BackupCategory.allCases,
                    strategy: strategy,
                    password: envelope.encrypted ? restorePassword : nil,
                    currentAccount: currentAccount
                )
                isWorking = false
                var message = result.summary
                if result.restored.contains(.personalSettings) {
                    message += "\n\n提示：部分外观设置将在重启后生效"
                }
                showAlert(title: "还原完成", message: message)
            } catch {
                isWorking = false
                showAlert(title: "还原失败", message: error.localizedDescription)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    // MARK: - UIKit 文件选择器（解决 sheet 中 SwiftUI fileImporter 回调不触发问题）

    /// 弹出文件选择器（导入备份文件）
    private func presentImportPicker() {
        guard let topVC = Self.topMostViewController() else {
            showAlert(title: "无法打开", message: "无法获取当前视图控制器")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        let delegate = ImportPickerDelegate { url in
            if let url = url {
                handleImportedFile(url: url)
            }
        }
        importPickerDelegate = delegate
        picker.delegate = delegate
        topVC.present(picker, animated: true)
    }

    /// 处理导入的文件
    private func handleImportedFile(url: URL) {
        print("[BackupRestore] 导入文件: \(url.lastPathComponent)")
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        // 读取大文件放到后台执行器，避免阻塞主线程；解析完成后回主线程更新 UI
        Task(priority: .userInitiated) {
            let data = try? Data(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let data else {
                    self.showAlert(title: "读取失败", message: "无法读取该文件，请确认文件未损坏")
                    return
                }
                print("[BackupRestore] 文件读取成功，\(data.count) bytes")
                self.importedData = data
                self.restorePassword = ""
                do {
                    self.importedEnvelope = try BackupManager.shared.parseEnvelope(data: data)
                    print("[BackupRestore] 备份文件解析成功")
                } catch {
                    self.importedEnvelope = nil
                    print("[BackupRestore] 备份文件解析失败: \(error)")
                    self.showAlert(title: "无法识别", message: error.localizedDescription)
                }
            }
        }
    }

    /// 弹出文件导出器（保存备份文件）
    private func presentExportPicker(data: Data, filename: String) {
        // 先写入临时目录
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try FileManager.default.removeItem(at: tempURL)
            }
            try data.write(to: tempURL)
        } catch {
            showAlert(title: "导出失败", message: "临时文件写入失败：\(error.localizedDescription)")
            return
        }

        guard let topVC = Self.topMostViewController() else {
            showAlert(title: "无法打开", message: "无法获取当前视图控制器")
            return
        }

        let picker = UIDocumentPickerViewController(forExporting: [tempURL], asCopy: true)
        picker.shouldShowFileExtensions = true
        let delegate = ExportPickerDelegate()
        exportPickerDelegate = delegate
        picker.delegate = delegate
        topVC.present(picker, animated: true)
    }

    /// 获取顶层视图控制器
    private static func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else { return nil }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }

    // MARK: - 工具

    private static func dateString(_ timestamp: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func stampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter.string(from: Date())
    }
}

// MARK: - 导入文件选择器代理

private final class ImportPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: (URL?) -> Void

    init(onPick: @escaping (URL?) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick(nil)
    }
}

// MARK: - 导出文件选择器代理

private final class ExportPickerDelegate: NSObject, UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // 导出成功，无需额外处理
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消，无需额外处理
    }
}

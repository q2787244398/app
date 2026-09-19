import SwiftUI
import UIKit

// MARK: - Node 登录 API 客户端
//
// P1-06/07: 光鸭/蜗牛由 Node 常驻系统托管，登录协议对齐 bundle kstore_index.js：
//   - 光鸭扫码: POST /website/api/login/start {provider:"guangya"} -> {taskId, qrImage}
//               POST /website/api/login/poll   {provider:"guangya", taskId} -> {status}
//               POST /website/api/login/cancel {taskId}
//   - 蜗牛账号: GET /website/api/woniu4k/verify -> {data:{taskId, image}}（验证码）
//               PUT /website/api/woniu4k/login  {account, password, verify, taskId}
// 登录成功后统一走 NodeCredentialSyncService.saveProfile() 把凭据拉回 Keychain。

struct NodeLoginAPIClient {
    /// 请求 bundle API，返回 JSON 字典；HTTP 非 2xx / code != 0 抛错
    static func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> [String: Any] {
        guard NodeRuntimeManager.shared.isSystemReady else {
            throw NodeLoginError.nodeNotReady
        }
        guard let url = URL(string: NodeRuntimeManager.shared.baseURL + path) else {
            throw NodeLoginError.unknown
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NodeLoginError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["code"] as? Int, code != 0 {
            throw NodeLoginError.nodeRejected(json["msg"] as? String ?? "code=\(code)")
        }
        return json
    }

    /// data URL 或裸 base64 → UIImage
    static func image(fromDataURL dataURL: String) -> UIImage? {
        var source = dataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = source.range(of: "base64,") {
            source = String(source[range.upperBound...])
        }
        guard let data = Data(base64Encoded: source, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }
}

enum NodeLoginError: LocalizedError {
    case nodeNotReady
    case httpStatus(Int)
    case nodeRejected(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .nodeNotReady: return "Node 常驻系统未就绪"
        case .httpStatus(let code): return "HTTP \(code)"
        case .nodeRejected(let msg): return "Node 返回: \(msg)"
        case .unknown: return "未知错误"
        }
    }
}

// MARK: - 光鸭网盘扫码授权（Node 托管）

struct NodeGuangyaQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: UIImage? = nil
    @State private var statusText = "准备生成二维码"
    @State private var errorText = ""
    @State private var isGenerating = false
    @State private var isPolling = false
    @State private var taskId: String? = nil
    @State private var timer: Timer? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("光鸭网盘扫码授权")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let qrImage {
                        Image(uiImage: qrImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(10)
                            .background(Color.white)
                            .cornerRadius(16)
                            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.gray.opacity(0.08))
                            .frame(width: 260, height: 260)
                            .overlay(
                                ProgressView()
                                    .scaleEffect(1.4)
                            )
                    }

                    statusCard
                    tipCard

                    Button(action: {
                        Task { await regenerate() }
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
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("光鸭网盘授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
            .onAppear {
                Task { await startLogin() }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
                cancelTask()
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isPolling ? Color.orange : (errorText.isEmpty ? Color.green : Color.red))
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(10)
    }

    private var tipCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("使用光鸭 App 或浏览器扫码，确认后自动回收 Token。", systemImage: "lightbulb.fill")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            if !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.06))
        .cornerRadius(10)
    }

    // MARK: 登录流程

    private func startLogin() async {
        await regenerate()
    }

    private func regenerate() async {
        timer?.invalidate()
        timer = nil
        guard !isGenerating else { return }
        isGenerating = true
        errorText = ""
        statusText = "正在生成二维码..."
        defer { isGenerating = false }
        do {
            let result = try await NodeLoginAPIClient.request("POST", "/website/api/login/start", body: ["provider": "guangya"])
            let newTaskId = result["taskId"] as? String ?? ""
            taskId = newTaskId
            if let qrSrc = result["qrImage"] as? String, let img = NodeLoginAPIClient.image(fromDataURL: qrSrc) {
                qrImage = img
                statusText = result["msg"] as? String ?? "请扫码确认"
                startPolling(taskId: newTaskId)
            } else {
                errorText = "二维码生成失败：缺少图片数据"
                statusText = "二维码生成失败"
            }
        } catch {
            errorText = error.localizedDescription
            statusText = "生成失败"
        }
    }

    private func startPolling(taskId: String) {
        guard taskId.isEmpty == false else { return }
        isPolling = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { await poll(taskId: taskId) }
        }
    }

    private func poll(taskId: String) async {
        do {
            let result = try await NodeLoginAPIClient.request("POST", "/website/api/login/poll", body: ["provider": "guangya", "taskId": taskId])
            let status = result["status"] as? String ?? "waiting"
            let msg = result["msg"] as? String ?? ""
            switch status {
            case "success":
                statusText = msg.isEmpty ? "登录成功" : msg
                timer?.invalidate()
                timer = nil
                isPolling = false
                await finishSuccess()
            case "expired", "error":
                statusText = msg.isEmpty ? "登录已过期或失败" : msg
                timer?.invalidate()
                timer = nil
                isPolling = false
            default:
                statusText = msg.isEmpty ? "等待扫码确认..." : msg
            }
        } catch {
            // 单次 poll 失败不终止，保持轮询；连续失败由 UI 状态体现
            statusText = "轮询中... (\(error.localizedDescription))"
        }
    }

    /// 登录成功：把 Node 侧凭据拉回 Keychain（Token 落点 extra["token"]）
    private func finishSuccess() async {
        _ = await NodeCredentialSyncService.shared.saveProfile()
    }

    private func cancelTask() {
        guard let taskId, !taskId.isEmpty else { return }
        Task {
            try? await NodeLoginAPIClient.request("POST", "/website/api/login/cancel", body: ["taskId": taskId])
        }
    }
}

// MARK: - 蜗牛网盘账号登录（Node 托管）

struct NodeWoniu4kLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var verify = ""
    @State private var captchaImage: UIImage? = nil
    @State private var taskId: String? = nil
    @State private var statusText = "准备获取验证码"
    @State private var errorText = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("蜗牛网盘账号登录")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("账号 / 手机号", text: $account)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        SecureField("密码", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))

                        HStack(spacing: 10) {
                            TextField("验证码", text: $verify)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 14))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            Button(action: {
                                Task { await fetchVerify() }
                            }) {
                                Group {
                                    if let captchaImage {
                                        Image(uiImage: captchaImage)
                                            .resizable()
                                            .interpolation(.none)
                                            .scaledToFit()
                                            .frame(width: 120, height: 40)
                                    } else {
                                        Text("获取验证码")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                }
                                .frame(width: 120, height: 40)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(12)

                    statusCard

                    Button(action: {
                        Task { await submit() }
                    }) {
                        Text(isSubmitting ? "登录中..." : "登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canSubmit ? Color(hex: "E11D48") : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!canSubmit || isSubmitting)

                    Text("登录成功后将自动回收登录态 Cookie，并同步到本机 Keychain。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("蜗牛网盘授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
            .onAppear {
                Task { await fetchVerify() }
            }
        }
    }

    private var canSubmit: Bool {
        !account.isEmpty && !password.isEmpty && !verify.isEmpty
    }

    private var statusCard: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(errorText.isEmpty ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(errorText.isEmpty ? statusText : errorText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(10)
    }

    // MARK: 登录流程

    private func fetchVerify() async {
        errorText = ""
        statusText = "正在获取验证码..."
        do {
            let result = try await NodeLoginAPIClient.request("GET", "/website/api/woniu4k/verify")
            guard let data = result["data"] as? [String: Any],
                  let newTaskId = data["taskId"] as? String,
                  let imageSrc = data["image"] as? String,
                  let img = NodeLoginAPIClient.image(fromDataURL: imageSrc) else {
                errorText = "验证码获取失败：响应缺少 taskId/image"
                statusText = "验证码获取失败"
                return
            }
            taskId = newTaskId
            captchaImage = img
            verify = ""
            statusText = "请输入验证码后登录"
        } catch {
            errorText = error.localizedDescription
            statusText = "验证码获取失败"
        }
    }

    private func submit() async {
        guard let taskId, !taskId.isEmpty else {
            errorText = "请先获取验证码"
            return
        }
        isSubmitting = true
        errorText = ""
        statusText = "正在登录..."
        defer { isSubmitting = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "PUT",
                "/website/api/woniu4k/login",
                body: ["account": account, "password": password, "verify": verify, "taskId": taskId]
            )
            statusText = "登录成功"
            // 把 Node 侧凭据拉回 Keychain（account/password/cookie）
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
            // 验证码可能失效，自动刷新
            Task { await fetchVerify() }
        }
    }
}

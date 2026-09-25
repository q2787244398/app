import SwiftUI
import UIKit
import WebKit

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
    /// Node 未就绪时最多等待 readyTimeout 秒（App 刚启动/重启后引擎仍在拉起）
    static func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 20) async throws -> [String: Any] {
        if !NodeRuntimeManager.shared.isSystemReady {
            try await waitForNodeReady(timeout: 15)
        }
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
            let msg = json["msg"] as? String ?? "code=\(code)"
            // bundle Kee.poll 对任务丢失/过期返回 terminal=true，属不可重试的终端状态
            if (json["terminal"] as? Bool) == true {
                throw NodeLoginError.terminal(msg)
            }
            throw NodeLoginError.nodeRejected(msg)
        }
        return json
    }

    /// 轮询等待 Node 常驻系统就绪；崩溃/启动失败时立即返回 false
    private static func waitForNodeReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NodeRuntimeManager.shared.isSystemReady {
                return
            }
            if NodeRuntimeManager.shared.isCrashed {
                throw NodeLoginError.nodeNotReady
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
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
    /// Node 侧明确返回终端状态（terminal=true，如"登录任务不存在或已结束"）：
    /// 轮询必须停止，不可当作瞬时错误重试
    case terminal(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .nodeNotReady: return "Node 常驻系统未就绪"
        case .httpStatus(let code): return "HTTP \(code)"
        case .nodeRejected(let msg): return "Node 返回: \(msg)"
        case .terminal(let msg): return "Node 返回: \(msg)"
        case .unknown: return "未知错误"
        }
    }
}

// MARK: - 光鸭网盘登录（Node 托管 · 仅手机验证码）
//
// P1 追加：光鸭扫码链路依赖官方 OAuth device code 确认页，实测扫码后空白无响应，
// 故移除扫码登录，仅保留 TVS 配置中心同款的手机号短信验证码登录
// （/website/api/guangya/sms/send + sms/login）。

struct NodeGuangyaLoginRootView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            NodeGuangyaSMSLoginView()
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("光鸭网盘授权")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
        }
    }
}

// MARK: - 光鸭网盘手机短信验证码登录（Node 托管）

struct NodeGuangyaSMSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var smsTaskId: String? = nil
    @State private var statusText = "输入手机号后获取验证码"
    @State private var errorText = ""
    @State private var isSending = false
    @State private var isLoggingIn = false
    @State private var countdown = 0
    @State private var countdownTimer: Timer? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("使用光鸭注册手机号接收验证码，登录成功后自动回收 Token。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        TextField("光鸭手机号", text: $phone)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .keyboardType(.phonePad)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Button(action: {
                            Task { await sendSms() }
                        }) {
                            Text(countdown > 0 ? "\(countdown)s" : "获取验证码")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(countdown > 0 ? .gray : Color(hex: "E11D48"))
                                .frame(width: 90, height: 34)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .disabled(isSending || countdown > 0)
                    }

                    TextField("短信验证码", text: $code)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 14))
                        .keyboardType(.numberPad)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                .padding(14)
                .background(Color.gray.opacity(0.04))
                .cornerRadius(12)

                statusCard

                Button(action: {
                    Task { await loginSms() }
                }) {
                    Text(isLoggingIn ? "登录中..." : "验证码登录")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(canLogin ? Color(hex: "E11D48") : Color.gray)
                        .cornerRadius(12)
                }
                .disabled(!canLogin || isLoggingIn)

                Text("与 TVS 配置中心的「光鸭手机号 + 短信验证码」登录一致。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .onDisappear {
            countdownTimer?.invalidate()
        }
    }

    private var canLogin: Bool {
        !phone.isEmpty && !code.isEmpty
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

    // MARK: 短信流程（对齐 bundle renderGuangYa / kAr / vAr）

    private func sendSms() async {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请输入光鸭手机号"
            return
        }
        errorText = ""
        isSending = true
        statusText = "正在发送验证码..."
        defer { isSending = false }
        do {
            let result = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/guangya/sms/send",
                body: ["phone": trimmed]
            )
            smsTaskId = result["taskId"] as? String ?? ""
            statusText = result["msg"] as? String ?? "验证码已发送"
            startCountdown()
        } catch {
            errorText = error.localizedDescription
            statusText = "发送失败"
        }
    }

    private func loginSms() async {
        guard let smsTaskId, !smsTaskId.isEmpty else {
            errorText = "请先获取验证码"
            return
        }
        isLoggingIn = true
        errorText = ""
        statusText = "正在登录..."
        defer { isLoggingIn = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/guangya/sms/login",
                body: ["taskId": smsTaskId, "code": code.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
            statusText = "登录成功"
            // 把 Node 侧凭据拉回 Keychain（token 落点 extra["token"]）
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 60
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdown > 1 {
                countdown -= 1
            } else {
                countdown = 0
                timer.invalidate()
                countdownTimer = nil
            }
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

// MARK: - 通用 Node 扫码登录（115）
//
// 复用光鸭扫码链路：POST /website/api/login/start {provider} -> {taskId, qrImage}
//                POST /website/api/login/poll  {provider, taskId} -> {status}
// provider 由调用方传入（目前仅 "pan115"），登录成功统一 saveProfile 拉回 Keychain。

struct NodeScanLoginRootView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: String
    let title: String
    let tip: String

    var body: some View {
        NavigationView {
            NodeScanQRLoginView(provider: provider, title: title, tip: tip)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
        }
    }
}

struct NodeScanQRLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: String
    let title: String
    let tip: String
    /// 登录成功回调。多步登录（如 UC网盘Node 先 Cookie 再 TV Token）传入后，
    /// 由调用方接管后续步骤，本视图不再自动 dismiss。
    var onSuccess: (() -> Void)? = nil

    @State private var qrImage: UIImage? = nil
    @State private var statusText = "准备生成二维码"
    @State private var errorText = ""
    @State private var isGenerating = false
    @State private var isPolling = false
    @State private var taskId: String? = nil
    @State private var timer: Timer? = nil

    /// 轮询上下文（引用类型：SwiftUI View 值重建时保留计时/失败计数/并发标志）
    private final class PollContext {
        var startedAt = Date()
        var consecutiveFailures = 0
        var inFlight = false
        /// 生成代数：每次 regenerate 自增，旧请求返回后结果直接丢弃
        var generation = 0
        /// 终端状态后自动重新生成的次数（限 1 次，防止引擎反复重启导致死循环）
        var autoRegenCount = 0
        var baseline = ""
    }
    @State private var pollCtx = PollContext()

    /// 轮询总时长上限：与 Node 侧任务 TTL（300s）对齐，到点停止引导重新生成
    private let pollTimeout: TimeInterval = 290
    /// 连续网络失败上限（1.5s/次 × 6 ≈ 9s），超过停止避免无限"轮询中"
    private let maxConsecutiveFailures = 6

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(title)
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
        .onAppear {
            Task { await regenerate() }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
            cancelTask()
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
            Label(tip, systemImage: "lightbulb.fill")
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

    private func regenerate() async {
        timer?.invalidate()
        timer = nil
        guard !isGenerating else { return }
        isGenerating = true
        // 重置轮询状态：旧请求结果作废、失败计数清零、允许下一次自动重生成
        pollCtx.generation += 1
        pollCtx.inFlight = false
        pollCtx.consecutiveFailures = 0
        errorText = ""
        statusText = "正在生成二维码..."
        defer { isGenerating = false }
        do {
            let result = try await NodeLoginAPIClient.request("POST", "/website/api/login/start", body: ["provider": provider])
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
        pollCtx.startedAt = Date()
        pollCtx.consecutiveFailures = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { await poll(taskId: taskId) }
        }
    }

    private func poll(taskId: String) async {
        // 并发护栏：上一次请求未返回时跳过本次（轮询超时 10s > 定时器 1.5s）
        guard !pollCtx.inFlight else { return }
        // 代数护栏：regenerate 后旧请求的结果直接丢弃
        let gen = pollCtx.generation
        pollCtx.inFlight = true
        defer { pollCtx.inFlight = false }

        // 总时长上限：与 Node 任务 TTL（300s）对齐，到点停止引导重新生成
        if Date().timeIntervalSince(pollCtx.startedAt) >= pollTimeout {
            stopPolling(status: "轮询超时", error: "二维码已过期，请重新生成")
            return
        }

        do {
            let result = try await NodeLoginAPIClient.request(
                "POST", "/website/api/login/poll",
                body: ["provider": provider, "taskId": taskId],
                timeout: 10
            )
            guard gen == pollCtx.generation else { return }
            pollCtx.consecutiveFailures = 0
            let status = result["status"] as? String ?? "waiting"
            let msg = result["msg"] as? String ?? ""
            switch status {
            case "success":
                statusText = msg.isEmpty ? "登录成功" : msg
                stopPolling(status: statusText, error: "")
                await finishSuccess()
            case "expired", "error":
                // 终端状态（code==0 + terminal=true）：任务已过期/结束
                handleTerminal(msg.isEmpty ? "登录已过期或失败" : msg)
            default:
                statusText = msg.isEmpty ? "等待扫码确认..." : msg
            }
        } catch let NodeLoginError.terminal(msg) {
            // Node 侧明确返回终端：任务不存在/已结束 → 停止轮询并引导重新生成
            guard gen == pollCtx.generation else { return }
            handleTerminal(msg)
        } catch {
            // 网络层 / HTTP / Node 未就绪等瞬时错误：连续失败计数，达上限停止
            guard gen == pollCtx.generation else { return }
            pollCtx.consecutiveFailures += 1
            if pollCtx.consecutiveFailures >= maxConsecutiveFailures {
                stopPolling(status: "轮询失败", error: "网络连接已中断，请重新生成二维码")
            } else {
                statusText = "轮询中... (\(error.localizedDescription))"
            }
        }
    }

    /// 终端状态：停止轮询并展示原因；Node 重启导致任务丢失时自动重新生成一次
    private func handleTerminal(_ msg: String) {
        stopPolling(status: "登录已结束", error: msg)
        pollCtx.autoRegenCount += 1
        guard pollCtx.autoRegenCount <= 1 else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !isPolling else { return }
            await regenerate()
        }
    }

    /// 统一停止轮询并落状态
    private func stopPolling(status: String, error: String) {
        timer?.invalidate()
        timer = nil
        isPolling = false
        statusText = status
        if error.isEmpty {
            errorText = ""
        } else {
            errorText = error
        }
    }

    /// 登录成功：把 Node 侧凭据拉回 Keychain；多步登录交由 onSuccess 接管后续步骤
    private func finishSuccess() async {
        _ = await NodeCredentialSyncService.shared.saveProfile()
        if let onSuccess {
            onSuccess()
            return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        dismiss()
    }

    private func cancelTask() {
        guard let taskId, !taskId.isEmpty else { return }
        Task {
            try? await NodeLoginAPIClient.request("POST", "/website/api/login/cancel", body: ["taskId": taskId])
        }
    }
}

// MARK: - 123 云盘账号密码登录（Node 托管）
//
// 对齐 bundle renderPan123 / savePan123：
//   PUT /website/api/pan123/account {account, password}

struct NodePan123LoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var statusText = "输入 123 网盘账号密码登录"
    @State private var errorText = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("123 网盘账号登录")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("123 账号", text: $account)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        SecureField("123 密码", text: $password)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                    }
                    .padding(14)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(12)

                    statusCard

                    Button(action: {
                        Task { await submit() }
                    }) {
                        Text(isSubmitting ? "登录中..." : "登录并保存")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canSubmit ? Color(hex: "E11D48") : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!canSubmit || isSubmitting)

                    Text("与 TVS 配置中心的「123 账号 + 密码」登录一致，登录成功后自动同步到本机 Keychain。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("123 网盘授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
    }

    private var canSubmit: Bool {
        !account.isEmpty && !password.isEmpty
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

    private func submit() async {
        isSubmitting = true
        errorText = ""
        statusText = "正在登录..."
        defer { isSubmitting = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "PUT",
                "/website/api/pan123/account",
                body: ["account": account.trimmingCharacters(in: .whitespacesAndNewlines),
                       "password": password]
            )
            statusText = "登录成功"
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
        }
    }
}

// MARK: - 139 移动云盘手机号验证码登录（Node 托管）
//
// 对齐 bundle renderNew139 / sendNew139Sms / loginNew139：
//   POST /website/api/new139/sms/send {phone} -> {msg, loginHeaders, captchaUrl?}
//   POST /website/api/new139/login   {phone, code, headers}
// 如触发滑块验证，内嵌 captchaUrl 页面完成后等待短信验证码。

struct NodePan139SMSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var code = ""
    @State private var loginHeaders: [String: Any] = [:]
    @State private var captchaUrl: String? = nil
    @State private var statusText = "输入移动手机号后获取验证码"
    @State private var errorText = ""
    @State private var isSending = false
    @State private var isLoggingIn = false
    @State private var countdown = 0
    @State private var countdownTimer: Timer? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("139 移动云盘使用手机号验证码登录；如触发滑块验证，请先在下方面板完成滑块，再等待短信。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("移动手机号", text: $phone)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 14))
                                .keyboardType(.phonePad)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            Button(action: {
                                Task { await sendSms() }
                            }) {
                                Text(countdown > 0 ? "\(countdown)s" : "获取验证码")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(countdown > 0 ? .gray : Color(hex: "E11D48"))
                                    .frame(width: 90, height: 34)
                                    .background(Color.gray.opacity(0.08))
                                    .cornerRadius(8)
                            }
                            .disabled(isSending || countdown > 0)
                        }

                        TextField("短信验证码", text: $code)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .keyboardType(.numberPad)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(14)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(12)

                    if let captchaUrl, !captchaUrl.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("滑块验证（完成后请等待短信）")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                            NodeCaptchaWebView(urlString: captchaUrl)
                                .frame(height: 300)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    statusCard

                    Button(action: {
                        Task { await loginSms() }
                    }) {
                        Text(isLoggingIn ? "登录中..." : "验证码登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canLogin ? Color(hex: "E11D48") : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!canLogin || isLoggingIn)

                    Text("与 TVS 配置中心的「139 手机号 + 短信验证码」登录一致。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("139 移动云盘授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
        .onDisappear {
            countdownTimer?.invalidate()
        }
    }

    private var canLogin: Bool {
        !phone.isEmpty && !code.isEmpty
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

    private func sendSms() async {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请输入移动手机号"
            return
        }
        errorText = ""
        isSending = true
        statusText = "正在发送验证码..."
        defer { isSending = false }
        do {
            let result = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/new139/sms/send",
                body: ["phone": trimmed]
            )
            loginHeaders = result["loginHeaders"] as? [String: Any] ?? [:]
            captchaUrl = result["captchaUrl"] as? String
            statusText = result["msg"] as? String ?? "验证码已发送"
            startCountdown()
        } catch {
            errorText = error.localizedDescription
            statusText = "发送失败"
        }
    }

    private func loginSms() async {
        isLoggingIn = true
        errorText = ""
        statusText = "正在登录..."
        defer { isLoggingIn = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/new139/login",
                body: [
                    "phone": phone.trimmingCharacters(in: .whitespacesAndNewlines),
                    "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
                    "headers": loginHeaders
                ]
            )
            statusText = "登录成功"
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 60
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdown > 1 {
                countdown -= 1
            } else {
                countdown = 0
                timer.invalidate()
                countdownTimer = nil
            }
        }
    }
}

// MARK: - 滑块验证码内嵌页（139 移动云盘）

struct NodeCaptchaWebView: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let url = URL(string: urlString) else { return }
        uiView.load(URLRequest(url: url))
    }
}

// MARK: - 189 天翼网盘登录入口（仅账号密码 + 短信验证码）
//
// 对齐 bundle renderPan189 与 TVS：189 官方已取消二维码登录，扫码通道
// open.e.189.cn oauth qrcode 已失效（扫码只会提示"页面已过期"），因此
// 不提供扫码入口。登录流程：
//   - PUT /website/api/pan189/account {account, password}，若返回 sms:true
//           再 POST /website/api/pan189/sms/login {code}

struct NodePan189LoginRootView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            NodePan189AccountLoginView()
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("天翼网盘授权")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                            .foregroundColor(Color(hex: "E11D48"))
                    }
                }
        }
    }
}

struct NodePan189AccountLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var smsCode = ""
    @State private var needSms = false
    @State private var statusText = "输入天翼账号密码登录"
    @State private var errorText = ""
    @State private var isSubmitting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("使用天翼网盘账号密码登录；若账号开启二次校验，Node 会下发短信验证码。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("天翼账号", text: $account)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 14))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("天翼密码", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .font(.system(size: 14))

                    if needSms {
                        TextField("短信验证码（非必填）", text: $smsCode)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .keyboardType(.numberPad)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                .padding(14)
                .background(Color.gray.opacity(0.04))
                .cornerRadius(12)

                statusCard

                Button(action: {
                    Task { await submit() }
                }) {
                    Text(isSubmitting ? "登录中..." : (needSms ? "验证短信并登录" : "登录并保存"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(canSubmit ? Color(hex: "E11D48") : Color.gray)
                        .cornerRadius(12)
                }
                .disabled(!canSubmit || isSubmitting)

                Text("与 TVS 配置中心的「天翼账号 + 密码（可选短信）」登录一致。")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var canSubmit: Bool {
        !account.isEmpty && !password.isEmpty && (!needSms || !smsCode.isEmpty)
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

    private func submit() async {
        isSubmitting = true
        errorText = ""
        defer { isSubmitting = false }
        if needSms {
            statusText = "正在验证短信..."
            do {
                _ = try await NodeLoginAPIClient.request(
                    "POST",
                    "/website/api/pan189/sms/login",
                    body: ["code": smsCode.trimmingCharacters(in: .whitespacesAndNewlines)]
                )
                statusText = "登录成功"
                _ = await NodeCredentialSyncService.shared.saveProfile()
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                statusText = "登录失败"
            }
            return
        }

        statusText = "正在登录..."
        do {
            let result = try await NodeLoginAPIClient.request(
                "PUT",
                "/website/api/pan189/account",
                body: ["account": account.trimmingCharacters(in: .whitespacesAndNewlines),
                       "password": password]
            )
            if let sms = result["sms"] as? Bool, sms {
                needSms = true
                statusText = result["msg"] as? String ?? "请输入短信验证码"
                return
            }
            statusText = "登录成功"
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
        }
    }
}

// MARK: - 迅雷云盘验证码登录（Node 托管）
//
// 对齐 bundle renderThunder / sendThunderSms / loginThunderSms：
//   POST /website/api/thunder/sms/send {mobile}
//   POST /website/api/thunder/sms/login {code}

struct NodeXunleiSMSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mobile = ""
    @State private var code = ""
    @State private var statusText = "输入手机号后获取验证码"
    @State private var errorText = ""
    @State private var isSending = false
    @State private var isLoggingIn = false
    @State private var countdown = 0
    @State private var countdownTimer: Timer? = nil

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("使用注册迅雷云盘的手机号接收验证码，登录成功后自动回收登录态。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            TextField("手机号", text: $mobile)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 14))
                                .keyboardType(.phonePad)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)

                            Button(action: {
                                Task { await sendSms() }
                            }) {
                                Text(countdown > 0 ? "\(countdown)s" : "获取验证码")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(countdown > 0 ? .gray : Color(hex: "E11D48"))
                                    .frame(width: 90, height: 34)
                                    .background(Color.gray.opacity(0.08))
                                    .cornerRadius(8)
                            }
                            .disabled(isSending || countdown > 0)
                        }

                        TextField("验证码", text: $code)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 14))
                            .keyboardType(.numberPad)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                    .padding(14)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(12)

                    statusCard

                    Button(action: {
                        Task { await loginSms() }
                    }) {
                        Text(isLoggingIn ? "登录中..." : "验证码登录")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canLogin ? Color(hex: "E11D48") : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!canLogin || isLoggingIn)

                    Text("与 TVS 配置中心的「迅雷手机号 + 验证码」登录一致。")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("迅雷云盘授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
        .onDisappear {
            countdownTimer?.invalidate()
        }
    }

    private var canLogin: Bool {
        !mobile.isEmpty && !code.isEmpty
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

    private func sendSms() async {
        let trimmed = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "请输入手机号"
            return
        }
        errorText = ""
        isSending = true
        statusText = "正在发送验证码..."
        defer { isSending = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/thunder/sms/send",
                body: ["mobile": trimmed]
            )
            statusText = "验证码已发送，请输入短信验证码"
            startCountdown()
        } catch {
            errorText = error.localizedDescription
            statusText = "发送失败"
        }
    }

    private func loginSms() async {
        isLoggingIn = true
        errorText = ""
        statusText = "正在登录..."
        defer { isLoggingIn = false }
        do {
            _ = try await NodeLoginAPIClient.request(
                "POST",
                "/website/api/thunder/sms/login",
                body: ["code": code.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
            statusText = "登录成功"
            _ = await NodeCredentialSyncService.shared.saveProfile()
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            statusText = "登录失败"
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 60
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            if countdown > 1 {
                countdown -= 1
            } else {
                countdown = 0
                timer.invalidate()
                countdownTimer = nil
            }
        }
    }
}

// MARK: - UC网盘Node 两步扫码登录（第 1 步 Cookie → 第 2 步 TV Token）
//
// UC Node 播放链路对非高会账号要求 Cookie 与 TV Token 同时存在：
// bundle loadPlayLinks 先 requireCookie（转存、目录、会员判断都依赖 Cookie），
// 非高会账号再 ensureTvToken 取流。两者由 bundle 两个独立 provider 产生
// （ucCookie 只写 pan.uc.cookie；ucToken 只写 pan.uc.token + refreshToken），
// 与原生 UC「先网页扫码拿 Cookie，再授权 TV 拿 Token」完全一致。
// 这里把两步串成一条流：第 1 步扫码成功即自动切出第 2 步二维码，免去手动切换。

struct NodeUcTwoStepLoginView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Step { case cookie, tv }

    @State private var step: Step = .cookie

    /// 本机是否已有可用 Cookie（上次登录已回拉到 ucNode 凭据）：有则可跳过第 1 步
    private var hasExistingCookie: Bool {
        let cookie = CloudDriveAuthManager.shared.credential(for: .ucNode)?.cookie ?? ""
        return !cookie.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
            switch step {
            case .cookie:
                NodeScanQRLoginView(
                    provider: "ucCookie",
                    title: "第 1 步 · 扫码获取 Cookie",
                    tip: "使用 UC 浏览器扫码后确认。Cookie 是基础登录态，转存与目录读取都依赖它。",
                    onSuccess: { Task { await goToTVStep() } }
                )
                .id("ucNode-step-cookie")
            case .tv:
                NodeScanQRLoginView(
                    provider: "ucToken",
                    title: "第 2 步 · 扫码获取 TV Token",
                    tip: "再用 UC 浏览器扫码授权 TV。TV Token 供非高会账号取流，与第 1 步的 Cookie 缺一不可。",
                    onSuccess: { Task { await finish() } }
                )
                .id("ucNode-step-tv")
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var stepIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                stepChip(index: 1, text: "Cookie", active: step == .cookie, done: step == .tv)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                stepChip(index: 2, text: "TV Token", active: step == .tv, done: false)
            }
            Text("UC网盘Node 播放需要 Cookie + TV Token 两项凭据，请按顺序完成两次扫码。")
                .font(.system(size: 12))
                .foregroundColor(.gray)
            if step == .cookie && hasExistingCookie {
                Button(action: {
                    Task { await goToTVStep() }
                }) {
                    Text("本机已有 Cookie，直接进行第 2 步")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func stepChip(index: Int, text: String, active: Bool, done: Bool) -> some View {
        let tint: Color = done ? .green : (active ? Color(hex: "E11D48") : .gray)
        return HStack(spacing: 5) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(index).circle.fill")
                .font(.system(size: 13))
            Text(text)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(active || done ? tint.opacity(0.1) : Color.clear)
        )
    }

    /// 第 1 步完成：短暂停留展示「已完成」后自动切到第 2 步
    private func goToTVStep() async {
        try? await Task.sleep(nanoseconds: 600_000_000)
        step = .tv
    }

    /// 第 2 步完成：凭据已由 NodeScanQRLoginView 回拉，收尾退出
    private func finish() async {
        try? await Task.sleep(nanoseconds: 800_000_000)
        dismiss()
    }
}



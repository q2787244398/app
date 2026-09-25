import SwiftUI
import WebKit
import UIKit

struct TokenWebView: View {
    let driveType: CloudDriveManager.DriveType
    @Binding var token: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            TokenWebViewRepresentable(driveType: driveType, token: $token)
                .navigationTitle("获取 \(driveType.displayName) Token")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct TokenWebViewRepresentable: UIViewRepresentable {
    let driveType: CloudDriveManager.DriveType
    @Binding var token: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = userAgent
        context.coordinator.webView = webView

        // 注入已有 Cookie（如果有）
        injectExistingCookies(into: webView) {
            webView.load(URLRequest(url: startURL))
        }

        // 启动定时轮询检测 Cookie（应对 AJAX 登录不刷新页面的情况）
        context.coordinator.startCookiePolling()

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var startURL: URL {
        switch driveType {
        case .baidu:
            return URL(string: "https://pan.baidu.com/")!
        case .ali:
            // 阿里云盘：使用 OpenList 授权页面，用户扫码后页面会展示 refresh_token
            return URL(string: "https://api.oplist.org/?driver=alicloud&driver_txt=alicloud_qr&server_use=true&server_set=true")!
        case .quark:
            return URL(string: "https://pan.quark.cn/")!
        case .uc:
            return URL(string: "https://drive.uc.cn/")!
        case .one15:
            // 115网盘登录页面（强制使用扫码/账密登录入口）
            return URL(string: "https://115.com/?ct=login")!
        case .pan123:
            // 123云盘登录页面，优先使用移动端登录页
            return URL(string: "https://www.123pan.com/login")!
        case .pan139:
            return URL(string: "https://yun.139.com/")!
        case .pan189:
            return URL(string: "https://cloud.189.cn/")!
        case .xunlei:
            return URL(string: "https://i.xunlei.com/xluser/login.html")!
        case .guangya, .woniu4k, .bilibili, .quarkNode, .ucNode, .baiduNode:
            // 光鸭/蜗牛/B站/夸克Node/UC网盘Node/百度网盘Node 由 Node 常驻系统托管，不走 WebView 登录；保留首页作兜底展示
            return URL(string: "https://guangyapan.com/")!
        }
    }

    private var userAgent: String {
        switch driveType {
        case .quark:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.54 Safari/537.36"
        case .uc:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.5 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/ucpan_other_ch"
        case .baidu:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .ali:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .one15:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 115Browser/27.0.3.4"
        case .pan123:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .pan139:
            return "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
        case .pan189:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        case .xunlei:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        case .guangya, .woniu4k, .bilibili, .quarkNode, .ucNode, .baiduNode:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }
    }

    private var cookieHosts: [String] {
        switch driveType {
        case .baidu: return ["pan.baidu.com", "passport.baidu.com", ".baidu.com"]
        case .ali: return ["aliyundrive.com", "alipan.com", ".aliyundrive.com", ".alipan.com", "passport.alipan.com", "auth.alipan.com", "api.alipan.com", "openapi.alipan.com"]
        case .quark: return ["pan.quark.cn", "drive-pc.quark.cn", ".quark.cn"]
        case .uc: return ["drive.uc.cn", "pc-api.uc.cn", ".uc.cn"]
        case .one15: return ["115.com", ".115.com"]
        case .pan123: return ["www.123pan.com", ".123pan.com", "123684.com", ".123684.com", "api.123pan.com", "openapi.123pan.com"]
        case .pan139: return ["yun.139.com", ".139.com", "caiyun.139.com"]
        case .pan189: return ["cloud.189.cn", ".189.cn", "api.189.cn"]
        case .xunlei: return ["pan.xunlei.com", ".xunlei.com", "i.xunlei.com", "login.xunlei.com", "dynamic.cloud.vip.xunlei.com"]
        case .guangya, .woniu4k, .bilibili, .quarkNode, .ucNode, .baiduNode:
            // Node 托管盘无 WebView Cookie 注入需求
            return []
        }
    }

    private func injectExistingCookies(into webView: WKWebView, completion: @escaping () -> Void) {
        guard let credential = CloudDriveAuthManager.shared.credential(for: driveType),
              let cookie = credential.cookie,
              !cookie.isEmpty else {
            completion()
            return
        }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let pieces = cookie.components(separatedBy: ";")
        let group = DispatchGroup()
        for host in cookieHosts {
            for piece in pieces {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let eqIndex = trimmed.firstIndex(of: "=") else { continue }
                let name = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: host,
                    .path: "/"
                ]
                if let cookie = HTTPCookie(properties: properties) {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
            }
        }
        group.notify(queue: .main) { completion() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: TokenWebViewRepresentable
        weak var webView: WKWebView?
        private var cookieTimer: Timer?
        private var hasDetected = false

        init(_ parent: TokenWebViewRepresentable) {
            self.parent = parent
        }

        deinit {
            cookieTimer?.invalidate()
        }

        // MARK: - Cookie 轮询（应对 AJAX 登录不触发 didFinish 的情况）
        func startCookiePolling() {
            cookieTimer?.invalidate()
            cookieTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                guard let self = self, !self.hasDetected, let webView = self.webView else {
                    self?.cookieTimer?.invalidate()
                    return
                }
                self.extractToken(from: webView)
            }
        }

        // MARK: - WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            extractToken(from: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // 115/123 等网盘登录页面可能通过 iframe 加载子资源，子帧加载失败不应中断主页面登录流程
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled || nsError.code == 102 {
                print("[TokenWebView] 忽略帧框加载中断: \(error.localizedDescription)")
                return
            }
            print("[TokenWebView] 页面加载失败: \(error.localizedDescription)")
        }

        // MARK: - WKUIDelegate：处理 window.open / alert / confirm / prompt
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // UC 等网页登录可能通过 window.open 打开新窗口，直接在当前页加载
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler()
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
            rootVC.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler(false)
                return
            }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            rootVC.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            guard let rootVC = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else {
                completionHandler(nil)
                return
            }
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            rootVC.present(alert, animated: true)
        }

        // MARK: - Token / Cookie 提取
        private func extractToken(from webView: WKWebView) {
            guard !hasDetected else { return }
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                var cookieString = ""
                for cookie in cookies {
                    cookieString += "\(cookie.name)=\(cookie.value); "
                }

                // 阿里云盘特殊处理：refresh_token 在页面中显示，不在 Cookie 里
                // 优先从页面内容提取，Cookie 检测仅作为兜底
                if self.parent.driveType == .ali {
                    self.extractAliToken(from: webView, cookieString: cookieString)
                    return
                }

                // 尝试从页面内容提取 token
                webView.evaluateJavaScript("document.body.innerText") { result, error in
                    if let text = result as? String {
                        if let token = self.extractTokenFromText(text) {
                            DispatchQueue.main.async {
                                self.parent.token = token
                                self.hasDetected = true
                                self.cookieTimer?.invalidate()
                            }
                        }
                    }
                }

                // 如果 cookie 足够，也保存 cookie
                if self.isEnough(cookieString) {
                    DispatchQueue.main.async {
                        self.parent.token = cookieString.trimmingCharacters(in: .whitespaces)
                        self.hasDetected = true
                        self.cookieTimer?.invalidate()
                    }
                }
            }
        }

        /// 阿里云盘专用：从页面 DOM 提取 refresh_token
        /// OpenList 页面会在 input/textarea 或页面文本中展示 refresh_token
        private func extractAliToken(from webView: WKWebView, cookieString: String) {
            // 多种 JS 提取方式，按优先级尝试
            let scripts = [
                // 1. 读取 input/textarea 中的值（OpenList 页面的 token 显示在输入框）
                "Array.from(document.querySelectorAll('input, textarea, [data-token], [data-refresh-token]')).map(e => e.value || e.textContent || e.getAttribute('data-token') || e.getAttribute('data-refresh-token')).find(v => v && v.trim().length > 50)",
                // 2. 读取所有 input 元素找 token
                "Array.from(document.querySelectorAll('input, textarea')).map(e => e.value).find(v => v && v.length > 20)",
                // 3. 读取页面显式文本
                "document.body.innerText",
            ]

            func tryNextScript(_ index: Int) {
                guard index < scripts.count, !hasDetected else { return }
                webView.evaluateJavaScript(scripts[index]) { result, error in
                    if let text = result as? String, let token = self.extractAliRefreshToken(text) {
                        DispatchQueue.main.async {
                            self.parent.token = token
                            self.hasDetected = true
                            self.cookieTimer?.invalidate()
                        }
                        return
                    }
                    // 尝试下一个脚本
                    tryNextScript(index + 1)
                }
            }
            tryNextScript(0)

            // Cookie 兜底：OpenList 登录后可能有 refresh_token 相关 cookie
            // 但仅当 cookie 中明确包含 refresh_token 时才用
            if cookieString.lowercased().contains("refresh_token") {
                let patterns = [
                    "refresh_token=([^;]+)",
                ]
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                          let match = regex.firstMatch(in: cookieString, range: NSRange(cookieString.startIndex..., in: cookieString)),
                          match.numberOfRanges > 1,
                          let range = Range(match.range(at: 1), in: cookieString) else { continue }
                    let token = String(cookieString[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if token.count > 20 {
                        DispatchQueue.main.async {
                            self.parent.token = token
                            self.hasDetected = true
                            self.cookieTimer?.invalidate()
                        }
                        return
                    }
                }
            }
        }

        /// 从页面文本提取阿里云盘 refresh_token（支持多种格式）
        private func extractAliRefreshToken(_ text: String) -> String? {
            let patterns = [
                // 标准格式: refresh_token: xxx 或 refresh_token：xxx
                "refresh_token[:：]\\s*([a-zA-Z0-9_-]{20,})",
                // 纯 token 格式（OpenList 页面可能直接显示 token 值）
                "([a-zA-Z0-9_-]{32,})",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                // 阿里 refresh_token 通常是较长字符串
                if token.count > 20 { return token }
            }
            // 如果整个文本就是 token（纯 token 无标签）
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 20 && trimmed.count < 500 && !trimmed.contains(" ") && !trimmed.contains("\n") {
                return trimmed
            }
            return nil
        }

        private func extractTokenFromText(_ text: String) -> String? {
            let patterns = [
                "refresh_token[:：]\\s*([a-zA-Z0-9_-]+)",
                "token[:：]\\s*([a-zA-Z0-9_-]+)",
                "access_token[:：]\\s*([a-zA-Z0-9_-]+)"
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if token.count > 20 { return token }
            }
            return nil
        }

        private func isEnough(_ cookie: String) -> Bool {
            let lower = cookie.lowercased()
            switch parent.driveType {
            case .baidu:
                return lower.contains("bduss=") && lower.contains("stoken=")
            case .ali:
                return lower.contains("token") || lower.contains("login") || lower.contains("aliyun")
            case .quark:
                return lower.contains("__puus=") || (lower.contains("__pus=") && lower.contains("__kps="))
            case .uc:
                return lower.contains("__pus=") || lower.contains("__kps=") || lower.contains("__uid=") || (lower.contains("uc") && lower.count > 50)
            case .one15:
                // 115 网盘要求 Cookie 包含 UID + CID（SEID/KID 为推荐字段）
                // 仅当同时包含 UID 和 CID 时才认为 Cookie 足够，避免过早接受不完整的 Cookie
                let hasUID = lower.contains("uid=")
                let hasCID = lower.contains("cid=")
                let hasKID = lower.contains("kid=")
                return (hasUID && hasCID) || (hasUID && hasKID)
            case .pan123:
                return lower.contains("authorization") || lower.contains("token") || lower.contains("auth") ||
                       lower.contains("session") || lower.contains("login") || lower.contains("userid") ||
                       lower.contains("uid=") || lower.contains("passport") || lower.contains("pan123") ||
                       lower.contains("123pan") || lower.contains("123_") || lower.contains("__uid")
            case .pan139:
                return lower.contains("ssotoken") || lower.contains("sso_token") || lower.contains("mcloud") || lower.contains("sessionid")
            case .pan189:
                return lower.contains("ssotoken=") || lower.contains("sso_token=") ||
                       lower.contains("usersession=") || lower.contains("ec_session=") ||
                       lower.contains("CASTGC=") || lower.contains("islogin=")
            case .xunlei:
                return lower.contains("userid=") || lower.contains("usernewno=") ||
                       lower.contains("xunlei_kis=") || lower.contains("gdriveid=") ||
                       lower.contains("xunlei_kisp=")
            case .guangya, .woniu4k, .bilibili, .quarkNode, .ucNode, .baiduNode:
                // Node 托管盘不走 WebView Cookie 校验
                return false
            }
        }
    }
}

// MARK: - TokenFetcherView（通用网盘Token抓取页面）
struct TokenFetcherView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloudDriveManager: CloudDriveManager
    var onTokenDetected: ((String, String) -> Void)? = nil
    @State private var detectedToken: (type: String, value: String)? = nil
    @State private var isLoading = true
    @State private var autoAdded = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebViewRepresentable(driveType: .ali, token: .constant(""))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { isLoading = false }

                if detectedToken == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载页面...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("请扫码登录后，页面会自动检测Token")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .padding(.bottom, 40)
                } else if let token = detectedToken {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("成功获取 Token")
                            .font(.system(size: 16, weight: .semibold))
                        Text("已自动添加到网盘列表")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                    }
                    .padding(.bottom, 40)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("获取Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Text("关闭").foregroundColor(Color(hex: "E11D48"))
                    }
                }
            }
        }
    }
}

// MARK: - CloudDriveWebAuthView（网盘授权页面）
struct CloudDriveWebAuthView: View {
    @Environment(\.dismiss) private var dismiss
    let driveType: CloudDriveManager.DriveType
    @State private var isLoading = true
    @State private var statusText = "请在官方页面完成登录或验证"
    @State private var saved = false
    @State private var detectedToken: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TokenWebView(driveType: driveType, token: $detectedToken)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { isLoading = false }
                    .onChange(of: detectedToken) { newToken in
                        guard !newToken.isEmpty, !saved else { return }
                        saveDetectedCredential(token: newToken)
                    }

                VStack(spacing: 8) {
                    if isLoading && !saved {
                        ProgressView()
                    }
                    Text(saved ? "授权已保存" : statusText)
                        .font(.system(size: 13, weight: saved ? .semibold : .regular))
                        .foregroundColor(saved ? .green : .gray)
                        .multilineTextAlignment(.center)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle("\(driveType.displayName) 授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            }
        }
    }

    private func saveDetectedCredential(token: String) {
        let credential = CloudDriveCredential(
            driveType: driveType.rawValue,
            authType: .webView,
            accessToken: driveType == .ali ? token : nil,
            refreshToken: driveType == .ali ? token : nil,
            cookie: driveType == .ali ? nil : token,
            driveId: nil,
            userId: nil,
            userName: nil,
            avatar: nil,
            expiresAt: nil,
            updatedAt: Date(),
            lastCheckedAt: Date(),
            state: .valid,
            statusMessage: "WebView 登录成功",
            extra: [:]
        )
        CloudDriveAuthManager.shared.saveCredential(credential)
        saved = true
        statusText = "授权已保存"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }
}

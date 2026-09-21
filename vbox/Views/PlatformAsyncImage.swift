import SwiftUI

// MARK: - 平台封面图 SwiftUI 组件
// 替换原生 AsyncImage, 支持:
// - 神秘电影: UA/Referer 头注入 (对应 Python img_url @UA@Referer)
// - 每日大乱斗/大赛: AES 解密 (对应 Python aesimg)
// - 内存缓存 + 并发去重

struct PlatformAsyncImage: View {
    let urlString: String
    let mode: PlatformImageMode
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var loadFailed = false

    init(urlString: String, mode: PlatformImageMode, contentMode: ContentMode = .fill) {
        self.urlString = urlString
        self.mode = mode
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if loadFailed {
                // 加载失败: 灰色背景 + 图标（不拦截点击，让其穿透到外层 NavigationLink/Button）
                Rectangle()
                    .fill(Color.gray.opacity(0.18))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 24))
                    )
                    .allowsHitTesting(false)
            } else {
                // 加载中（占位不拦截点击，让其穿透到外层 NavigationLink/Button）
                Rectangle()
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        Image(systemName: "play.rectangle.fill")
                            .foregroundColor(.white.opacity(0.3))
                            .font(.system(size: 20))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onAppear { loadImage() }
        .onChange(of: urlString) { _ in
            image = nil
            loadFailed = false
            loadImage()
        }
    }

    private func loadImage() {
        guard !urlString.isEmpty, image == nil else { return }
        let requestURL = urlString

        // 先检查缓存
        let cacheKey = PlatformImageLoader.makeCacheKey(requestURL, mode: mode)
        if let cached = PlatformImageCache.shared.get(cacheKey) {
            image = cached
            return
        }

        Task {
            let loaded = await PlatformImageLoader.shared.loadImage(urlString: requestURL, mode: mode)
            await MainActor.run {
                guard requestURL == urlString else { return }
                if let loaded = loaded {
                    image = loaded
                } else {
                    loadFailed = true
                }
            }
        }
    }
}

// MARK: - 便捷构造器

extension PlatformAsyncImage {
    /// 神秘电影封面图 (带 UA/Referer 头)
    static func mysteryMovie(_ urlString: String) -> PlatformAsyncImage {
        PlatformAsyncImage(urlString: urlString, mode: .mysteryMovie)
    }

    /// 每日大乱斗/大赛封面图 (AES 解密)
    static func dailyBattle(_ urlString: String) -> PlatformAsyncImage {
        PlatformAsyncImage(urlString: urlString, mode: .dailyBattle)
    }

    /// 多源发现封面图（支持 Referer 防盗链）
    /// - Parameters:
    ///   - urlString: 图片 URL
    ///   - referer: 源站 Referer（如 "https://www.91panta.cn/"），nil 则不注入
    static func sourceCover(_ urlString: String, referer: String?, sslBypass: Bool = false, contentMode: ContentMode = .fill) -> PlatformAsyncImage {
        let finalURL: String
        if let ref = referer, !ref.isEmpty {
            // 使用 @key=value 格式与 parseHeaderSuffix 匹配
            let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
            let normalizedRef = ref.hasSuffix("/") ? ref : "\(ref)/"
            let sslFlag = sslBypass ? "@X-VBox-SSL-Bypass=1" : ""
            finalURL = "\(urlString)@User-Agent=\(ua)@Referer=\(normalizedRef)\(sslFlag)"
        } else {
            finalURL = urlString
        }
        return PlatformAsyncImage(urlString: finalURL, mode: .mysteryMovie, contentMode: contentMode)
    }
}

// MARK: - PlatformImageLoader 缓存键扩展

extension PlatformImageLoader {
    static func makeCacheKey(_ urlString: String, mode: PlatformImageMode) -> String {
        let (cleanURL, headers) = PlatformImageLoader.parseHeaderSuffix(urlString)
        let headerKey = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(cleanURL)#\(mode)#\(headerKey)"
    }
}

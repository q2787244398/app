import SwiftUI
import UIKit
import Darwin

// MARK: - AppDelegate 用于控制屏幕方向
class VBoxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationHelper.currentOrientationMask
    }
}

@main
struct VBoxApp: App {
    @UIApplicationDelegateAdaptor(VBoxAppDelegate.self) var appDelegate

    init() {
        // 强制加载 AliyunPlayer 动态框架，使 NSClassFromString("AliPlayer") 在运行时可用
        loadAliyunPlayerIfNeeded()
        DoubanImageProxyServer.shared.start()
        RemuxProxyServer.shared.start()  // 转封装代理（PiP 用，端口 18081）
        // [优化7] 启动 Go HTTP/2 代理引擎（夸克播放加速）
        GoProxyManager.shared.start()
        // P1-01: 启动 Node 常驻系统（网盘解析引擎，端口 58080；不影响既有网盘）
        NodeRuntimeManager.shared.start()
        // 触发数据库初始化（建表 + 数据迁移）
        let _ = DatabaseManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// 运行时强制加载 AliyunPlayer 动态框架（解决 NSClassFromString 返回 nil 的问题）
/// 供内核选择面板在选中“阿里”前再次尝试加载
func loadAliyunPlayerIfNeeded() {
    guard NSClassFromString("AliPlayer") == nil else {
        print("[AliyunPlayer] ✅ AliPlayer 类已存在，无需加载")
        return
    }

    let frameworkName = "AliyunPlayer"
    let dependencyNames = ["alivcffmpeg", "AliyunMediaDownloader"]

    // 1) 先尝试预加载依赖框架（部分构建中 AliyunPlayer 依赖它们）
    for dep in dependencyNames {
        _ = loadFrameworkBinary(named: dep)
    }

    // 2) 尝试通过 Bundle(identifier:) 加载（Info.plist 中 CFBundleIdentifier 为 com.alibaba.AliyunPlayer.AliyunVodPlayerSDK）
    if let bundle = Bundle(identifier: "com.alibaba.AliyunPlayer.AliyunVodPlayerSDK"),
       !bundle.isLoaded {
        let loaded = bundle.load()
        print("[AliyunPlayer] Bundle(identifier:) load: \(loaded ? "成功" : "失败")")
    }

    // 3) 遍历所有已发现的 bundle，按名称匹配并加载
    let allBundles = Bundle.allBundles + Bundle.allFrameworks
    for bundle in allBundles {
        let name = bundle.bundleURL.lastPathComponent
        if name.contains("AliyunPlayer") || name.contains("AliyunVodPlayer") {
            if !bundle.isLoaded {
                let loaded = bundle.load()
                print("[AliyunPlayer] 发现 bundle \(name)，load: \(loaded ? "成功" : "失败")")
            }
        }
    }

    // 4) 兜底：使用 dlopen 强制加载 framework 二进制
    _ = loadFrameworkBinary(named: frameworkName)

    if NSClassFromString("AliPlayer") != nil {
        print("[AliyunPlayer] ✅ 运行时 AliPlayer 类已可用")
    } else {
        print("[AliyunPlayer] ❌ 运行时仍无法找到 AliPlayer 类")
    }
}

/// 尝试通过多种常见路径加载某个 framework 的可执行文件，返回是否成功
@discardableResult
private func loadFrameworkBinary(named name: String) -> Bool {
    let mainBundle = Bundle.main
    var candidates: [String] = []

    // iOS App Embed Frameworks 的标准路径
    candidates.append(mainBundle.bundlePath + "/Frameworks/\(name).framework/\(name)")
    // 部分打包方式会放在 app 根目录
    candidates.append(mainBundle.bundlePath + "/\(name).framework/\(name)")
    // 可执行文件相邻路径（针对 extension/app 嵌套场景）
    if let execPath = mainBundle.executableURL?.path {
        candidates.append((execPath as NSString).deletingLastPathComponent + "/Frameworks/\(name).framework/\(name)")
        candidates.append((execPath as NSString).deletingLastPathComponent + "/\(name).framework/\(name)")
    }
    // Frameworks 目录本身
    if let frameworksPath = mainBundle.privateFrameworksPath {
        candidates.append(frameworksPath + "/\(name).framework/\(name)")
    }

    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            if dlopen(path, RTLD_LAZY) != nil {
                print("[AliyunPlayer] dlopen 加载成功: \(path)")
                return true
            } else {
                let err = String(cString: dlerror())
                print("[AliyunPlayer] dlopen 失败: \(path) -> \(err)")
            }
        }
    }
    return false
}

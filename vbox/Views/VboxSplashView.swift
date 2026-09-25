//
//  VboxSplashView.swift
//  vbox-ios
//
//  启动页动画（常驻循环版）：Vbox 字母飞入聚合 + v2 swoosh 托底，
//  聚合完成后进入"呼吸缩放 + 上下浮动"的无限循环动画。
//  退出时机由外部控制：ContentView 监听 SplashGateMonitor.homeDataReady
//  （首页数据就绪）或 10 秒兜底定时器，负责淡出本视图。
//
//  素材已归一化：4 张字母 PNG 同一画布高（1010）、同一基线（860），
//  聚合后按参考图重叠装配（v9：box 三字母缩小 0.85 → 帧高 85pt、下移 12.7pt 墨迹底对齐基线，
//  V 保持 100pt 大一号，形成"V 大 box 小"的层级），
//  v2 的 3D swoosh 托底（画布 y=720、顺时针 4° 压平），整体 100pt 显示、
//  容器 -8° 上翘（右端上扬），swoosh 与字母基线平行，终态贴近参考 logo 原图。
//  适配 iOS 14+，SwiftUI
//

import SwiftUI

// MARK: - 字母飞入方向
enum LetterFlyDirection {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var offset: CGSize {
        let distance: CGFloat = 500
        switch self {
        case .topLeft:     return CGSize(width: -distance, height: -distance * 0.7)
        case .topRight:    return CGSize(width:  distance, height: -distance * 0.7)
        case .bottomLeft:  return CGSize(width: -distance, height:  distance * 0.7)
        case .bottomRight: return CGSize(width:  distance, height:  distance * 0.7)
        }
    }

    var rotation: Double {
        switch self {
        case .topLeft:     return -30
        case .topRight:    return  30
        case .bottomLeft:  return  25
        case .bottomRight: return -25
        }
    }
}

// MARK: - 单个字母配置
struct LetterImageConfig: Identifiable {
    let id = UUID()
    let imageName: String       // 资源图片名（Assets.xcassets 中）
    let direction: LetterFlyDirection
    let delay: Double
    let width: CGFloat          // 显示宽度（按归一化画布等比换算）
    let xOffset: CGFloat        // 聚合后的水平位置（重叠聚拢，来自最终 pos）
    let yOffset: CGFloat        // 聚合后的垂直位置（box 缩小后下移，墨迹底对齐基线）
}

// MARK: - Vbox Splash View
struct VboxSplashView: View {
    // ---- 归一化布局常量（画布高 1010、基线 860，V 显示高 100pt，S=100/1010）----
    private let logoHeight: CGFloat = 100        // V 统一显示高度
    private let compWidth: CGFloat = 182.2       // 聚拢后字标总宽（v9：box 0.85 后帧宽，x 右缘 115.9+66.3）
    private let logoTilt: Double = -8            // 整体 8° 右端上翘（对应参考图趋势；SwiftUI 负=逆时针）

    // v2 swoosh：宽 182.2pt，相对字标左上 (0, 72.3)，
    // 顺时针 4° 压平（容器 -8° 上翘下，swoosh 与字母基线平行，贴近参考图"平缓托底"）
    private let swooshWidth: CGFloat = 182.2
    private let swooshTilt: Double = 4
    private let swooshOffset = CGPoint(x: 0, y: 72.3)

    // 字母配置（v9：box 缩小 0.85 → 宽×0.85、帧高 85pt、yOffset +12.7 墨迹底对齐基线）
    // V = 左上飞入，b = 左下飞入，o = 右上飞入，x = 右下飞入
    private let letters: [LetterImageConfig] = [
        LetterImageConfig(imageName: "splash_letter_V", direction: .topLeft,     delay: 0.00, width: 81.0, xOffset:   0.0, yOffset:  0.0),
        LetterImageConfig(imageName: "splash_letter_b", direction: .bottomLeft,  delay: 0.08, width: 43.6, xOffset:  50.5, yOffset: 12.7),
        LetterImageConfig(imageName: "splash_letter_o", direction: .topRight,    delay: 0.14, width: 37.8, xOffset:  89.1, yOffset: 12.7),
        LetterImageConfig(imageName: "splash_letter_x", direction: .bottomRight, delay: 0.20, width: 66.3, xOffset: 115.9, yOffset: 12.7),
    ]

    // ---- 循环动画参数 ----
    private let breathingCycle: Double = 2.4     // 呼吸缩放周期（秒）
    private let floatCycle: Double = 3.0         // 上下浮动周期（秒）
    private let breathScale: CGFloat = 1.05     // 呼吸最大缩放
    private let floatAmplitude: CGFloat = 6      // 浮动最大位移（pt）

    // ---- 深浅模式自适应 ----
    // 启动页作为 ContentView 覆盖层，自动继承其 preferredColorScheme：
    // 跟随手机外观开 → 跟随系统深浅；手动深色/liquid → 深色；手动浅色 → 浅色
    @Environment(\.colorScheme) private var colorScheme

    private var backgroundColors: [Color] {
        switch colorScheme {
        case .light:
            return [
                Color(red: 0.97, green: 0.97, blue: 0.98),
                Color(red: 0.90, green: 0.90, blue: 0.93)
            ]
        default:
            return [
                Color(red: 0.12, green: 0.12, blue: 0.16),
                Color(red: 0.05, green: 0.05, blue: 0.07)
            ]
        }
    }

    private var subtitleColor: Color {
        colorScheme == .light ? Color.black.opacity(0.18) : Color.white.opacity(0.25)
    }

    // 软件版本号：直接读 Info.plist，随构建版本自动变化（CI 递增后无需改代码）
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // ---- 动画状态 ----
    @State private var isAnimating = false       // 第一阶段：飞入聚合
    @State private var showGlow = false          // 聚合完成后发光
    @State private var breathing = false         // 第二阶段：呼吸循环
    @State private var floating = false          // 第二阶段：浮动循环

    var body: some View {
        ZStack {
            // 深浅自适应渐变背景（跟随软件/系统外观）
            LinearGradient(
                gradient: Gradient(colors: backgroundColors),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Logo：swoosh 托底 + 字母重叠聚拢 + 整体倾角 + 呼吸浮动循环
            ZStack(alignment: .topLeading) {
                // swoosh（最底层，v2 素材，从 V 底部延伸到 x 右侧）
                Image("splash_swoosh")
                    .resizable()
                    .scaledToFit()
                    .frame(width: swooshWidth)
                    .rotationEffect(.degrees(swooshTilt))     // 绕自身中心顺时针 4°
                    .offset(x: swooshOffset.x, y: swooshOffset.y)
                    .offset(x: isAnimating ? 0 : -160)        // 从左向右扫入
                    .opacity(isAnimating ? 1 : 0)
                    .animation(
                        .easeOut(duration: 0.55).delay(0.30),
                        value: isAnimating
                    )

                // 字母（重叠聚拢）
                ForEach(letters) { letter in
                    ZStack {
                        // 发光层（聚合完成后常亮）
                        Image(letter.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: letter.width)
                            .blur(radius: showGlow ? 14 : 0)
                            .opacity(showGlow ? 0.5 : 0)
                            .animation(.easeOut(duration: 0.4), value: showGlow)

                        // 主字母
                        Image(letter.imageName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: letter.width)
                    }
                    .offset(x: letter.xOffset, y: letter.yOffset)       // 聚合后的最终位置
                    .offset(isAnimating ? .zero : letter.direction.offset)
                    .rotationEffect(.degrees(isAnimating ? 0 : letter.direction.rotation))
                    .opacity(isAnimating ? 1 : 0)
                    .animation(
                        .spring(response: 0.75, dampingFraction: 0.62, blendDuration: 0.2)
                        .delay(letter.delay),
                        value: isAnimating
                    )
                }
            }
            .frame(width: compWidth, height: logoHeight, alignment: .topLeading)
            .rotationEffect(.degrees(logoTilt))
            // 呼吸缩放（无限循环）
            .scaleEffect(breathing ? breathScale : 1.0)
            .animation(
                .easeInOut(duration: breathingCycle).repeatForever(autoreverses: true),
                value: breathing
            )
            // 上下浮动（无限循环）
            .offset(y: floating ? -floatAmplitude : floatAmplitude)
            .animation(
                .easeInOut(duration: floatCycle).repeatForever(autoreverses: true),
                value: floating
            )

            // 底部小字 + 软件版本号（聚合完成后一起淡入）
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Text("愿你每一次观影都能释放现有压力")
                    Text("vbox聚合观影软件由Ai开发而来")
                }
                .font(.system(size: 12, weight: .regular))
                .tracking(2)
                .foregroundColor(subtitleColor)
                .multilineTextAlignment(.center)

                // 版本号：读取 Info.plist 的 CFBundleShortVersionString，
                // 构建时 CI 递增版本后自动跟随，无需手改。取不到时不显示。
                if !Self.appVersion.isEmpty {
                    Text(Self.appVersion)
                        .font(.system(size: 11, weight: .regular))
                        .tracking(1)
                        .foregroundColor(subtitleColor.opacity(0.75))
                        .padding(.top, 14)
                }
            }
            .padding(.bottom, 80)
            .opacity(showGlow ? 1 : 0)
            .animation(.easeIn(duration: 0.4).delay(0.5), value: showGlow)
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        // 第 1 阶段：字母飞入聚合 + swoosh 扫入（一次性）
        isAnimating = true

        // 第 2 阶段：聚合完成后发光（常亮）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.4)) {
                showGlow = true
            }
        }

        // 第 3 阶段：进入无限循环（呼吸缩放 + 上下浮动）
        // 注意：状态切换不能再用 withAnimation 包裹 —— 视图上已挂
        // .animation(_:value:) + repeatForever 修饰符，双驱动在部分 iOS 版本
        // 会让 repeatForever 只播放一次不循环；这里只切状态，动画交给修饰符。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            breathing = true
            floating = true
        }
    }
}

// MARK: - 使用示例（退出由 ContentView 数据门控/兜底定时器控制）
/*
 // 1. 把 5 张 PNG 拖进 Assets.xcassets，命名为：
 //    splash_letter_V / splash_letter_b / splash_letter_o / splash_letter_x / splash_swoosh
 //    素材要求：四张字母 PNG 同画布高（1010）、同基线（860），直接按本文件布局即可对齐；
 //    splash_swoosh 必须使用 v2 的 swoosh（2446×469 的那张），替换旧素材。
 //
 // 2. 在 ContentView 中作为全屏覆盖层常驻，监听 SplashGateMonitor.shared.homeDataReady：
 //    .overlay {
 //        if showSplash {
 //            VboxSplashView()
 //                .transition(.opacity)
 //                .zIndex(30)
 //        }
 //    }
 //    数据就绪或 10 秒兜底后淡出。
 */

// MARK: - 预览
struct VboxSplashView_Previews: PreviewProvider {
    static var previews: some View {
        VboxSplashView()
    }
}

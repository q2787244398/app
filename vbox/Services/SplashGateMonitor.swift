//
//  SplashGateMonitor.swift
//  vbox-ios
//
//  启动页数据门控：首页数据就绪信号（进程内单例）。
//  HomeView 在确认首页有可展示数据时调用 markHomeReady()；
//  ContentView 监听 homeDataReady，数据就绪即淡出启动页进入首页；
//  若 10 秒内未就绪，由 ContentView 的兜底定时器强制退出启动页。
//

import Foundation
import Combine

final class SplashGateMonitor: ObservableObject {
    static let shared = SplashGateMonitor()
    @Published private(set) var homeDataReady = false
    private init() {}

    /// 首页已有可展示数据时调用（幂等，重复调用无副作用）
    func markHomeReady() {
        guard !homeDataReady else { return }
        homeDataReady = true
    }
}

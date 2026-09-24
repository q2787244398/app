//
//  BiliQrLoginView.swift
//  vbox
//
//  哔哩哔哩 原生扫码授权 — 整屏 Sheet 样式
//  样式对齐「阿里云盘原生扫码」(NativeCloudQRLoginView)：
//  标题 + 大二维码卡片 + 状态卡 + 提示卡 + 生成/重新生成按钮。
//
//  ★ 已移除旧的 DisclosureGroup 内联折叠样式。
//

import SwiftUI

struct BiliQrLoginView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = BiliAuthManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    Text("哔哩哔哩 原生扫码授权")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    qrCard
                    statusCard
                    tipCard

                    Button {
                        Task { await auth.startQrLogin() }
                    } label: {
                        Text(auth.qrLoginState.isPolling ? "重新生成二维码" : "生成二维码")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.pink)
                            .cornerRadius(12)
                    }
                    .disabled(auth.qrLoginState == .loading)
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("扫码授权")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(.pink)
                }
                if auth.checkLoginStatus() {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("退出登录") {
                            Task { await auth.clearCookie() }
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .onDisappear { auth.stopPolling() }
        }
    }

    // MARK: - 二维码卡片

    private var qrCard: some View {
        VStack(spacing: 12) {
            if let qrImage = auth.qrCodeImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            } else if auth.qrLoginState == .loading {
                ProgressView()
                    .frame(width: 220, height: 220)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 88))
                    .foregroundColor(.gray.opacity(0.45))
                    .frame(width: 220, height: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.gray.opacity(0.05)))
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusDot
                Text(auth.qrLoginState.displayText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                if auth.qrLoginState == .success {
                    Text("已登录")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(8)
                }
            }
            if !auth.message.isEmpty, auth.qrLoginState.isPolling || auth.qrLoginState == .success {
                Text(auth.message)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            if case .error(let msg) = auth.qrLoginState {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.05)))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch auth.qrLoginState {
        case .idle: return .gray
        case .loading: return .orange
        case .waitingScan: return .blue
        case .scanned: return .yellow
        case .saving: return .orange
        case .success: return .green
        case .error: return .red
        }
    }

    // MARK: - 提示卡片

    private var tipCard: some View {
        Text("请使用哔哩哔哩 App 扫码并确认。扫码成功后自动回收 Cookie 到授权中心，用于「哔哩|影视」资源播放。")
            .font(.system(size: 12))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.pink.opacity(0.08)))
    }
}

//
//  BiliQrLoginView.swift
//  vbox
//
//  B站扫码登录 UI — 授权中心折叠区
//  照搬 AliyunPgQrLoginView 的结构，改 API 和文案
//

import SwiftUI

struct BiliQrLoginView: View {

    @StateObject private var authManager = BiliAuthManager.shared
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            BiliQrCodeSection()
                .padding(.top, 8)
        } label: {
            HStack {
                Image(systemName: "tv.fill")
                    .foregroundColor(.pink)
                Text("B站扫码登录")
                    .fontWeight(.medium)
                Spacer()
                if authManager.qrLoginState == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                Text("bilibili")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 扫码区

private struct BiliQrCodeSection: View {

    @StateObject private var authManager = BiliAuthManager.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(authManager.qrLoginState.displayText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if authManager.qrLoginState == .success {
                    Text("已登录")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                }
            }

            HStack(spacing: 12) {
                if authManager.qrLoginState == .waitingScan ||
                   authManager.qrLoginState == .scanned {
                    Button(action: { authManager.cancel() }) {
                        Text("取消")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                } else {
                    Button {
                        Task { await authManager.startQrLogin() }
                    } label: {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                            Text("B站扫码登录")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.pink)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }
            }

            // 二维码展示
            if authManager.qrLoginState == .waitingScan ||
               authManager.qrLoginState == .scanned {
                if let qrImage = authManager.qrCodeImage {
                    VStack(spacing: 8) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .cornerRadius(8)
                            .shadow(radius: 4)
                        Text("用 B站 App 扫描二维码")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }

            if authManager.qrLoginState == .loading {
                ProgressView().scaleEffect(1.2)
            }

            // 错误提示
            if case .error(let msg) = authManager.qrLoginState {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(8)
            }

            // 已登录时显示清除按钮
            if authManager.qrLoginState == .success {
                Button(role: .destructive) {
                    Task { await authManager.clearCookie() }
                } label: {
                    Text("退出 B站登录")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.08))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch authManager.qrLoginState {
        case .idle: return .gray
        case .loading: return .orange
        case .waitingScan: return .blue
        case .scanned: return .yellow
        case .success: return .green
        case .error: return .red
        }
    }
}

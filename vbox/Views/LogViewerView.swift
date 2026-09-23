//
//  LogViewerView.swift
//  vbox
//
//  日志查看器页面
//  - 实时滚动显示
//  - 按级别/模块筛选
//  - 关键词搜索
//  - 导出 / 清空
//

import SwiftUI
import UniformTypeIdentifiers

struct LogViewerView: View {
    @StateObject private var logStore = AppLogStore.shared
    @Environment(\.dismiss) private var dismiss
    
    // 筛选状态
    @State private var selectedCategory: LogCategory? = nil
    @State private var selectedLevel: LogLevel = .verbose  // 默认显示所有 (>= verbose)
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var showExportSheet = false
    @State private var exportFileURL: URL?
    @State private var showClearConfirm = false
    
    // 滚动控制
    @State private var scrollProxy: ScrollViewProxy?
    @State private var lastEntryID: String?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 崩溃提示条
                if logStore.lastRunCrashed {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("上次运行发生异常退出")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                        Spacer()
                        Button("知道了") {
                            // 清除提示
                            logStore.lastRunCrashed = false
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.1))
                }
                
                // 筛选栏
                filterBar
                
                // 日志列表
                logList
                
                // 底部操作栏
                bottomBar
            }
            .navigationBarTitle("日志记录", displayMode: .inline)
            .navigationBarItems(
                leading: Button("关闭") { dismiss() },
                trailing: Menu {
                    Button {
                        showExportSheet = true
                        exportAll()
                    } label: {
                        Label("导出全部日志", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        showExportSheet = true
                        exportFiltered()
                    } label: {
                        Label("导出筛选结果", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("清空日志", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                }
            )
        }
        .sheet(isPresented: $showExportSheet) {
            if let url = exportFileURL {
                ActivityView(activityItems: [url])
            }
        }
        .alert("确认清空日志？", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                logStore.clearMemory()
            }
        } message: {
            Text("将清除内存中的日志，磁盘上的日志文件保留 3 天。")
        }
    }
    
    // MARK: - 筛选栏
    
    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // 模块筛选
                Menu {
                    Button("全部") { selectedCategory = nil }
                    ForEach(LogCategory.allCases, id: \.self) { cat in
                        Button(cat.displayName) { selectedCategory = cat }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedCategory?.displayName ?? "全部模块")
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)
                }
                
                // 级别筛选
                Menu {
                    ForEach([LogLevel.verbose, .info, .warn, .error], id: \.self) { level in
                        Button(level.displayName) { selectedLevel = level }
                    }
                } label: {
                    HStack(spacing: 4) {
                        levelIcon(selectedLevel)
                        Text(selectedLevel.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(8)
                }
                
                // 搜索框
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    TextField("搜索", text: $searchText)
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(8)
            }
            
            // 统计
            HStack {
                Text("共 \(filteredEntries.count) 条")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.7)
                    .frame(width: 40, height: 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.gray.opacity(0.2)),
            alignment: .bottom
        )
    }
    
    // MARK: - 日志列表
    
    private var filteredEntries: [LogEntry] {
        logStore.filterEntries(
            level: selectedLevel,
            category: selectedCategory,
            keyword: searchText.isEmpty ? nil : searchText
        )
    }
    
    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries, id: \.self) { entry in
                LogRowView(entry: entry)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .background(Color(.systemGroupedBackground))
            .onChange(of: filteredEntries.count) { _ in
                if autoScroll, let last = filteredEntries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                self.scrollProxy = proxy
                // 初始滚动到底部
                if autoScroll, let last = filteredEntries.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
    
    // MARK: - 底部操作栏
    
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                // 滚到底部
                if let last = filteredEntries.last {
                    scrollProxy?.scrollTo(last, anchor: .bottom)
                }
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
            }
            .frame(width: 40, height: 40)
            
            Spacer()
            
            Button {
                showExportSheet = true
                exportFiltered()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                    Text("导出")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue)
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.gray.opacity(0.2)),
            alignment: .top
        )
    }
    
    // MARK: - 辅助
    
    private func levelIcon(_ level: LogLevel) -> some View {
        Text(level.icon)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(levelColor(level))
    }
    
    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .verbose: return .gray
        case .info:    return .blue
        case .warn:    return .orange
        case .error:   return .red
        }
    }
    
    private func exportAll() {
        exportFileURL = logStore.exportAll()
        if exportFileURL == nil {
            // 暂无日志
        }
    }
    
    private func exportFiltered() {
        exportFileURL = logStore.exportFiltered(
            level: selectedLevel,
            category: selectedCategory,
            keyword: searchText.isEmpty ? nil : searchText
        )
    }
}

// MARK: - 日志行

struct LogRowView: View {
    let entry: LogEntry
    @State private var expanded = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 级别图标
            Text(entry.level.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(levelColor)
                .frame(width: 16)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                // 时间 + 模块
                HStack(spacing: 6) {
                    Text(entry.timeString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                    
                    Text(entry.category.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(categoryColor.opacity(0.8))
                        .cornerRadius(3)
                    
                    if entry.thread != "main" {
                        Text(entry.thread)
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                    }
                }
                
                // 消息
                Text(entry.message)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        }
    }
    
    private var levelColor: Color {
        switch entry.level {
        case .verbose: return .gray
        case .info:    return .blue
        case .warn:    return .orange
        case .error:   return .red
        }
    }
    
    private var categoryColor: Color {
        switch entry.category {
        case .app:      return Color(hex: "6B7280")
        case .spider:   return Color(hex: "8B5CF6")
        case .player:   return Color(hex: "EF4444")
        case .cloud:    return Color(hex: "3B82F6")
        case .proxy:    return Color(hex: "10B981")
        case .network:  return Color(hex: "F59E0B")
        case .db:       return Color(hex: "6366F1")
        case .download: return Color(hex: "EC4899")
        case .welfare:  return Color(hex: "F97316")
        case .node:     return Color(hex: "14B8A6")
        case .music:    return Color(hex: "EC4899")
        }
    }
}

// MARK: - UIActivityViewController 封装

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

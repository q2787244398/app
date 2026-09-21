import SwiftUI

// MARK: - 源选择弹窗（长条竖排，网盘在前）

struct SourcePickerSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var selectedSource: SourceDisplayItem?
    let sources: [SourceDisplayItem]
    let onSelect: (SourceDisplayItem) -> Void

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var filteredSources: [SourceDisplayItem] {
        if searchText.isEmpty { return sources }
        return sources.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var groupedSources: [(String, [SourceDisplayItem])] {
        let groups = Dictionary(grouping: filteredSources) { $0.category.displayName }
        let order = ["网盘", "API", "站源", "JS", "论坛"]
        return order.compactMap { key in
            if let items = groups[key], !items.isEmpty {
                return (key, items)
            }
            return nil
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                    TextField("搜索源...", text: $searchText)
                        .font(.system(size: 15))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(uiColor: .systemGray6))
                )
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 源列表
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(groupedSources, id: \.0) { group in
                            Section {
                                ForEach(group.1) { source in
                                    SourceRow(
                                        source: source,
                                        isSelected: selectedSource?.id == source.id
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(source)
                                        dismiss()
                                    }

                                    if source.id != group.1.last?.id {
                                        Divider()
                                            .padding(.leading, 56)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.0)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(group.1.count) 个")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(uiColor: .systemGroupedBackground))
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemGroupedBackground))
        }
    }
}

// MARK: - 源行

private struct SourceRow: View {
    let source: SourceDisplayItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // 类型图标
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: categoryIcon)
                    .font(.system(size: 14))
                    .foregroundColor(categoryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(source.category.displayName)
                        .font(.system(size: 11))
                        .foregroundColor(categoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(categoryColor.opacity(0.12))
                        )

                    if !source.supportsHome {
                        Text("仅搜索")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            if !source.supportsHome {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(source.supportsHome ? 1.0 : 0.6)
    }

    private var categoryColor: Color {
        switch source.category {
        case .cloudCMS, .cloudSPA: return Color(hex: "007AFF")
        case .cloudForum: return Color(hex: "FF9500")
        case .api: return Color(hex: "34C759")
        case .jsSpider: return Color(hex: "AF52DE")
        case .zhanyuan: return Color(hex: "FF3B30")
        case .music: return Color(hex: "FF2D92")
        }
    }

    private var categoryIcon: String {
        switch source.category {
        case .cloudCMS, .cloudSPA: return "icloud.fill"
        case .cloudForum: return "text.bubble.fill"
        case .api: return "antenna.radiowaves.left.and.right"
        case .jsSpider: return "gearshape.2.fill"
        case .zhanyuan: return "link"
        case .music: return "music.note"
        }
    }
}
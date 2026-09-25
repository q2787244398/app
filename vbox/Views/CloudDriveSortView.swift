import SwiftUI

struct CloudDriveSortPopup: View {
    @ObservedObject private var sortManager = CloudDriveSortManager.shared
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("网盘排序")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("长按拖动调整详情页网盘显示顺序")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                List {
                    ForEach(sortManager.sortableOrder, id: \.self) { type in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                            Image(systemName: icon(for: type))
                                .font(.system(size: 15))
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            Text(type.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .onMove(perform: sortManager.move)
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(sortManager.sortableOrder.count) * 44, 340))

                HStack {
                    Button("恢复默认") {
                        sortManager.resetToDefault()
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)

                    Spacer()

                    Button("完成") {
                        onClose()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(hex: "E11D48"))
                    )
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
            )
            .padding(.horizontal, 24)
        }
    }

    private func icon(for type: CloudDriveManager.DriveType) -> String {
        switch type {
        case .ali: return "icloud"
        case .quark: return "link.circle"
        case .baidu: return "link"
        case .one15: return "link.icloud"
        case .uc: return "paperplane"
        case .pan123: return "externaldrive"
        case .pan139: return "tray.full"
        case .pan189: return "cloud"
        case .xunlei: return "bolt"
        case .guangya: return "g.circle"
        case .woniu4k: return "s.circle"
        case .bilibili: return "tv.fill"
        case .quarkNode: return "q.square"
        case .ucNode: return "u.square"
        }
    }
}

import SwiftUI

final class CloudDriveSortManager: ObservableObject {
    static let shared = CloudDriveSortManager()

    private let defaults = UserDefaults.standard
    private let storageKey = "cloud_drive_sort_order_v1"

    let defaultOrder: [CloudDriveManager.DriveType] = [
        .quark, .uc, .baidu, .ali, .one15, .pan123, .pan139, .pan189
    ]

    @Published private(set) var order: [CloudDriveManager.DriveType] = []

    private init() {
        order = normalizedOrder()
    }

    var displayOrder: [CloudDriveManager.DriveType] {
        orderedDriveTypes(from: CloudDriveManager.DriveType.allCases)
    }

    /// 弹窗可排序列表：排除派生的「夸克Node」与「UC网盘Node」。
    /// 二者在详情页的位置恒定跟随其原生盘（见 PlayerViews.sortIndex），
    /// 不参与独立排序，避免弹窗出现“拖了不生效”的无效行；displayOrder 保持不变。
    var sortableOrder: [CloudDriveManager.DriveType] {
        displayOrder.filter { $0 != .quarkNode && $0 != .ucNode }
    }

    func orderedDriveTypes(from available: [CloudDriveManager.DriveType]) -> [CloudDriveManager.DriveType] {
        let availableSet = Set(available)
        let ordered = order.filter { availableSet.contains($0) }
        let remaining = available.filter { !ordered.contains($0) }
        return ordered + remaining
    }

    func orderIndex(forDriveName driveName: String) -> Int {
        guard let type = driveType(forDisplayName: driveName) else {
            return Int.max
        }
        return displayOrder.firstIndex(of: type) ?? Int.max - 1
    }

    func move(from source: IndexSet, to destination: Int) {
        // 与弹窗展示的 sortableOrder 保持一致，避免与 displayOrder 索引错位
        var current = sortableOrder
        current.move(fromOffsets: source, toOffset: destination)
        save(current)
    }

    func resetToDefault() {
        save(defaultOrder)
    }

    func driveType(forDisplayName name: String) -> CloudDriveManager.DriveType? {
        CloudDriveManager.DriveType.allCases.first { $0.displayName == name }
    }

    private func normalizedOrder() -> [CloudDriveManager.DriveType] {
        let saved = defaults.stringArray(forKey: storageKey) ?? []
        let savedTypes = saved.compactMap { CloudDriveManager.DriveType(rawValue: $0) }
        let all = CloudDriveManager.DriveType.allCases
        let base = savedTypes.isEmpty ? defaultOrder : savedTypes
        let filtered = base.filter { all.contains($0) }
        let appended = all.filter { !filtered.contains($0) }
        return filtered + appended
    }

    private func save(_ types: [CloudDriveManager.DriveType]) {
        let normalized = normalize(types)
        order = normalized
        defaults.set(normalized.map(\.rawValue), forKey: storageKey)
    }

    private func normalize(_ types: [CloudDriveManager.DriveType]) -> [CloudDriveManager.DriveType] {
        var seen = Set<CloudDriveManager.DriveType>()
        let unique = types.filter { seen.insert($0).inserted }
        let missing = CloudDriveManager.DriveType.allCases.filter { !seen.contains($0) }
        return unique + missing
    }
}

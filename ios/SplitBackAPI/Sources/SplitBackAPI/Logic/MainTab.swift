import Foundation

/// The three reorderable main pages (Settings is pinned separately, always last). The order is stored as a
/// comma-joined `rawValue` string in `@AppStorage("tabOrder")` and synced via the preferences blob.
enum MainTab: String, CaseIterable, Identifiable {
    case accounts, splits, goals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "Accounts"
        case .splits: return "Splits"
        case .goals: return "Goals"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "building.columns.fill"
        case .splits: return "person.2.fill"
        case .goals: return "target"
        }
    }

    /// Parse a stored comma-joined order into tabs: keep valid ids in order, append any missing tabs
    /// (forward-compat if a tab is added), and drop duplicates. Always returns all `allCases` exactly once.
    static func parse(_ raw: String) -> [MainTab] {
        var order = raw.split(separator: ",").compactMap { MainTab(rawValue: String($0)) }
        for tab in allCases where !order.contains(tab) { order.append(tab) }
        var seen = Set<MainTab>()
        return order.filter { seen.insert($0).inserted }
    }

    /// The canonical comma-joined string for a tab order.
    static func serialize(_ order: [MainTab]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}

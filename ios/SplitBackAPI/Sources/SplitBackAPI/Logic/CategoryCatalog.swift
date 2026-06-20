import Foundation

/// In-memory `name → SF Symbol` cache so the free `categorySymbol(_:)` can honor a category's
/// user-chosen icon without every call site holding the synced `Category` list. Rebuilt by
/// `CategoryRepository` whenever categories reconcile/change. Main-thread only.
@MainActor
final class CategoryCatalog {
    static let shared = CategoryCatalog()
    private var icons: [String: String] = [:]

    func update(_ categories: [SpendCategory]) {
        icons = Dictionary(
            categories.compactMap { c in c.icon.flatMap { $0.isEmpty ? nil : (c.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func icon(for name: String) -> String? { icons[name] }
}

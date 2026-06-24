import Foundation
import SwiftData

/// The editable canonical category taxonomy. Categories are local-authoritative (per user) and backed up
/// to the per-owner preferences blob via `CategorySync`, so mutations write SwiftData and then push a
/// best-effort backup. After any change it refreshes `CategoryCatalog` so `categorySymbol` honors custom
/// icons. (Built-ins are seeded by `CategorySeed`; restore happens via `CategorySync.pull`.)
@MainActor
struct CategoryRepository {
    let client: Client
    let context: ModelContext

    @discardableResult
    func create(name: String, icon: String?) async throws -> UUID {
        let position = (try context.fetch(FetchDescriptor<SpendCategory>()).map(\.position).max() ?? -1) + 1
        let category = SpendCategory(id: UUID(), name: name, builtin: false, position: position, icon: icon)
        context.insert(category)
        try save()
        await CategorySync.pushBestEffort(context, client: client)
        return category.id
    }

    /// Rename and/or set the icon (nil fields are left unchanged).
    func update(id: UUID, name: String? = nil, icon: String? = nil) async throws {
        guard let category = try context.fetch(
            FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        if let name { category.name = name }
        if let icon { category.icon = icon }
        try save()
        await CategorySync.pushBestEffort(context, client: client)
    }

    func delete(id: UUID) async throws {
        guard let category = try context.fetch(
            FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        context.delete(category)
        try save()
        await CategorySync.pushBestEffort(context, client: client)
    }

    /// Persist and rebuild the icon cache `categorySymbol` reads.
    private func save() throws {
        try context.save()
        CategoryCatalog.shared.update(try context.fetch(FetchDescriptor<SpendCategory>()))
    }
}

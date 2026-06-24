import Foundation
import SwiftData

/// The raw-Plaid → canonical category map. Local-authoritative (per user): the map is computed on-device
/// (see `CategoryMapper`) or chosen manually, written to SwiftData, then backed up to the per-owner
/// preferences blob via `CategorySync`.
@MainActor
struct CategoryMapRepository {
    let client: Client
    let context: ModelContext

    /// Upserts one mapping by raw label (`source` is "manual" or "ondevice") and pushes a best-effort backup.
    func set(raw: String, canonical: String, source: String) async throws {
        let now = Date()
        if let existing = try context.fetch(
            FetchDescriptor<CategoryMap>(predicate: #Predicate { $0.rawCategory == raw })
        ).first {
            existing.canonicalCategory = canonical
            existing.source = source
            existing.updatedAt = now
        } else {
            context.insert(CategoryMap(
                id: UUID(), rawCategory: raw, canonicalCategory: canonical, source: source,
                createdAt: now, updatedAt: now))
        }
        try context.save()
        await CategorySync.pushBestEffort(context, client: client)
    }
}

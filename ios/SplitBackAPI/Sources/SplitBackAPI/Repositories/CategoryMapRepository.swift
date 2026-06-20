import Foundation
import SwiftData

/// Reads/writes the raw-Plaid → canonical category map. The map is computed on-device (see
/// `CategoryMapper`) or chosen manually, then synced; this reconciles it into SwiftData.
@MainActor
struct CategoryMapRepository {
    let client: Client
    let context: ModelContext

    func refresh() async throws {
        let responses = try await client.list_category_map_category_map_get().ok.body.json
        try upsert(responses)
        let keep = Set(responses.map(\.raw_category))
        for local in try context.fetch(FetchDescriptor<CategoryMap>())
        where !keep.contains(local.rawCategory) {
            context.delete(local)
        }
        try context.save()
    }

    /// Stores one mapping (`source` is "manual" or "ondevice") and caches the response.
    func set(raw: String, canonical: String, source: String) async throws {
        let output = try await client.upsert_category_map_category_map_put(
            body: .json(Mapping.categoryMapUpsert(raw: raw, canonical: canonical, source: source))
        )
        switch output {
        case let .ok(ok): try upsert([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func upsert(_ responses: [Components.Schemas.CategoryMapResponse]) throws {
        for r in responses {
            let raw = r.raw_category
            if let existing = try context.fetch(
                FetchDescriptor<CategoryMap>(predicate: #Predicate { $0.rawCategory == raw })
            ).first {
                existing.canonicalCategory = r.canonical_category
                existing.source = r.source
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.categoryMap(r))
            }
        }
        try context.save()
    }
}

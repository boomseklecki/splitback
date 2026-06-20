import Foundation
import SwiftData

/// Reads/writes the editable canonical category taxonomy (`/categories`) and reconciles it into
/// SwiftData. After any change it refreshes `CategoryCatalog` so `categorySymbol` honors custom icons.
@MainActor
struct CategoryRepository {
    let client: Client
    let context: ModelContext

    func refresh() async throws {
        let responses = try await client.list_categories_categories_get().ok.body.json
        try upsert(responses)
        let keep = Set(try responses.map { try Mapping.uuid($0.id, field: "Category.id") })
        for local in try context.fetch(FetchDescriptor<SpendCategory>()) where !keep.contains(local.id) {
            context.delete(local)
        }
        try save()
    }

    @discardableResult
    func create(name: String, icon: String?) async throws -> UUID {
        let output = try await client.create_category_categories_post(body: .json(.init(name: name, icon: icon)))
        switch output {
        case let .created(created):
            let r = try created.body.json
            try upsert([r])
            return try Mapping.uuid(r.id, field: "Category.id")
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Rename and/or set the icon (nil fields are left unchanged server-side).
    func update(id: UUID, name: String? = nil, icon: String? = nil) async throws {
        let output = try await client.update_category_categories__category_id__patch(
            path: .init(category_id: id.uuidString),
            body: .json(.init(name: name, icon: icon))
        )
        switch output {
        case let .ok(ok): try upsert([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func delete(id: UUID) async throws {
        let output = try await client.delete_category_categories__category_id__delete(
            path: .init(category_id: id.uuidString)
        )
        switch output {
        case .noContent:
            if let local = try context.fetch(
                FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
            ).first {
                context.delete(local)
                try save()
            }
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func upsert(_ responses: [Components.Schemas.CategoryResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Category.id")
            if let existing = try context.fetch(
                FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.name = r.name
                existing.builtin = r.builtin
                existing.position = r.position
                existing.icon = r.icon
            } else {
                context.insert(try Mapping.category(r))
            }
        }
        try save()
    }

    /// Persist and rebuild the icon cache `categorySymbol` reads.
    private func save() throws {
        try context.save()
        CategoryCatalog.shared.update(try context.fetch(FetchDescriptor<SpendCategory>()))
    }
}

import Foundation
import SwiftData

/// Reads expenses (with splits/items/receipts) from the backend and reconciles them into SwiftData.
/// Because the server replaces splits/items wholesale, an existing expense is deleted (cascading its
/// children) and re-inserted from the fresh response, keeping the cache an exact mirror.
@MainActor
struct ExpenseRepository {
    let client: Client
    let context: ModelContext

    func refresh(
        groupId: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        includeArchived: Bool = false,
        limit: Int = 100,
        offset: Int = 0
    ) async throws {
        let output = try await client.list_expenses_expenses_get(query: .init(
            group_id: groupId?.uuidString,
            since: since.map(Mapping.dateOnlyFormatter.string(from:)),
            until: until.map(Mapping.dateOnlyFormatter.string(from:)),
            updated_since: updatedSince,
            include_archived: includeArchived,
            limit: limit,
            offset: offset
        ))
        try upsert(try output.ok.body.json)
    }

    // MARK: Writes

    /// Creates an expense. For a Splitwise group the backend pushes to Splitwise first (push-first),
    /// so a 422/409/502 here means the upstream push failed and nothing was stored.
    @discardableResult
    func create(_ draft: ExpenseDraft) async throws -> UUID {
        let output = try await client.create_expense_expenses_post(
            body: .json(Mapping.expenseCreate(draft))
        )
        switch output {
        case let .created(created):
            let response = try created.body.json
            try upsert([response])
            return try Mapping.uuid(response.id, field: "Expense.id")
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    func update(id: UUID, _ draft: ExpenseDraft) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(Mapping.expenseUpdate(draft))
        )
        switch output {
        case let .ok(ok):
            try upsert([try ok.body.json])
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Patches only the category (splits/items untouched server-side; pushes to Splitwise for
    /// linked expenses).
    func updateCategory(id: UUID, category: String) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(
                group_id: nil, description: nil, amount: nil, currency: nil,
                date: nil, category: category, transaction_id: nil, splits: nil, items: nil
            ))
        )
        switch output {
        case let .ok(ok):
            try upsert([try ok.body.json])
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Deletes an expense. `propagate` overrides the backend's default for Splitwise-linked rows
    /// (nil = let the backend decide by expense kind). The local row is removed on success.
    func delete(id: UUID, propagate: Bool? = nil) async throws {
        let output = try await client.delete_expense_expenses__expense_id__delete(
            path: .init(expense_id: id.uuidString),
            query: .init(propagate: propagate)
        )
        switch output {
        case .noContent:
            if let existing = try context.fetch(
                FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
            ).first {
                context.delete(existing)
                try context.save()
            }
        case let .unprocessableContent(error):
            throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _):
            throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Fetches a single expense's full detail and upserts it.
    func refreshDetail(id: UUID) async throws {
        let output = try await client.get_expense_expenses__expense_id__get(
            .init(path: .init(expense_id: id.uuidString))
        )
        try upsert([try output.ok.body.json])
    }

    /// Full fetch (incl. archived) that also deletes local expenses the server no longer has, so
    /// cached deletes (which `updated_since` doesn't report) are reconciled. Optionally group-scoped.
    func reconcileAll(groupId: UUID? = nil) async throws {
        let responses = try await client.list_expenses_expenses_get(query: .init(
            group_id: groupId?.uuidString, include_archived: true, limit: 500
        )).ok.body.json
        try upsert(responses)
        let keep = Set(try responses.map { try Mapping.uuid($0.id, field: "Expense.id") })
        let predicate: Predicate<Expense> = groupId.map { gid in
            #Predicate { $0.groupId == gid }
        } ?? #Predicate { _ in true }
        for local in try context.fetch(FetchDescriptor<Expense>(predicate: predicate))
        where !keep.contains(local.id) {
            context.delete(local)
        }
        try context.save()
    }

    func upsert(_ responses: [Components.Schemas.ExpenseResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Expense.id")
            if let existing = try context.fetch(
                FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
            ).first {
                context.delete(existing)
            }
        }
        try context.save()

        for r in responses {
            context.insert(try Mapping.expense(r))
        }
        try context.save()
    }
}

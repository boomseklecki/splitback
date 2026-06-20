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
    func updateCategory(id: UUID, category: String, updatedBy: String?) async throws {
        let output = try await client.update_expense_expenses__expense_id__patch(
            path: .init(expense_id: id.uuidString),
            body: .json(.init(
                group_id: nil, description: nil, amount: nil, currency: nil,
                date: nil, category: category, notes: nil, updated_by: updatedBy,
                transaction_id: nil, splits: nil, items: nil
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
            let mapped = try Mapping.expense(r)  // fresh, not yet inserted
            guard let existing = try context.fetch(
                FetchDescriptor<Expense>(predicate: #Predicate { $0.id == id })
            ).first else {
                context.insert(mapped)
                continue
            }
            // Update in place so the Expense (and its unchanged splits/items/receipts) keep their
            // identity — deleting + re-inserting invalidates objects live views still hold, which
            // crashes SwiftData ("access a full future backing data … with nil").
            existing.groupId = mapped.groupId
            existing.transactionId = mapped.transactionId
            existing.splitwiseExpenseId = mapped.splitwiseExpenseId
            existing.details = mapped.details
            existing.amount = mapped.amount
            existing.currency = mapped.currency
            existing.date = mapped.date
            existing.category = mapped.category
            existing.createdByIdentifier = mapped.createdByIdentifier
            existing.updatedByIdentifier = mapped.updatedByIdentifier
            existing.splitwiseCreatedAt = mapped.splitwiseCreatedAt
            existing.splitwiseUpdatedAt = mapped.splitwiseUpdatedAt
            existing.notes = mapped.notes
            existing.commentsCount = mapped.commentsCount
            existing.repeats = mapped.repeats
            existing.repeatInterval = mapped.repeatInterval
            existing.expenseBundleId = mapped.expenseBundleId
            existing.splitwiseReceiptURL = mapped.splitwiseReceiptURL
            existing.splitwiseRepayments = mapped.splitwiseRepayments
            existing.archivedAt = mapped.archivedAt
            existing.createdAt = mapped.createdAt
            existing.updatedAt = mapped.updatedAt
            reconcileSplits(existing, mapped.splits)
            reconcileItems(existing, mapped.items)
            reconcileReceipts(existing, mapped.receipts)
        }
        try context.save()
    }

    /// Reconcile a to-many relationship by `id`: update matched children in place, insert new ones,
    /// delete removed ones — so unchanged children aren't invalidated out from under live views.
    private func reconcileSplits(_ expense: Expense, _ incoming: [Split]) {
        var byId = Dictionary(expense.splits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Split] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.userIdentifier = new.userIdentifier
                current.paidShare = new.paidShare
                current.owedShare = new.owedShare
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.splits = result
    }

    private func reconcileItems(_ expense: Expense, _ incoming: [ExpenseItem]) {
        var byId = Dictionary(expense.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ExpenseItem] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.name = new.name
                current.quantity = new.quantity
                current.price = new.price
                current.category = new.category
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.items = result
    }

    private func reconcileReceipts(_ expense: Expense, _ incoming: [Receipt]) {
        var byId = Dictionary(expense.receipts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Receipt] = []
        for new in incoming {
            if let current = byId.removeValue(forKey: new.id) {
                current.bucket = new.bucket
                current.objectKey = new.objectKey
                current.contentType = new.contentType
                result.append(current)
            } else {
                context.insert(new)
                result.append(new)
            }
        }
        for removed in byId.values { context.delete(removed) }
        expense.receipts = result
    }
}

import Foundation
import SwiftData

/// Reads accounts and transactions from the backend and reconciles them into SwiftData.
/// Plaid-sourced transactions dedupe on `plaidTransactionId`; upsert is keyed on `id`.
@MainActor
struct AccountRepository {
    let client: Client
    let context: ModelContext

    func refreshAccounts() async throws {
        let output = try await client.list_accounts_accounts_get()
        let responses = try output.ok.body.json
        // Cache only the caller's OWN accounts; partner-shared accounts (`shared_by_identifier != nil`) are
        // never persisted, so they can't leak into net-worth/analytics @Query results. The "Shared with you"
        // section live-fetches them separately (see `sharedInAccounts()`).
        let own = responses.filter { $0.shared_by_identifier == nil }
        try upsertAccounts(own)
        // The owned list is the full (per-caller-scoped) set, so prune any cached account the backend
        // no longer returns — plus the transactions belonging to those removed accounts — so another
        // user's data (or a now-hidden account) can't linger after sign-in/scoping. refreshTransactions is
        // paged and must NOT prune, so the transaction cleanup is anchored to account ownership here.
        let keep = Set(try own.map { try Mapping.uuid($0.id, field: "Account.id") })
        for account in try context.fetch(FetchDescriptor<Account>()) where !keep.contains(account.id) {
            context.delete(account)
        }
        for txn in try context.fetch(FetchDescriptor<Transaction>()) {
            if let aid = txn.accountId, !keep.contains(aid) { context.delete(txn) }
        }
        try context.save()
    }

    /// Partner-owned accounts shared *to* the caller (balances or full). Transient API objects — never
    /// cached, so they stay out of the owner-pure local analytics. Drives the "Shared with you" section.
    func sharedInAccounts() async throws -> [Components.Schemas.AccountResponse] {
        let responses = try await client.list_accounts_accounts_get().ok.body.json
        return responses.filter { $0.shared_by_identifier != nil }
    }

    /// Live, non-caching read of a (full-shared) account's transactions for the read-only shared drill-in.
    /// Deliberately does NOT upsert into SwiftData — shared transactions must never enter the local cache.
    func fetchTransactions(accountId: UUID, limit: Int = 200) async throws
        -> [Components.Schemas.TransactionResponse] {
        try await client.list_transactions_transactions_get(query: .init(
            account_id: accountId.uuidString, limit: limit, offset: 0)).ok.body.json
    }

    func refreshTransactions(
        accountId: UUID? = nil,
        since: Date? = nil,
        until: Date? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws {
        let output = try await client.list_transactions_transactions_get(query: .init(
            account_id: accountId?.uuidString,
            since: since.map(Mapping.dateOnlyFormatter.string(from:)),
            until: until.map(Mapping.dateOnlyFormatter.string(from:)),
            limit: limit,
            offset: offset
        ))
        try upsertTransactions(try output.ok.body.json)
    }

    /// Creates a manual transaction (source=manual) and caches it.
    @discardableResult
    func createTransaction(_ draft: TransactionDraft) async throws -> UUID {
        let output = try await client.create_transaction_transactions_post(
            body: .json(Mapping.transactionCreate(draft))
        )
        switch output {
        case let .created(created):
            let response = try created.body.json
            try upsertTransactions([response])
            return try Mapping.uuid(response.id, field: "Transaction.id")
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Sets (or clears, with nil) the per-transaction category override and caches the response.
    func setCategoryOverride(id: UUID, category: String?) async throws {
        let output = try await client.update_transaction_transactions__transaction_id__patch(
            path: .init(transaction_id: id.uuidString),
            body: .json(.init(category_override: category))
        )
        switch output {
        case let .ok(ok): try upsertTransactions([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Sets the per-transaction budget overrides (include in spending / cash flow) and caches the response.
    func setTransactionFlags(id: UUID, includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) async throws {
        let output = try await client.update_transaction_override_transactions__transaction_id__override_patch(
            path: .init(transaction_id: id.uuidString),
            body: .json(.init(include_in_spending: includeInSpending, include_in_cash_flow: includeInCashFlow))
        )
        switch output {
        case let .ok(ok): try upsertTransactions([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Replaces a transaction's line items (receipt itemization) and caches the response.
    func setItems(id: UUID, items: [ItemDraft]) async throws {
        let output = try await client.set_transaction_items_transactions__transaction_id__items_put(
            path: .init(transaction_id: id.uuidString),
            body: .json(items.map(Mapping.transactionItemInput))
        )
        switch output {
        case let .ok(ok): try upsertTransactions([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Updates per-account overrides (any subset; a nil argument leaves that field unchanged server-side,
    /// matching the backend's exclude_unset semantics) and caches the response. Pass an empty
    /// `displayName` to reset the name back to the Plaid value.
    func update(id: UUID, displayName: String? = nil, kind: String? = nil,
                includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil,
                shareLevel: String? = nil) async throws {
        let output = try await client.update_account_accounts__account_id__patch(
            path: .init(account_id: id.uuidString),
            body: .json(Mapping.accountUpdate(
                displayName: displayName, kind: kind,
                includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow,
                shareLevel: shareLevel))
        )
        switch output {
        case let .ok(ok): try upsertAccounts([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Sets just the Goals-analytics inclusion overrides (thin wrapper over `update`).
    func updateFlags(id: UUID, includeInSpending: Bool?, includeInCashFlow: Bool?) async throws {
        try await update(id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
    }

    func upsertAccounts(_ responses: [Components.Schemas.AccountResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Account.id")
            if let existing = try context.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.name = r.name
                existing.displayName = r.display_name
                existing.type = r._type
                existing.kindOverride = r.kind
                existing.mask = r.mask
                existing.plaidAccountId = r.plaid_account_id
                existing.balance = try Mapping.decimal(r.balance, field: "Account.balance")
                existing.currency = r.currency
                existing.includeInSpending = r.include_in_spending
                existing.includeInCashFlow = r.include_in_cash_flow
                existing.institutionName = r.institution_name
                existing.institutionDomain = r.institution_domain
                existing.institutionColor = r.institution_color
                existing.institutionStatus = r.institution_status
                existing.shareLevel = r.share_level
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.account(r))
            }
        }
        try context.save()
    }

    func upsertTransactions(_ responses: [Components.Schemas.TransactionResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Transaction.id")
            let transaction: Transaction
            if let existing = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.accountId = try Mapping.optionalUUID(r.account_id, field: "Transaction.account_id")
                existing.plaidTransactionId = r.plaid_transaction_id
                existing.source = Mapping.transactionSource(r.source)
                existing.details = r.description
                existing.amount = try Mapping.decimal(r.amount, field: "Transaction.amount")
                existing.currency = r.currency
                existing.date = try Mapping.dateOnly(r.date, field: "Transaction.date")
                existing.category = r.category
                existing.categoryOverride = r.category_override
                existing.pending = r.pending
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
                transaction = existing
            } else {
                let new = try Mapping.transaction(r)
                context.insert(new)
                transaction = new
            }
            try reconcileItems(transaction, r.items ?? [])
        }
        try context.save()
    }

    /// Upserts a transaction's line items by id (preserving object identity for unchanged rows), inserting
    /// new ones and deleting any the server dropped. Mirrors `ExpenseRepository.reconcileItems`.
    private func reconcileItems(_ transaction: Transaction,
                                _ incoming: [Components.Schemas.TransactionItemResponse]) throws {
        var byId = Dictionary(transaction.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [TransactionItem] = []
        for r in incoming {
            let mapped = try Mapping.transactionItem(r)
            if let current = byId.removeValue(forKey: mapped.id) {
                current.name = mapped.name
                current.quantity = mapped.quantity
                current.price = mapped.price
                current.category = mapped.category
                current.editedBy = mapped.editedBy
                current.editedOn = mapped.editedOn
                result.append(current)
            } else {
                context.insert(mapped)
                result.append(mapped)
            }
        }
        for removed in byId.values { context.delete(removed) }
        transaction.items = result
    }
}

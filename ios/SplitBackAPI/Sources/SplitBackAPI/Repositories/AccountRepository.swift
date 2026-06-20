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
        try upsertAccounts(try output.ok.body.json)
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

    /// Sets the Goals-analytics inclusion overrides on an account and caches the response.
    func updateFlags(id: UUID, includeInSpending: Bool?, includeInCashFlow: Bool?) async throws {
        let output = try await client.update_account_accounts__account_id__patch(
            path: .init(account_id: id.uuidString),
            body: .json(Mapping.accountUpdate(
                includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow))
        )
        switch output {
        case let .ok(ok): try upsertAccounts([try ok.body.json])
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func upsertAccounts(_ responses: [Components.Schemas.AccountResponse]) throws {
        for r in responses {
            let id = try Mapping.uuid(r.id, field: "Account.id")
            if let existing = try context.fetch(
                FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
            ).first {
                existing.name = r.name
                existing.type = r._type
                existing.plaidAccountId = r.plaid_account_id
                existing.balance = try Mapping.decimal(r.balance, field: "Account.balance")
                existing.currency = r.currency
                existing.includeInSpending = r.include_in_spending
                existing.includeInCashFlow = r.include_in_cash_flow
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
                existing.pending = r.pending
                existing.createdAt = r.created_at
                existing.updatedAt = r.updated_at
            } else {
                context.insert(try Mapping.transaction(r))
            }
        }
        try context.save()
    }
}

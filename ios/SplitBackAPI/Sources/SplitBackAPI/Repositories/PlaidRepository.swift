import Foundation
import SwiftData

/// Plaid link/exchange/sync + linked-item management. Accounts/transactions are reconciled through
/// the existing `AccountRepository`. Linked items are fetched live (not cached).
@MainActor
struct PlaidRepository {
    let client: Client
    let context: ModelContext

    func linkToken(userIdentifier: String = "matt") async throws -> String {
        let output = try await client.create_link_token_plaid_link_token_post(
            body: .json(.init(user_identifier: userIdentifier))
        )
        switch output {
        case let .ok(ok): return try ok.body.json.link_token
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Exchanges the Plaid public token for an item + accounts, and caches the accounts.
    func exchange(publicToken: String, userIdentifier: String = "matt", institutionName: String? = nil) async throws {
        let output = try await client.exchange_plaid_exchange_post(
            body: .json(.init(public_token: publicToken, user_identifier: userIdentifier, institution_name: institutionName))
        )
        switch output {
        case let .ok(ok):
            try AccountRepository(client: client, context: context).upsertAccounts(try ok.body.json.accounts)
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    /// Runs a Plaid sync, then refreshes cached accounts + transactions.
    @discardableResult
    func sync(itemId: UUID? = nil) async throws -> Components.Schemas.SyncResponse {
        let output = try await client.run_sync_plaid_sync_post(
            body: .json(.init(item_id: itemId?.uuidString))
        )
        switch output {
        case let .ok(ok):
            let stats = try ok.body.json
            let accounts = AccountRepository(client: client, context: context)
            try await accounts.refreshAccounts()
            try await accounts.refreshTransactions()
            return stats
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }

    func items() async throws -> [Components.Schemas.PlaidItemResponse] {
        try await client.list_items_plaid_items_get().ok.body.json
    }

    func deleteItem(id: UUID) async throws {
        let output = try await client.delete_item_plaid_items__item_id__delete(
            path: .init(item_id: id.uuidString)
        )
        switch output {
        case .noContent: break
        case let .unprocessableContent(error): throw BackendError.validation(BackendError.validationMessage(try? error.body.json))
        case let .undocumented(statusCode, _): throw BackendError.fromUndocumented(statusCode)
        }
    }
}

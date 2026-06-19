import Foundation

/// Fetches computed balances (`/balances`, `/groups/{id}/balances`). Balances are derived
/// server-side from active expenses, so they're fetched on demand rather than cached.
@MainActor
struct BalanceService {
    let client: Client

    func overall() async throws -> [Balance] {
        try await client.overall_balances_balances_get().ok.body.json.map(Mapping.balance)
    }

    func forGroup(_ groupId: UUID) async throws -> [Balance] {
        try await client.group_balances_groups__group_id__balances_get(
            path: .init(group_id: groupId.uuidString)
        ).ok.body.json.map(Mapping.balance)
    }
}

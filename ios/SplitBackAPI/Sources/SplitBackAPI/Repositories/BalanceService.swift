import Foundation
import SwiftData

/// Fetches server-computed balances (`/groups/{id}/balances`) and caches them as `GroupBalance` rows, so
/// the Splits list and group detail render from the cache instantly and update in the background. Balances
/// are authoritative server values (`net = paid − owed` over active expenses) — not recomputed locally,
/// which would drift when the local expense cache is incomplete.
@MainActor
struct BalanceRepository {
    let client: Client
    let context: ModelContext

    /// Fetch one group's balances and replace its cached rows.
    func refreshGroup(_ groupId: UUID) async throws {
        let entries = try await client.group_balances_groups__group_id__balances_get(
            path: .init(group_id: groupId.uuidString)
        ).ok.body.json.map(Mapping.balance)
        try replace(groupId: groupId, with: entries)
    }

    /// Refresh every group's balances (best-effort per group). Background work behind the cached display.
    func refreshAll(_ groupIds: [UUID]) async {
        for id in groupIds { try? await refreshGroup(id) }
    }

    private func replace(groupId: UUID, with balances: [Balance]) throws {
        for stale in try context.fetch(
            FetchDescriptor<GroupBalance>(predicate: #Predicate { $0.groupId == groupId })
        ) {
            context.delete(stale)
        }
        let now = Date()
        for b in balances {
            context.insert(GroupBalance(
                groupId: groupId, userIdentifier: b.identifier, paidTotal: b.paidTotal,
                owedTotal: b.owedTotal, net: b.net, updatedAt: now))
        }
        try context.save()
    }
}

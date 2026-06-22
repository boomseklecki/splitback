import Foundation
import SwiftData

/// On-device group balances computed from the cached expenses' splits — the same per-member
/// `net = paid − owed` the backend derives from active expenses, but instant (no network round-trip).
/// The expense sync supplies the "update when available": as cached expenses change, these recompute.
@MainActor
enum LocalBalances {
    /// Per-member balances for a group from its non-archived expenses' splits. `displayName` is left nil —
    /// callers resolve names via the users directory. Sorted by net (creditors first).
    static func forGroup(_ expenses: [Expense]) -> [Balance] {
        var paid: [String: Decimal] = [:]
        var owed: [String: Decimal] = [:]
        for e in expenses where e.archivedAt == nil {
            for s in e.splits {
                paid[s.userIdentifier, default: 0] += s.paidShare
                owed[s.userIdentifier, default: 0] += s.owedShare
            }
        }
        return Set(paid.keys).union(owed.keys).map { id in
            let p = paid[id] ?? 0, o = owed[id] ?? 0
            return Balance(identifier: id, displayName: nil, paidTotal: p, owedTotal: o, net: p - o)
        }
        .sorted { ($0.net, $0.identifier) > ($1.net, $1.identifier) }
    }

    /// The signed-in user's net per group (group id → net), aggregated from the local cache in one fetch.
    /// Groups with no cached expenses map to 0.
    static func myNets(_ groups: [ExpenseGroup], me: String?, context: ModelContext) -> [UUID: Decimal] {
        guard let me else { return [:] }
        let ids = Set(groups.map(\.id))
        var result = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Decimal(0)) })
        let active = (try? context.fetch(
            FetchDescriptor<Expense>(predicate: #Predicate { $0.archivedAt == nil }))) ?? []
        for e in active where ids.contains(e.groupId) {
            for s in e.splits where s.userIdentifier == me {
                result[e.groupId, default: 0] += s.paidShare - s.owedShare
            }
        }
        return result
    }
}

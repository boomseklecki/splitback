import Foundation
import SwiftData

/// Pull-to-refresh staleness thresholds (minutes), loaded from server settings. A live provider sync fires
/// only when the in-scope data is staler than the level's threshold; 0 = always sync.
public struct RefreshThresholds {
    var list: Int
    var detail: Int
    var leaf: Int
    var item: Int

    public init(list: Int = 30, detail: Int = 15, leaf: Int = 0, item: Int = 5) {
        self.list = list; self.detail = detail; self.leaf = leaf; self.item = item
    }

    func minutes(for level: AppEnvironment.RefreshLevel) -> Int {
        switch level {
        case .list: return list
        case .detail: return detail
        case .leaf: return leaf
        case .item: return item
        }
    }
}

@MainActor
extension AppEnvironment {
    /// How tight the freshness threshold is, by screen scope.
    public enum RefreshLevel { case list, detail, leaf, item }
    /// The external source a scope can live-sync from.
    public enum RefreshSource { case bank, splitwise, none }
    /// Which slice of Splitwise a live sync pulls. Drill-in scopes hit the narrow endpoints (one group /
    /// friend / expense) so a detail pull doesn't re-fetch the whole account; `.all` is the list-level
    /// token-wide sync. Associated values: Splitwise group id / local friend identifier / Splitwise expense id.
    public enum SplitwiseScope: Sendable { case all, group(String), friend(String), expense(String) }

    /// The one pull-to-refresh path. Decides — from the in-scope `freshness` (an entity's `updatedAt`, which
    /// equals its last sync time) vs the level's server-set threshold — whether to do a **live** provider sync
    /// then reconcile, or just **reconcile** the backend cache. Drives the status banner. `reconcile` is the
    /// screen's local re-fetch (used in the reconcile-only path and after a Splitwise live sync).
    func smartRefresh(
        level: RefreshLevel,
        source rawSource: RefreshSource,
        freshness: Date?,
        plaidItemId: UUID? = nil,
        splitwiseScope: SplitwiseScope = .all,
        context: ModelContext,
        reconcile: () async throws -> Void
    ) async {
        // A Splitwise scope falls back to reconcile-only when Splitwise isn't connected.
        let source: RefreshSource = (rawSource == .splitwise && !splitwiseConnected) ? .none : rawSource
        let threshold = refreshThresholds.minutes(for: level)
        let stale = freshness == nil || threshold <= 0
            || Date().timeIntervalSince(freshness!) >= Double(threshold) * 60
        do {
            if source != .none && stale {
                showSyncStatus(source == .bank ? "Syncing with your bank…" : "Syncing with Splitwise…",
                               autoDismiss: false)
                let reconciledByLiveSync = try await liveSync(
                    source, plaidItemId: plaidItemId, splitwiseScope: splitwiseScope, context: context)
                if !reconciledByLiveSync { try await reconcile() }
                showSyncStatus("Updated just now", autoDismiss: true)
            } else {
                try await reconcile()
                showSyncStatus(source == .none ? "Refreshed" : "Already up to date", autoDismiss: true)
            }
        } catch {
            showSyncStatus("Couldn't refresh — pull to try again.", autoDismiss: true)
        }
    }

    /// Runs the live provider sync. Returns true if it already reconciled the local cache (Plaid sync does;
    /// the Splitwise syncs are server-side only, so the caller still reconciles).
    private func liveSync(
        _ source: RefreshSource, plaidItemId: UUID?, splitwiseScope: SplitwiseScope, context: ModelContext
    ) async throws -> Bool {
        switch source {
        case .bank:
            try await plaid(context).sync(itemId: plaidItemId)  // nil = all banks; also refreshes the cache
            return true
        case .splitwise:
            // Scoped or token-wide; best-effort so one failing path doesn't abort the others. The drill-in
            // scopes deliberately don't advance the server-side cursor (the backend leaves it untouched).
            switch splitwiseScope {
            case .all:
                _ = try? await splitwise.syncExpenses()
                try? await splitwise.syncGroups()
                try? await splitwise.syncUsers()
            case let .group(swGroupId):
                try? await splitwise.syncGroup(swGroupId)
            case let .friend(identifier):
                try? await splitwise.syncFriend(identifier)
            case let .expense(swExpenseId):
                try? await splitwise.syncExpense(swExpenseId)
            }
            return false
        case .none:
            return false
        }
    }
}

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

    /// The one pull-to-refresh path. Decides — from the in-scope `freshness` (an entity's `updatedAt`, which
    /// equals its last sync time) vs the level's server-set threshold — whether to do a **live** provider sync
    /// then reconcile, or just **reconcile** the backend cache. Drives the status banner. `reconcile` is the
    /// screen's local re-fetch (used in the reconcile-only path and after a Splitwise live sync).
    func smartRefresh(
        level: RefreshLevel,
        source rawSource: RefreshSource,
        freshness: Date?,
        plaidItemId: UUID? = nil,
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
                let reconciledByLiveSync = try await liveSync(source, plaidItemId: plaidItemId, context: context)
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
    private func liveSync(_ source: RefreshSource, plaidItemId: UUID?, context: ModelContext) async throws -> Bool {
        switch source {
        case .bank:
            try await plaid(context).sync(itemId: plaidItemId)  // nil = all banks; also refreshes the cache
            return true
        case .splitwise:
            // Token-wide incremental (v1); best-effort so one failing path doesn't abort the others.
            _ = try? await splitwise.syncExpenses()
            try? await splitwise.syncGroups()
            try? await splitwise.syncUsers()
            return false
        case .none:
            return false
        }
    }
}

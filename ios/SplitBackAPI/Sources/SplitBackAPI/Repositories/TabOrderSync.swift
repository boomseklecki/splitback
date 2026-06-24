import Foundation

/// Versioned snapshot of the main-tab order, for the preferences blob.
struct TabOrderSnapshot: Codable {
    var version: Int = 1
    var order: [String]
}

/// Backs up the locally-authoritative main-tab order (`@AppStorage("tabOrder")`) to the per-owner preferences
/// blob and restores it on a new device. Push on reorder, pull (apply-if-newer) on launch; last-write-wins by
/// the blob's `updated_at` vs a local watermark.
enum TabOrderSync {
    static let key = "tabOrder.v1"
    static let orderKey = "tabOrder"  // the @AppStorage key the TabView reads
    private static let syncedAtKey = "tabOrder.syncedAt"

    /// The current order from local storage (robust to missing/extra tabs).
    @MainActor
    static func current() -> [MainTab] {
        MainTab.parse(UserDefaults.standard.string(forKey: orderKey) ?? "")
    }

    /// Persist a new order locally (the TabView re-renders) — call before pushing.
    @MainActor
    static func write(_ order: [MainTab]) {
        UserDefaults.standard.set(MainTab.serialize(order), forKey: orderKey)
    }

    /// Back up the current local order to the blob. Best-effort.
    @MainActor
    static func pushBestEffort(client: Client) async {
        let snap = TabOrderSnapshot(order: current().map(\.rawValue))
        guard let data = try? JSONEncoder().encode(snap) else { return }
        if let updatedAt = await Preferences.put(key, String(decoding: data, as: UTF8.self), client: client) {
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        }
    }

    /// Apply the backed-up order from a prefetched preferences set when it's newer than the local watermark.
    @MainActor
    @discardableResult
    static func applyIfNewer(from rows: [String: (value: String, updatedAt: Date)]) -> Bool {
        guard let row = rows[key], row.updatedAt.timeIntervalSince1970 > UserDefaults.standard.double(
            forKey: syncedAtKey) else { return false }
        guard let snap = try? JSONDecoder().decode(TabOrderSnapshot.self, from: Data(row.value.utf8)) else {
            return false
        }
        UserDefaults.standard.set(MainTab.serialize(MainTab.parse(snap.order.joined(separator: ","))),
                                  forKey: orderKey)
        UserDefaults.standard.set(row.updatedAt.timeIntervalSince1970, forKey: syncedAtKey)
        return true
    }
}

import Foundation

/// A tiny UserDefaults-backed record of recently-deleted **Splitwise** groups, so the app can offer a
/// one-tap "Restore" right after a delete (restore needs the Splitwise group id, which is gone from the DB
/// once the local row is hard-deleted). Capped + time-bounded so it doesn't grow forever.
enum RecentlyDeletedGroups {
    struct Entry: Codable, Identifiable, Hashable {
        let splitwiseGroupId: String
        let name: String
        let deletedAt: Date
        var id: String { splitwiseGroupId }
    }

    private static let key = "recentlyDeletedSplitwiseGroups"
    private static let maxCount = 10
    private static let maxAge: TimeInterval = 60 * 60 * 24 * 30  // 30 days

    /// Recent deletions, newest first (expired entries pruned).
    static func all() -> [Entry] {
        let raw = UserDefaults.standard.data(forKey: key)
        let entries = raw.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        let cutoff = Date().addingTimeInterval(-maxAge)
        return entries.filter { $0.deletedAt >= cutoff }.sorted { $0.deletedAt > $1.deletedAt }
    }

    static func record(splitwiseGroupId: String, name: String) {
        var entries = all().filter { $0.splitwiseGroupId != splitwiseGroupId }
        entries.insert(Entry(splitwiseGroupId: splitwiseGroupId, name: name, deletedAt: Date()), at: 0)
        save(Array(entries.prefix(maxCount)))
    }

    static func remove(splitwiseGroupId: String) {
        save(all().filter { $0.splitwiseGroupId != splitwiseGroupId })
    }

    private static func save(_ entries: [Entry]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}

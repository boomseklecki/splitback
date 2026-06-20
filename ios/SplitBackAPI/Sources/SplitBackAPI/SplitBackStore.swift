import Foundation
import SwiftData

/// Public entry point for the SwiftData cache. The app builds its `ModelContainer` through here so
/// it never names the internal `@Model` types directly (which also avoids the `Group`/`Transaction`
/// collisions with SwiftUI's same-named types).
public enum SplitBackStore {
    /// All cached entities mirroring the server's source-of-truth tables.
    public static var schema: Schema {
        Schema([
            Group.self,
            Account.self,
            Transaction.self,
            Expense.self,
            ExpenseItem.self,
            Split.self,
            Receipt.self,
            User.self,
            GroupMember.self,
            SyncCursor.self,
            Goal.self,
            CategoryMap.self
        ])
    }

    /// Builds the shared container. Pass `inMemory: true` for tests/previews.
    ///
    /// The store is only a cache (the server is source of truth), so if an existing on-disk store is
    /// incompatible with the current schema — e.g. after adding a model/field — discard it and rebuild
    /// rather than crashing on launch. The data simply re-syncs.
    public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            guard !inMemory else { throw error }
            destroyStore(configuration)
            return try ModelContainer(for: schema, configurations: configuration)
        }
    }

    /// Removes the SQLite store and its `-wal`/`-shm` sidecars so the next container build starts clean.
    private static func destroyStore(_ configuration: ModelConfiguration) {
        let store = configuration.url
        let sidecars = [store,
                        URL(fileURLWithPath: store.path + "-wal"),
                        URL(fileURLWithPath: store.path + "-shm")]
        for url in sidecars { try? FileManager.default.removeItem(at: url) }
    }
}

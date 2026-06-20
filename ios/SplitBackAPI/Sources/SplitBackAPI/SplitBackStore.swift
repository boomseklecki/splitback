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
    public static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

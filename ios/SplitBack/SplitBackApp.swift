import SwiftUI
import SwiftData
import SplitBackAPI

@main
struct SplitBackApp: App {
    /// Shared SwiftData container caching the server's source-of-truth data.
    let modelContainer: ModelContainer = {
        do {
            return try SplitBackStore.makeModelContainer()
        } catch {
            // Last resort: launch with an ephemeral cache rather than crashing. Data re-syncs from
            // the server (the store is only a cache).
            return try! SplitBackStore.makeModelContainer(inMemory: true)
        }
    }()

    /// App-wide services (API client, repositories, token state), injected into the environment.
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        .modelContainer(modelContainer)
    }
}

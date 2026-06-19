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
            fatalError("Failed to create ModelContainer: \(error)")
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

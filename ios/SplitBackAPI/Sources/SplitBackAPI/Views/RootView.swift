import SwiftUI
import SwiftData

/// The app's root. The thin app shell presents this and injects `AppEnvironment` + the model
/// container. Tabs: Accounts, Splits, Budget, Settings.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var didInitialRefresh = false
    @State private var errorMessageText: String?

    public init() {}

    public var body: some View {
        TabView {
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
            GroupsListView()
                .tabItem { Label("Splits", systemImage: "person.2.fill") }
            GoalsView()
                .tabItem { Label("Goals", systemImage: "target") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .errorAlert($errorMessageText)
        .task {
            guard !didInitialRefresh else { return }
            didInitialRefresh = true
            await env.refreshCurrentUser(context)
            await env.refreshSplitwiseStatus()
            do { try await env.refreshAll(context) }
            catch { errorMessageText = errorMessage(error) }
        }
    }
}

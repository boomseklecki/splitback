import SwiftUI
import SwiftData

/// The app's root. The thin app shell presents this and injects `AppEnvironment` + the model
/// container. Three tabs: Groups, Balances, Settings.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var didInitialRefresh = false
    @State private var errorMessageText: String?

    public init() {}

    public var body: some View {
        TabView {
            GroupsListView()
                .tabItem { Label("Groups", systemImage: "person.2.fill") }
            BalancesView()
                .tabItem { Label("Balances", systemImage: "scalemass.fill") }
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .errorAlert($errorMessageText)
        .task {
            guard !didInitialRefresh else { return }
            didInitialRefresh = true
            await env.refreshCurrentUser(context)
            do { try await env.refreshAll(context) }
            catch { errorMessageText = errorMessage(error) }
        }
    }
}

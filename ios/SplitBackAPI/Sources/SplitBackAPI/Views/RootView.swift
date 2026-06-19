import SwiftUI
import SwiftData

/// The app's root. The thin app shell presents this and injects `AppEnvironment` + the model
/// container. Tabs: Accounts, Expenses, Budget, Settings.
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
                .tabItem { Label("Expenses", systemImage: "list.bullet.rectangle.fill") }
            BudgetView()
                .tabItem { Label("Budget", systemImage: "chart.pie.fill") }
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

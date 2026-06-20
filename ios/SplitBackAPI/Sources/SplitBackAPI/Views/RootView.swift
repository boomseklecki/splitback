import SwiftUI
import SwiftData

/// The app's root and launch gate. Shows the sign-in gate when the backend requires auth and there's
/// no token; otherwise the main tabs. Open-mode backends launch straight in.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var checking = true

    public init() {}

    private enum Phase { case checking, gate, ready }
    private var phase: Phase {
        if checking { return .checking }
        // Open backends never gate. Otherwise (requires auth, or unknown) gate until there's a token.
        if env.serverRequiresAuth == false { return .ready }
        return env.hasToken ? .ready : .gate
    }

    public var body: some View {
        LockGateView {
            SwiftUI.Group {
                switch phase {
                case .checking:
                    ProgressView().controlSize(.large)
                case .gate:
                    AuthGateView(isLaunchGate: true)
                case .ready:
                    MainTabView()
                }
            }
            .task {
                await env.loadServerInfo()
                checking = false
            }
        }
    }
}

/// The signed-in app: the four tabs plus the on-launch data refresh.
private struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var didInitialRefresh = false
    @State private var errorMessageText: String?

    var body: some View {
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

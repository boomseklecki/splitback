import SwiftUI
import SwiftData

/// The app's root and launch gate. Shows the sign-in gate when the backend requires auth and there's
/// no token; otherwise the main tabs. Open-mode backends launch straight in.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var checking = true
    @State private var plaidSession = PlaidLinkSession.shared

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
        // Plaid OAuth redirect (Universal Link). In-process flows resume their live handler; a flow
        // interrupted by app termination re-presents Link from the persisted token to finish.
        .onOpenURL { PlaidLinkSession.shared.handleOAuthRedirect($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { PlaidLinkSession.shared.handleOAuthRedirect(url) }
        }
        .fullScreenCover(item: $plaidSession.resume) { resume in
            PlaidLinkView(
                linkToken: resume.token,
                resumeRedirect: resume.redirect,
                onSuccess: { publicToken in
                    PlaidLinkSession.shared.finish()
                    Task { await exchange(publicToken) }
                },
                onExit: { PlaidLinkSession.shared.finish() }
            )
            .ignoresSafeArea()
        }
    }

    /// Exchanges a public token after a terminated-then-resumed Plaid OAuth flow.
    private func exchange(_ publicToken: String) async {
        guard let me = env.currentUser?.identifier else { return }
        try? await env.plaid(context).exchange(publicToken: publicToken, userIdentifier: me)
    }
}

/// Persistent reminder that the current backend is a public demo with sample data.
private struct DemoBanner: View {
    var body: some View {
        Label("Demo — sample data, nothing real is linked", systemImage: "wand.and.stars")
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.15))
            .foregroundStyle(.tint)
    }
}

/// The signed-in app: the four tabs plus the on-launch data refresh.
private struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var didInitialRefresh = false
    @State private var errorMessageText: String?

    var body: some View {
        VStack(spacing: 0) {
            if env.serverIsDemo { DemoBanner() }
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

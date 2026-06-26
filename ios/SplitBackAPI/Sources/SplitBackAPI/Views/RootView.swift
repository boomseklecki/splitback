import SwiftUI
import SwiftData

/// The app's root and launch gate. Shows the sign-in gate when the backend requires auth and there's
/// no token; otherwise the main tabs. Open-mode backends launch straight in.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var checking = true
    @State private var plaidSession = PlaidLinkSession.shared
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

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
        // Inbound links: a join link (adopt backend + capture invite) takes priority; otherwise a Plaid
        // OAuth redirect (Universal Link) resumes its live handler, re-presenting Link if needed.
        .onOpenURL { url in
            if env.adoptJoinLink(url, context: context) { return }
            PlaidLinkSession.shared.handleOAuthRedirect(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            if env.adoptJoinLink(url, context: context) { return }
            PlaidLinkSession.shared.handleOAuthRedirect(url)
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
        .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
    }

    /// Exchanges a public token after a terminated-then-resumed Plaid OAuth flow.
    private func exchange(_ publicToken: String) async {
        guard let me = env.currentUser?.identifier else { return }
        try? await env.plaid(context).exchange(publicToken: publicToken, userIdentifier: me)
    }
}

/// Transient banner shown during/after a pull-to-refresh ("Syncing with your bank…", "Already up to date"),
/// driven by `AppEnvironment.syncStatus`. Auto-dismisses (the env clears terminal messages on a timer).
private struct SyncStatusBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        SwiftUI.Group {
            if let status = env.syncStatus {
                Label(status, systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
                    .shadow(radius: 2, y: 1)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: env.syncStatus)
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

/// The signed-in app: the reorderable main tabs (Settings pinned last) plus the on-launch data refresh.
private struct MainTabView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var didInitialRefresh = false
    @State private var errorMessageText: String?
    @AppStorage("tabOrder") private var tabOrderRaw = MainTab.serialize(MainTab.allCases)
    @State private var selection = MainTab.accounts.rawValue

    var body: some View {
        VStack(spacing: 0) {
            if env.serverIsDemo { DemoBanner() }
            TabView(selection: $selection) {
                ForEach(MainTab.parse(tabOrderRaw)) { tab in
                    tabContent(tab)
                        .tabItem { Label(tab.title, systemImage: tab.icon) }
                        .tag(tab.rawValue)
                        .badge(tab == .inbox ? env.inboxBadge : 0)
                }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag("settings")
            }
        }
        .overlay(alignment: .top) { SyncStatusBanner() }
        .errorAlert($errorMessageText)
        .task {
            guard !didInitialRefresh else { return }
            didInitialRefresh = true
            await env.refreshCurrentUser(context)
            await env.refreshSplitwiseStatus()
            await env.bootstrapPreferences(context)
            await env.loadRefreshThresholds()
            do { try await env.refreshAll(context) }
            catch { errorMessageText = errorMessage(error) }
            await env.refreshInboxBadge(context)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: MainTab) -> some View {
        switch tab {
        case .accounts: AccountsView()
        case .splits: GroupsListView()
        case .goals: GoalsView()
        case .inbox: InboxView()
        }
    }
}

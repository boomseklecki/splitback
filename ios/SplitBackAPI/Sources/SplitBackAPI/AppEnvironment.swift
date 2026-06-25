import Foundation
import SwiftData
import Observation

/// Shared app-wide services: one configured API `Client` plus repository/service factories and the
/// bearer-token state. Created by the app shell and injected into the SwiftUI environment.
/// The auth middleware reads the Keychain token per request, so token changes take effect at once.
@MainActor
@Observable
public final class AppEnvironment {
    @ObservationIgnored private(set) var client: Client
    /// A long-timeout client for slow operations (the Splitwise cold-backfill import + syncs), which can
    /// run for minutes and otherwise hit NSURLErrorTimedOut on the default 60s request timeout.
    @ObservationIgnored private(set) var slowClient: Client
    @ObservationIgnored private let tokenStore: KeychainTokenStore

    /// Whether a bearer token is stored (drives Settings UI). The backend is default-open without one.
    public private(set) var hasToken: Bool
    /// Current base URL string (drives Settings UI).
    public private(set) var baseURLString: String
    /// The signed-in user's profile from `GET /me` (nil in open mode / not signed in). Source of truth
    /// for "you" — no hardcoded identity.
    public private(set) var currentUser: CurrentUser?
    /// Whether a Splitwise token is connected. Gates the scoped sync endpoints (which 400 without one)
    /// so non-Splitwise instances don't call them on every pull-to-refresh.
    public private(set) var splitwiseConnected = false
    /// Whether the configured backend requires sign-in (from the unguarded `GET /server-info`). Nil
    /// until first loaded / when server-info is unreachable; drives the launch gate.
    public private(set) var serverRequiresAuth: Bool?
    /// Sign-in providers the backend offers (e.g. ["apple","google","splitwise"]); filters the gate.
    public private(set) var authProviders: [String] = []
    /// Whether the last `/server-info` probe reached a SplitBack backend. Nil before the first probe;
    /// false means the configured URL is wrong/unreachable (drives the gate's connectivity hint).
    public private(set) var serverReachable: Bool?
    /// The backend's friendly name from `/server-info` (e.g. "Matt's Household"); used as the join link label.
    public private(set) var serverName: String?
    /// Whether the configured backend is a public DEMO instance (guest login + sample data). Drives the
    /// gate's "Start Demo" path and the persistent "sample data" banner.
    public private(set) var serverIsDemo = false
    /// A single-use enrollment invite captured from a join link, applied to the next sign-in (then cleared).
    /// Persisted so it survives the install→open hop; drives the gate's "you have an invite" hint.
    public private(set) var pendingInvite: String?

    private static let pendingInviteKey = "pending_invite"

    public init() {
        let store = KeychainTokenStore()
        self.tokenStore = store
        self.client = APIClientFactory.makeClient(tokenStore: store)
        self.slowClient = APIClientFactory.makeClient(tokenStore: store, requestTimeout: 300)
        self.hasToken = (store.load()?.isEmpty == false)
        self.baseURLString = APIConfig.baseURL.absoluteString
        self.pendingInvite = UserDefaults.standard.string(forKey: Self.pendingInviteKey)
    }

    /// Stores (or clears) the pending enrollment invite, persisted across launches.
    func setPendingInvite(_ code: String?) {
        pendingInvite = (code?.isEmpty == false) ? code : nil
        if let pendingInvite {
            UserDefaults.standard.set(pendingInvite, forKey: Self.pendingInviteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
        }
    }

    /// Handles an inbound join link: adopts its backend URL and captures any single-use invite for the next
    /// sign-in. Switching to a different backend wipes the local cache + signs out (prod/dev don't intermingle).
    /// Returns true if the URL was a join link (so the caller stops other handlers).
    @discardableResult
    func adoptJoinLink(_ url: URL, context: ModelContext) -> Bool {
        guard let parsed = JoinLink.parse(url) else { return false }
        if parsed.api != baseURLString {
            wipeLocalData(context)
            setBaseURL(parsed.api)
        }
        setPendingInvite(parsed.invite)
        Task { await loadServerInfo() }
        return true
    }

    func setToken(_ token: String?) {
        tokenStore.save(token)
        hasToken = (token?.isEmpty == false)
    }

    /// Refreshes the signed-in profile from `GET /me`. A definitive 401 means the stored token is
    /// invalid/expired → sign out so it isn't resent and the launch gate re-shows. Transient/offline
    /// failures leave the prior state (so a network blip doesn't lock a signed-in user out).
    func refreshCurrentUser(_ context: ModelContext) async {
        do {
            currentUser = try await users(context).currentUser()
        } catch BackendError.http(401) {
            signOut()
        } catch {
            // transient/offline — keep the prior currentUser
        }
    }

    /// Loads the backend's auth requirement + providers from the unguarded `GET /server-info`, and
    /// records whether the configured URL actually reached a SplitBack backend.
    func loadServerInfo() async {
        do {
            let info = try await client.server_info_server_info_get().ok.body.json
            serverRequiresAuth = info.requires_auth
            authProviders = info.auth_providers
            serverName = info.name
            serverIsDemo = info.demo ?? false
            serverReachable = true
        } catch {
            serverReachable = false  // wrong URL / unreachable / not a SplitBack backend
        }
    }

    /// Refreshes whether Splitwise is connected (best-effort; leaves the prior value on failure).
    func refreshSplitwiseStatus() async {
        if let connected = try? await splitwise.status().connected {
            splitwiseConnected = connected
        }
    }

    /// Applies a session token issued after a provider sign-in, then loads the profile.
    func applySession(token: String, context: ModelContext) async {
        setToken(token)
        await refreshCurrentUser(context)
    }

    /// Clears the session token and profile (sign out).
    func signOut() {
        setToken(nil)
        currentUser = nil
    }

    /// Changes the backend base URL (persisted) and rebuilds the client.
    func setBaseURL(_ string: String?) {
        APIConfig.setOverride(string)
        baseURLString = APIConfig.baseURL.absoluteString
        client = APIClientFactory.makeClient(baseURL: APIConfig.baseURL, tokenStore: tokenStore)
        slowClient = APIClientFactory.makeClient(baseURL: APIConfig.baseURL, tokenStore: tokenStore,
                                                 requestTimeout: 300)
    }

    /// Wipes the local SwiftData cache and signs out — used when switching backends so prod/dev data don't
    /// intermingle. The cache re-syncs from the (now-current) backend on the next refresh.
    func wipeLocalData(_ context: ModelContext) {
        try? SplitBackStore.eraseAll(context)
        signOut()
    }

    // Repository/service factories (constructed per-use with the view's ModelContext).
    func groups(_ context: ModelContext) -> GroupRepository { .init(client: client, context: context) }
    func expenses(_ context: ModelContext) -> ExpenseRepository { .init(client: client, context: context) }
    func users(_ context: ModelContext) -> UserRepository { .init(client: client, context: context) }
    func receipts(_ context: ModelContext) -> ReceiptRepository { .init(client: client, context: context) }
    func accounts(_ context: ModelContext) -> AccountRepository { .init(client: client, context: context) }
    func goals(_ context: ModelContext) -> GoalRepository { .init(client: client, context: context) }
    func categoryMaps(_ context: ModelContext) -> CategoryMapRepository { .init(client: client, context: context) }
    func plaid(_ context: ModelContext) -> PlaidRepository { .init(client: client, context: context) }
    func plaidSlow(_ context: ModelContext) -> PlaidRepository { .init(client: slowClient, context: context) }  // exchange auto-syncs the new bank, which can backfill many months

    /// Fire-and-forget: pre-warm a Plaid link token so the next "Link Bank" tap opens Plaid Link without the
    /// token round-trip. No-op without a signed-in user; best-effort (never blocks, never surfaces errors).
    func prewarmPlaidLinkToken(_ context: ModelContext) {
        guard let me = currentUser?.identifier else { return }
        Task { await PlaidLinkTokenCache.shared.prewarm(for: me) {
            try await self.plaid(context).linkToken(userIdentifier: me)
        } }
    }
    func balances(_ context: ModelContext) -> BalanceRepository { .init(client: client, context: context) }
    func categories(_ context: ModelContext) -> CategoryRepository { .init(client: client, context: context) }
    var splitwise: SplitwiseService { .init(client: slowClient) }  // slow client: the cold-backfill import can run minutes
    var backups: BackupsRepository { .init(client: slowClient) }   // slow client: pg_dump/restore + receipts can run minutes
    var invites: InviteRepository { .init(client: client) }
    var serverSettings: ServerSettingsRepository { .init(client: client) }
    func auth(_ context: ModelContext) -> AuthService { .init(client: client, context: context) }

    /// On-launch / pull-to-refresh: reconcile the cacheable collections (handles server-side deletes).
    /// Categories are local-authoritative now (see `bootstrapPreferences`), so they're not reconciled here.
    func refreshAll(_ context: ModelContext) async throws {
        try await groups(context).reconcileAll()
        try await users(context).refresh()
        try await expenses(context).reconcileAll()
        try await goals(context).refresh()
    }

    /// On launch: ensure built-in categories exist, then restore any per-user preference blobs (categories,
    /// tab order) that are newer than what this device last applied — a new phone gets them back. One fetch
    /// serves all consumers; apply-if-newer never clobbers a device that's ahead.
    func bootstrapPreferences(_ context: ModelContext) async {
        CategorySeed.ensureBuiltins(context)
        let rows = await Preferences.fetchAll(client)
        CategorySync.applyIfNewer(from: rows, context: context)
        OrderPreference.tabs.applyIfNewer(from: rows)
        OrderPreference.goals.applyIfNewer(from: rows)
    }

    /// Manual "Sync now" from Categories settings: restore a newer backup, else back up local.
    func syncCategoriesNow(_ context: ModelContext) async {
        await CategorySync.syncNow(context, client: client)
    }

    /// Persist a new main-tab order locally (the TabView re-renders) and back it up to the preferences blob.
    func setTabOrder(_ order: [MainTab]) async {
        OrderPreference.tabs.write(order)
        await OrderPreference.tabs.pushBestEffort(client: client)
    }

    /// Persist a new Goals-page section order locally and back it up to the preferences blob.
    func setGoalsOrder(_ order: [GoalSection]) async {
        OrderPreference.goals.write(order)
        await OrderPreference.goals.pushBestEffort(client: client)
    }
}

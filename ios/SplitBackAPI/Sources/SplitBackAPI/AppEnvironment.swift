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

    public init() {
        let store = KeychainTokenStore()
        self.tokenStore = store
        self.client = APIClientFactory.makeClient(tokenStore: store)
        self.hasToken = (store.load()?.isEmpty == false)
        self.baseURLString = APIConfig.baseURL.absoluteString
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
    var balances: BalanceService { .init(client: client) }
    func categories(_ context: ModelContext) -> CategoryRepository { .init(client: client, context: context) }
    var splitwise: SplitwiseService { .init(client: client) }
    func auth(_ context: ModelContext) -> AuthService { .init(client: client, context: context) }

    /// On-launch / pull-to-refresh: reconcile the cacheable collections (handles server-side deletes).
    func refreshAll(_ context: ModelContext) async throws {
        try await groups(context).reconcileAll()
        try await users(context).refresh()
        try await expenses(context).reconcileAll()
        try await goals(context).refresh()
        try await categoryMaps(context).refresh()
        try await categories(context).refresh()
    }
}

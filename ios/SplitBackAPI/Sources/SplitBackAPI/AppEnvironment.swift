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

    /// Refreshes the signed-in profile from `GET /me` (best-effort).
    func refreshCurrentUser(_ context: ModelContext) async {
        currentUser = try? await users(context).currentUser()
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

    // Repository/service factories (constructed per-use with the view's ModelContext).
    func groups(_ context: ModelContext) -> GroupRepository { .init(client: client, context: context) }
    func expenses(_ context: ModelContext) -> ExpenseRepository { .init(client: client, context: context) }
    func users(_ context: ModelContext) -> UserRepository { .init(client: client, context: context) }
    func receipts(_ context: ModelContext) -> ReceiptRepository { .init(client: client, context: context) }
    func accounts(_ context: ModelContext) -> AccountRepository { .init(client: client, context: context) }
    func plaid(_ context: ModelContext) -> PlaidRepository { .init(client: client, context: context) }
    var balances: BalanceService { .init(client: client) }
    var categories: CategoryService { .init(client: client) }
    var splitwise: SplitwiseService { .init(client: client) }
    func auth(_ context: ModelContext) -> AuthService { .init(client: client, context: context) }

    /// On-launch / pull-to-refresh: reconcile the cacheable collections (handles server-side deletes).
    func refreshAll(_ context: ModelContext) async throws {
        try await groups(context).reconcileAll()
        try await users(context).refresh()
        try await expenses(context).reconcileAll()
    }
}

import Foundation
import SwiftData
import GoogleSignIn

/// Errors surfaced by the sign-in flow.
enum AuthError: LocalizedError, Equatable {
    case notConfigured(String)
    case cancelled
    case invalidResponse
    case rejected
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(message): return message
        case .cancelled: return "Sign-in was cancelled."
        case .invalidResponse: return "The sign-in response couldn't be read."
        case .rejected: return "The server rejected this sign-in."
        case let .failed(message): return message
        }
    }
}

/// Captures a provider credential (Apple/Google/Splitwise) and exchanges it for a backend session JWT.
/// Apple credential capture happens in `AuthGateView` (SwiftUI `SignInWithAppleButton`); Google and
/// Splitwise capture happen here.
@MainActor
struct AuthService {
    let client: Client
    let context: ModelContext

    // MARK: Backend exchanges

    /// Apple identity token → backend session JWT.
    func exchangeApple(identityToken: String, fullName: String?) async throws -> String {
        let output = try await client.auth_apple_auth_apple_post(
            body: .json(.init(identity_token: identityToken, full_name: fullName))
        )
        switch output {
        case let .ok(ok): return try ok.body.json.token
        case .unprocessableContent: throw AuthError.rejected
        case let .undocumented(statusCode, _): throw Self.error(statusCode)
        }
    }

    /// Demo guest login (name only, no OAuth) → backend session JWT. Only the demo backend exposes
    /// `POST /auth/demo`; elsewhere it 404s (surfaced as `.failed`).
    func startDemo(displayName: String?) async throws -> String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try await client.auth_demo_auth_demo_post(
            body: .json(.init(display_name: (name?.isEmpty == false) ? name : nil))
        )
        switch output {
        case let .ok(ok): return try ok.body.json.token
        case .unprocessableContent: throw AuthError.rejected
        case let .undocumented(statusCode, _): throw Self.error(statusCode)
        }
    }

    /// Google ID token → backend session JWT.
    func exchangeGoogle(idToken: String) async throws -> String {
        let output = try await client.auth_google_auth_google_post(body: .json(.init(id_token: idToken)))
        switch output {
        case let .ok(ok): return try ok.body.json.token
        case .unprocessableContent: throw AuthError.rejected
        case let .undocumented(statusCode, _): throw Self.error(statusCode)
        }
    }

    // MARK: Capture + exchange

    /// Google Sign-In SDK → ID token → backend JWT. Needs `GIDClientID` in the Info.plist.
    func signInWithGoogle() async throws -> String {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty else {
            throw AuthError.notConfigured("Google sign-in isn't configured yet (missing GIDClientID).")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let presenter = AppPresentation.topViewController() else { throw AuthError.invalidResponse }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AuthError.invalidResponse }
        return try await exchangeGoogle(idToken: idToken)
    }

    /// Splitwise web OAuth via `ASWebAuthenticationSession`; the backend callback returns
    /// `splitback://auth?token=<jwt>`.
    func signInWithSplitwise() async throws -> String {
        guard let url = splitwiseLoginURL() else { throw AuthError.invalidResponse }
        let callback = try await WebAuth.start(url: url, callbackScheme: "splitback")
        guard let token = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw AuthError.invalidResponse
        }
        return token
    }

    func splitwiseLoginURL() -> URL? {
        APIConfig.baseURL.appendingPathComponent("auth/splitwise/login")
    }

    private static func error(_ statusCode: Int) -> AuthError {
        statusCode == 401 ? .rejected : .failed("Sign-in failed (HTTP \(statusCode)).")
    }
}

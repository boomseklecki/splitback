import SwiftUI
import AuthenticationServices

/// Sign-in / onboarding: pick a server, then sign in with Apple, Google, or Splitwise.
/// Splitwise works against the standard backend; Apple needs the app's Sign-in-with-Apple entitlement
/// and Google needs `GIDClientID` in the Info.plist (both surfaced as friendly errors until configured).
/// Presented from Settings for now — not yet a hard launch gate.
public struct AuthGateView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var busy = false
    @State private var errorText: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("API base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Use This Server") { env.setBaseURL(baseURL) }
                }

                Section("Sign In") {
                    SignInWithAppleButton(.signIn,
                        onRequest: { $0.requestedScopes = [.fullName, .email] },
                        onCompletion: handleApple)
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 44)
                        .listRowInsets(EdgeInsets())

                    Button { run { try await env.auth(context).signInWithGoogle() } } label: {
                        Label("Continue with Google", systemImage: "g.circle.fill")
                    }
                    Button { run { try await env.auth(context).signInWithSplitwise() } } label: {
                        Label("Continue with Splitwise", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(busy)
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { baseURL = env.baseURLString }
            .errorAlert($errorText)
        }
    }

    /// Runs a capture+exchange that yields a session token, applies it, and dismisses.
    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let token = try await work()
                await env.applySession(token: token, context: context)
                dismiss()
            } catch {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                errorText = errorMessage(error)
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorText = AuthError.invalidResponse.errorDescription
                return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            run { try await env.auth(context).exchangeApple(identityToken: identityToken,
                                                            fullName: name.isEmpty ? nil : name) }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorText = errorMessage(error)
        }
    }
}

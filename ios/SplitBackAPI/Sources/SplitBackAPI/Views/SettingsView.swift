import SwiftUI
import SwiftData

/// Backend base URL, bearer-token entry (Keychain), Splitwise status + import, and the people roster.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @State private var token = ""
    @State private var baseURL = ""
    @State private var splitwiseConnected: Bool?
    @State private var importing = false
    @State private var importSummary: String?
    @State private var showingNewUser = false
    @State private var newUserName = ""
    @State private var showingSplitwiseLogin = false
    @State private var showingSignIn = false
    @State private var errorText: String?

    private var splitwiseLoginURL: URL? {
        var components = URLComponents(url: APIConfig.baseURL.appendingPathComponent("auth/splitwise/login"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: "matt")]
        return components?.url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = env.currentUser {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                            if let email = user.email {
                                Text(email).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Sign Out", role: .destructive) { env.signOut() }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Button("Sign In…") { showingSignIn = true }
                    }
                }

                Section("Backend") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save Base URL") {
                        env.setBaseURL(baseURL)
                        Task { await reloadAfterConfigChange() }
                    }
                }

                Section("API Token") {
                    SecureField("Bearer token (optional)", text: $token)
                    Button("Save Token") {
                        env.setToken(token.isEmpty ? nil : token)
                        token = ""
                    }
                    if env.hasToken {
                        Text("A token is stored.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Splitwise") {
                    Button("Connect Splitwise", systemImage: "link") { showingSplitwiseLogin = true }
                        .disabled(splitwiseLoginURL == nil)
                    if let connected = splitwiseConnected {
                        Label(connected ? "Connected" : "Not connected",
                              systemImage: connected ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(connected ? .green : .secondary)
                    }
                    Button("Run Import", action: runImport).disabled(importing)
                    if let importSummary {
                        Text(importSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("People") {
                    ForEach(users) { user in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                            Text("\(user.identifier) · \(user.source.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Add Person") { showingNewUser = true }
                }
            }
            .navigationTitle("Settings")
            .task {
                baseURL = env.baseURLString
                await loadStatus()
            }
            .alert("Add Person", isPresented: $showingNewUser) {
                TextField("Display name", text: $newUserName)
                Button("Add", action: addUser)
                Button("Cancel", role: .cancel) { newUserName = "" }
            }
            .sheet(isPresented: $showingSplitwiseLogin, onDismiss: { Task { await loadStatus() } }) {
                if let url = splitwiseLoginURL { SafariView(url: url) }
            }
            .sheet(isPresented: $showingSignIn) { AuthGateView() }
            .errorAlert($errorText)
        }
    }

    private func loadStatus() async {
        do { splitwiseConnected = try await env.splitwise.status().connected }
        catch { /* status is best-effort; leave nil */ }
    }

    private func reloadAfterConfigChange() async {
        do { try await env.refreshAll(context) }
        catch { errorText = errorMessage(error) }
        await loadStatus()
    }

    private func runImport() {
        importing = true
        Task {
            defer { importing = false }
            do {
                let count = try await env.splitwise.runImport()
                importSummary = "Imported \(count) expense\(count == 1 ? "" : "s")."
                try await env.refreshAll(context)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func addUser() {
        let name = newUserName.trimmingCharacters(in: .whitespaces)
        newUserName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await env.users(context).create(UserDraft(displayName: name)) }
            catch { errorText = errorMessage(error) }
        }
    }
}

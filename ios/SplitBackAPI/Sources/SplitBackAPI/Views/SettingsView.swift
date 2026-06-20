import SwiftUI
import SwiftData

/// Account/session, backend base URL, bearer-token entry (Keychain), Splitwise status + import,
/// linked banks (Plaid), and a drill-through to the people roster.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @State private var token = ""
    @State private var baseURL = ""
    @State private var importing = false
    @State private var importSummary: String?
    @State private var showingSplitwiseLogin = false
    @State private var showingSignIn = false
    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var errorText: String?

    struct LinkSession: Identifiable { let id = UUID(); let token: String }

    /// Connect Splitwise to *your* account. Requires a signed-in user (nil disables the button) so the
    /// Splitwise token is linked to the real identity from `/me`, not a hardcoded name.
    private var splitwiseLoginURL: URL? {
        guard let me = env.currentUser?.identifier else { return nil }
        var components = URLComponents(url: APIConfig.baseURL.appendingPathComponent("auth/splitwise/login"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: me)]
        return components?.url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let user = env.currentUser {
                        HStack(spacing: 12) {
                            AvatarView(url: user.avatarURL, name: user.displayName.titleCased, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName.titleCased)
                                if let email = user.email {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Sign Out", role: .destructive) { env.signOut() }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Button("Sign In…") { showingSignIn = true }
                    }
                }

                Section {
                    Toggle(isOn: $lockEnabled) {
                        Label("Require Face ID / Passcode", systemImage: "faceid")
                    }
                    .disabled(!AppLock.isAvailable)
                } header: {
                    Text("Security")
                } footer: {
                    Text(AppLock.isAvailable
                         ? "Lock the app on launch and when it returns from the background."
                         : "Set a device passcode to enable app lock.")
                }

                Section {
                    NavigationLink {
                        PeopleView()
                    } label: {
                        HStack {
                            Label("People", systemImage: "person.2")
                            Spacer()
                            Text("\(users.count)").foregroundStyle(.secondary)
                        }
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
                    Label(env.splitwiseConnected ? "Connected" : "Not connected",
                          systemImage: env.splitwiseConnected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(env.splitwiseConnected ? .green : .secondary)
                    Button("Run Import", action: runImport).disabled(importing)
                    if let importSummary {
                        Text(importSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Spending") {
                    NavigationLink {
                        CategoryMappingView()
                    } label: {
                        Label("Spending Categories", systemImage: "tag")
                    }
                }

                Section("Linked Banks") {
                    ForEach(items, id: \.id) { item in
                        NavigationLink {
                            LinkedBankView(item: item)
                        } label: {
                            let count = item.accounts?.count ?? 0
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.institution_name ?? "Bank")
                                Text("\(count) account\(count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: unlink)
                    Button(action: linkBank) {
                        Label(linking ? "Preparing…" : "Link Bank", systemImage: "building.columns")
                    }
                    .disabled(linking || env.currentUser == nil)
                    if env.currentUser == nil {
                        Text("Sign in to link a bank.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                baseURL = env.baseURLString
                await env.refreshSplitwiseStatus()
                await loadItems()
            }
            .sheet(isPresented: $showingSplitwiseLogin, onDismiss: { Task { await env.refreshSplitwiseStatus() } }) {
                if let url = splitwiseLoginURL { SafariView(url: url) }
            }
            .sheet(isPresented: $showingSignIn) { AuthGateView() }
            .fullScreenCover(item: $linkSession) { session in
                PlaidLinkView(
                    linkToken: session.token,
                    onSuccess: { publicToken in
                        linkSession = nil
                        Task { await exchange(publicToken) }
                    },
                    onExit: { linkSession = nil }
                )
                .ignoresSafeArea()
            }
            .errorAlert($errorText)
        }
    }

    private func loadItems() async {
        items = (try? await env.plaid(context).items()) ?? items
    }

    private func reloadAfterConfigChange() async {
        do { try await env.refreshAll(context) }
        catch { errorText = errorMessage(error) }
        await env.refreshSplitwiseStatus()
        await loadItems()
    }

    private func runImport() {
        importing = true
        Task {
            defer { importing = false }
            do {
                let count = try await env.splitwise.runImport()
                importSummary = "Imported \(count.formatted()) expense\(count == 1 ? "" : "s")."
                await env.refreshSplitwiseStatus()
                try await env.refreshAll(context)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func linkBank() {
        guard let me = env.currentUser?.identifier else {
            errorText = "Sign in to link a bank."
            return
        }
        linking = true
        Task {
            defer { linking = false }
            do { linkSession = LinkSession(token: try await env.plaid(context).linkToken(userIdentifier: me)) }
            catch { errorText = errorMessage(error) }
        }
    }

    private func exchange(_ publicToken: String) async {
        guard let me = env.currentUser?.identifier else {
            errorText = "Sign in to link a bank."
            return
        }
        do {
            try await env.plaid(context).exchange(publicToken: publicToken, userIdentifier: me)
            await loadItems()
        } catch { errorText = errorMessage(error) }
    }

    private func unlink(_ offsets: IndexSet) {
        let ids = offsets.compactMap { UUID(uuidString: items[$0].id) }
        Task {
            do {
                for id in ids { try await env.plaid(context).deleteItem(id: id) }
                await loadItems()
            } catch { errorText = errorMessage(error) }
        }
    }
}

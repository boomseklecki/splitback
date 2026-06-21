import SwiftUI
import SwiftData
import UIKit

/// Account/session, backend base URL, bearer-token entry (Keychain), Splitwise status + import,
/// linked banks (Plaid), and a drill-through to the people roster.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    /// Remembered backend presets so switching dev↔prod is one tap (set once, then quick-fill the field).
    @AppStorage("backend.devURL") private var devURL = ""
    @AppStorage("backend.prodURL") private var prodURL = ""
    @State private var token = ""
    @State private var baseURL = ""
    @State private var confirmingWipe = false
    @State private var importing = false
    @State private var importSummary: String?
    @State private var showingSplitwiseLogin = false
    @State private var showingSignIn = false
    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var syncing = false
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
                                // Your join key: balances/splits only show when this matches the
                                // user_identifier in the data (e.g. the dev seed's `--as`).
                                Text("ID: \(user.identifier)")
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
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

                Section {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !devURL.isEmpty || !prodURL.isEmpty {
                        HStack {
                            Button("Use Dev") { baseURL = devURL }.disabled(devURL.isEmpty)
                            Spacer()
                            Button("Use Prod") { baseURL = prodURL }.disabled(prodURL.isEmpty)
                        }
                        .buttonStyle(.bordered).font(.callout)
                    }
                    Button("Save Base URL") {
                        env.setBaseURL(baseURL)
                        Task { await reloadAfterConfigChange() }
                    }
                    DisclosureGroup("Presets") {
                        urlField("Dev URL", text: $devURL)
                        urlField("Prod URL", text: $prodURL)
                    }
                    Button("Clear Local Data…", role: .destructive) { confirmingWipe = true }
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Set Dev/Prod presets once, then switch with a tap. After switching backends, "
                         + "Clear Local Data so cached prod and dev records don't mix.")
                }

                if let joinURL = JoinLink.url(apiBaseURL: env.baseURLString, name: env.serverName) {
                    Section {
                        QRCodeView(string: joinURL.absoluteString)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .padding(.vertical, 8)
                        ShareLink(item: joinURL) {
                            Label("Share Join Link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.url = joinURL
                        } label: {
                            Label("Copy Join Link", systemImage: "doc.on.doc")
                        }
                        Text(joinURL.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } header: {
                        Text("Invite")
                    } footer: {
                        Text(JoinLink.isPubliclyReachable(env.baseURLString)
                             ? "Share to set up SplitBack on another device against this backend."
                             : "This backend address only works on your local network. Set a public (tunnel/HTTPS) Base URL above before sharing.")
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
                        ManageCategoriesView()
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
                    if !items.isEmpty {
                        Button(action: syncBanks) {
                            Label(syncing ? "Syncing…" : "Sync All Banks",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(syncing)
                    }
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
                        PlaidLinkSession.shared.finish()
                        Task { await exchange(publicToken) }
                    },
                    onExit: { linkSession = nil; PlaidLinkSession.shared.finish() }
                )
                .ignoresSafeArea()
            }
            .errorAlert($errorText)
            .confirmationDialog("Clear all locally cached data?", isPresented: $confirmingWipe,
                                titleVisibility: .visible) {
                Button("Clear Local Data", role: .destructive) {
                    env.wipeLocalData(context)
                    Task { await reloadAfterConfigChange() }
                }
            } message: {
                Text("Removes cached accounts, transactions, groups, and expenses on this device and signs "
                     + "you out. Your data stays on the backend and re-syncs after you sign in.")
            }
        }
    }

    @ViewBuilder
    private func urlField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
    }

    private func loadItems() async {
        items = (try? await env.plaid(context).items()) ?? items
    }

    private func reloadAfterConfigChange() async {
        await env.loadServerInfo()  // refresh the server name/reachability for the join link
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

    /// Global Plaid sync across all linked banks (moved here from the Accounts tab).
    private func syncBanks() {
        syncing = true
        Task {
            defer { syncing = false }
            do {
                try await env.plaid(context).sync()
                try await env.refreshAll(context)
                await loadItems()
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
            do {
                let token = try await env.plaid(context).linkToken(userIdentifier: me)
                PlaidLinkSession.shared.begin(token: token)  // persist so a terminated OAuth can resume
                linkSession = LinkSession(token: token)
            } catch { errorText = errorMessage(error) }
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

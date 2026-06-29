import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Account/session, backend base URL, bearer-token entry (Keychain), Splitwise status + import,
/// linked banks (Plaid), and a drill-through to the people roster.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(LinkSensitivity.storageKey) private var linkSensitivityRaw = LinkSensitivity.strict.rawValue
    @AppStorage("debug.categoryProvenance") private var showCategoryProvenance = false
    @State private var baseURL = ""
    @State private var pendingBaseURL = ""
    @State private var confirmingSwitch = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var importing = false
    @State private var importSummary: String?
    @State private var importingStatement = false
    @State private var statementBusy = false
    @State private var statementSummary: String?
    @State private var splitwiseConnectURL: IdentifiableURL?
    @State private var showingSignIn = false
    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var syncing = false
    @State private var syncSummary: String?
    @State private var invitesOpenToMembers = false
    @State private var errorText: String?
    @State private var linkDiagnostics = PlaidLinkDiagnosticsStore.shared

    struct LinkSession: Identifiable { let id = UUID(); let token: String }
    struct IdentifiableURL: Identifiable { let id = UUID(); let url: URL }

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
                        Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                        Button("Delete Account", role: .destructive) { confirmingDelete = true }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                        Button("Sign In…") { showingSignIn = true }
                    }
                }

                Section("Appearance") {
                    Picker(selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                    } label: {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                    }
                    NavigationLink {
                        CustomizeTabsView()
                    } label: {
                        Label("Customize Tabs", systemImage: "rectangle.3.group")
                    }
                }

                Section {
                    Picker("Link sensitivity", selection: $linkSensitivityRaw) {
                        ForEach(LinkSensitivity.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Suggestions")
                } footer: {
                    Text("How aggressively the Inbox suggests linking a bank charge to an expense. "
                         + "Looser shows more matches — you’ll still confirm each one before it links.")
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
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Button("Save") { saveBaseURL() }
                            .disabled(baseURL.trimmingCharacters(in: .whitespaces) == env.baseURLString)
                        Spacer()
                        if let serverURL = JoinLink.url(apiBaseURL: env.baseURLString, name: env.serverName) {
                            Button { UIPasteboard.general.url = serverURL } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .accessibilityLabel("Copy server link")
                            ShareLink(item: serverURL,
                                      preview: SharePreview(env.serverName ?? "SplitBack",
                                                            image: Image("AppLogo"))) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share server link")
                        }
                    }
                    .buttonStyle(.borderless)  // individually tappable in the Form row
                } header: {
                    Text("Server")
                } footer: {
                    Text(JoinLink.isPubliclyReachable(env.baseURLString)
                         ? "The SplitBack server this app is connected to. Use the copy/share icons to set it "
                           + "up on another of your devices."
                         : "The SplitBack server this app is connected to. This address only works on your "
                           + "local network — set a public (tunnel/HTTPS) Base URL before sharing.")
                }

                if env.currentUser?.isAdmin == true || invitesOpenToMembers {
                    Section {
                        NavigationLink {
                            InvitePeopleView()
                        } label: {
                            Label("Invite a Person", systemImage: "person.badge.plus")
                        }
                    } footer: {
                        Text("Create a single-use link that lets one new person sign in and join this server.")
                    }
                }

                // Operator-only: server settings + backups. Admins only.
                if env.currentUser?.isAdmin == true {
                    Section {
                        NavigationLink {
                            ServerSettingsView()
                        } label: {
                            Label("Server Settings", systemImage: "slider.horizontal.3")
                        }
                        NavigationLink {
                            BackupsView()
                        } label: {
                            Label("Backups", systemImage: "externaldrive")
                        }
                    }
                }

                Section("Plaid") {
                    NavigationLink {
                        ManageAccountsView(items: $items)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accounts")
                            Text("Banks, imported & manual").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
                        if let syncSummary {
                            Text(syncSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if env.currentUser == nil {
                        Text("Sign in to link a bank.").font(.caption).foregroundStyle(.secondary)
                    }
                    if linkDiagnostics.last != nil {
                        NavigationLink {
                            PlaidLinkDiagnosticsView()
                        } label: {
                            Label("Last Link Diagnostics", systemImage: "ladybug")
                        }
                    }
                }

                Section("Splitwise") {
                    // Status first (mirrors the Plaid section's Linked Banks row above the actions).
                    Label(env.splitwiseConnected ? "Connected" : "Not connected",
                          systemImage: env.splitwiseConnected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(env.splitwiseConnected ? .green : .secondary)
                    Button("Connect Splitwise", systemImage: "link") { connectSplitwise() }
                        .disabled(env.currentUser == nil)
                    Button("Run Import", action: runImport).disabled(importing)
                    if let importSummary {
                        Text(importSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Import Statement (.ofx)", systemImage: "doc.badge.plus") {
                        importingStatement = true
                    }.disabled(statementBusy)
                    if let statementSummary {
                        Text(statementSummary).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Bank Statements")
                } footer: {
                    Text("For accounts no aggregator supports (e.g. Apple Card): export a statement from "
                         + "Wallet and share it to SplitBack, or pick a saved .ofx file here.")
                }
                .fileImporter(isPresented: $importingStatement,
                              allowedContentTypes: [UTType(filenameExtension: "ofx") ?? .data]) { result in
                    importStatement(result)
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
                    NavigationLink {
                        PartnersView()
                    } label: {
                        Label("Partners", systemImage: "person.line.dotted.person")
                    }
                }

                Section("Spending") {
                    NavigationLink {
                        ManageCategoriesView()
                    } label: {
                        Label("Spending Categories", systemImage: "tag")
                    }
                    NavigationLink {
                        SubscriptionsView()
                    } label: {
                        Label("Subscriptions", systemImage: "repeat")
                    }
                    Toggle(isOn: $showCategoryProvenance) {
                        Label("Show category provenance", systemImage: "tag.circle")
                    }
                }

            }
            .navigationTitle("Settings")
            .task {
                env.prewarmPlaidLinkToken(context)  // background; never blocks this screen's load
                baseURL = env.baseURLString
                // Whether non-admins may invite (admins always can) — best-effort.
                if env.currentUser?.isAdmin != true {
                    invitesOpenToMembers = (try? await env.serverSettings.get().invites_open_to_members) ?? false
                }
                await env.refreshSplitwiseStatus()
                await loadItems()
            }
            .sheet(item: $splitwiseConnectURL, onDismiss: { Task { await env.refreshSplitwiseStatus() } }) { item in
                SafariView(url: item.url)
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
                    onExit: {
                        linkSession = nil
                        PlaidLinkSession.shared.finish()
                        env.prewarmPlaidLinkToken(context)  // ready a fresh token for a quick retry
                    }
                )
                .ignoresSafeArea()
            }
            .errorAlert($errorText)
            .confirmationDialog("Switch to this server?", isPresented: $confirmingSwitch,
                                titleVisibility: .visible) {
                Button("Switch", role: .destructive) {
                    env.setBaseURL(pendingBaseURL)   // load the new server's own token (if any)
                    env.eraseLocalCache(context)     // drop the old server's cached data so they don't mix
                    Task { await reloadAfterConfigChange() }
                }
            } message: {
                Text("Connects to the new server and clears locally cached accounts, transactions, groups, "
                     + "and expenses so prod and dev records don't mix. You stay signed in if you've used "
                     + "this server before — otherwise sign in again.")
            }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { env.signOut() }
            } message: {
                Text("You'll need to sign in again to use this server.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Account", role: .destructive, action: deleteAccount)
            } message: {
                Text("Permanently deletes your account and personal data — linked banks (revoked), "
                     + "transactions, budgets, and goals. Shared group expenses remain for the others. "
                     + "This can't be undone.")
            }
        }
    }

    private func deleteAccount() {
        guard let id = env.currentUser?.id else { return }
        Task {
            do {
                try await env.users(context).delete(id: id)
                env.wipeLocalData(context)   // clears the local cache + signs out
            } catch { errorText = errorMessage(error) }
        }
    }

    /// Saves the Base URL. When it names a *different* server, confirm first — switching clears the local
    /// cache + signs out (mirrors `AppEnvironment.adoptJoinLink`). The button is disabled when unchanged.
    private func saveBaseURL() {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard trimmed != env.baseURLString else { return }
        pendingBaseURL = trimmed
        confirmingSwitch = true
    }

    private func loadItems() async {
        items = (try? await env.plaid(context).items()) ?? items
    }

    private func reloadAfterConfigChange() async {
        await env.loadServerInfo()  // refresh the server name/reachability for the join link
        await env.refreshCurrentUser(context)  // reflect the new server's stored session (signed in or not)
        do { try await env.refreshAll(context) }
        catch { errorText = errorMessage(error) }
        await env.refreshSplitwiseStatus()
        await loadItems()
    }

    /// Starts the Splitwise connect flow: asks the backend (authenticated) for the authorize URL bound to the
    /// signed-in caller, then opens it. The bearer this request carries is how the token gets bound to you.
    private func connectSplitwise() {
        Task {
            do { splitwiseConnectURL = IdentifiableURL(url: try await env.splitwise.startConnect()) }
            catch { errorText = errorMessage(error) }
        }
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

    /// Import a picked OFX statement (the in-app alternative to the share-sheet flow).
    private func importStatement(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        statementBusy = true
        Task {
            defer { statementBusy = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let r = try await env.statements(context).importOFX(data)
                statementSummary = "Imported \(r.imported.formatted()) of \(r.total.formatted()) "
                    + "transaction\(r.total == 1 ? "" : "s") into \(r.account_name)."
            } catch { errorText = errorMessage(error) }
        }
    }

    /// Global Plaid sync across all linked banks (moved here from the Accounts tab).
    private func syncBanks() {
        syncing = true
        Task {
            defer { syncing = false }
            do {
                let stats = try await env.plaid(context).sync()
                syncSummary = Self.syncSummary(stats)
                try await env.refreshAll(context)
                await loadItems()
            } catch { errorText = errorMessage(error) }
        }
    }

    /// A one-line recap of a Plaid sync (mirrors the Splitwise import summary), e.g.
    /// "Synced 2 banks · 423 new, 12 updated." or "Synced 2 banks · already up to date."
    private static func syncSummary(_ stats: Components.Schemas.SyncResponse) -> String {
        let banks = "\(stats.items_synced) bank\(stats.items_synced == 1 ? "" : "s")"
        var parts: [String] = []
        if stats.added > 0 { parts.append("\(stats.added.formatted()) new") }
        if stats.modified > 0 { parts.append("\(stats.modified.formatted()) updated") }
        if stats.removed > 0 { parts.append("\(stats.removed.formatted()) removed") }
        return "Synced \(banks) · " + (parts.isEmpty ? "already up to date" : parts.joined(separator: ", "))
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
                // Use the pre-warmed token when ready (instant), else fetch on demand.
                let token: String
                if let cached = PlaidLinkTokenCache.shared.take(for: me) {
                    token = cached
                } else {
                    token = try await env.plaid(context).linkToken(userIdentifier: me)
                }
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
        syncing = true
        defer { syncing = false }
        do {
            // Slow client: exchange auto-syncs the new bank, which can backfill ~24 months.
            try await env.plaidSlow(context).exchange(publicToken: publicToken, userIdentifier: me)
            await loadItems()
        } catch { errorText = errorMessage(error) }
    }

}

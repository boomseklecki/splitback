import SwiftUI
import SwiftData

/// The finance side: linked banks (Plaid), cached accounts, a sync action, and a link to transactions.
struct AccountsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var syncing = false
    @State private var errorText: String?

    struct LinkSession: Identifiable { let id = UUID(); let token: String }

    var body: some View {
        NavigationStack {
            List {
                Section("Accounts") {
                    if accounts.isEmpty {
                        Text("No accounts yet.").foregroundStyle(.secondary)
                    }
                    ForEach(accounts) { account in
                        NavigationLink {
                            TransactionsView(account: account)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    if let type = account.type {
                                        Text(type).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(account.balance.formatted(.currency(code: account.currency)))
                            }
                        }
                    }
                }

                Section {
                    NavigationLink("All Transactions") { TransactionsView() }
                }

                Section("Linked Banks") {
                    ForEach(items, id: \.id) { item in
                        let count = item.accounts?.count ?? 0
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.institution_name ?? "Bank")
                            Text("\(count) account\(count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
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
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: sync) {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(syncing)
                }
            }
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
            .refreshable { await reload() }
            .task { await reload() }
            .errorAlert($errorText)
        }
    }

    private func reload() async {
        do { items = try await env.plaid(context).items() }
        catch { errorText = errorMessage(error) }
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
            await reload()
        } catch { errorText = errorMessage(error) }
    }

    private func sync() {
        syncing = true
        Task {
            defer { syncing = false }
            do { try await env.plaid(context).sync(); await reload() }
            catch { errorText = errorMessage(error) }
        }
    }

    private func unlink(_ offsets: IndexSet) {
        let ids = offsets.compactMap { UUID(uuidString: items[$0].id) }
        Task {
            do {
                for id in ids { try await env.plaid(context).deleteItem(id: id) }
                await reload()
            } catch { errorText = errorMessage(error) }
        }
    }
}

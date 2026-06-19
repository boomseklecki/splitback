import SwiftUI
import SwiftData

/// The finance side: linked banks (Plaid), cached accounts, a sync action, and a link to transactions.
struct AccountsView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case balance = "Balance"
        case lastTransaction = "Last transaction"
        case type = "Type"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]

    @AppStorage("accounts.sortMode") private var sortModeRaw = SortMode.balance.rawValue

    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    @State private var linkSession: LinkSession?
    @State private var linking = false
    @State private var syncing = false
    @State private var errorText: String?
    /// Latest transaction date per account (account id → date), for the last-transaction sort. Loaded
    /// on demand with a `fetchLimit: 1` query per account.
    @State private var lastTransaction: [UUID: Date] = [:]

    struct LinkSession: Identifiable { let id = UUID(); let token: String }

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .balance }

    /// Type sections, in display order. Each renders only when it has accounts.
    private static let typeSections: [(title: String, kind: AccountKind)] = [
        ("Cash-flow", .cashFlow), ("Liabilities", .liability), ("Holdings", .holdings),
    ]

    private func byBalance(_ list: [Account]) -> [Account] {
        list.sorted { $0.balance > $1.balance }
    }
    private func byLastTransaction(_ list: [Account]) -> [Account] {
        list.sorted { (lastTransaction[$0.id] ?? .distantPast) > (lastTransaction[$1.id] ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if accounts.isEmpty {
                    Section("Accounts") {
                        Text("No accounts yet.").foregroundStyle(.secondary)
                    }
                } else if sortMode == .type {
                    ForEach(Self.typeSections, id: \.title) { section in
                        let items = byBalance(accounts.filter { AccountKind.classify($0.type) == section.kind })
                        if !items.isEmpty {
                            Section(section.title) {
                                ForEach(items) { accountRow($0) }
                            }
                        }
                    }
                } else {
                    Section("Accounts") {
                        let sorted = sortMode == .balance ? byBalance(accounts) : byLastTransaction(accounts)
                        ForEach(sorted) { accountRow($0) }
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
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort by", selection: $sortModeRaw) {
                            ForEach(SortMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
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

    @ViewBuilder
    private func accountRow(_ account: Account) -> some View {
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

    private func reload() async {
        do { items = try await env.plaid(context).items() }
        catch { errorText = errorMessage(error) }
        loadLastTransactions()
    }

    /// Loads each account's most-recent transaction date with a single-row fetch per account, for the
    /// last-transaction sort. Reads the local cache, so it reflects the last sync.
    private func loadLastTransactions() {
        var result: [UUID: Date] = [:]
        for account in accounts {
            let aid = account.id
            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.accountId == aid },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            if let latest = try? context.fetch(descriptor).first {
                result[account.id] = latest.date
            }
        }
        lastTransaction = result
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

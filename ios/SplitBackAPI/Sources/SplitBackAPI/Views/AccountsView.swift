import SwiftUI
import SwiftData

/// The finance side: cached accounts (sortable), a sync action, and a link to transactions. Linking
/// and managing banks lives in Settings → Linked Banks.
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

    @State private var errorText: String?
    @State private var showingManual = false
    @State private var linkSession: LinkSession?
    @State private var linking = false
    /// Latest transaction date per account (account id → date), for the last-transaction sort. Loaded
    /// on demand with a `fetchLimit: 1` query per account.
    @State private var lastTransaction: [UUID: Date] = [:]

    struct LinkSession: Identifiable { let id = UUID(); let token: String }

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .balance }

    /// Type sections, in display order. Each renders only when it has accounts.
    private static let typeSections: [(title: String, kind: AccountKind)] = [
        ("Cash-flow", .cashFlow), ("Liabilities", .liability), ("Savings", .holdings),
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
                        Text("No accounts yet. Link a bank in Settings.").foregroundStyle(.secondary)
                    }
                } else if sortMode == .type {
                    ForEach(Self.typeSections, id: \.title) { section in
                        let items = byBalance(accounts.filter { $0.kind == section.kind })
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
                    Menu {
                        Button("Blank Transaction", systemImage: "square.and.pencil") { showingManual = true }
                        Divider()
                        Button("Link Bank", systemImage: "building.columns") { linkBank() }
                            .disabled(linking || env.currentUser == nil)
                    } label: {
                        Image(systemName: linking ? "ellipsis" : "plus")
                    }
                }
            }
            .sheet(isPresented: $showingManual) { ManualTransactionView() }
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
                    Text(account.displayLabel)
                    Text(account.kind.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.balance.formatted(.currency(code: account.currency)))
                    .foregroundStyle(account.kind.balanceColor)
            }
        }
    }

    /// Pull-to-refresh / on-appear: refresh cached accounts from the backend, then recompute the
    /// last-transaction dates. The Sync button does the heavier Plaid round-trip.
    private func reload() async {
        do { try await env.accounts(context).refreshAccounts() }
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

    /// Start Plaid Link to add a bank (the global bank Sync now lives in Settings → Linked Banks).
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
        guard let me = env.currentUser?.identifier else { return }
        do {
            try await env.plaid(context).exchange(publicToken: publicToken, userIdentifier: me)
            await reload()
        } catch { errorText = errorMessage(error) }
    }
}

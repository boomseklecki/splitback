import SwiftUI
import SwiftData

/// The finance side: cached accounts (sortable), a sync action, and a link to transactions. Linking
/// and managing banks lives in Settings → Linked Banks.
struct AccountsView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case balance = "Balance"
        case lastTransaction = "Last transaction"
        case type = "Type"
        case bank = "Bank"
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
    /// Plaid items (bank → its accounts), loaded lazily for the Bank sort only.
    @State private var items: [Components.Schemas.PlaidItemResponse] = []
    /// Partner-owned accounts shared *to* you (live-fetched, never cached so they stay out of analytics).
    @State private var sharedAccounts: [Components.Schemas.AccountResponse] = []

    struct LinkSession: Identifiable { let id = UUID(); let token: String }

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .balance }

    /// Type sections, in display order. Each renders only when it has accounts.
    private static let typeSections: [(title: String, kind: AccountKind)] = [
        ("Cash-flow", .cashFlow), ("Liabilities", .liability), ("Savings", .holdings),
    ]

    private func byBalance(_ list: [Account]) -> [Account] {
        list.sorted { $0.balance > $1.balance }
    }

    /// Accounts grouped by their Plaid institution for the Bank sort: one `(bank, accounts)` group per
    /// item (alphabetical, balance-desc within), plus a trailing "Other" group for accounts not covered
    /// by any item (manual, or before `items` has loaded). Empty groups are dropped.
    private var bankGroups: [(title: String, domain: String?, accounts: [Account])] {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var covered = Set<UUID>()
        var groups: [(title: String, domain: String?, accounts: [Account])] = []
        let sortedItems = items.sorted {
            ($0.institution_name ?? "Bank").localizedCaseInsensitiveCompare($1.institution_name ?? "Bank")
                == .orderedAscending
        }
        for item in sortedItems {
            let linked = (item.accounts ?? []).compactMap { UUID(uuidString: $0.id).flatMap { byId[$0] } }
            linked.forEach { covered.insert($0.id) }
            if !linked.isEmpty {
                groups.append((item.institution_name ?? "Bank", item.institution_domain, byBalance(linked)))
            }
        }
        let other = accounts.filter { !covered.contains($0.id) }
        if !other.isEmpty { groups.append(("Other", nil, byBalance(other))) }
        return groups
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
                                ForEach(items) { accountRow($0, byType: true) }
                            }
                        }
                    }
                } else if sortMode == .bank {
                    ForEach(bankGroups, id: \.title) { group in
                        Section {
                            ForEach(group.accounts) { accountRow($0, inBank: true) }
                        } header: {
                            HStack(spacing: 8) {
                                AvatarView(url: InstitutionBrand.logoURL(domain: group.domain, name: group.title),
                                           name: group.title, size: 22,
                                           systemImage: "building.columns", logo: true)
                                Text(group.title).textCase(nil)
                            }
                        }
                    }
                } else {
                    Section("Accounts") {
                        let sorted = sortMode == .balance ? byBalance(accounts) : byLastTransaction(accounts)
                        ForEach(sorted) { accountRow($0) }
                    }
                }

                if !sharedAccounts.isEmpty {
                    Section("Shared with you") {
                        ForEach(sharedAccounts, id: \.id) { sharedRow($0) }
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
                    onExit: {
                        linkSession = nil
                        PlaidLinkSession.shared.finish()
                        env.prewarmPlaidLinkToken(context)  // ready a fresh token for a quick retry
                    }
                )
                .ignoresSafeArea()
            }
            .refreshable { await reload() }
            .task {
                env.prewarmPlaidLinkToken(context)  // background; + menu's "Link Bank" opens without the wait
                await reload()
            }
            .onChange(of: sortModeRaw) { _, new in
                if new == SortMode.bank.rawValue && items.isEmpty { Task { await loadItems() } }
            }
            .errorAlert($errorText)
        }
    }

    @ViewBuilder
    private func accountRow(_ account: Account, inBank: Bool = false, byType: Bool = false) -> some View {
        // Bank sections show type + mask; Type sections already convey the type, so show bank + mask there
        // (not the type again); other sorts show bank + type.
        let caption: String = inBank
            ? account.kind.label + (account.maskLabel.map { " · \($0)" } ?? "")
            : byType
                ? [account.institutionName, account.maskLabel].compactMap { $0 }.joined(separator: " · ")
                : [account.institutionName, account.kind.label].compactMap { $0 }.joined(separator: " · ")
        NavigationLink {
            TransactionsView(account: account)
        } label: {
            HStack(spacing: 12) {
                if !inBank {
                    AvatarView(url: account.institutionLogoURL,
                               name: account.institutionName ?? account.displayLabel, size: 32,
                               systemImage: "building.columns", logo: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayLabel)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.balance.formatted(.currency(code: account.currency)))
                    .foregroundStyle(account.kind.balanceColor)
            }
        }
    }

    /// A partner-shared account row. A `full` account drills into a read-only, live-fetched transaction
    /// list; a `balances` account shows the balance only (no drill-in). Never enters the local cache.
    @ViewBuilder
    private func sharedRow(_ r: Components.Schemas.AccountResponse) -> some View {
        let balance = (try? Mapping.decimal(r.balance, field: "Account.balance")) ?? 0
        let label = HStack(spacing: 12) {
            AvatarView(url: InstitutionBrand.logoURL(domain: r.institution_domain, name: r.institution_name),
                       name: r.institution_name ?? r.name, size: 32,
                       systemImage: "building.columns", logo: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.display_name ?? r.name)
                Text("Shared by \(r.shared_by ?? "partner")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(balance.formatted(.currency(code: r.currency)))
        }
        if r.share_level == "full" {
            NavigationLink {
                SharedAccountTransactionsView(account: r)
            } label: { label }
        } else {
            label
        }
    }

    /// Pull-to-refresh / on-appear: refresh cached accounts from the backend, then recompute the
    /// last-transaction dates. The Sync button does the heavier Plaid round-trip.
    private func reload() async {
        await env.smartRefresh(source: .bank,
                               freshness: accounts.map(\.updatedAt).max(), context: context) {
            try await env.accounts(context).refreshAccounts()
        }
        loadLastTransactions()
        sharedAccounts = (try? await env.accounts(context).sharedInAccounts()) ?? sharedAccounts
        if sortMode == .bank { await loadItems() }
    }

    /// Fetches the Plaid items (bank → accounts) used by the Bank sort. Best-effort; keeps the prior list
    /// on failure so the grouping doesn't collapse offline.
    private func loadItems() async {
        items = (try? await env.plaid(context).items()) ?? items
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
        guard let me = env.currentUser?.identifier else { return }
        do {
            // Slow client: exchange auto-syncs the new bank, which can backfill ~24 months.
            try await env.plaidSlow(context).exchange(publicToken: publicToken, userIdentifier: me)
            await reload()
        } catch { errorText = errorMessage(error) }
    }
}

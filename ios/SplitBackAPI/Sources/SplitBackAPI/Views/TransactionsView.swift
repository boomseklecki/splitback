import SwiftUI
import SwiftData

/// Cached transactions (date-desc). Add a manual transaction, or turn any transaction into an expense.
struct TransactionsView: View {
    let account: Account?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]

    @State private var showingManual = false
    @State private var errorText: String?

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }

    init(account: Account? = nil) {
        self.account = account
        if let accountId = account?.id {
            _transactions = Query(
                filter: #Predicate<Transaction> { $0.accountId == accountId },
                sort: \Transaction.date, order: .reverse
            )
        } else {
            _transactions = Query(sort: \Transaction.date, order: .reverse)
        }
    }

    var body: some View {
        // Build the raw→canonical map ONCE per render. Referencing the `lookup` computed property from
        // inside the row closure rebuilt this dictionary for every transaction — O(rows × maps) of
        // dictionary construction on the main thread, which froze long lists.
        let lookup = self.lookup
        return List {
            if let account {
                AccountSummaryHeader(account: account, transactions: transactions)
            }
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions", systemImage: "list.bullet.rectangle",
                    description: Text(account == nil
                        ? "Sync a linked bank or add one manually."
                        : "No transactions for this account yet.")
                )
            }
            ForEach(transactions) { transaction in
                NavigationLink {
                    TransactionDetailView(transaction: transaction)
                } label: {
                    let category = CategoryMapping.effectiveCategory(for: transaction, lookup: lookup)
                    HStack(spacing: 12) {
                        Image(systemName: categorySymbol(category))
                            .foregroundStyle(categoryColor(category)).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.details).foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                                if let category { Text("· \(category)") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(transaction.amount.formatted(.currency(code: transaction.currency)))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .navigationTitle(account?.name ?? "Transactions")
        .toolbar {
            if account == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingManual = true } label: { Image(systemName: "plus") }
                }
            } else if let account {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Goals") {
                            Toggle("Include in spending", isOn: Binding(
                                get: { account.countsInSpending },
                                set: { setFlags(account, includeInSpending: $0) }))
                            Toggle("Include in cash flow", isOn: Binding(
                                get: { account.countsInCashFlow },
                                set: { setFlags(account, includeInCashFlow: $0) }))
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showingManual) { ManualTransactionView() }
        .refreshable {
            do { try await env.accounts(context).refreshTransactions(accountId: account?.id) }
            catch { errorText = errorMessage(error) }
        }
        .errorAlert($errorText)
    }

    /// Persists one inclusion override (the unspecified flag is left untouched server-side).
    private func setFlags(_ account: Account, includeInSpending: Bool? = nil,
                          includeInCashFlow: Bool? = nil) {
        Task {
            do {
                try await env.accounts(context).updateFlags(
                    id: account.id, includeInSpending: includeInSpending,
                    includeInCashFlow: includeInCashFlow)
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// A minimal manual-transaction form (source = manual on the backend).
/// A manual (cash/self-entered) transaction. Conforms to our other forms: a tappable category icon
/// top-left, plus an optional account. Categorized manual transactions count toward budgets/Trends.
struct ManualTransactionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var details = ""
    @State private var amountString = ""
    @State private var date = Date()
    @State private var category: String?
    @State private var accountId: UUID?
    @State private var showingCategoryPicker = false
    @State private var saving = false
    @State private var errorText: String?

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var canSave: Bool { !details.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button { showingCategoryPicker = true } label: {
                            Image(systemName: categorySymbol(category))
                                .font(.title3).foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                        TextField("Description", text: $details).font(.title3)
                    }
                    HStack(spacing: 8) {
                        Text("$").font(.title2).foregroundStyle(.secondary)
                        TextField("0.00", text: $amountString).keyboardType(.decimalPad).font(.title2)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                Section {
                    Picker("Account", selection: $accountId) {
                        Text("None (cash)").tag(UUID?.none)
                        ForEach(accounts) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } footer: {
                    Text("Optional — scope it to an account, or leave as cash. Either way it counts toward your budgets by category.")
                }
            }
            .navigationTitle("Manual Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).disabled(!canSave) }
            }
            .sheet(isPresented: $showingCategoryPicker) {
                CategoryPickerView(current: category) { category = $0 }
            }
            .errorAlert($errorText)
        }
    }

    private func save() {
        saving = true
        let draft = TransactionDraft(accountId: accountId, details: details, amount: amount,
                                     date: date, category: category)
        Task {
            defer { saving = false }
            do {
                try await env.accounts(context).createTransaction(draft)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// Pick a group, then open the expense editor prefilled from the transaction (links via transaction_id).
/// The group list hides settled groups and sorts by recent activity, matching the Expenses tab.
/// Presented from `TransactionDetailView`'s "Add to a Group".
struct NewExpenseFromTransactionView: View {
    let transaction: Transaction

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ExpenseGroup> { $0.archivedAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query private var members: [GroupMember]
    @State private var selectedGroupId: UUID?
    @State private var showingEditor = false
    @State private var showSettled = false
    @State private var myNets: [UUID: Decimal] = [:]
    @State private var lastExpense: [UUID: GroupSummary.Last] = [:]

    private var selectedGroup: ExpenseGroup? { groups.first { $0.id == selectedGroupId } }
    private var memberIdentifiers: [String] {
        members.filter { $0.groupId == selectedGroupId }.map(\.userIdentifier)
    }

    private var hiddenCount: Int {
        groups.filter { GroupSummary.isSettled($0, myNets: myNets, lastExpense: lastExpense) }.count
    }
    private var visibleGroups: [ExpenseGroup] {
        GroupSummary.visible(groups, myNets: myNets, lastExpense: lastExpense, includeSettled: showSettled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    Picker("Group", selection: $selectedGroupId) {
                        Text("Select a group").tag(UUID?.none)
                        ForEach(visibleGroups) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    if hiddenCount > 0 || showSettled {
                        Toggle("Show settled groups", isOn: $showSettled)
                    }
                }
                Section("Transaction") {
                    LabeledContent("Description", value: transaction.details)
                    LabeledContent("Amount", value: transaction.amount.formatted(.currency(code: transaction.currency)))
                    LabeledContent("Date", value: transaction.date.formatted(date: .abbreviated, time: .omitted))
                }
                Section {
                    Button("Create Expense") { showingEditor = true }.disabled(selectedGroupId == nil)
                }
            }
            .navigationTitle("From Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                myNets = await GroupSummary.myNets(groups, me: env.currentUser?.identifier, balances: env.balances)
                loadLastExpenses()
            }
            .onChange(of: showSettled) { _, _ in loadLastExpenses() }
            .sheet(isPresented: $showingEditor) {
                if let selectedGroup {
                    ExpenseEditView(group: selectedGroup, members: memberIdentifiers,
                                    prefill: .from(transaction))
                }
            }
        }
    }

    private func loadLastExpenses() {
        lastExpense = GroupSummary.lastExpenses(groups, myNets: myNets, includeSettled: showSettled, context: context)
    }
}

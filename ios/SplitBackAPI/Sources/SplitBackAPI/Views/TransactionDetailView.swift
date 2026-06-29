import SwiftUI
import SwiftData

/// Drill-through detail for a single bank/manual transaction: a header with a tappable category icon
/// (like the expense detail), the transaction's fields, an on-device "categorize this one" action, and
/// a button that continues to the prefilled expense-creation flow (or links to the expense already made
/// from it). Recategorizing here writes a per-transaction override, independent of the Plaid label.
struct TransactionDetailView: View {
    let transaction: Transaction

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]
    @Query private var accounts: [Account]
    @Query private var subscriptionRules: [SubscriptionRule]

    @State private var showingCategoryPicker = false
    @State private var showingCreate = false
    @State private var showingLinkExpense = false
    @State private var showingItems = false
    @State private var categorizing = false
    @State private var aiAvailable = false
    @State private var errorText: String?
    /// "This transaction already posted" flow: set when a customize action 404s on a pending row. `postedTwin`
    /// is the posted replacement (matched by `pendingTransactionId`), if we found it; `showingPosted` drives
    /// the prompt; `showingTwin` opens the twin in a sheet. `sheetDetectedGone` relays the signal from the
    /// items/link child sheets so we trigger the prompt only after the sheet has dismissed (no alert/sheet race).
    @State private var postedTwin: Transaction?
    @State private var showingPosted = false
    @State private var showingTwin = false
    @State private var sheetDetectedGone = false
    /// The expense linked to this transaction, loaded off the render path (see `loadLinkedExpense`). A
    /// body-time `@Query` over the expenses table blocked the navigation push on large datasets.
    @State private var linkedExpense: Expense?
    @AppStorage("debug.categoryProvenance") private var showProvenance = false

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var sources: [String: String] { CategoryMapping.sources(categoryMaps) }
    private var resolution: CategoryResolution {
        CategoryMapping.resolve(for: transaction, lookup: lookup, sources: sources)
    }
    private var effectiveCategory: String? { resolution.category }

    /// The account this transaction belongs to (for the name). Filtered in memory from the observed
    /// query — never fetch from the context during `body`, which loops the view.
    private var account: Account? {
        guard let id = transaction.accountId else { return nil }
        return accounts.first { $0.id == id }
    }

    /// This transaction's line items in entry order.
    private var itemsByAdded: [TransactionItem] {
        transaction.items.sorted { ($0.addedOn ?? .distantPast) < ($1.addedOn ?? .distantPast) }
    }

    /// The raw Plaid label, humanized, shown only when it differs from the effective category.
    private var rawLabel: String? {
        guard let raw = transaction.category, !raw.isEmpty else { return nil }
        let humanized = PlaidCategory.humanized(raw)
        return humanized == effectiveCategory ? nil : humanized
    }

    private var amountText: String { transaction.amount.formatted(.currency(code: transaction.currency)) }

    /// This transaction's merchant key + any matching subscription rule (for the Mark-as-Subscription row).
    private var subscriptionMerchantKey: String { SubscriptionDetector.merchantKey(transaction.details) }
    private var subscriptionRule: SubscriptionRule? {
        subscriptionRules.first {
            $0.merchantKey == subscriptionMerchantKey
                && SubscriptionDetector.matches(amount: transaction.amount, rule: $0)
        }
    }

    var body: some View {
        List {
            Section { header }

            Section("Details") {
                LabeledContent("Description", value: transaction.details)
                LabeledContent("Amount", value: amountText)
                LabeledContent("Date", value: transaction.date.formatted(date: .abbreviated, time: .omitted))
                if let account { LabeledContent("Account", value: account.name) }
                LabeledContent("Status", value: transaction.pending ? "Pending" : "Posted")
                LabeledContent("Source", value: transaction.source == .plaid ? "Bank" : "Manual")
                if let rawLabel { LabeledContent("Bank category", value: rawLabel) }
                LabeledContent("Updated", value: transaction.updatedAt.relativeUpdated)
            }

            Section("Category") {
                if aiAvailable {
                    Button {
                        Task { await categorizeWithAI() }
                    } label: {
                        Label(categorizing ? "Categorizing…" : "Categorize with Apple Intelligence",
                              systemImage: "sparkles")
                    }
                    .disabled(categorizing)
                }
                if transaction.categoryOverride != nil {
                    Button("Reset to Automatic", role: .destructive) {
                        setOverride(nil)
                    }
                }
            }

            Section {
                Toggle("Include in spending", isOn: Binding(
                    get: { transaction.includeInSpending ?? account?.countsInSpending ?? true },
                    set: { setFlags(includeInSpending: $0) }))
                Toggle("Include in cash flow", isOn: Binding(
                    get: { transaction.includeInCashFlow ?? account?.countsInCashFlow ?? true },
                    set: { setFlags(includeInCashFlow: $0) }))
            } header: {
                Text("Budget")
            } footer: {
                Text("Turn off to keep this transaction out of spending / cash flow and Trends. Doesn't change "
                     + "any balances.")
            }

            Section {
                NavigationLink {
                    DescriptionDetailView(seedDescription: transaction.details, seedCategory: effectiveCategory,
                                          seedAmount: transaction.amount)
                } label: {
                    Label("Find Related Transactions", systemImage: "text.magnifyingglass")
                }
            } footer: {
                Text("Group bank/manual transactions with a similar description and recategorize them together.")
            }

            if transaction.amount > 0 {
                Section {
                    if let rule = subscriptionRule {
                        Button(rule.isSubscription ? "Remove from Subscriptions" : "Remove Exclusion",
                               role: .destructive) {
                            context.delete(rule)
                            do { try context.save() } catch { errorText = errorMessage(error) }
                        }
                    } else {
                        Button { markAsSubscription() } label: {
                            Label("Mark as Subscription", systemImage: "repeat")
                        }
                    }
                } footer: {
                    Text("Track this recurring charge in Subscriptions (matches this merchant near this amount).")
                }
            }

            if transaction.amount > 0 {
                Section {
                    ForEach(itemsByAdded, id: \.id) { item in
                        let itemCategory = item.category.flatMap { CategoryMapping.canonical($0, lookup: lookup) }
                        HStack(spacing: 12) {
                            Image(systemName: categorySymbol(itemCategory))
                                .foregroundStyle(categoryColor(itemCategory)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                Text(itemCategory ?? "Uncategorized")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.price.formatted(.currency(code: transaction.currency)))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button {
                        showingItems = true
                    } label: {
                        Label(transaction.items.isEmpty ? "Itemize…" : "Edit Items",
                              systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text("Split this transaction across categories by line item — counts toward your budgets and Trends per item.")
                }
            }

            Section {
                if let expense = linkedExpense {
                    NavigationLink {
                        LazyView(ExpenseDetailView(expense: expense))
                    } label: {
                        Label("View Expense", systemImage: "arrow.up.right.square")
                    }
                } else {
                    Button {
                        showingCreate = true
                    } label: {
                        Label("Add to a Group", systemImage: "plus.circle")
                    }
                    Button {
                        showingLinkExpense = true
                    } label: {
                        Label("Link Existing Expense", systemImage: "link")
                    }
                }
            } footer: {
                if linkedExpense == nil {
                    Text("Turn this transaction into a shared expense, or link one you already have so it "
                         + "isn't double-counted in spending.")
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {  // leaf: always live-sync this transaction's bank (if any), then reconcile
            let pid = accounts.first { $0.id == transaction.accountId }?.plaidItemId
            await env.smartRefresh(source: pid != nil ? .bank : .none,
                                   freshness: transaction.updatedAt, plaidItemId: pid, context: context) {
                try await env.accounts(context).refreshTransactions(accountId: transaction.accountId)
            }
        }
        .task {
            aiAvailable = CategoryMapper.isAvailable
            loadLinkedExpense()
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: effectiveCategory) { setOverride($0) }
        }
        // Re-resolve the linked expense after creating/linking one (no @Query to auto-update now).
        .sheet(isPresented: $showingCreate, onDismiss: handleSheetDismiss) {
            NewExpenseFromTransactionView(transaction: transaction) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $showingLinkExpense, onDismiss: handleSheetDismiss) {
            ExpenseLinkPickerView(transaction: transaction) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $showingItems, onDismiss: handleSheetDismiss) {
            TransactionItemsView(transaction: transaction) { sheetDetectedGone = true }
        }
        .sheet(isPresented: $showingTwin) {
            if let twin = postedTwin {
                NavigationStack { TransactionDetailView(transaction: twin) }
            }
        }
        .alert("This transaction has already posted", isPresented: $showingPosted) {
            if postedTwin != nil {
                Button("View posted transaction") { showingTwin = true }
            }
            Button("Back to account", role: .cancel) { dismiss() }
        } message: {
            Text(postedTwin != nil
                 ? "Your change wasn’t saved here — this pending charge posted as a new transaction. Open it to make the change there."
                 : "Your change wasn’t saved here — this pending charge posted as a new transaction. It’ll appear in your account in a moment.")
        }
        .errorAlert($errorText)
    }

    /// Header mirroring the expense detail: tappable category icon (→ picker), amount, category, date.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { showingCategoryPicker = true } label: {
                Image(systemName: categorySymbol(effectiveCategory))
                    .font(.title2)
                    .foregroundStyle(categoryColor(effectiveCategory))
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .background(Circle().fill(Color(.systemBackground)))
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(amountText).font(.title2).fontWeight(.semibold)
                HStack(spacing: 6) {
                    Text(effectiveCategory ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
                    CategoryProvenanceBadge(source: resolution.source)
                }
                if showProvenance {
                    Text(resolution.inspectorString)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Fetch the linked expense with a scoped, single-row descriptor — off the body/render path so opening
    /// the detail never blocks on the expenses table.
    private func loadLinkedExpense() {
        let tid = transaction.id
        var descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.transactionId == tid })
        descriptor.fetchLimit = 1
        linkedExpense = (try? context.fetch(descriptor))?.first
    }

    /// Force this merchant into Subscriptions (an include rule keyed by merchant + this amount).
    private func markAsSubscription() {
        let name = subscriptionMerchantKey
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        context.insert(SubscriptionRule(merchantKey: subscriptionMerchantKey, amount: transaction.amount,
                                        isSubscription: true,
                                        displayName: name.isEmpty ? transaction.details : name))
        do { try context.save() } catch { errorText = errorMessage(error) }
    }

    private func setOverride(_ category: String?) {
        let id = transaction.id
        Task {
            do { try await env.accounts(context).setCategoryOverride(id: id, category: category) }
            catch { await handleCustomizeError(error) }
        }
    }

    private func setFlags(includeInSpending: Bool? = nil, includeInCashFlow: Bool? = nil) {
        let id = transaction.id
        Task {
            do {
                try await env.accounts(context).setTransactionFlags(
                    id: id, includeInSpending: includeInSpending, includeInCashFlow: includeInCashFlow)
            } catch { await handleCustomizeError(error) }
        }
    }

    /// A customize action failed. If it's a pending row that the server no longer has, the charge posted —
    /// run the "already posted" flow instead of a generic error.
    private func handleCustomizeError(_ error: Error) async {
        if transaction.pending, (error as? BackendError) == .notFound {
            await handlePosted()
        } else {
            errorText = errorMessage(error)
        }
    }

    /// Refresh (upsert-only, so we don't reap THIS still-displayed row), locate the posted twin by the
    /// pending charge's plaid id, and raise the prompt.
    private func handlePosted() async {
        try? await env.accounts(context).refreshTransactions(accountId: transaction.accountId)
        if let p1 = transaction.plaidTransactionId {
            var descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate { $0.pendingTransactionId == p1 && !$0.pending })
            descriptor.fetchLimit = 1
            postedTwin = (try? context.fetch(descriptor))?.first
        }
        showingPosted = true
    }

    /// After an items/link child sheet dismisses, relay its "transaction gone" signal into the posted flow.
    private func handleSheetDismiss() {
        loadLinkedExpense()
        guard sheetDetectedGone else { return }
        sheetDetectedGone = false
        Task { await handlePosted() }
    }

    private func categorizeWithAI() async {
        categorizing = true
        defer { categorizing = false }
        let item = CategoryMapper.Item(id: transaction.id, description: transaction.details,
                                       rawCategory: transaction.category, current: nil)
        let result = await CategoryMapper.refine([item], allowed: spendCategories.map(\.name))
        guard let category = result[transaction.id] else { return }  // keep prior if the model abstains
        setOverride(category)
    }
}

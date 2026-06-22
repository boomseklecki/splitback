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
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]
    @Query private var accounts: [Account]

    @State private var showingCategoryPicker = false
    @State private var showingCreate = false
    @State private var showingLinkExpense = false
    @State private var showingItems = false
    @State private var categorizing = false
    @State private var aiAvailable = false
    @State private var errorText: String?
    /// The expense linked to this transaction, loaded off the render path (see `loadLinkedExpense`). A
    /// body-time `@Query` over the expenses table blocked the navigation push on large datasets.
    @State private var linkedExpense: Expense?

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var effectiveCategory: String? {
        CategoryMapping.effectiveCategory(for: transaction, lookup: lookup)
    }

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

            if transaction.amount > 0 {
                Section {
                    ForEach(itemsByAdded, id: \.id) { item in
                        HStack(spacing: 12) {
                            Image(systemName: categorySymbol(item.category))
                                .foregroundStyle(categoryColor(item.category)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                Text(item.category ?? "Uncategorized")
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
        .task {
            aiAvailable = CategoryMapper.isAvailable
            loadLinkedExpense()
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: effectiveCategory) { setOverride($0) }
        }
        // Re-resolve the linked expense after creating/linking one (no @Query to auto-update now).
        .sheet(isPresented: $showingCreate, onDismiss: loadLinkedExpense) {
            NewExpenseFromTransactionView(transaction: transaction)
        }
        .sheet(isPresented: $showingLinkExpense, onDismiss: loadLinkedExpense) {
            ExpenseLinkPickerView(transaction: transaction)
        }
        .sheet(isPresented: $showingItems) {
            TransactionItemsView(transaction: transaction)
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
                Text(effectiveCategory ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
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

    private func setOverride(_ category: String?) {
        let id = transaction.id
        Task {
            do { try await env.accounts(context).setCategoryOverride(id: id, category: category) }
            catch { errorText = errorMessage(error) }
        }
    }

    private func categorizeWithAI() async {
        categorizing = true
        defer { categorizing = false }
        let item = CategoryMapper.Item(id: transaction.id, description: transaction.details,
                                       rawCategory: transaction.category)
        let result = await CategoryMapper.refine([item], allowed: spendCategories.map(\.name))
        guard let category = result[transaction.id] else { return }  // keep prior if the model abstains
        setOverride(category)
    }
}

import SwiftUI
import SwiftData

/// Cached transactions (date-desc). Add a manual transaction, or turn any transaction into an expense.
struct TransactionsView: View {
    let account: Account?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]

    @State private var showingManual = false
    @State private var selected: Transaction?
    @State private var errorText: String?

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
        List {
            if transactions.isEmpty {
                ContentUnavailableView(
                    "No Transactions", systemImage: "list.bullet.rectangle",
                    description: Text(account == nil
                        ? "Sync a linked bank or add one manually."
                        : "No transactions for this account yet.")
                )
            }
            ForEach(transactions) { transaction in
                Button { selected = transaction } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.details).foregroundStyle(.primary)
                            Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
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
            }
        }
        .sheet(isPresented: $showingManual) { ManualTransactionView() }
        .sheet(item: $selected) { NewExpenseFromTransactionView(transaction: $0) }
        .refreshable {
            do { try await env.accounts(context).refreshTransactions(accountId: account?.id) }
            catch { errorText = errorMessage(error) }
        }
        .errorAlert($errorText)
    }
}

/// A minimal manual-transaction form (source = manual on the backend).
private struct ManualTransactionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var details = ""
    @State private var amountString = ""
    @State private var date = Date()
    @State private var saving = false
    @State private var errorText: String?

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var canSave: Bool { !details.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 && !saving }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Description", text: $details)
                TextField("Amount", text: $amountString).keyboardType(.decimalPad)
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("Manual Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: save).disabled(!canSave) }
            }
            .errorAlert($errorText)
        }
    }

    private func save() {
        saving = true
        let draft = TransactionDraft(details: details, amount: amount, date: date)
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
private struct NewExpenseFromTransactionView: View {
    let transaction: Transaction

    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ExpenseGroup> { $0.archivedAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query private var members: [GroupMember]
    @State private var selectedGroupId: UUID?
    @State private var showingEditor = false

    private var selectedGroup: ExpenseGroup? { groups.first { $0.id == selectedGroupId } }
    private var memberIdentifiers: [String] {
        members.filter { $0.groupId == selectedGroupId }.map(\.userIdentifier)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    Picker("Group", selection: $selectedGroupId) {
                        Text("Select a group").tag(UUID?.none)
                        ForEach(groups) { Text($0.name).tag(UUID?.some($0.id)) }
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
            .sheet(isPresented: $showingEditor) {
                if let selectedGroup {
                    ExpenseEditView(group: selectedGroup, members: memberIdentifiers,
                                    prefill: .from(transaction))
                }
            }
        }
    }
}

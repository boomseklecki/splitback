import SwiftUI
import SwiftData

/// "Link a transaction" for an expense: on-device ranked suggestions (heuristic, re-ranked by Apple
/// Intelligence when available) plus a searchable browse of all transactions. Picking one links it so
/// spending counts your share of the expense once instead of both it and the gross transaction.
struct TransactionMatchView: View {
    let expense: Expense

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]

    @State private var model = TransactionMatchModel()
    @State private var search = ""
    @State private var linkingId: UUID?
    @State private var errorText: String?

    private var browseResults: [Transaction] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(transactions.prefix(50)) }
        return transactions.filter { $0.details.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(expense.details,
                                   value: expense.amount.formatted(.currency(code: expense.currency)))
                    .font(.subheadline)
                } footer: {
                    Text("Link the bank payment for this expense to de-duplicate it in your spending.")
                }

                Section {
                    if model.isRanking {
                        HStack { ProgressView(); Text("Finding matches…").foregroundStyle(.secondary) }
                    } else if model.candidates.isEmpty {
                        Text("No close matches — pick one below.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, match in
                            row(match.transaction, confidence: confidenceLabel(match.score),
                                reason: index == 0 ? model.topReason : "")
                        }
                    }
                } header: {
                    HStack {
                        Text("Suggested")
                        if model.usedAppleIntelligence {
                            Image(systemName: "sparkles").foregroundStyle(.tint)
                        }
                    }
                }

                Section("All Transactions") {
                    if browseResults.isEmpty {
                        Text("No transactions found.").foregroundStyle(.secondary)
                    }
                    ForEach(browseResults) { row($0, confidence: nil, reason: "") }
                }
            }
            .navigationTitle("Link a Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search transactions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                await model.load(expense: expense, transactions: transactions,
                                 expenses: expenses, me: env.currentUser?.identifier)
            }
            .errorAlert($errorText)
        }
    }

    @ViewBuilder
    private func row(_ t: Transaction, confidence: String?, reason: String) -> some View {
        Button { link(t) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.details).foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(t.date.formatted(date: .abbreviated, time: .omitted))
                        if let confidence { Text("· \(confidence)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !reason.isEmpty {
                        Text(reason).font(.caption2).foregroundStyle(.tint)
                    }
                }
                Spacer()
                if linkingId == t.id {
                    ProgressView()
                } else {
                    Text(t.amount.formatted(.currency(code: t.currency)))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .disabled(linkingId != nil)
    }

    private func confidenceLabel(_ score: Double) -> String {
        switch score {
        case 0.8...: return "Strong match"
        case 0.5..<0.8: return "Likely match"
        default: return "Possible match"
        }
    }

    private func link(_ t: Transaction) {
        linkingId = t.id
        Task {
            defer { linkingId = nil }
            do {
                try await env.expenses(context).linkTransaction(expenseId: expense.id, transactionId: t.id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// Reverse flow: "link an existing expense to this transaction" — heuristic-ranked unlinked expenses.
struct ExpenseLinkPickerView: View {
    let transaction: Transaction

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var expenses: [Expense]

    @State private var linkingId: UUID?
    @State private var errorText: String?

    private var candidates: [Expense] {
        TransactionMatcher.expenseCandidates(for: transaction, expenses: expenses,
                                             me: env.currentUser?.identifier)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(transaction.details,
                                   value: transaction.amount.formatted(.currency(code: transaction.currency)))
                    .font(.subheadline)
                } footer: {
                    Text("Link an existing expense this transaction paid for, so it isn't double-counted.")
                }
                Section("Suggested Expenses") {
                    if candidates.isEmpty {
                        Text("No close expense matches.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { expense in
                        Button { link(expense) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(expense.details)
                                    Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if linkingId == expense.id {
                                    ProgressView()
                                } else {
                                    Text(expense.amount.formatted(.currency(code: expense.currency)))
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                        .disabled(linkingId != nil)
                    }
                }
            }
            .navigationTitle("Link an Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .errorAlert($errorText)
        }
    }

    private func link(_ expense: Expense) {
        linkingId = expense.id
        Task {
            defer { linkingId = nil }
            do {
                try await env.expenses(context).linkTransaction(expenseId: expense.id,
                                                                transactionId: transaction.id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

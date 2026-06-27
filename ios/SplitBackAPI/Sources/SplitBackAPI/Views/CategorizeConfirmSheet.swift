import SwiftData
import SwiftUI

/// Confirmation before accepting a "Use {category}" suggestion — the on-device AI disagrees with a
/// transaction's current category. Shows the transaction and the current → suggested change so the user can
/// vet it before it becomes an override. `onConfirm` performs the accept (InboxView → setCategoryOverride).
struct CategorizeConfirmSheet: View {
    let suggestion: Suggestion
    let onConfirm: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var transactions: [Transaction] = []

    var body: some View {
        NavigationStack {
            List {
                if !transactions.isEmpty {
                    Section {
                        LabeledContent("Current", value: suggestion.currentCategory ?? "Uncategorized")
                        LabeledContent("Suggested") {
                            Text(suggestion.category ?? "—").fontWeight(.semibold).foregroundStyle(.tint)
                        }
                    } header: {
                        Text("Category")
                    } footer: {
                        Text(transactions.count == 1 ? "Sets the category on this transaction."
                             : "Sets the category on \(transactions.count) transactions.")
                    }
                    Section("Transactions (\(transactions.count))") {
                        ForEach(transactions) { t in
                            SuggestionRecordRow(title: t.details, amount: t.amount,
                                                currency: t.currency, date: t.date)
                        }
                    }
                } else {
                    ContentUnavailableView("Couldn’t load the transactions", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Confirm Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(suggestion.acceptLabel) { onConfirm(); dismiss() }.disabled(transactions.isEmpty)
                }
            }
            .task { resolve() }
        }
    }

    private func resolve() {
        let ids = suggestion.transactionIds.isEmpty
            ? [suggestion.transactionId].compactMap { $0 } : suggestion.transactionIds
        let idSet = Set(ids)
        let fetched = (try? context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { idSet.contains($0.id) }))) ?? []
        // Preserve the suggestion's order (newest-first from the engine).
        transactions = ids.compactMap { id in fetched.first { $0.id == id } }
    }
}

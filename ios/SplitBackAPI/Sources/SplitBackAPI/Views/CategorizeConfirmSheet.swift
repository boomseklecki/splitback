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
    @State private var transaction: Transaction?

    var body: some View {
        NavigationStack {
            List {
                if let transaction {
                    Section("Transaction") {
                        SuggestionRecordRow(title: transaction.details, amount: transaction.amount,
                                            currency: transaction.currency, date: transaction.date)
                    }
                    Section {
                        LabeledContent("Current", value: suggestion.currentCategory ?? "Uncategorized")
                        LabeledContent("Suggested") {
                            Text(suggestion.category ?? "—").fontWeight(.semibold).foregroundStyle(.tint)
                        }
                    } header: {
                        Text("Category")
                    } footer: {
                        Text("Sets a category override on this transaction.")
                    }
                } else {
                    ContentUnavailableView("Couldn’t load the transaction", systemImage: "questionmark.circle")
                }
            }
            .navigationTitle("Confirm Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(suggestion.acceptLabel) { onConfirm(); dismiss() }.disabled(transaction == nil)
                }
            }
            .task { resolve() }
        }
    }

    private func resolve() {
        guard let tid = suggestion.transactionId else { return }
        transaction = try? context.fetch(
            FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == tid })).first
    }
}

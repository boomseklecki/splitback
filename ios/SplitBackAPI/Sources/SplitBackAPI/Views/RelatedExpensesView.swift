import SwiftUI
import SwiftData

/// The expense sibling of `RelatedTransactionsView`: groups expenses with a similar merchant description (via
/// `RelatedTransactions.group`) and recategorizes the whole group at once by tapping the category avatar.
/// Reached from "Find Related Expenses" on an expense detail. Shares the Merchant/Amount filter controls and
/// their preference with the transaction screen.
struct RelatedExpensesView: View {
    let seedDescription: String
    /// Pre-selects the category picker (the category of the expense you came from).
    var seedCategory: String? = nil
    /// The amount of the expense you came from — drives the Amount match axis (Close/Equal) when present.
    var seedAmount: Decimal? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]

    @State private var showingCategoryPicker = false
    @State private var applying = false
    @State private var errorText: String?
    @AppStorage("relatedTransactions.matchStrictness")
    private var strictnessRaw = RelatedTransactions.MatchStrictness.balanced.rawValue
    @AppStorage("relatedTransactions.amountMatch")
    private var amountRaw = RelatedTransactions.AmountMatch.any.rawValue

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var strictness: RelatedTransactions.MatchStrictness {
        RelatedTransactions.MatchStrictness(rawValue: strictnessRaw) ?? .balanced
    }
    private var amountMatch: RelatedTransactions.AmountMatch {
        RelatedTransactions.AmountMatch(rawValue: amountRaw) ?? .any
    }

    var body: some View {
        let group = RelatedTransactions.group(
            seedDescription: seedDescription, seedAmount: seedAmount, in: expenses,
            strictness: strictness, amount: amountMatch)
        let name = RelatedTransactions.displayName(for: seedDescription)
        let code = group.first?.currency ?? "USD"
        let total = group.reduce(Decimal(0)) { $0 + $1.amount }
        let average = group.isEmpty ? 0 : total / Decimal(group.count)
        let current = currentCategory(in: group)

        return List {
            Section {
                VStack(spacing: 8) {
                    Button { showingCategoryPicker = true } label: {
                        CategoryAvatar(category: current)
                    }
                    .buttonStyle(.plain)
                    .disabled(applying || group.isEmpty)
                    Text(name).font(.title2).fontWeight(.semibold)
                    Text("avg \(currency(average, code)) · \(group.count) "
                         + "expense\(group.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if applying { ProgressView() }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section {
                LabeledContent("Total", value: currency(total, code))
                if let current {
                    LabeledContent("Category", value: current)
                }
            }

            RelatedMatchFilters(strictnessRaw: $strictnessRaw, amountRaw: $amountRaw,
                                showAmount: seedAmount != nil)

            Section {
                ForEach(group) { e in
                    NavigationLink {
                        LazyView(ExpenseDetailView(expense: e))
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.details).lineLimit(1)
                                Text(e.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currency(e.amount, e.currency))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if group.isEmpty {
                    Text("No related expenses.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Expenses")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: current, subject: name) { apply($0, to: group) }
        }
        .errorAlert($errorText)
    }

    private func currency(_ value: Decimal, _ code: String) -> String {
        value.formatted(.currency(code: code))
    }

    /// The seed's (canonicalized) category, else the most common canonical category across the group.
    private func currentCategory(in group: [Expense]) -> String? {
        if let seedCategory, let c = CategoryMapping.canonical(seedCategory, lookup: lookup) { return c }
        let counts = group.reduce(into: [String: Int]()) { tally, e in
            if let raw = e.category, let c = CategoryMapping.canonical(raw, lookup: lookup) {
                tally[c, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Apply the picked category to every expense in the group (concurrent batch, one cache write).
    private func apply(_ category: String, to group: [Expense]) {
        let ids = group.map(\.id)
        let me = env.currentUser?.identifier
        Task {
            applying = true
            defer { applying = false }
            do {
                try await env.expenses(context).updateCategory(ids: ids, category: category, updatedBy: me)
            } catch {
                errorText = errorMessage(error)
            }
        }
    }
}

import SwiftUI
import SwiftData

/// A merchant-by-description detail, mirroring `SubscriptionDetailView`: fuzzy-groups bank/manual
/// transactions that share a significant word with the one you came from, shows the total spend and a
/// charge history (with each row's description, since the match is fuzzy), and lets you recategorize the
/// whole group at once by tapping the category avatar at the top. Reached from "Find Related Transactions"
/// on a transaction or expense detail.
struct DescriptionDetailView: View {
    let seedDescription: String
    /// Pre-selects the category picker (the category of the row you came from).
    var seedCategory: String? = nil
    /// The amount of the row you came from — used by the "Exact" match level to isolate one recurring charge.
    var seedAmount: Decimal? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]

    @State private var showingCategoryPicker = false
    @State private var applying = false
    @State private var errorText: String?
    @AppStorage("relatedTransactions.matchStrictness")
    private var strictnessRaw = RelatedTransactions.MatchStrictness.balanced.rawValue

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var strictness: RelatedTransactions.MatchStrictness {
        RelatedTransactions.MatchStrictness(rawValue: strictnessRaw) ?? .balanced
    }

    var body: some View {
        // Group once per render (not inside the row builders), like SubscriptionsView.
        let group = RelatedTransactions.group(
            seedDescription: seedDescription, seedAmount: seedAmount, in: transactions, strictness: strictness)
        let name = RelatedTransactions.displayName(for: seedDescription)
        let code = group.first?.currency ?? "USD"
        let total = group.reduce(Decimal(0)) { $0 + $1.amount }
        let average = group.isEmpty ? 0 : total / Decimal(group.count)
        let current = currentCategory(in: group)

        return List {
            Section {
                VStack(spacing: 8) {
                    Button { showingCategoryPicker = true } label: {
                        categoryAvatar(current)
                    }
                    .buttonStyle(.plain)
                    .disabled(applying || group.isEmpty)
                    Text(name).font(.title2).fontWeight(.semibold)
                    Text("avg \(currency(average, code)) · \(group.count) "
                         + "transaction\(group.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if applying { ProgressView() }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section {
                LabeledContent("Total spend", value: currency(total, code))
                if let current {
                    LabeledContent("Category", value: current)
                }
            }

            Section {
                Picker("Matching", selection: $strictnessRaw) {
                    ForEach(RelatedTransactions.MatchStrictness.allCases) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Matching")
            } footer: {
                Text("Fuzzy groups any shared word; Strict only the same merchant; "
                     + "Exact is the same merchant and amount (isolates a recurring charge).")
            }

            Section {
                ForEach(group) { t in
                    NavigationLink {
                        LazyView(TransactionDetailView(transaction: t))
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.details).lineLimit(1)
                                Text(t.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currency(t.amount, t.currency))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                if group.isEmpty {
                    Text("No related transactions.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Charges")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: current, subject: name) { apply($0, to: group) }
        }
        .errorAlert($errorText)
    }

    /// A circular, category-colored icon with a pencil badge — tappable to recategorize the whole group.
    private func categoryAvatar(_ category: String?) -> some View {
        Image(systemName: categorySymbol(category))
            .font(.title)
            .foregroundStyle(categoryColor(category))
            .frame(width: 64, height: 64)
            .background(categoryColor(category).opacity(0.15), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil.circle.fill")
                    .font(.body).foregroundStyle(.secondary)
                    .background(Circle().fill(Color(.systemBackground)))
            }
    }

    private func currency(_ value: Decimal, _ code: String) -> String {
        value.formatted(.currency(code: code))
    }

    /// The seed's category, else the most common effective category across the group.
    private func currentCategory(in group: [Transaction]) -> String? {
        if let seedCategory { return seedCategory }
        let counts = group.reduce(into: [String: Int]()) { tally, t in
            if let c = CategoryMapping.effectiveCategory(for: t, lookup: lookup) { tally[c, default: 0] += 1 }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Apply the picked category to every transaction in the group (no batch endpoint — loop the override).
    private func apply(_ category: String, to group: [Transaction]) {
        let ids = group.map(\.id)
        Task {
            applying = true
            defer { applying = false }
            do {
                for id in ids {
                    try await env.accounts(context).setCategoryOverride(id: id, category: category)
                }
            } catch {
                errorText = errorMessage(error)
            }
        }
    }
}

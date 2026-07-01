import SwiftUI

/// The shared Merchant + Amount match-filter controls for the "Find Related" screens (transactions and
/// expenses). Bound to the caller's `relatedTransactions.matchStrictness` / `.amountMatch` AppStorage so the
/// preference is consistent across both. Renders as its own List sections.
struct RelatedMatchFilters: View {
    @Binding var strictnessRaw: String
    @Binding var amountRaw: String
    /// Whether the seed has an amount (the Amount axis is hidden without one).
    let showAmount: Bool

    var body: some View {
        Section {
            Picker("Merchant", selection: $strictnessRaw) {
                ForEach(RelatedTransactions.MatchStrictness.allCases) {
                    Text($0.label).tag($0.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Merchant")
        } footer: {
            Text("Fuzzy = any shared word · Balanced = most words · Strict = one contains the other · "
                 + "Exact = exactly the same merchant.")
        }

        if showAmount {
            Section {
                Picker("Amount", selection: $amountRaw) {
                    ForEach(RelatedTransactions.AmountMatch.allCases) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Amount")
            } footer: {
                Text("Any ignores amount · Close matches a fluctuating charge · "
                     + "Equal isolates an identical recurring charge.")
            }
        }
    }
}

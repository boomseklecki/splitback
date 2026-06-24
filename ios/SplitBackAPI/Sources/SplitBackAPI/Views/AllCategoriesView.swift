import SwiftUI

/// The full per-category spend breakdown for a month (every category, not just the donut's top 6). Each row
/// drills into that category's contributing transactions/expenses. Pushed from the Goals donut section.
struct AllCategoriesView: View {
    let slices: [CategorySpend]
    let month: Date

    var body: some View {
        List(slices) { slice in
            NavigationLink {
                SpendContributorsView(title: slice.category, month: month,
                                      scope: .category(slice.category))
            } label: {
                CategorySpendRow(slice: slice)
            }
        }
        .navigationTitle("All Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

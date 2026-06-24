import SwiftUI

/// The full per-category spend breakdown for a month (every category, not just the donut's top 6), led by the
/// same spend donut + "Spent this month" total as the Goals page. Each row — and each donut slice — drills into
/// that category's contributing transactions/expenses. Pushed from the Goals donut section.
struct AllCategoriesView: View {
    let slices: [CategorySpend]
    let month: Date

    @State private var selectedCategory: String?

    private var total: Decimal { slices.reduce(0) { $0 + $1.total } }

    var body: some View {
        List {
            Section {
                SpendingDonut(slices: slices, total: total) { selectedCategory = $0 }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            Section {
                ForEach(slices) { slice in
                    NavigationLink {
                        SpendContributorsView(title: slice.category, month: month,
                                              scope: .category(slice.category))
                    } label: {
                        CategorySpendRow(slice: slice)
                    }
                }
            }
        }
        .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedCategory) { category in
            SpendContributorsView(title: category, month: month, scope: .category(category))
        }
    }
}

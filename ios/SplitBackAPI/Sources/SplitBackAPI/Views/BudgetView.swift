import SwiftUI

/// Placeholder for the upcoming budgeting feature.
struct BudgetView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Budget", systemImage: "chart.pie",
                                   description: Text("Budgeting is coming soon."))
                .navigationTitle("Budget")
        }
    }
}

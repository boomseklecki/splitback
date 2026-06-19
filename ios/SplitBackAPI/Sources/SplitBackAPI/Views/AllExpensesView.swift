import SwiftUI
import SwiftData

/// Every active expense across all groups, most recent first. Tapping opens the expense detail.
struct AllExpensesView: View {
    @Query(filter: #Predicate<Expense> { $0.archivedAt == nil },
           sort: \Expense.date, order: .reverse)
    private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]

    private var groupName: [UUID: String] {
        Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        List(expenses) { expense in
            NavigationLink(value: expense) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.details)
                        Text("\(groupName[expense.groupId] ?? "—") · \(expense.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(expense.amount.formatted(.currency(code: expense.currency)))
                }
            }
        }
        .navigationTitle("All Expenses")
        .navigationDestination(for: Expense.self) { ExpenseDetailView(expense: $0) }
        .overlay {
            if expenses.isEmpty {
                ContentUnavailableView("No Expenses", systemImage: "list.bullet.rectangle",
                                       description: Text("Add an expense in a group."))
            }
        }
    }
}

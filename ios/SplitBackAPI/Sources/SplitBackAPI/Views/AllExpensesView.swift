import SwiftUI
import SwiftData

/// Every active expense across all groups, grouped into month sections, most recent first. Rows match
/// the group detail (stacked date, category icon, your share) with the group name in the subtitle.
struct AllExpensesView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(filter: #Predicate<Expense> { $0.archivedAt == nil },
           sort: \Expense.date, order: .reverse)
    private var expenses: [Expense]
    @Query private var groups: [ExpenseGroup]
    @Query private var users: [User]

    private var groupName: [UUID: String] {
        Dictionary(groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        List {
            ForEach(expenseMonthGroups(expenses), id: \.id) { month in
                Section {
                    ForEach(month.expenses) { expense in
                        NavigationLink(value: expense) {
                            ExpenseRow(expense: expense, users: users,
                                       meIdentifier: env.currentUser?.identifier,
                                       groupName: groupName[expense.groupId])
                        }
                    }
                } header: {
                    Text(month.label).textCase(nil)
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

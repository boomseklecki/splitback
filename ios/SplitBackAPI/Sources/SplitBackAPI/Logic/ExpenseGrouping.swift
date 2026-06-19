import Foundation

/// Groups date-descending expenses into month buckets with a "June 2026" label, newest month first,
/// preserving date order within each month. Shared by the group detail and All Expenses lists.
func expenseMonthGroups(_ expenses: [Expense]) -> [(id: String, label: String, expenses: [Expense])] {
    let calendar = Calendar.current
    let buckets = Dictionary(grouping: expenses) {
        calendar.dateComponents([.year, .month], from: $0.date)
    }
    return buckets.keys
        .sorted { (calendar.date(from: $0) ?? .distantPast) > (calendar.date(from: $1) ?? .distantPast) }
        .map { key in
            let date = calendar.date(from: key) ?? .now
            return ("\(key.year ?? 0)-\(key.month ?? 0)",
                    date.formatted(.dateTime.month(.wide).year()),
                    buckets[key] ?? [])
        }
}

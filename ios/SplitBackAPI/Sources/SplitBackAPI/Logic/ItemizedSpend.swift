import Foundation

/// Breaks an expense into the current user's per-category spend, honoring item assignment: items
/// owned by `me` count at full price under their category; the rest of your owed share
/// (`owedShare − your assigned items`) is spread across the shared items + the non-item remainder
/// (tax/tip) by price. An expense with no items yields a single contribution at your owed share.
enum ItemizedSpend {
    static func categoryContributions(for expense: Expense, me: String,
                                      lookup: [String: String]) -> [(category: String, amount: Decimal)] {
        let owed = expense.splits.first { $0.userIdentifier == me }?.owedShare ?? 0
        let items = expense.items

        guard !items.isEmpty else {
            guard owed > 0, let c = canonical(expense.category, lookup) else { return [] }
            return [(c, owed)]
        }

        var totals: [String: Decimal] = [:]
        func add(_ rawCategory: String?, _ amount: Decimal) {
            guard amount > 0, let c = canonical(rawCategory ?? expense.category, lookup) else { return }
            totals[c, default: 0] += amount
        }

        // Items assigned to me → full price under their category.
        let mine = items.filter { $0.ownerIdentifier == me }
        for item in mine { add(item.category, item.price) }
        let assignedToMe = mine.reduce(Decimal(0)) { $0 + $1.price }

        // My share of the shared pool (unassigned items + non-item remainder), spread by price.
        let poolShare = max(owed - assignedToMe, 0)
        if poolShare > 0 {
            let shared = items.filter { $0.ownerIdentifier == nil }
            let itemsTotal = items.reduce(Decimal(0)) { $0 + $1.price }
            let nonItemRemainder = max(expense.amount - itemsTotal, 0)
            let poolTotal = shared.reduce(Decimal(0)) { $0 + $1.price } + nonItemRemainder
            if poolTotal > 0 {
                for item in shared { add(item.category, poolShare * item.price / poolTotal) }
                add(nil, poolShare * nonItemRemainder / poolTotal)  // remainder → expense category
            } else {
                add(nil, poolShare)
            }
        }
        return totals.map { (category: $0.key, amount: $0.value) }
    }

    private static func canonical(_ raw: String?, _ lookup: [String: String]) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return CategoryMapping.canonical(raw, lookup: lookup)
    }
}

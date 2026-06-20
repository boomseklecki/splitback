import Foundation

/// One category's spend (donut + budgets).
struct CategorySpend: Identifiable, Equatable {
    let category: String
    let total: Decimal
    var id: String { category }
}

/// A month bucket's value (spending or net income). `month` is the first of the month.
struct MonthlyValue: Identifiable, Equatable {
    let month: Date
    let value: Decimal
    var id: Date { month }
}

/// A normalized spend/cash-flow item from either a Plaid transaction or an expense. Unifying the two
/// lets the Goals/Trends analytics count expenses that never showed up in the bank sync (cash splits,
/// Splitwise) without double-counting the ones already represented by a linked transaction.
/// Sign convention: `amount > 0` is an outflow (spend), `amount < 0` is an inflow.
struct SpendEvent: Identifiable {
    let id: UUID
    let date: Date
    let label: String
    let category: String?
    let amount: Decimal
    let countsInSpending: Bool
    let countsInCashFlow: Bool
}

/// Pure spend/cash-flow aggregations over a unified `SpendEvent` stream, scoped by accounts' effective
/// inclusion flags (`countsInSpending` / `countsInCashFlow`) and the canonical category map.
enum SpendingAnalytics {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static func monthStart(_ date: Date, _ cal: Calendar = calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Builds the unified event stream: every Plaid transaction (gross, scoped by its account's flags)
    /// **plus** each non-archived expense that isn't already linked to a transaction (`transactionId ==
    /// nil`), counted at the current user's owed share. Expenses have no account, so they always count;
    /// internal/transfer/income categories are dropped so settle-ups and reimbursements don't distort
    /// spend or cash flow. `me` nil ⇒ no expenses (we can't know your share).
    static func spendEvents(transactions: [Transaction], accounts: [Account], lookup: [String: String],
                            expenses: [Expense] = [], me: String? = nil) -> [SpendEvent] {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [SpendEvent] = []

        for t in transactions where t.source == .plaid {
            guard let accountId = t.accountId, let account = byId[accountId] else { continue }
            events.append(SpendEvent(
                id: t.id, date: t.date, label: t.details,
                category: CategoryMapping.effectiveCategory(for: t, lookup: lookup),
                amount: t.amount,
                countsInSpending: account.countsInSpending,
                countsInCashFlow: account.countsInCashFlow))
        }

        if let me {
            for e in expenses where e.transactionId == nil && e.archivedAt == nil {
                guard let category = e.category.flatMap({ CategoryMapping.canonical($0, lookup: lookup) }),
                      !CanonicalCategory.neutral.contains(category) else { continue }  // settle-up/transfer
                let mySplit = e.splits.first { $0.userIdentifier == me }
                let amount: Decimal
                if CanonicalCategory.incomeLike.contains(category) {
                    // Inflow (negative): your share of received money. Reimbursement encodes the
                    // "gets back" as paidShare; income items use your owed share.
                    let inflow = category == Reimbursement.category ? (mySplit?.paidShare ?? 0)
                                                                    : (mySplit?.owedShare ?? 0)
                    guard inflow > 0 else { continue }
                    amount = -inflow
                } else if !e.items.isEmpty {
                    // Itemized outflow: attribute your share of each item to its own category.
                    for c in ItemizedSpend.categoryContributions(for: e, me: me, lookup: lookup) {
                        events.append(SpendEvent(
                            id: e.id, date: e.date, label: e.details, category: c.category,
                            amount: c.amount, countsInSpending: true, countsInCashFlow: true))
                    }
                    continue
                } else {
                    let share = mySplit?.owedShare ?? 0
                    guard share > 0 else { continue }  // you consumed nothing (or aren't in this expense)
                    amount = share
                }
                events.append(SpendEvent(
                    id: e.id, date: e.date, label: e.details, category: category,
                    amount: amount, countsInSpending: true, countsInCashFlow: true))
            }
        }
        return events
    }

    /// Whether an event is spend that counts toward budgets/donut: an outflow on a spending-included
    /// source whose category isn't an internal/transfer/income one.
    static func isSpend(_ e: SpendEvent) -> Bool {
        guard e.countsInSpending, e.amount > 0, let category = e.category else { return false }
        return !CanonicalCategory.excludedFromSpend.contains(category)
    }

    /// Spend by canonical category in the given month, descending.
    static func byCategory(in month: Date, transactions: [Transaction], accounts: [Account],
                           lookup: [String: String], expenses: [Expense] = [],
                           me: String? = nil) -> [CategorySpend] {
        let cal = calendar
        let target = monthStart(month, cal)
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, me: me)
        var totals: [String: Decimal] = [:]
        for e in events where monthStart(e.date, cal) == target && isSpend(e) {
            if let category = e.category { totals[category, default: 0] += e.amount }
        }
        return totals.map { CategorySpend(category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Total monthly spend for the last `months` months (oldest → newest), zero-filled.
    static func monthlySpending(transactions: [Transaction], accounts: [Account],
                                lookup: [String: String], months: Int, ending: Date = .now,
                                expenses: [Expense] = [], me: String? = nil) -> [MonthlyValue] {
        let cal = calendar
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, me: me)
        var totals: [Date: Decimal] = [:]
        for e in events where isSpend(e) {
            totals[monthStart(e.date, cal), default: 0] += e.amount
        }
        return monthRange(months: months, ending: ending, cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    /// Net income (inflow − outflow) per month over cash-flow sources, excluding transfers/settle-ups
    /// (income & reimbursements count as inflow). Negative in deficit months. Last `months` months,
    /// oldest → newest, zero-filled.
    static func monthlyNetIncome(transactions: [Transaction], accounts: [Account],
                                 lookup: [String: String], months: Int, ending: Date = .now,
                                 expenses: [Expense] = [], me: String? = nil) -> [MonthlyValue] {
        let cal = calendar
        let events = spendEvents(transactions: transactions, accounts: accounts, lookup: lookup,
                                 expenses: expenses, me: me)
        var totals: [Date: Decimal] = [:]
        for e in events where e.countsInCashFlow {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }  // settle-up/transfer
            // inflow (amount<0) adds to income, outflow (amount>0) subtracts.
            totals[monthStart(e.date, cal), default: 0] -= e.amount
        }
        return monthRange(months: months, ending: ending, cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    /// The first-of-month dates for the last `months` months ending in `ending`'s month (oldest first).
    static func monthRange(months: Int, ending: Date, cal: Calendar) -> [Date] {
        let end = monthStart(ending, cal)
        return (0..<max(months, 0)).reversed().compactMap {
            cal.date(byAdding: .month, value: -$0, to: end)
        }
    }
}

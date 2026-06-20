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

/// Pure spend/cash-flow aggregations over Plaid transactions, scoped by the accounts' effective
/// inclusion flags (`countsInSpending` / `countsInCashFlow`) and the canonical category map.
/// Sign convention: `amount > 0` is an outflow (spend), `amount < 0` is an inflow.
enum SpendingAnalytics {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static func monthStart(_ date: Date, _ cal: Calendar = calendar) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Whether a transaction is spend that counts toward budgets/donut: an outflow on a Plaid,
    /// spending-included account whose effective category isn't an internal/transfer/income one.
    static func isSpend(_ t: Transaction, accounts: [UUID: Account], lookup: [String: String]) -> Bool {
        guard t.source == .plaid, t.amount > 0,
              let accountId = t.accountId, accounts[accountId]?.countsInSpending == true,
              let category = CategoryMapping.effectiveCategory(for: t, lookup: lookup) else { return false }
        return !CanonicalCategory.excludedFromSpend.contains(category)
    }

    /// Spend by canonical category in the given month, descending.
    static func byCategory(in month: Date, transactions: [Transaction], accounts: [Account],
                           lookup: [String: String]) -> [CategorySpend] {
        let cal = calendar
        let target = monthStart(month, cal)
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var totals: [String: Decimal] = [:]
        for t in transactions where monthStart(t.date, cal) == target
            && isSpend(t, accounts: byId, lookup: lookup) {
            if let category = CategoryMapping.effectiveCategory(for: t, lookup: lookup) {
                totals[category, default: 0] += t.amount
            }
        }
        return totals.map { CategorySpend(category: $0.key, total: $0.value) }
            .sorted { $0.total > $1.total }
    }

    /// Total monthly spend for the last `months` months (oldest → newest), zero-filled.
    static func monthlySpending(transactions: [Transaction], accounts: [Account],
                                lookup: [String: String], months: Int, ending: Date = .now) -> [MonthlyValue] {
        let cal = calendar
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var totals: [Date: Decimal] = [:]
        for t in transactions where isSpend(t, accounts: byId, lookup: lookup) {
            totals[monthStart(t.date, cal), default: 0] += t.amount
        }
        return monthRange(months: months, ending: ending, cal: cal)
            .map { MonthlyValue(month: $0, value: totals[$0] ?? 0) }
    }

    /// Net income (inflow − outflow) per month over cash-flow accounts, excluding transfers. Negative
    /// in deficit months. Last `months` months, oldest → newest, zero-filled.
    static func monthlyNetIncome(transactions: [Transaction], accounts: [Account],
                                 lookup: [String: String], months: Int, ending: Date = .now) -> [MonthlyValue] {
        let cal = calendar
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var totals: [Date: Decimal] = [:]
        for t in transactions where t.source == .plaid {
            guard let accountId = t.accountId, byId[accountId]?.countsInCashFlow == true else { continue }
            if CategoryMapping.effectiveCategory(for: t, lookup: lookup) == CanonicalCategory.transfer { continue }
            // inflow (amount<0) adds to income, outflow (amount>0) subtracts.
            totals[monthStart(t.date, cal), default: 0] -= t.amount
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

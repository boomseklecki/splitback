import Foundation

/// Pure split math + the client-side balance check. Kept out of views so it's unit-testable.
enum SplitMath {
    static let tolerance = Decimal(string: "0.01")!

    private static func cents(_ amount: Decimal) -> Int {
        NSDecimalNumber(decimal: amount * 100).rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0,
                                   raiseOnExactness: false, raiseOnOverflow: false,
                                   raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
    }

    private static func money(_ cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    static func paidSum(_ splits: [SplitDraft]) -> Decimal {
        splits.reduce(Decimal(0)) { $0 + $1.paidShare }
    }

    static func owedSum(_ splits: [SplitDraft]) -> Decimal {
        splits.reduce(Decimal(0)) { $0 + $1.owedShare }
    }

    /// `paid` and `owed` must each equal `amount` within ±0.01.
    static func isBalanced(amount: Decimal, splits: [SplitDraft]) -> Bool {
        abs(paidSum(splits) - amount) <= tolerance && abs(owedSum(splits) - amount) <= tolerance
    }

    /// Equal split: `payer` paid the full amount; everyone (incl. the payer) owes an equal share.
    /// Remainder pennies are assigned to the earliest participants so owed sums to the amount exactly.
    static func equalSplit(amount: Decimal, payer: String, participants: [String]) -> [SplitDraft] {
        let people = participants.isEmpty ? [payer] : participants
        let total = cents(amount)
        let n = people.count
        let base = total / n
        let remainder = total - base * n
        return people.enumerated().map { index, identifier in
            let owedCents = base + (index < remainder ? 1 : 0)
            return SplitDraft(
                userIdentifier: identifier,
                paidShare: identifier == payer ? amount : 0,
                owedShare: money(owedCents)
            )
        }
    }
}

/// Splitwise-style presentation: collapse expenses older than the most recent settle-up.
enum SettleUp {
    static let category = "Settle-up"

    /// `expenses` must be sorted newest-first. Returns the visible prefix (through the most recent
    /// settle-up, inclusive) and how many older expenses were collapsed.
    static func collapseOlder(_ expenses: [Expense]) -> (visible: [Expense], collapsed: Int) {
        guard let index = expenses.firstIndex(where: { $0.category == category }) else {
            return (expenses, 0)
        }
        let visible = Array(expenses[...index])
        return (visible, expenses.count - visible.count)
    }
}

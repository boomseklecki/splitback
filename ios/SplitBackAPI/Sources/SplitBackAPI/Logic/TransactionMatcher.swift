import Foundation

/// A candidate transaction for linking to an expense, with a 0…1 heuristic confidence.
struct TransactionMatch: Identifiable {
    let transaction: Transaction
    let score: Double
    var id: UUID { transaction.id }
}

/// Pure, on-device ranking of which bank/manual transactions best match an expense — the basis for the
/// "link a transaction" suggestions. Deterministic (no model needed); the Foundation Models layer in
/// `TransactionMatchModel` can re-rank the top of this list when Apple Intelligence is available.
///
/// Signals: amount closeness (a shared bill is paid in full from one account, so we compare against both
/// the expense's full cost *and* the payer's `paidShare`), date proximity, and merchant/description token
/// overlap, with a small nudge when the expense recurs.
enum TransactionMatcher {
    /// A linked pair pays the same bill, so the amounts must be close — require within ~40% (closeness
    /// ≥ 0.6) before name/date can contribute. Stops a wildly different amount from matching on name alone.
    private static let minAmountScore = 0.6

    /// Words that carry no matching signal (payment plumbing / legal suffixes).
    private static let stopWords: Set<String> = [
        "the", "and", "for", "payment", "pmt", "ach", "autopay", "auto", "bill", "online",
        "llc", "inc", "co", "corp", "ltd", "card", "purchase", "pos", "debit", "credit",
    ]

    static func candidates(for expense: Expense, transactions: [Transaction], expenses: [Expense],
                           me: String?, limit: Int = 8, windowDays: Int = 21) -> [TransactionMatch] {
        // Exclude transactions already linked to another expense.
        var linked = Set<UUID>()
        for e in expenses where e.id != expense.id {
            if let tid = e.transactionId { linked.insert(tid) }
        }

        let full = nsDouble(expense.amount)
        let mySplit = me.flatMap { id in expense.splits.first { $0.userIdentifier == id } }
        let myPaid: Double? = mySplit.map { nsDouble($0.paidShare) }
        let expenseTokens = tokens(expense.details)
        let recurring = expense.repeats == true

        var matches: [TransactionMatch] = []
        for t in transactions where !linked.contains(t.id) {
            let days = abs(daysBetween(t.date, expense.date))
            guard days <= windowDays else { continue }
            let amount = nsDouble(t.amount)
            // Best of (matches full bill) / (matches your paid share).
            let amountScore = max(closeness(amount, full), myPaid.map { closeness(amount, $0) } ?? 0)
            guard amountScore >= minAmountScore else { continue }  // amounts must be close to be the same bill
            let dateScore = max(0, 1 - Double(days) / Double(windowDays))
            let nameScore = overlap(tokens(t.details), expenseTokens)

            var score = 0.55 * amountScore + 0.30 * dateScore + 0.15 * nameScore
            if recurring { score = min(1, score + 0.05) }
            matches.append(TransactionMatch(transaction: t, score: score))
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Symmetric ranking for the reverse flow ("link an existing expense to this transaction"): unlinked,
    /// non-neutral expenses scored against a transaction by the same amount/date/name signals.
    static func expenseCandidates(for transaction: Transaction, expenses: [Expense], me: String?,
                                  limit: Int = 8, windowDays: Int = 21) -> [Expense] {
        let amount = nsDouble(transaction.amount)
        let txnTokens = tokens(transaction.details)
        var scored: [(Expense, Double)] = []
        for e in expenses where e.transactionId == nil {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }  // settle-up/transfer
            let days = abs(daysBetween(transaction.date, e.date))
            guard days <= windowDays else { continue }
            let myPaid = me.flatMap { id in e.splits.first { $0.userIdentifier == id }?.paidShare }
                .map(nsDouble)
            let amountScore = max(closeness(amount, nsDouble(e.amount)),
                                  myPaid.map { closeness(amount, $0) } ?? 0)
            guard amountScore >= minAmountScore else { continue }
            let dateScore = max(0, 1 - Double(days) / Double(windowDays))
            let nameScore = overlap(txnTokens, tokens(e.details))
            scored.append((e, 0.55 * amountScore + 0.30 * dateScore + 0.15 * nameScore))
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }

    // MARK: Scoring helpers

    /// 1 when equal, decaying to 0 at a 100% relative difference.
    private static func closeness(_ a: Double, _ b: Double) -> Double {
        guard b > 0 else { return 0 }
        return max(0, 1 - min(abs(a - b) / b, 1))
    }

    /// Overlap coefficient |A∩B| / min(|A|,|B|) over meaningful tokens (0 when either side is empty).
    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }

    /// Lowercased alphanumeric tokens of length ≥ 2, minus payment-noise stop words.
    static func tokens(_ text: String) -> Set<String> {
        let parts = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { $0.count >= 2 && !stopWords.contains($0) })
    }

    private static func daysBetween(_ a: Date, _ b: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: a),
                                        to: Calendar.current.startOfDay(for: b)).day ?? Int.max
    }

    private static func nsDouble(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
}

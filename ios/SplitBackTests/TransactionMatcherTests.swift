import XCTest
@testable import SplitBackAPI

final class TransactionMatcherTests: XCTestCase {
    private func txn(_ amount: Decimal, details: String, daysAgo: Int = 0,
                    date base: Date = Date()) -> Transaction {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: base)!
        return Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: details,
                           amount: amount, currency: "USD", date: d, category: nil,
                           createdAt: Date(), updatedAt: Date())
    }

    /// A $2000 expense where `me` paid in full and owes `owed`, optionally recurring/linked.
    private func expense(_ amount: Decimal, details: String, me: String = "me", owed: Decimal,
                         repeats: Bool = false, transactionId: UUID? = nil, date: Date = Date()) -> Expense {
        let split = Split(id: UUID(), userIdentifier: me, paidShare: amount, owedShare: owed)
        let e = Expense(id: UUID(), groupId: UUID(), transactionId: transactionId, details: details,
                        amount: amount, currency: "USD", date: date, category: "Mortgage",
                        createdAt: Date(), updatedAt: Date(), splits: [split])
        e.repeats = repeats
        return e
    }

    func testFullBillSameDayRanksFirst() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let match = txn(2000, details: "WELLS FARGO MORTGAGE PMT", daysAgo: 0, date: now)
        let off = txn(57, details: "Coffee Shop", daysAgo: 1, date: now)
        let far = txn(2000, details: "Mortgage", daysAgo: 60, date: now)   // outside the window
        let ranked = TransactionMatcher.candidates(for: exp, transactions: [off, match, far],
                                                   expenses: [exp], me: "me")
        XCTAssertEqual(ranked.first?.transaction.id, match.id)
        XCTAssertFalse(ranked.contains { $0.transaction.id == far.id })   // windowed out
        XCTAssertGreaterThan(ranked.first!.score, 0.8)
    }

    func testMatchesPayerShareWhenBillNotFull() {
        // The expense's full cost is $100 but the user only paid their $50 share from the bank.
        let now = Date()
        let exp = expense(100, details: "Dinner", owed: 50, date: now)
        let mySplit = Split(id: UUID(), userIdentifier: "me", paidShare: 50, owedShare: 50)
        exp.splits = [mySplit]
        let half = txn(50, details: "Dinner", daysAgo: 0, date: now)
        let ranked = TransactionMatcher.candidates(for: exp, transactions: [half], expenses: [exp], me: "me")
        XCTAssertEqual(ranked.first?.transaction.id, half.id)
    }

    func testExcludesTransactionsLinkedToAnotherExpense() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let candidate = txn(2000, details: "Mortgage", daysAgo: 0, date: now)
        // Another expense already owns that transaction → it must not be suggested.
        let other = expense(2000, details: "Mortgage", owed: 1000, transactionId: candidate.id, date: now)
        let ranked = TransactionMatcher.candidates(for: exp, transactions: [candidate],
                                                   expenses: [exp, other], me: "me")
        XCTAssertTrue(ranked.isEmpty)
    }

    func testWildlyDifferentAmountDropped() {
        let now = Date()
        let exp = expense(2000, details: "Mortgage", owed: 1000, date: now)
        let unrelated = txn(12, details: "Mortgage paperwork fee", daysAgo: 0, date: now)
        let ranked = TransactionMatcher.candidates(for: exp, transactions: [unrelated],
                                                   expenses: [exp], me: "me")
        XCTAssertTrue(ranked.isEmpty)  // amount closeness 0 → not a candidate
    }
}

import XCTest
@testable import SplitBackAPI

/// Review-queue suggestion generation: each card type, the explicit-choice guard, and dismissal filtering.
final class SuggestionEngineTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func txn(_ details: String, _ amount: Decimal, category: String? = nil, date: Date = Date(),
                     override: String? = nil, ai: String? = nil) -> Transaction {
        let t = Transaction(id: UUID(), accountId: UUID(), source: .plaid, details: details,
                            amount: amount, currency: "USD", date: date, category: category,
                            categoryOverride: override, createdAt: Date(), updatedAt: Date())
        t.aiSuggestedCategory = ai
        return t
    }

    private func expense(_ details: String, _ amount: Decimal, category: String?,
                         splits: [(String, Decimal)], date: Date = Date(), group: UUID = UUID(),
                         transactionId: UUID? = nil) -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, transactionId: transactionId, details: details,
                       amount: amount, currency: "USD", date: date, category: category,
                       createdAt: Date(), updatedAt: Date(), splits: s)
    }

    private func generate(transactions: [Transaction] = [], expenses: [Expense] = [],
                          templates: [SplitTemplate] = [], rules: [SubscriptionRule] = [],
                          decisions: [SuggestionDecision] = []) -> [Suggestion] {
        SuggestionEngine.generate(transactions: transactions, expenses: expenses, lookup: [:], sources: [:],
                                  templates: templates, rules: rules, decisions: decisions, me: me)
    }

    func testCategorizeOverNonExplicit() {
        // GENERAL_SERVICES resolves to a deterministic "Other"; AI suggests Shopping → one card.
        let cards = generate(transactions: [txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")])
        let cat = cards.filter { $0.kind == .categorize }
        XCTAssertEqual(cat.count, 1)
        XCTAssertEqual(cat.first?.category, "Shopping")
    }

    func testCategorizeSuppressedByExplicitChoice() {
        // An explicit override must not be second-guessed by the AI.
        let cards = generate(transactions: [txn("Store", 10, category: "GENERAL_SERVICES",
                                                 override: "Dining", ai: "Shopping")])
        XCTAssertTrue(cards.filter { $0.kind == .categorize }.isEmpty)
    }

    func testLinkHighConfidence() {
        let e = expense("Dinner", 50, category: "Dining", splits: [(me, 50)])
        let t = txn("Dinner", 50, date: e.date)
        let links = generate(transactions: [t], expenses: [e]).filter { $0.kind == .link }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.expenseId, e.id)
        XCTAssertEqual(links.first?.transactionId, t.id)
    }

    func testSubscriptionCardThenSuppressedByRule() {
        let cal = Calendar.current
        let charges = (0..<4).map { i in
            txn("Netflix", 15, date: cal.date(byAdding: .day, value: -30 * i, to: Date())!)
        }
        let key = SubscriptionDetector.merchantKey("Netflix")
        let withCard = generate(transactions: charges).filter { $0.kind == .subscription }
        XCTAssertTrue(withCard.contains { $0.merchantKey == key })

        let rule = SubscriptionRule(merchantKey: key, amount: 15, isSubscription: true, displayName: "Netflix")
        let suppressed = generate(transactions: charges, rules: [rule]).filter { $0.kind == .subscription }
        XCTAssertFalse(suppressed.contains { $0.merchantKey == key })
    }

    func testRecurringSplitFromTemplate() {
        let group = UUID()
        let tmpl = SplitTemplate(merchantKey: SubscriptionDetector.merchantKey("Rent"), groupId: group,
                                 category: "Rent", sharesJSON: SplitTemplate.encode([me: 0.5, alex: 0.5]),
                                 source: "auto", displayName: "Rent")
        let t = txn("Rent", 2000)
        let cards = generate(transactions: [t], templates: [tmpl]).filter { $0.kind == .recurringSplit }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.transactionId, t.id)
    }

    func testDismissalSuppresses() {
        let t = txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")
        let decision = SuggestionDecision(key: "cat:\(t.id.uuidString):Shopping", decision: "dismissed")
        let cards = generate(transactions: [t], decisions: [decision])
        XCTAssertTrue(cards.filter { $0.kind == .categorize }.isEmpty)
    }

    func testDistributeRoundsToExactTotal() {
        let parts = SuggestionService.distribute(100, fractions: [me: 0.5, alex: 0.5])
        XCTAssertEqual(parts.reduce(Decimal(0)) { $0 + $1.1 }, 100)
        // A 1/3 split still sums exactly (remainder absorbed).
        let thirds = SuggestionService.distribute(100, fractions: ["a": 1, "b": 1, "c": 1])
        XCTAssertEqual(thirds.reduce(Decimal(0)) { $0 + $1.1 }, 100)
    }
}

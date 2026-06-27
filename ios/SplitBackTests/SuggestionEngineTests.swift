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
                          decisions: [SuggestionDecision] = [],
                          linkThreshold: Double = SuggestionEngine.defaultLinkThreshold) -> [Suggestion] {
        SuggestionEngine.generate(transactions: transactions, expenses: expenses, lookup: [:], sources: [:],
                                  templates: templates, rules: rules, decisions: decisions, me: me,
                                  linkThreshold: linkThreshold)
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
        // Confidence rides along for the confirmation sheet.
        XCTAssertEqual(links.first?.matchScore ?? 0, 1.0, accuracy: 0.0001)
    }

    func testLinkThresholdGatesLooserMatches() {
        // Exact amount but 5 days apart and no name overlap → score ≈ 0.78: below Strict (0.85), above Loose.
        let date = Date()
        let e = expense("Acme", 50, category: "Dining", splits: [(me, 50)], date: date)
        let t = txn("Zenith", 50, date: Calendar.current.date(byAdding: .day, value: 5, to: date)!)
        XCTAssertTrue(generate(transactions: [t], expenses: [e], linkThreshold: 0.85)
            .filter { $0.kind == .link }.isEmpty)
        let loose = generate(transactions: [t], expenses: [e], linkThreshold: 0.70).filter { $0.kind == .link }
        XCTAssertEqual(loose.count, 1)
        if let score = loose.first?.matchScore { XCTAssertTrue((0.70..<0.85).contains(score)) }
        else { XCTFail("expected a match score") }
    }

    func testLinkSensitivityThresholds() {
        XCTAssertEqual(LinkSensitivity.strict.threshold, 0.85, accuracy: 0.0001)
        XCTAssertEqual(LinkSensitivity.balanced.threshold, 0.78, accuracy: 0.0001)
        XCTAssertEqual(LinkSensitivity.loose.threshold, 0.70, accuracy: 0.0001)
    }

    func testLinkSensitivityDefaultsStrict() {
        let suite = "test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LinkSensitivity.current(d), .strict)       // unset → strict (preserves prior behavior)
        d.set(LinkSensitivity.loose.rawValue, forKey: LinkSensitivity.storageKey)
        XCTAssertEqual(LinkSensitivity.current(d), .loose)
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
        // The categorize card is keyed by merchant (lowercased details) + suggestion, so a dismissal sticks.
        let t = txn("Store", 10, category: "GENERAL_SERVICES", ai: "Shopping")
        let decision = SuggestionDecision(key: "cat:store:Shopping", decision: "dismissed")
        let cards = generate(transactions: [t], decisions: [decision])
        XCTAssertTrue(cards.filter { $0.kind == .categorize }.isEmpty)
    }

    func testCategorizeAggregatesByDescription() {
        // Same merchant + same AI suggestion → one accept-all card; a different merchant → its own.
        let cards = generate(transactions: [
            txn("BURRITO PALACE", 12, category: "GENERAL_SERVICES", ai: "Dining"),
            txn("BURRITO PALACE", 9, category: "GENERAL_SERVICES", ai: "Dining"),
            txn("ACME FUEL", 40, category: "GENERAL_SERVICES", ai: "Fuel"),
        ]).filter { $0.kind == .categorize }
        XCTAssertEqual(cards.count, 2)
        let burrito = cards.first { $0.title == "BURRITO PALACE" }
        XCTAssertEqual(burrito?.transactionIds.count, 2)
        XCTAssertEqual(burrito?.category, "Dining")
        XCTAssertTrue(burrito?.subtitle.contains("2 transactions") ?? false)
        let fuel = cards.first { $0.title == "ACME FUEL" }
        XCTAssertEqual(fuel?.transactionIds.count, 1)
        XCTAssertFalse(fuel?.subtitle.contains("transactions") ?? true)  // no count suffix for a single txn
    }

    func testDistributeRoundsToExactTotal() {
        let parts = SuggestionService.distribute(100, fractions: [me: 0.5, alex: 0.5])
        XCTAssertEqual(parts.reduce(Decimal(0)) { $0 + $1.1 }, 100)
        // A 1/3 split still sums exactly (remainder absorbed).
        let thirds = SuggestionService.distribute(100, fractions: ["a": 1, "b": 1, "c": 1])
        XCTAssertEqual(thirds.reduce(Decimal(0)) { $0 + $1.1 }, 100)
    }
}

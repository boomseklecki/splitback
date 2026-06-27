import XCTest
@testable import SplitBackAPI

final class RelatedTransactionsTests: XCTestCase {
    private let cal = Calendar.current

    private func date(_ daysAgo: Int) -> Date {
        cal.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func txn(_ details: String, _ amount: Decimal = 20, daysAgo: Int = 0,
                     source: TransactionSource = .plaid) -> Transaction {
        Transaction(id: UUID(), accountId: UUID(), source: source, details: details,
                    amount: amount, currency: "USD", date: date(daysAgo), category: "Software",
                    createdAt: Date(), updatedAt: Date())
    }

    /// The user's case: three description variants of one merchant. Seeding from the multi-word variant
    /// catches all three via shared "anthropic"/"claude" tokens.
    func testMultiWordSeedGroupsAllVariants() {
        let all = [txn("ANTHROPIC"), txn("ANTHROPIC CLAUDE SUB"), txn("CLAUDE.AI SUBSCRIPTION"),
                   txn("NETFLIX.COM")]
        let group = RelatedTransactions.group(seedDescription: "ANTHROPIC CLAUDE SUB", in: all)
        let details = Set(group.map(\.details))
        XCTAssertEqual(details, ["ANTHROPIC", "ANTHROPIC CLAUDE SUB", "CLAUDE.AI SUBSCRIPTION"])
        XCTAssertFalse(details.contains("NETFLIX.COM"))
    }

    /// Conservative / seed-relative: a bare seed only matches descriptions sharing *its* word, so it does
    /// not transitively reach "CLAUDE.AI SUBSCRIPTION".
    func testBareSeedIsConservative() {
        let all = [txn("ANTHROPIC"), txn("ANTHROPIC CLAUDE SUB"), txn("CLAUDE.AI SUBSCRIPTION")]
        let details = Set(RelatedTransactions.group(seedDescription: "ANTHROPIC", in: all).map(\.details))
        XCTAssertEqual(details, ["ANTHROPIC", "ANTHROPIC CLAUDE SUB"])
        XCTAssertFalse(details.contains("CLAUDE.AI SUBSCRIPTION"))
    }

    func testUnrelatedMerchantExcluded() {
        let all = [txn("SPOTIFY USA"), txn("NETFLIX.COM"), txn("HULU 877-824-4858")]
        let group = RelatedTransactions.group(seedDescription: "SPOTIFY", in: all)
        XCTAssertEqual(group.map(\.details), ["SPOTIFY USA"])
    }

    /// A noise-only / empty seed has nothing meaningful to match on → empty group.
    func testNoiseOnlySeedGroupsNothing() {
        let all = [txn("ANTHROPIC"), txn("SUBSCRIPTION PAYMENT")]
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "SUBSCRIPTION PAYMENT", in: all).isEmpty)
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "", in: all).isEmpty)
    }

    func testResultsSortedNewestFirst() {
        let all = [txn("ANTHROPIC", daysAgo: 30), txn("ANTHROPIC CLAUDE", daysAgo: 0),
                   txn("ANTHROPIC", daysAgo: 60)]
        let group = RelatedTransactions.group(seedDescription: "ANTHROPIC", in: all)
        XCTAssertEqual(group.map(\.date), group.map(\.date).sorted(by: >))
    }

    func testDisplayNameTitleCasesBrandWords() {
        XCTAssertEqual(RelatedTransactions.displayName(for: "ANTHROPIC CLAUDE SUB"), "Anthropic Claude Sub")
        XCTAssertEqual(RelatedTransactions.displayName(for: "CLAUDE.AI SUBSCRIPTION"), "Claude")
    }

    // MARK: - Strictness tiers

    /// One shared generic word ("joes"/"trader") over-matches under Fuzzy but is cut by Balanced/Strict.
    func testTiersFilterSingleSharedWord() {
        let all = [txn("TRADER JOES #123"), txn("JOES CRAB SHACK"), txn("TRADER VICS")]
        func names(_ s: RelatedTransactions.MatchStrictness) -> Set<String> {
            Set(RelatedTransactions.group(seedDescription: "TRADER JOES #456", in: all, strictness: s)
                .map(\.details))
        }
        XCTAssertEqual(names(.fuzzy), ["TRADER JOES #123", "JOES CRAB SHACK", "TRADER VICS"])
        XCTAssertEqual(names(.balanced), ["TRADER JOES #123"])
        XCTAssertEqual(names(.strict), ["TRADER JOES #123"])
    }

    /// Two-of-three shared words: Balanced keeps it (0.667 > 0.5), Strict drops it (neither set is a subset).
    func testBalancedVsStrictDiverge() {
        let all = [txn("BLUE BOTTLE CAFE")]
        let seed = "BLUE BOTTLE COFFEE"
        XCTAssertEqual(RelatedTransactions.group(seedDescription: seed, in: all, strictness: .balanced).count, 1)
        XCTAssertTrue(RelatedTransactions.group(seedDescription: seed, in: all, strictness: .strict).isEmpty)
    }

    /// The default strictness is Balanced (a single-word overlap out of 2+ tokens is excluded).
    func testDefaultStrictnessIsBalanced() {
        let all = [txn("JOES CRAB SHACK")]
        XCTAssertTrue(RelatedTransactions.group(seedDescription: "TRADER JOES", in: all).isEmpty)
    }

    /// The user's Apple Card case: a recurring $9.99 subscription lumped with one-off charges under the same
    /// "APPLE.COM" description. Strict groups every Apple row; Exact (merchant + amount) isolates the $9.99s;
    /// Exact with no seed amount falls back to Strict.
    func testExactMatchIsolatesByAmount() {
        let all = [txn("APPLE.COM/BILL", 9.99, daysAgo: 0), txn("APPLE.COM/BILL", 9.99, daysAgo: 30),
                   txn("APPLE.COM/BILL", 4.99, daysAgo: 5)]
        XCTAssertEqual(RelatedTransactions.group(seedDescription: "APPLE.COM/BILL", in: all,
                                                 strictness: .strict).count, 3)
        let exact = RelatedTransactions.group(seedDescription: "APPLE.COM/BILL", seedAmount: 9.99, in: all,
                                              strictness: .exact)
        XCTAssertEqual(exact.count, 2)
        XCTAssertTrue(exact.allSatisfy { $0.amount == 9.99 })
        // No seed amount → behaves like Strict (no amount filter).
        XCTAssertEqual(RelatedTransactions.group(seedDescription: "APPLE.COM/BILL", seedAmount: nil, in: all,
                                                 strictness: .exact).count, 3)
    }
}

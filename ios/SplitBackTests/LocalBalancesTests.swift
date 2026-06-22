import XCTest
@testable import SplitBackAPI

@MainActor
final class LocalBalancesTests: XCTestCase {
    private func expense(_ amount: Decimal, group: UUID, category: String? = nil, archived: Date? = nil,
                         splits: [(String, Decimal, Decimal)]) -> Expense {
        Expense(id: UUID(), groupId: group, details: "e", amount: amount, currency: "USD",
                date: Date(), category: category, archivedAt: archived, createdAt: Date(), updatedAt: Date(),
                splits: splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: $0.1, owedShare: $0.2) })
    }

    func testForGroupNetsSumToZero() {
        let g = UUID()
        // Matt paid $60, split equally three ways ($20 each): Matt +40, Nikki/Sam −20.
        let exps = [expense(60, group: g, splits: [("matt", 60, 20), ("nikki", 0, 20), ("sam", 0, 20)])]
        let balances = LocalBalances.forGroup(exps)
        let byId = Dictionary(balances.map { ($0.identifier, $0.net) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byId["matt"], 40)
        XCTAssertEqual(byId["nikki"], -20)
        XCTAssertEqual(byId["sam"], -20)
        XCTAssertEqual(balances.reduce(Decimal(0)) { $0 + $1.net }, 0)
        XCTAssertEqual(balances.first?.identifier, "matt")  // sorted creditors-first
    }

    func testArchivedExpensesExcluded() {
        let g = UUID()
        let exps = [
            expense(60, group: g, splits: [("matt", 60, 20), ("nikki", 0, 40)]),
            expense(100, group: g, archived: Date(), splits: [("nikki", 100, 50), ("matt", 0, 50)]),
        ]
        let byId = Dictionary(LocalBalances.forGroup(exps).map { ($0.identifier, $0.net) },
                              uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byId["matt"], 40)   // only the active expense counts
        XCTAssertEqual(byId["nikki"], -40)
    }

    func testSettleUpNetsOut() {
        let g = UUID()
        // Nikki pays Matt $40 back: nets cancel the prior +40/−40.
        let exps = [
            expense(60, group: g, splits: [("matt", 60, 20), ("nikki", 0, 40)]),
            expense(40, group: g, category: SettleUp.category, splits: [("nikki", 40, 0), ("matt", 0, 40)]),
        ]
        let byId = Dictionary(LocalBalances.forGroup(exps).map { ($0.identifier, $0.net) },
                              uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byId["matt"], 0)
        XCTAssertEqual(byId["nikki"], 0)
    }
}

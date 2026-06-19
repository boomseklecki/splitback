import XCTest
@testable import SplitBackAPI

final class SplitMathTests: XCTestCase {
    func testEqualSplitEvenlyDivisible() {
        let splits = SplitMath.equalSplit(amount: 10, payer: "matt", participants: ["matt", "nikki"])
        XCTAssertEqual(splits.count, 2)
        XCTAssertEqual(SplitMath.owedSum(splits), 10)
        XCTAssertEqual(SplitMath.paidSum(splits), 10)
        XCTAssertEqual(splits.first(where: { $0.userIdentifier == "matt" })?.paidShare, 10)
        XCTAssertEqual(splits.first(where: { $0.userIdentifier == "nikki" })?.paidShare, 0)
        XCTAssertTrue(splits.allSatisfy { $0.owedShare == 5 })
    }

    func testEqualSplitDistributesRemainderPennies() {
        let splits = SplitMath.equalSplit(amount: Decimal(string: "10.01")!,
                                          payer: "a", participants: ["a", "b", "c"])
        // 1001 cents / 3 = 333 each, remainder 2 -> first two get 3.34, last 3.33.
        XCTAssertEqual(SplitMath.owedSum(splits), Decimal(string: "10.01"))
        XCTAssertEqual(splits[0].owedShare, Decimal(string: "3.34"))
        XCTAssertEqual(splits[1].owedShare, Decimal(string: "3.34"))
        XCTAssertEqual(splits[2].owedShare, Decimal(string: "3.33"))
        XCTAssertTrue(SplitMath.isBalanced(amount: Decimal(string: "10.01")!, splits: splits))
    }

    func testIsBalancedTolerance() {
        let off = [SplitDraft(userIdentifier: "a", paidShare: 10, owedShare: 9)]
        XCTAssertFalse(SplitMath.isBalanced(amount: 10, splits: off))
        let within = [SplitDraft(userIdentifier: "a", paidShare: 10, owedShare: Decimal(string: "9.995")!)]
        XCTAssertTrue(SplitMath.isBalanced(amount: 10, splits: within))
    }

    func testSettleUpCollapse() {
        func expense(_ name: String, category: String?) -> Expense {
            Expense(id: UUID(), groupId: UUID(), details: name, amount: 1, currency: "USD",
                    date: Date(), category: category, createdAt: Date(), updatedAt: Date())
        }
        // Newest-first: two recent, a settle-up, then two older.
        let expenses = [
            expense("new1", category: "food"),
            expense("new2", category: "food"),
            expense("settle", category: SettleUp.category),
            expense("old1", category: "food"),
            expense("old2", category: "food")
        ]
        let result = SettleUp.collapseOlder(expenses)
        XCTAssertEqual(result.visible.map(\.details), ["new1", "new2", "settle"])
        XCTAssertEqual(result.collapsed, 2)
    }

    func testSettleUpNoSettleUpShowsAll() {
        let result = SettleUp.collapseOlder([])
        XCTAssertEqual(result.collapsed, 0)
    }
}

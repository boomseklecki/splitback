import XCTest
@testable import SplitBackAPI

final class TransactionMappingTests: XCTestCase {
    func testTransactionCreateReverseMapper() {
        let draft = TransactionDraft(
            details: "Coffee", amount: Decimal(string: "4.50")!,
            date: Mapping.dateOnlyFormatter.date(from: "2026-06-19")!, category: "coffee"
        )
        let create = Mapping.transactionCreate(draft)
        XCTAssertEqual(create.amount, "4.5")  // Decimal("4.50") normalizes to 4.5; server accepts it
        XCTAssertEqual(create.description, "Coffee")
        XCTAssertEqual(create.date, "2026-06-19")
        XCTAssertEqual(create.category, "coffee")
        XCTAssertNil(create.account_id)
    }

    func testMonthGroupsBucketsNewestFirst() {
        let cal = Calendar.current
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d))!
        }
        // Two June dates and one May date, fed in mixed order.
        let dates = [day(2026, 6, 20), day(2026, 5, 2), day(2026, 6, 5)]
        let groups = monthGroups(dates, date: { $0 })
        XCTAssertEqual(groups.map(\.id), ["2026-6", "2026-5"])           // newest month first
        XCTAssertEqual(groups.map(\.label), ["June 2026", "May 2026"])
        XCTAssertEqual(groups.first?.items.count, 2)                      // both June dates bucketed together
        XCTAssertEqual(groups.last?.items, [day(2026, 5, 2)])
    }

    func testExpensePrefillFromTransaction() {
        let id = UUID()
        let transaction = Transaction(
            id: id, source: .manual, details: "Lunch", amount: Decimal(string: "20.00")!,
            currency: "USD", date: Mapping.dateOnlyFormatter.date(from: "2026-06-18")!,
            category: "food", createdAt: Date(), updatedAt: Date()
        )
        let prefill = ExpensePrefill.from(transaction)
        XCTAssertEqual(prefill.details, "Lunch")
        XCTAssertEqual(prefill.amount, Decimal(string: "20.00"))
        XCTAssertEqual(prefill.category, "food")
        XCTAssertEqual(prefill.transactionId, id)
        XCTAssertTrue(prefill.items.isEmpty)
    }
}

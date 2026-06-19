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

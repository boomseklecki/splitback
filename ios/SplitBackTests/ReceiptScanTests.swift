import XCTest
@testable import SplitBackAPI

final class ReceiptHeuristicsTests: XCTestCase {
    func testTotalPrefersTotalLineOverSubtotal() {
        let text = "Store ABC\nSubtotal 10.00\nTax 2.34\nTotal 12.34"
        XCTAssertEqual(ReceiptHeuristics.parse(text).total, Decimal(string: "12.34"))
    }

    func testTotalFallsBackToLargestAmount() {
        let text = "Corner Shop\nItem A 3.00\nItem B 9.99"
        XCTAssertEqual(ReceiptHeuristics.parse(text).total, Decimal(string: "9.99"))
    }

    func testCommaThousandsSeparator() {
        XCTAssertEqual(ReceiptHeuristics.parse("Total 1,234.56").total, Decimal(string: "1234.56"))
    }

    func testMerchantIsFirstLine() {
        XCTAssertEqual(ReceiptHeuristics.parse("Trader Joe's\nfoo 1.00").merchant, "Trader Joe's")
    }

    func testDateDetected() {
        XCTAssertNotNil(ReceiptHeuristics.parse("Receipt\nDate 06/19/2026\nTotal 5.00").date)
    }
}

final class ExpensePrefillTests: XCTestCase {
    func testPrefillFromExtraction() {
        let extraction = ReceiptExtraction(
            merchant: "Cafe", date: "2026-06-19", total: 12.5,
            items: [ExtractedItem(name: "Latte", quantity: 1, price: 5.5, category: "coffee")]
        )
        let prefill = ExpensePrefill.from(extraction)
        XCTAssertEqual(prefill.details, "Cafe")
        XCTAssertEqual(prefill.amount, Decimal(string: "12.50"))
        XCTAssertEqual(prefill.date, Mapping.dateOnlyFormatter.date(from: "2026-06-19"))
        XCTAssertEqual(prefill.category, "coffee")
        XCTAssertEqual(prefill.items.count, 1)
        XCTAssertEqual(prefill.items.first?.price, Decimal(string: "5.50"))
    }

    func testPrefillFromHeuristics() {
        let result = ReceiptHeuristics.Result(merchant: "Shop", date: nil, total: Decimal(string: "9.99"))
        let prefill = ExpensePrefill.from(result)
        XCTAssertEqual(prefill.details, "Shop")
        XCTAssertEqual(prefill.amount, Decimal(string: "9.99"))
        XCTAssertTrue(prefill.items.isEmpty)
    }
}

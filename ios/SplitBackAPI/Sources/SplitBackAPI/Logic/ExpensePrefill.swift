import Foundation

/// Seed values for a new expense, produced from a receipt scan (model extraction or heuristics) or
/// from a bank transaction. The user confirms/adjusts (and enters splits) in `ExpenseEditView`.
struct ExpensePrefill {
    var details: String
    var amount: Decimal
    var date: Date
    var category: String?
    var items: [ItemDraft]
    /// Links the created expense back to the originating transaction, if any.
    var transactionId: UUID? = nil

    /// From a bank/manual transaction (carries `transactionId` so the expense links to it).
    static func from(_ transaction: Transaction) -> ExpensePrefill {
        ExpensePrefill(
            details: transaction.details,
            amount: transaction.amount,
            date: transaction.date,
            category: transaction.category,
            items: [],
            transactionId: transaction.id
        )
    }

    /// From the on-device model extraction.
    static func from(_ extraction: ReceiptExtraction) -> ExpensePrefill {
        ExpensePrefill(
            details: extraction.merchant,
            amount: decimal(extraction.total),
            date: recentReceiptDate(Mapping.dateOnlyFormatter.date(from: extraction.date)),
            category: extraction.items.first?.category,
            items: extraction.items.map {
                ItemDraft(name: $0.name, quantity: decimal($0.quantity), price: decimal($0.price), category: $0.category)
            }
        )
    }

    /// From the model-free heuristic parse.
    static func from(_ result: ReceiptHeuristics.Result) -> ExpensePrefill {
        ExpensePrefill(
            details: result.merchant ?? "",
            amount: result.total ?? 0,
            date: recentReceiptDate(result.date),
            category: nil,
            items: []
        )
    }

    /// Bounds a scanned receipt date to a realistic window. A receipt can't be in the future, and a date
    /// older than `window` days is almost certainly a wrong-year extraction → fall back to today (receipts are
    /// scanned fresh). nil → today. Date-only (start of day). Only the receipt-scan funnels clamp; a bank
    /// transaction's date is authoritative.
    static func recentReceiptDate(_ date: Date?, now: Date = Date(), window: Int = 60) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let earliest = cal.date(byAdding: .day, value: -window, to: today) ?? today
        guard let date, case let d = cal.startOfDay(for: date), d >= earliest, d <= today else { return today }
        return d
    }

    /// Double → Decimal rounded to 2 places (avoids binary-float noise in money).
    private static func decimal(_ value: Double) -> Decimal {
        Decimal(string: String(format: "%.2f", value)) ?? 0
    }
}

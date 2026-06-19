import Foundation
import SwiftData

/// A line item on an expense (e.g. a single product on a receipt). Mirrors `expense_items`.
@Model
final class ExpenseItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var quantity: Decimal
    var price: Decimal
    var category: String?
    var expense: Expense?

    init(
        id: UUID,
        name: String,
        quantity: Decimal,
        price: Decimal,
        category: String? = nil,
        expense: Expense? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.price = price
        self.category = category
        self.expense = expense
    }
}

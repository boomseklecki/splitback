import Foundation
import SwiftData

/// A bank/manual transaction. Mirrors the server `transactions` table.
/// Dedupe key for Plaid-sourced rows is `plaidTransactionId`.
///
/// Note: the type name shadows SwiftUI's `Transaction`; qualify as `SwiftUI.Transaction` where the
/// animation type is needed in views.
@Model
final class Transaction {
    @Attribute(.unique) var id: UUID
    var accountId: UUID?
    var plaidTransactionId: String?
    var source: TransactionSource
    var details: String
    var amount: Decimal
    var currency: String
    var date: Date
    var category: String?
    var pending: Bool
    /// On-device (Apple Intelligence) category refinement from the merchant description, for rows whose
    /// Plaid category is vague ("Other"/uncategorized). Client-only and derived — not synced, and the
    /// transaction upsert never clears it.
    var refinedCategory: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        accountId: UUID? = nil,
        plaidTransactionId: String? = nil,
        source: TransactionSource,
        details: String,
        amount: Decimal,
        currency: String,
        date: Date,
        category: String? = nil,
        pending: Bool = false,
        refinedCategory: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.plaidTransactionId = plaidTransactionId
        self.source = source
        self.details = details
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.pending = pending
        self.refinedCategory = refinedCategory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

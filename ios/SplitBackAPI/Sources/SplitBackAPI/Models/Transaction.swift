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
    /// On a posted row, the `plaidTransactionId` of the pending charge it replaced (Plaid's value). Lets the
    /// app point a user from a since-posted pending transaction to its posted twin. Null otherwise.
    var pendingTransactionId: String?
    var source: TransactionSource
    var details: String
    var amount: Decimal
    var currency: String
    var date: Date
    var category: String?
    /// Explicit per-transaction canonical category (manual pick or on-device AI on this one row).
    /// Backend-synced and independent of the label-wide category map — wins over it in `effectiveCategory`.
    var categoryOverride: String?
    /// The caller's per-user budget overrides (from `transaction_overrides`); nil = the default (derive from
    /// the account). Excludes this transaction from spending / cash-flow analytics.
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    var pending: Bool
    /// On-device (Apple Intelligence) category refinement from the merchant description, for rows whose
    /// Plaid category is vague ("Other"/uncategorized). Client-only and derived — not synced, and the
    /// transaction upsert never clears it.
    var refinedCategory: String?
    /// The on-device AI's *opinion* of this transaction's category, kept even when a higher-precedence
    /// layer wins — distinct from `refinedCategory` (a fallback used in resolution). Powers the review
    /// queue's "recategorize" suggestions. Client-only, derived, never synced; survives the upsert.
    var aiSuggestedCategory: String?
    /// Line items breaking this transaction's spend across categories (receipt itemization). Empty for a
    /// flat transaction; when present, analytics attribute each item to its own category.
    @Relationship(deleteRule: .cascade, inverse: \TransactionItem.transaction)
    var items: [TransactionItem]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        accountId: UUID? = nil,
        plaidTransactionId: String? = nil,
        pendingTransactionId: String? = nil,
        source: TransactionSource,
        details: String,
        amount: Decimal,
        currency: String,
        date: Date,
        category: String? = nil,
        categoryOverride: String? = nil,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        pending: Bool = false,
        refinedCategory: String? = nil,
        items: [TransactionItem] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.accountId = accountId
        self.plaidTransactionId = plaidTransactionId
        self.pendingTransactionId = pendingTransactionId
        self.source = source
        self.details = details
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.categoryOverride = categoryOverride
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.pending = pending
        self.refinedCategory = refinedCategory
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

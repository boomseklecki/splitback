import Foundation
import SwiftData

/// An expense in a group, with its splits, line items, and receipts.
/// Mirrors the server `expenses` table. Dedupe key for Splitwise-sourced rows is
/// `splitwiseExpenseId`.
@Model
final class Expense {
    @Attribute(.unique) var id: UUID
    var groupId: UUID
    var transactionId: UUID?
    var splitwiseExpenseId: String?
    var details: String
    var amount: Decimal
    var currency: String
    var date: Date
    var category: String?
    /// Who added the expense (user identifier, from Splitwise created_by); nil for self-hosted.
    var createdByIdentifier: String?
    /// Splitwise receipt image URL (remote) + the simplified repayments as a raw JSON string, from import.
    var splitwiseReceiptURL: String?
    var splitwiseRepayments: String?
    /// Soft-delete marker; null = active. Archived expenses are excluded from the list endpoint
    /// and from balances, but still fetchable by id.
    var archivedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Split.expense)
    var splits: [Split]
    @Relationship(deleteRule: .cascade, inverse: \ExpenseItem.expense)
    var items: [ExpenseItem]
    @Relationship(deleteRule: .cascade, inverse: \Receipt.expense)
    var receipts: [Receipt]

    init(
        id: UUID,
        groupId: UUID,
        transactionId: UUID? = nil,
        splitwiseExpenseId: String? = nil,
        details: String,
        amount: Decimal,
        currency: String,
        date: Date,
        category: String? = nil,
        createdByIdentifier: String? = nil,
        splitwiseReceiptURL: String? = nil,
        splitwiseRepayments: String? = nil,
        archivedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        splits: [Split] = [],
        items: [ExpenseItem] = [],
        receipts: [Receipt] = []
    ) {
        self.id = id
        self.groupId = groupId
        self.transactionId = transactionId
        self.splitwiseExpenseId = splitwiseExpenseId
        self.details = details
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.createdByIdentifier = createdByIdentifier
        self.splitwiseReceiptURL = splitwiseReceiptURL
        self.splitwiseRepayments = splitwiseRepayments
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.splits = splits
        self.items = items
        self.receipts = receipts
    }
}

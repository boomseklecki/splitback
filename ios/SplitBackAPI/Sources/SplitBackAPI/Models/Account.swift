import Foundation
import SwiftData

/// A financial account (Plaid-linked or manual). Mirrors the server `accounts` table.
@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    var type: String?
    var plaidAccountId: String?
    /// Present server-side but not returned by `GET /accounts`; left nil when mapped from the API.
    var plaidItemId: UUID?
    var balance: Decimal
    var currency: String
    /// Goals-analytics inclusion overrides; nil = derive from the account's classification (subtype).
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        type: String? = nil,
        plaidAccountId: String? = nil,
        plaidItemId: UUID? = nil,
        balance: Decimal,
        currency: String,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.plaidAccountId = plaidAccountId
        self.plaidItemId = plaidItemId
        self.balance = balance
        self.currency = currency
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

import Foundation
import SwiftData

/// A financial account (Plaid-linked or manual). Mirrors the server `accounts` table.
@Model
final class Account {
    @Attribute(.unique) var id: UUID
    var name: String
    /// User-set display name overriding the Plaid `name`; nil = show `name`. Survives Plaid re-sync.
    var displayName: String?
    var type: String?
    /// User-set classification override ("cash_flow" | "liability" | "savings"); nil = derive from `type`.
    var kindOverride: String?
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
        displayName: String? = nil,
        type: String? = nil,
        kindOverride: String? = nil,
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
        self.displayName = displayName
        self.type = type
        self.kindOverride = kindOverride
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

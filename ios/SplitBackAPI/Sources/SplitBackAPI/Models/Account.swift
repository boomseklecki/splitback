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
    /// The account number's last few digits (Plaid `mask`), shown on the account row; nil for manual.
    var mask: String?
    var plaidAccountId: String?
    /// Present server-side but not returned by `GET /accounts`; left nil when mapped from the API.
    var plaidItemId: UUID?
    var balance: Decimal
    var currency: String
    /// Goals-analytics inclusion overrides; nil = derive from the account's classification (subtype).
    var includeInSpending: Bool?
    var includeInCashFlow: Bool?
    /// Institution branding (denormalized from the account's bank): name, logo domain, brand hex color, and
    /// Plaid connection status. nil for manual accounts (or Plaid accounts not yet re-synced).
    var institutionName: String?
    var institutionDomain: String?
    var institutionColor: String?
    var institutionStatus: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        name: String,
        displayName: String? = nil,
        type: String? = nil,
        kindOverride: String? = nil,
        mask: String? = nil,
        plaidAccountId: String? = nil,
        plaidItemId: UUID? = nil,
        balance: Decimal,
        currency: String,
        includeInSpending: Bool? = nil,
        includeInCashFlow: Bool? = nil,
        institutionName: String? = nil,
        institutionDomain: String? = nil,
        institutionColor: String? = nil,
        institutionStatus: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.type = type
        self.kindOverride = kindOverride
        self.mask = mask
        self.plaidAccountId = plaidAccountId
        self.plaidItemId = plaidItemId
        self.balance = balance
        self.currency = currency
        self.includeInSpending = includeInSpending
        self.includeInCashFlow = includeInCashFlow
        self.institutionName = institutionName
        self.institutionDomain = institutionDomain
        self.institutionColor = institutionColor
        self.institutionStatus = institutionStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

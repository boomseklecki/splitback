import Foundation

/// Resolves a transaction's raw Plaid category to a canonical one using the synced `category_map`.
enum CategoryMapping {
    /// Builds a fast raw→canonical lookup from the cached map rows.
    static func lookup(_ maps: [CategoryMap]) -> [String: String] {
        Dictionary(maps.map { ($0.rawCategory, $0.canonicalCategory) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The canonical category for a transaction. Precedence: an explicit user/on-device override in the
    /// synced map, else the built-in deterministic Plaid taxonomy map, else the raw string itself (so an
    /// already-canonical or unrecognized label still groups). Nil only when there's no category.
    static func effectiveCategory(for transaction: Transaction, lookup: [String: String]) -> String? {
        guard let raw = transaction.category, !raw.isEmpty else { return nil }
        return canonical(raw, lookup: lookup)
    }

    /// Resolves a raw category string the same way (used where only the string is available).
    static func canonical(_ raw: String, lookup: [String: String]) -> String? {
        guard !raw.isEmpty else { return nil }
        return lookup[raw] ?? PlaidCategory.canonical(raw) ?? raw
    }
}

/// Canonical categories that are internal transfers / income — excluded from spend totals and
/// (for Transfer) from net income, so card payments and account-to-account moves don't distort it.
/// Mirrors `backend/app/categories.py`.
enum CanonicalCategory {
    static let excludedFromSpend: Set<String> = ["Transfer", "Income", "Settle-up"]
    static let transfer = "Transfer"

    /// The app's canonical taxonomy (kept in sync with the backend list). Used by the on-device mapper
    /// to constrain its output and by the category palette.
    static let all: [String] = [
        "Groceries", "Dining", "Transport", "Fuel", "Utilities", "Rent", "Mortgage",
        "Entertainment", "Travel", "Health", "Insurance", "Shopping", "Household",
        "Subscriptions", "Education", "Gifts", "Personal Care", "Pets", "Fees",
        "Income", "Transfer", "Settle-up", "Other",
    ]
}

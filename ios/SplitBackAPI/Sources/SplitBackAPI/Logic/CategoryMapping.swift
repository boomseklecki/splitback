import Foundation

/// Resolves a transaction's raw Plaid category to a canonical one using the synced `category_map`.
enum CategoryMapping {
    /// Builds a fast raw→canonical lookup from the cached map rows.
    static func lookup(_ maps: [CategoryMap]) -> [String: String] {
        Dictionary(maps.map { ($0.rawCategory, $0.canonicalCategory) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The canonical category for a transaction. Precedence: an explicit user/on-device override in the
    /// synced map → a confident built-in Plaid mapping → the per-transaction on-device refinement (for
    /// vague rows) → the built-in "Other"/raw string. Nil only when there's no category.
    static func effectiveCategory(for transaction: Transaction, lookup: [String: String]) -> String? {
        guard let raw = transaction.category, !raw.isEmpty else { return nil }
        if let explicit = lookup[raw] { return explicit }
        let builtin = PlaidCategory.canonical(raw)
        if let builtin, builtin != "Other" { return builtin }
        if let refined = transaction.refinedCategory, !refined.isEmpty { return refined }
        return builtin ?? raw
    }

    /// Resolves a raw category string without a transaction's refinement (map → built-in → raw).
    static func canonical(_ raw: String, lookup: [String: String]) -> String? {
        guard !raw.isEmpty else { return nil }
        return lookup[raw] ?? PlaidCategory.canonical(raw) ?? raw
    }

    /// Whether a transaction's category is vague enough to benefit from a description-based refinement:
    /// no explicit override and the built-in map yields "Other" or nothing.
    static func needsRefinement(_ transaction: Transaction, lookup: [String: String]) -> Bool {
        guard transaction.source == .plaid, let raw = transaction.category, !raw.isEmpty,
              lookup[raw] == nil else { return false }
        let builtin = PlaidCategory.canonical(raw)
        return builtin == nil || builtin == "Other"
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

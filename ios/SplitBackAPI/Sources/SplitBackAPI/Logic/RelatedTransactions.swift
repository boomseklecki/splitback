import Foundation

/// Conservative, seed-relative fuzzy grouping of transactions by merchant description, for batch
/// recategorization. A transaction is "related" iff its significant words overlap the *exact* description
/// you tapped (single pass, no transitive chaining) — so "ANTHROPIC CLAUDE SUB" groups with both
/// "ANTHROPIC" and "CLAUDE.AI SUBSCRIPTION", while unrelated merchants stay out. Pure and unit-tested.
enum RelatedTransactions {
    /// Bank/manual transactions whose significant words overlap the seed description's, most recent first.
    /// Returns `[]` when the seed has no significant words (nothing meaningful to match on).
    static func group(seedDescription: String, in transactions: [Transaction]) -> [Transaction] {
        let seed = SubscriptionDetector.significantTokens(seedDescription)
        guard !seed.isEmpty else { return [] }
        return transactions
            .filter { $0.source == .plaid || $0.source == .manual }
            .filter { !SubscriptionDetector.significantTokens($0.details).isDisjoint(with: seed) }
            .sorted { $0.date > $1.date }
    }

    /// A human title for the group, derived from the seed's brand words (e.g. "ANTHROPIC CLAUDE SUB" →
    /// "Anthropic Claude"), falling back to the raw description when there are none.
    static func displayName(for seedDescription: String) -> String {
        let words = SubscriptionDetector.significantWords(seedDescription).prefix(3)
        guard !words.isEmpty else { return seedDescription }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

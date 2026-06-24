import Foundation

/// Conservative, seed-relative grouping of transactions by merchant description, for batch recategorization.
/// A transaction is "related" when its significant words overlap the *exact* description you tapped (single
/// pass, no transitive chaining), with a user-chosen strictness on how much overlap is required — so a single
/// shared generic word ("...JOE'S CRAB SHACK" vs "TRADER JOE'S") need not pull in unrelated merchants. Pure
/// and unit-tested.
enum RelatedTransactions {
    /// How much significant-word overlap a transaction must share with the seed to be "related".
    enum MatchStrictness: String, CaseIterable, Identifiable {
        case fuzzy     // any shared significant word (broadest)
        case balanced  // most words match (overlap coefficient > 0.5)
        case strict    // same merchant: one description's significant words fully contain the other's
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fuzzy: return "Fuzzy"
            case .balanced: return "Balanced"
            case .strict: return "Strict"
            }
        }
    }

    /// Bank/manual transactions whose significant words overlap the seed description's at the given
    /// `strictness`, most recent first. Returns `[]` when the seed has no significant words.
    static func group(
        seedDescription: String, in transactions: [Transaction], strictness: MatchStrictness = .balanced
    ) -> [Transaction] {
        let seed = SubscriptionDetector.significantTokens(seedDescription)
        guard !seed.isEmpty else { return [] }
        return transactions
            .filter { $0.source == .plaid || $0.source == .manual }
            .filter { matches(SubscriptionDetector.significantTokens($0.details), seed, strictness) }
            .sorted { $0.date > $1.date }
    }

    /// Whether candidate tokens `c` are "related" to seed tokens `s` at `strictness` (both assumed non-empty).
    private static func matches(_ c: Set<String>, _ s: Set<String>, _ strictness: MatchStrictness) -> Bool {
        switch strictness {
        case .fuzzy:
            return !c.isDisjoint(with: s)
        case .balanced:
            guard !c.isEmpty else { return false }
            return Double(c.intersection(s).count) / Double(min(c.count, s.count)) > 0.5
        case .strict:
            return !c.isEmpty && (s.isSubset(of: c) || c.isSubset(of: s))
        }
    }

    /// A human title for the group, derived from the seed's brand words (e.g. "ANTHROPIC CLAUDE SUB" →
    /// "Anthropic Claude"), falling back to the raw description when there are none.
    static func displayName(for seedDescription: String) -> String {
        let words = SubscriptionDetector.significantWords(seedDescription).prefix(3)
        guard !words.isEmpty else { return seedDescription }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

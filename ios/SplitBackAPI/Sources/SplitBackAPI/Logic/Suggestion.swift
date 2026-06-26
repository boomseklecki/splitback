import Foundation

/// One review-queue card: a recommended action over cached data, with a stable `id` so a dismissal sticks.
/// Pure value type produced by `SuggestionEngine`; `SuggestionService` performs the accept/dismiss.
struct Suggestion: Identifiable, Equatable {
    enum Kind: String { case categorize, link, subscription, recurringSplit }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let acceptLabel: String

    // Targets — set per kind.
    var transactionId: UUID? = nil
    var expenseId: UUID? = nil
    var category: String? = nil           // suggested category (categorize) / template category
    var templateMerchantKey: String? = nil
    var merchantKey: String? = nil        // subscription / recurring — basis for "never for this merchant"
    var amount: Decimal? = nil            // subscription latest amount (for the include rule's tolerance)

    /// The "never for this merchant" decision key, when the suggestion is merchant-scoped.
    var merchantScopeKey: String? { merchantKey.map { "merchant:\($0)" } }
}

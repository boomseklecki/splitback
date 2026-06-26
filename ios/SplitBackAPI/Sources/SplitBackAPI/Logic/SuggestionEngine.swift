import Foundation

/// Generates the review-queue suggestions on-device from cached data — pure and synchronous so it's cheap
/// to recompute and easy to test. The costly AI step (populating `Transaction.aiSuggestedCategory`) runs
/// separately in `SuggestionService`; this only reads the cached opinion.
enum SuggestionEngine {
    /// Confidence floor for a transaction↔expense link suggestion (TransactionMatcher score 0…1).
    static let linkThreshold = 0.85
    /// How far back a recurring-split template will match an unlinked charge.
    static let recurringWindowDays = 60
    /// Cap on subscription "track this?" cards so a big history doesn't flood the queue.
    static let maxSubscriptionCards = 8

    static func generate(transactions: [Transaction], expenses: [Expense], lookup: [String: String],
                         sources: [String: String], templates: [SplitTemplate], rules: [SubscriptionRule],
                         decisions: [SuggestionDecision], me: String?, asOf: Date = Date()) -> [Suggestion] {
        // Active dismissals/snoozes: both per-suggestion ids and merchant-scope keys.
        let blocked = Set(decisions.filter { $0.isActive }.map(\.key))
        let linkedTxnIds = Set(expenses.lazy.compactMap(\.transactionId))

        var out: [Suggestion] = []

        // 1) Recategorize — AI disagrees with the current category, and no human/AI-map chose it.
        for t in transactions {
            guard let suggested = t.aiSuggestedCategory, !suggested.isEmpty else { continue }
            let res = CategoryMapping.resolve(for: t, lookup: lookup, sources: sources)
            guard res.source == .deterministic || res.source == .raw else { continue }
            guard suggested != res.category else { continue }
            out.append(Suggestion(
                id: "cat:\(t.id.uuidString):\(suggested)", kind: .categorize,
                title: t.details, subtitle: "\(res.category ?? "Uncategorized") → \(suggested)",
                icon: "sparkles", acceptLabel: "Use \(suggested)",
                transactionId: t.id, category: suggested))
        }

        // 2) Link — an unlinked expense with a high-confidence matching unlinked transaction (de-dupes spend).
        for e in expenses where e.transactionId == nil {
            if let c = e.category, CanonicalCategory.neutral.contains(c) { continue }
            guard let top = TransactionMatcher.candidates(
                for: e, transactions: transactions, expenses: expenses, me: me).first,
                  top.score >= linkThreshold else { continue }
            out.append(Suggestion(
                id: "link:\(top.transaction.id.uuidString):\(e.id.uuidString)", kind: .link,
                title: e.details, subtitle: "Looks like “\(top.transaction.details)” — link to de-dupe",
                icon: "link", acceptLabel: "Link",
                transactionId: top.transaction.id, expenseId: e.id))
        }

        // 3) Subscriptions — newly detected recurring charges with no rule yet.
        let ruleKeys = Set(rules.map(\.merchantKey))
        let subs = SubscriptionDetector.analyze(
            transactions: transactions, expenses: expenses, lookup: lookup, me: me, rules: rules, asOf: asOf)
            .subscriptions
        for sub in subs where !ruleKeys.contains(sub.id) {
            out.append(Suggestion(
                id: "sub:\(sub.id)", kind: .subscription,
                title: sub.displayName,
                subtitle: "\(sub.cadence.label) · \(sub.latestAmount.formatted(.currency(code: sub.currency)))",
                icon: "repeat", acceptLabel: "Track",
                merchantKey: sub.id, amount: sub.latestAmount))
            if out.filter({ $0.kind == .subscription }).count >= maxSubscriptionCards { break }
        }

        // 4) Recurring split — an unlinked recent charge matching a learned template.
        let cutoff = Calendar.current.date(byAdding: .day, value: -recurringWindowDays, to: asOf) ?? asOf
        let templatesByKey = Dictionary(templates.map { ($0.merchantKey, $0) }, uniquingKeysWith: { a, _ in a })
        for t in transactions where t.amount > 0 && !linkedTxnIds.contains(t.id) && t.date >= cutoff {
            guard let tmpl = templatesByKey[SubscriptionDetector.merchantKey(t.details)] else { continue }
            out.append(Suggestion(
                id: "rsplit:\(t.id.uuidString):\(tmpl.merchantKey)", kind: .recurringSplit,
                title: t.details, subtitle: "Split like last time · \(tmpl.displayName)",
                icon: "arrow.triangle.2.circlepath", acceptLabel: "Split",
                transactionId: t.id, category: tmpl.category, templateMerchantKey: tmpl.merchantKey,
                merchantKey: tmpl.merchantKey))
        }

        // Drop anything the user dismissed (by id or by merchant scope).
        return out.filter { !blocked.contains($0.id) && !($0.merchantScopeKey.map(blocked.contains) ?? false) }
    }
}

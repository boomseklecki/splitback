import Foundation

/// Generates the review-queue suggestions on-device from cached data — pure and synchronous so it's cheap
/// to recompute and easy to test. The costly AI step (populating `Transaction.aiSuggestedCategory`) runs
/// separately in `SuggestionService`; this only reads the cached opinion.
enum SuggestionEngine {
    /// Default confidence floor for a transaction↔expense link suggestion (TransactionMatcher score 0…1).
    /// Overridable per call via `linkThreshold` (the user's `LinkSensitivity` preference).
    static let defaultLinkThreshold = 0.85
    /// How far back a recurring-split template will match an unlinked charge.
    static let recurringWindowDays = 60
    /// Cap on subscription "track this?" cards so a big history doesn't flood the queue.
    static let maxSubscriptionCards = 8

    static func generate(transactions: [Transaction], expenses: [Expense], lookup: [String: String],
                         sources: [String: String], templates: [SplitTemplate], rules: [SubscriptionRule],
                         decisions: [SuggestionDecision], me: String?, asOf: Date = Date(),
                         linkThreshold: Double = defaultLinkThreshold) -> [Suggestion] {
        // Active dismissals/snoozes: both per-suggestion ids and merchant-scope keys.
        let blocked = Set(decisions.filter { $0.isActive }.map(\.key))
        let linkedTxnIds = Set(expenses.lazy.compactMap(\.transactionId))

        var out: [Suggestion] = []

        // 1) Recategorize — AI disagrees with the current category (and no human/AI-map chose it). Aggregate
        // by (description, suggested) so dozens of identical merchant rows become one accept-all card.
        struct CatGroup { let title: String; let suggested: String; let current: String?; var ids: [UUID] }
        var catGroups: [String: CatGroup] = [:]
        var catOrder: [String] = []
        for t in transactions {
            guard let suggested = t.aiSuggestedCategory, !suggested.isEmpty else { continue }
            let res = CategoryMapping.resolve(for: t, lookup: lookup, sources: sources)
            guard res.source == .deterministic || res.source == .raw else { continue }
            guard suggested != res.category else { continue }
            let key = "\(t.details.lowercased())|\(suggested)"
            if catGroups[key] == nil {
                catGroups[key] = CatGroup(title: t.details, suggested: suggested, current: res.category, ids: [])
                catOrder.append(key)
            }
            catGroups[key]?.ids.append(t.id)
        }
        for g in catOrder.compactMap({ catGroups[$0] }) {
            let suffix = g.ids.count > 1 ? " · \(g.ids.count) transactions" : ""
            out.append(Suggestion(
                id: "cat:\(g.title.lowercased()):\(g.suggested)", kind: .categorize,
                title: g.title, subtitle: "\(g.current ?? "Uncategorized") → \(g.suggested)\(suffix)",
                icon: "sparkles", acceptLabel: "Use \(g.suggested)",
                transactionId: g.ids.first, transactionIds: g.ids,
                category: g.suggested, currentCategory: g.current))
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
                transactionId: top.transaction.id, expenseId: e.id, matchScore: top.score))
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

extension SuggestionEngine {
    static let sharedBudgetFloor: Decimal = 50    // min monthly household spend to suggest a shared budget
    static let settleUpThreshold: Decimal = 5     // min |balance| to nudge a settle-up

    /// The "broad" nudge cards — they navigate/prefill rather than mutate. Computed from goals, household
    /// spend, and friend balances; filtered by the same dismissal decisions.
    static func nudges(
        goals: [Goal], transactions: [Transaction], expenses: [Expense], accounts: [Account],
        lookup: [String: String], groupMembers: [GroupMember], partners: Set<String>,
        friendNets: [(identifier: String, name: String, net: Decimal)],
        decisions: [SuggestionDecision], me: String?, asOf: Date = Date()) -> [Suggestion] {
        let blocked = Set(decisions.filter { $0.isActive }.map(\.key))
        let month = SpendingAnalytics.monthStart(asOf)
        let spendGoals = goals.filter { $0.goalKind == .spend }
        let sharedGroupIds = me.map {
            HouseholdBudget.sharedGroupIds(viewer: $0, partners: partners,
                                           membersByGroup: HouseholdBudget.membership(groupMembers))
        } ?? []
        var out: [Suggestion] = []

        // Shared-budget candidate — the household spends in a category but has no shared budget for it.
        if let me, !partners.isEmpty {
            let existing = Set(spendGoals.filter { $0.shared }.compactMap { $0.category })
            let combined = HouseholdBudget.combinedByCategory(
                month: month, expenses: expenses, sharedGroupIds: sharedGroupIds, viewer: me, partners: partners)
            for (category, spend) in combined
            where spend.combined >= sharedBudgetFloor && !existing.contains(category) {
                out.append(Suggestion(
                    id: "sharedbudget:\(category)", kind: .sharedBudgetCandidate,
                    title: "\(category) household budget",
                    subtitle: "You + partner spent \(spend.combined.formatted(.currency(code: "USD"))) — set a shared budget?",
                    icon: "person.2", acceptLabel: "Create",
                    category: category, amount: roundedTarget(spend.combined)))
            }
        }

        // Overspend — a spend goal already over its limit this month (own via GoalProgress, shared via household).
        for goal in spendGoals {
            guard let category = goal.category else { continue }
            let spent: Decimal = (goal.shared && me != nil)
                ? HouseholdBudget.combined(category: category, month: month, expenses: expenses,
                                           sharedGroupIds: sharedGroupIds, viewer: me!, partners: partners).combined
                : GoalProgress.spent(for: category, in: month, transactions: transactions,
                                     accounts: accounts, lookup: lookup, expenses: expenses, me: me)
            guard spent > goal.targetAmount else { continue }
            out.append(Suggestion(
                id: "overspend:\(goal.id.uuidString)", kind: .overspend, title: goal.name,
                subtitle: "Over budget: \(spent.formatted(.currency(code: "USD"))) of \(goal.targetAmount.formatted(.currency(code: "USD")))",
                icon: "exclamationmark.triangle", acceptLabel: "View", goalId: goal.id))
        }

        // Settle up — a friend balance past the threshold.
        for fn in friendNets where abs(fn.net) >= settleUpThreshold {
            out.append(Suggestion(
                id: "settleup:\(fn.identifier)", kind: .settleUp, title: fn.name,
                subtitle: fn.net > 0 ? "Owes you \(fn.net.formatted(.currency(code: "USD")))"
                                     : "You owe \((-fn.net).formatted(.currency(code: "USD")))",
                icon: "arrow.left.arrow.right", acceptLabel: "Settle",
                friendIdentifier: fn.identifier, amount: fn.net))
        }

        return out.filter { !blocked.contains($0.id) }
    }

    /// Rounds a spend figure up to a tidy budget target (nearest 10).
    private static func roundedTarget(_ amount: Decimal) -> Decimal {
        Decimal((NSDecimalNumber(decimal: amount).doubleValue / 10).rounded(.up) * 10)
    }
}

import Foundation
import SwiftData

/// Backs the review queue: fetches cached data + runs `SuggestionEngine`, runs the on-device AI pass that
/// populates `Transaction.aiSuggestedCategory`, performs accept/dismiss via existing repos, and maintains
/// split templates. Everything is local + existing endpoints — no new backend.
@MainActor
struct SuggestionService {
    let client: Client
    let context: ModelContext
    let me: String?

    /// Max transactions the AI pass classifies per run (Apple Intelligence inference is not free).
    private static let aiBatch = 25

    // MARK: Read

    /// Suggestions computed **synchronously** from the cached store, given a known partner set. No network —
    /// the caller supplies `partners` (so the Inbox can paint cached cards instantly, then recompute once the
    /// accepted-connections fetch returns). Friend nudges read the cached `Friend` snapshot.
    func current(partners: Set<String>) throws -> [Suggestion] {
        let transactions = try context.fetch(FetchDescriptor<Transaction>())
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let accounts = try context.fetch(FetchDescriptor<Account>())
        let goals = try context.fetch(FetchDescriptor<Goal>())
        let groupMembers = try context.fetch(FetchDescriptor<GroupMember>())
        let maps = try context.fetch(FetchDescriptor<CategoryMap>())
        let templates = try context.fetch(FetchDescriptor<SplitTemplate>())
        let rules = try context.fetch(FetchDescriptor<SubscriptionRule>())
        let decisions = try context.fetch(FetchDescriptor<SuggestionDecision>())
        let lookup = CategoryMapping.lookup(maps), sources = CategoryMapping.sources(maps)

        var result = SuggestionEngine.generate(
            transactions: transactions, expenses: expenses, lookup: lookup, sources: sources,
            templates: templates, rules: rules, decisions: decisions, me: me,
            linkThreshold: LinkSensitivity.current().threshold)

        // Read the cached Friend balances (snapshot from the last /friends sync); names from the directory.
        let directory = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let friendNets: [(identifier: String, name: String, net: Decimal)] =
            ((try? context.fetch(FetchDescriptor<Friend>())) ?? []).map { f in
                (f.identifier, directory.displayName(for: f.identifier), f.net)
            }
        result += SuggestionEngine.nudges(
            goals: goals, transactions: transactions, expenses: expenses, accounts: accounts, lookup: lookup,
            groupMembers: groupMembers, partners: partners, friendNets: friendNets, decisions: decisions, me: me)
        return result
    }

    /// The accepted partner connections (network, best-effort — offline yields an empty set).
    func fetchPartners() async -> Set<String> {
        Set(((try? await ConnectionRepository(client: client).list()) ?? [])
            .filter { $0.status == "accepted" }.map(\.other_identifier))
    }

    /// Convenience one-shot: fetch partners then compute (used where streaming isn't needed, e.g. the badge).
    func current() async throws -> [Suggestion] {
        try current(partners: await fetchPartners())
    }

    // MARK: AI pass

    /// Classifies a bounded batch of not-yet-processed outflow transactions with the on-device model and
    /// stores each opinion in `aiSuggestedCategory` ("" marks "processed, no confident suggestion"). No-op
    /// without Apple Intelligence.
    func refreshAI() async {
        guard CategoryMapper.isAvailable else { return }
        let pending = (try? context.fetch(FetchDescriptor<Transaction>()))?
            .filter { $0.amount > 0 && $0.aiSuggestedCategory == nil }
            .sorted { $0.date > $1.date }
            .prefix(Self.aiBatch) ?? []
        guard !pending.isEmpty else { return }
        let items = pending.map {
            CategoryMapper.Item(id: $0.id, description: $0.details, rawCategory: $0.category)
        }
        let result = await CategoryMapper.refine(Array(items))
        for t in pending { t.aiSuggestedCategory = result[t.id] ?? "" }
        try? context.save()
    }

    // MARK: Accept / dismiss

    func accept(_ s: Suggestion) async throws {
        switch s.kind {
        case .categorize:
            guard let id = s.transactionId, let category = s.category else { return }
            try await AccountRepository(client: client, context: context)
                .setCategoryOverride(id: id, category: category)
        case .link:
            guard let expenseId = s.expenseId, let txnId = s.transactionId else { return }
            try await ExpenseRepository(client: client, context: context)
                .linkTransaction(expenseId: expenseId, transactionId: txnId)
        case .subscription:
            guard let key = s.merchantKey else { return }
            context.insert(SubscriptionRule(merchantKey: key, amount: s.amount ?? 0,
                                            isSubscription: true, displayName: s.title))
            try context.save()
        case .recurringSplit:
            try await acceptRecurringSplit(s)
        case .sharedBudgetCandidate, .settleUp, .overspend:
            break  // navigate-only — the inbox view handles these
        }
    }

    /// Creates the shared expense for a recurring-split suggestion from its template, linked to the charge.
    private func acceptRecurringSplit(_ s: Suggestion) async throws {
        guard let me, let txnId = s.transactionId, let key = s.templateMerchantKey,
              let txn = try context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.id == txnId })).first,
              let tmpl = try context.fetch(
                FetchDescriptor<SplitTemplate>(predicate: #Predicate { $0.merchantKey == key })).first
        else { return }
        let owed = Self.distribute(txn.amount, fractions: tmpl.shares)
        let splits = owed.map { uid, share in
            SplitDraft(userIdentifier: uid, paidShare: uid == me ? txn.amount : 0, owedShare: share)
        }
        let draft = ExpenseDraft(
            groupId: tmpl.groupId, details: txn.details, amount: txn.amount, currency: txn.currency,
            date: txn.date, category: tmpl.category, createdBy: me, transactionId: txn.id, splits: splits)
        try await ExpenseRepository(client: client, context: context).create(draft)
    }

    func dismiss(_ s: Suggestion, forMerchant: Bool = false) throws {
        let key = forMerchant ? (s.merchantScopeKey ?? s.id) : s.id
        context.insert(SuggestionDecision(key: key, decision: "dismissed"))
        if forMerchant, let merchant = s.merchantKey {
            if s.kind == .recurringSplit {
                for t in try context.fetch(FetchDescriptor<SplitTemplate>(
                    predicate: #Predicate { $0.merchantKey == merchant })) { context.delete(t) }
            } else if s.kind == .subscription {
                context.insert(SubscriptionRule(merchantKey: merchant, amount: s.amount ?? 0,
                                                isSubscription: false, displayName: s.title))
            }
        }
        try context.save()
        pushSync()
    }

    // MARK: Templates

    /// Auto-derives templates from history and upserts them (an explicit template is never overwritten).
    func learnTemplates() throws {
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<SplitTemplate>()).map { ($0.merchantKey, $0) },
            uniquingKeysWith: { a, _ in a })
        for t in SplitTemplateLearning.derive(expenses: expenses) {
            if let current = existing[t.merchantKey] {
                guard current.source == "auto" else { continue }  // don't clobber an explicit one
                current.groupId = t.groupId
                current.category = t.category
                current.sharesJSON = t.sharesJSON
                current.displayName = t.displayName
                current.updatedAt = Date()
            } else {
                context.insert(t)
            }
        }
        try context.save()
        pushSync()
    }

    /// "Remember this split": pins an explicit template from a shared, transaction-linked expense.
    func rememberSplit(_ expense: Expense) throws {
        let key = SubscriptionDetector.merchantKey(expense.details)
        guard !key.isEmpty else { return }
        let total = expense.splits.reduce(Decimal(0)) { $0 + max($1.owedShare, 0) }
        guard total > 0 else { return }
        var fractions: [String: Double] = [:]
        for split in expense.splits where split.owedShare > 0 {
            fractions[split.userIdentifier] = NSDecimalNumber(decimal: split.owedShare / total).doubleValue
        }
        let json = SplitTemplate.encode(fractions)
        if let current = try context.fetch(FetchDescriptor<SplitTemplate>(
            predicate: #Predicate { $0.merchantKey == key })).first {
            current.groupId = expense.groupId
            current.category = expense.category
            current.sharesJSON = json
            current.source = "explicit"
            current.displayName = expense.details
            current.updatedAt = Date()
        } else {
            context.insert(SplitTemplate(merchantKey: key, groupId: expense.groupId,
                                         category: expense.category, sharesJSON: json,
                                         source: "explicit", displayName: expense.details))
        }
        try context.save()
        pushSync()
    }

    /// Splits `amount` by `fractions`, rounding to cents and giving any remainder to the largest share so
    /// the parts sum exactly to `amount`.
    /// Best-effort cross-device backup of templates + decisions after a local change.
    private func pushSync() { Task { await SuggestionSync.pushBestEffort(context, client: client) } }

    nonisolated static func distribute(_ amount: Decimal, fractions: [String: Double]) -> [(String, Decimal)] {
        let totalFraction = fractions.values.reduce(0, +)
        guard totalFraction > 0 else { return [] }
        var result: [(String, Decimal)] = []
        var allocated: Decimal = 0
        let sorted = fractions.sorted { $0.value > $1.value }
        for (i, entry) in sorted.enumerated() {
            if i == sorted.count - 1 {
                result.append((entry.key, amount - allocated))  // remainder → largest is first, last is smallest
            } else {
                let share = round2(amount * Decimal(entry.value / totalFraction))
                allocated += share
                result.append((entry.key, share))
            }
        }
        return result
    }

    nonisolated private static func round2(_ d: Decimal) -> Decimal {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 2, .plain)
        return r
    }
}

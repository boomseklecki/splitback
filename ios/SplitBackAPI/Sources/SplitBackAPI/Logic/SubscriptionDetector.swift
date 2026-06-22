import Foundation

/// How often a subscription recurs. `periodsPerYear` drives the estimated annual cost.
enum SubscriptionCadence: CaseIterable {
    case weekly, biweekly, monthly, quarterly, yearly

    var periodsPerYear: Decimal {
        switch self {
        case .weekly: return 52
        case .biweekly: return 26
        case .monthly: return 12
        case .quarterly: return 4
        case .yearly: return 1
        }
    }
    var days: Int {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        case .quarterly: return 91
        case .yearly: return 365
        }
    }
    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        case .quarterly: return "Quarterly"
        case .yearly: return "Yearly"
        }
    }
    /// Compact amount suffix, e.g. "$15.99/mo".
    var unit: String {
        switch self {
        case .weekly: return "wk"
        case .biweekly: return "2wk"
        case .monthly: return "mo"
        case .quarterly: return "qtr"
        case .yearly: return "yr"
        }
    }

    /// Maps a median inter-charge interval (in days) to a cadence band, or nil if it's not regular.
    static func classify(medianDays: Double) -> SubscriptionCadence? {
        switch medianDays {
        case 5...9: return .weekly
        case 11...17: return .biweekly
        case 24...37: return .monthly
        case 80...100: return .quarterly
        case 330...400: return .yearly
        default: return nil
        }
    }
}

/// One charge behind a detected subscription, for the history list (drills into the txn/expense).
struct SubscriptionCharge: Identifiable {
    let id: String
    let source: EventSource
    let date: Date
    let amount: Decimal
}

/// A recurring charge detected on-device: its cadence, latest/prior amount, predicted next date, and the
/// charges behind it. `amount` is the gross transaction or, for a shared expense, your owed share.
struct Subscription: Identifiable {
    let id: String           // normalized merchant key (stable grouping id)
    let displayName: String  // cleaned merchant; the brand model refines this for display
    let cadence: SubscriptionCadence
    let latestAmount: Decimal
    let priorAmount: Decimal?
    let currency: String
    let nextDate: Date
    let lastDate: Date
    let isShared: Bool
    let charges: [SubscriptionCharge]  // most-recent first

    var increased: Bool { priorAmount.map { latestAmount > $0 } ?? false }
    var increaseFrom: Decimal? { increased ? priorAmount : nil }
    var annualCost: Decimal { latestAmount * cadence.periodsPerYear }
    /// Amount normalized to a monthly figure (for the "per month" total).
    var monthlyEquivalent: Decimal { annualCost / 12 }
}

/// Pure, on-device recurring-charge detection across all categories. No model required (the brand/logo
/// step is separate); deterministic and unit-tested.
enum SubscriptionDetector {
    private struct Event {
        let date: Date
        let amount: Decimal
        let currency: String
        let source: EventSource
        let shared: Bool
    }

    /// Merchant tokens that carry no brand signal (payment plumbing / geography / suffixes).
    private static let noise: Set<String> = [
        "com", "www", "http", "https", "inc", "llc", "ltd", "co", "corp",
        "pos", "purchase", "recurring", "payment", "autopay", "auto", "bill",
        "online", "usa", "the", "subscription", "monthly", "annual",
    ]

    static func detect(transactions: [Transaction], expenses: [Expense],
                       lookup: [String: String], me: String?, asOf: Date = Date()) -> [Subscription] {
        // A shared subscription is represented by its expense share, so skip the linked gross transaction
        // (mirrors SpendingAnalytics' dedupe).
        let linkedTxnIds = Set(expenses.lazy.filter { $0.archivedAt == nil }.compactMap(\.transactionId))
        var byKey: [String: [Event]] = [:]

        for t in transactions where t.source == .plaid || t.source == .manual {
            guard t.amount > 0, !linkedTxnIds.contains(t.id) else { continue }
            let cat = CategoryMapping.effectiveCategory(for: t, lookup: lookup)
            if let cat, CanonicalCategory.excludedFromSpend.contains(cat) { continue }  // transfer/income
            let key = merchantKey(t.details)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(
                Event(date: t.date, amount: t.amount, currency: t.currency,
                      source: .transaction(t), shared: false))
        }

        if let me {
            for e in expenses where e.archivedAt == nil {
                guard let cat = e.category.flatMap({ CategoryMapping.canonical($0, lookup: lookup) }),
                      !CanonicalCategory.neutral.contains(cat),
                      !CanonicalCategory.incomeLike.contains(cat) else { continue }
                let share = e.splits.first { $0.userIdentifier == me }?.owedShare ?? 0
                guard share > 0 else { continue }
                let key = merchantKey(e.details)
                guard !key.isEmpty else { continue }
                byKey[key, default: []].append(
                    Event(date: e.date, amount: share, currency: e.currency,
                          source: .expense(e), shared: true))
            }
        }

        return byKey.compactMap { subscription(key: $0.key, events: $0.value, asOf: asOf) }
            .sorted { $0.annualCost > $1.annualCost }
    }

    private static func subscription(key: String, events rawEvents: [Event], asOf: Date) -> Subscription? {
        let events = rawEvents.sorted { $0.date < $1.date }
        guard events.count >= 2 else { return nil }
        let cal = Calendar.current

        var intervals: [Double] = []
        for i in 1..<events.count {
            let d = cal.dateComponents([.day], from: cal.startOfDay(for: events[i - 1].date),
                                       to: cal.startOfDay(for: events[i].date)).day ?? 0
            if d > 0 { intervals.append(Double(d)) }
        }
        guard !intervals.isEmpty, let cadence = SubscriptionCadence.classify(medianDays: median(intervals))
        else { return nil }

        // Enough occurrences (yearly is lenient — little history exists), and a regular rhythm.
        guard events.count >= (cadence == .yearly ? 2 : 3) else { return nil }
        let band = Double(cadence.days)
        let inBand = intervals.filter { abs($0 - band) <= band * 0.4 }.count
        guard Double(inBand) / Double(intervals.count) >= 0.6 else { return nil }

        // Reject variable merchants (groceries, Amazon): amounts must cluster near the median (a modest
        // price increase still passes).
        let medAmount = median(events.map(\.amount))
        guard medAmount > 0,
              events.allSatisfy({ let r = $0.amount / medAmount; return r >= 0.5 && r <= 1.8 })
        else { return nil }

        let latest = events[events.count - 1]
        let prior = events[events.count - 2].amount
        let nextDate = cal.date(byAdding: .day, value: cadence.days, to: latest.date) ?? latest.date
        let charges = events.reversed().enumerated().map { idx, e in
            SubscriptionCharge(id: "\(key)-\(idx)", source: e.source, date: e.date, amount: e.amount)
        }
        return Subscription(
            id: key, displayName: displayName(key), cadence: cadence,
            latestAmount: latest.amount, priorAmount: prior, currency: latest.currency,
            nextDate: nextDate, lastDate: latest.date,
            isShared: events.contains { $0.shared }, charges: charges)
    }

    // MARK: Helpers

    /// A stable grouping key from a merchant string: lowercase, letters only, noise/short words dropped,
    /// first few significant words joined (e.g. "Netflix.com 866-579-7172 CA" → "netflix").
    static func merchantKey(_ details: String) -> String {
        let words = details.lowercased()
            .map { ($0.isLetter || $0 == " ") ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !noise.contains($0) }
        return words.prefix(3).joined(separator: " ")
    }

    private static func displayName(_ key: String) -> String {
        key.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    private static func median(_ values: [Decimal]) -> Decimal {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}

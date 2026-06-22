import SwiftUI
import SwiftData

/// A Rocket Money–style overview of recurring charges, detected on-device across all categories. Shows
/// the estimated annual cost, upcoming predicted charges, and each subscription with its brand logo, per-
/// period amount, annual cost, and a price-increase flag. Reached from Settings → Subscriptions.
struct SubscriptionsView: View {
    @Environment(AppEnvironment.self) private var env
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]

    @State private var brandModel = SubscriptionBrandModel()

    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var subscriptions: [Subscription] {
        SubscriptionDetector.detect(transactions: transactions, expenses: expenses,
                                    lookup: lookup, me: env.currentUser?.identifier)
    }

    var body: some View {
        // Detect once per render (not inside the row builders).
        let subs = subscriptions
        let annual = subs.reduce(Decimal(0)) { $0 + $1.annualCost }
        // Upcoming = predicted charges from today through the next 30 days. A nextDate in the past means
        // the charge already lapsed (stale data) — don't show it as "upcoming".
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let windowEnd = cal.date(byAdding: .day, value: 30, to: today)!
        let upcoming = subs
            .filter { $0.nextDate >= today && $0.nextDate <= windowEnd }
            .sorted { $0.nextDate < $1.nextDate }

        return List {
            if subs.isEmpty {
                ContentUnavailableView("No Subscriptions Found", systemImage: "repeat",
                    description: Text("Recurring charges are detected from your transactions. Sync a bank "
                                      + "or add a few months of activity, then check back."))
            } else {
                Section {
                    VStack(spacing: 4) {
                        Text(annual.formatted(.currency(code: "USD"))).font(.largeTitle).fontWeight(.bold)
                        Text("estimated per year").font(.subheadline).foregroundStyle(.secondary)
                        Text("\((annual / 12).formatted(.currency(code: "USD")))/mo · \(subs.count) "
                             + "subscription\(subs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }

                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { sub in
                            row(sub, trailing: .upcoming)
                        }
                    }
                }

                Section("Subscriptions") {
                    ForEach(subs) { sub in
                        NavigationLink {
                            SubscriptionDetailView(subscription: sub, brand: brandModel.brand(for: sub))
                        } label: {
                            row(sub, trailing: .annual)
                        }
                    }
                }
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .task { await brandModel.resolve(subs) }
    }

    private enum Trailing { case annual, upcoming }

    @ViewBuilder
    private func row(_ sub: Subscription, trailing: Trailing) -> some View {
        let brand = brandModel.brand(for: sub)
        HStack(spacing: 12) {
            AvatarView(url: brand.logoURL, name: brand.name, size: 40, systemImage: "repeat")
            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(sub.latestAmount.formatted(.currency(code: sub.currency)))/\(sub.cadence.unit)")
                    if sub.isShared {
                        Text("· your share").foregroundStyle(.secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if sub.increased, let from = sub.increaseFrom {
                    Label("Up from \(from.formatted(.currency(code: sub.currency)))", systemImage: "arrow.up.right")
                        .font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            switch trailing {
            case .annual:
                Text("\(sub.annualCost.formatted(.currency(code: sub.currency)))/yr")
                    .foregroundStyle(.secondary).monospacedDigit()
            case .upcoming:
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sub.latestAmount.formatted(.currency(code: sub.currency))).monospacedDigit()
                    Text("Due \(sub.nextDate.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

import SwiftUI

/// One subscription's detail: brand header, cadence + annual estimate, predicted next charge, a price-
/// increase note, and the charge history (each drills into the underlying transaction or expense).
struct SubscriptionDetailView: View {
    let subscription: Subscription
    let brand: SubscriptionBrand

    private func currency(_ value: Decimal) -> String {
        value.formatted(.currency(code: subscription.currency))
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    AvatarView(url: brand.logoURL, name: brand.name, size: 64, systemImage: "repeat")
                    Text(brand.name).font(.title2).fontWeight(.semibold)
                    Text("\(currency(subscription.latestAmount))/\(subscription.cadence.unit) · "
                         + subscription.cadence.label)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }

            Section {
                LabeledContent("Estimated yearly", value: currency(subscription.annualCost))
                LabeledContent("Next charge",
                               value: subscription.nextDate.formatted(date: .abbreviated, time: .omitted))
                if subscription.increased, let from = subscription.increaseFrom {
                    LabeledContent("Price change") {
                        Label("Up from \(currency(from))", systemImage: "arrow.up.right")
                            .foregroundStyle(.red)
                    }
                }
                if subscription.isShared {
                    LabeledContent("Tracked as", value: "Shared expense (your share)")
                }
            }

            Section("Charges") {
                ForEach(subscription.charges) { charge in
                    NavigationLink {
                        switch charge.source {
                        case .transaction(let t): TransactionDetailView(transaction: t)
                        case .expense(let e): ExpenseDetailView(expense: e)
                        }
                    } label: {
                        HStack {
                            Text(charge.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(currency(charge.amount)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle(brand.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

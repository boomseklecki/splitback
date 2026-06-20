import SwiftUI
import SwiftData
import Charts

/// Mint-style Trends: monthly spending bars and net-income bars (green positive / red negative) over
/// the recent months, derived from Plaid transactions plus your owed share of expenses not linked to a
/// transaction (cash splits, Splitwise).
struct TrendsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var accounts: [Account]
    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]

    private let months = 6
    private var lookup: [String: String] { CategoryMapping.lookup(categoryMaps) }
    private var me: String? { env.currentUser?.identifier }
    private var spending: [MonthlyValue] {
        SpendingAnalytics.monthlySpending(transactions: transactions, accounts: accounts,
                                          lookup: lookup, months: months, expenses: expenses, me: me)
    }
    private var netIncome: [MonthlyValue] {
        SpendingAnalytics.monthlyNetIncome(transactions: transactions, accounts: accounts,
                                           lookup: lookup, months: months, expenses: expenses, me: me)
    }
    private var rangeLabel: String {
        guard let first = spending.first?.month, let last = spending.last?.month else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated).year()))"
    }

    var body: some View {
        List {
            Section {
                MonthBarChart(series: spending, titlePrefix: "Spending", scope: .spending, positiveOnly: true)
            } header: {
                Text("Spending  \(rangeLabel)").textCase(nil)
            } footer: {
                Text("Tap a month to see what it's made of.")
            }

            Section {
                MonthBarChart(series: netIncome, titlePrefix: "Net Income", scope: .cashFlow, positiveOnly: false)
            } header: {
                Text("Net Income  \(rangeLabel)").textCase(nil)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A month-bucketed bar chart whose bars drill through to the contributing items for that month. Owns its
/// own selection + destination so the Spending and Net Income charts don't collide.
private struct MonthBarChart: View {
    let series: [MonthlyValue]
    let titlePrefix: String
    let scope: SpendContributors.Scope
    let positiveOnly: Bool

    @State private var selectedMonth: Date?

    var body: some View {
        Chart(series) { point in
            BarMark(
                x: .value("Month", point.month, unit: .month),
                y: .value("Amount", NSDecimalNumber(decimal: point.value).doubleValue)
            )
            .foregroundStyle(positiveOnly || point.value >= 0 ? Color.green : Color.red)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow))
            }
        }
        .frame(height: 200)
        .padding(.vertical, 4)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geo[plotFrame].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        selectedMonth = nearestMonth(to: date)
                    }
            }
        }
        .navigationDestination(item: $selectedMonth) { month in
            SpendContributorsView(
                title: "\(titlePrefix) · \(month.formatted(.dateTime.month(.abbreviated).year()))",
                month: month, scope: scope)
        }
    }

    /// Snap a tapped x-position date to the nearest bar's month.
    private func nearestMonth(to date: Date) -> Date? {
        series.min {
            abs($0.month.timeIntervalSince(date)) < abs($1.month.timeIntervalSince(date))
        }?.month
    }
}

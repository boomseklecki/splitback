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
                chart(spending, positiveOnly: true)
            } header: {
                Text("Spending  \(rangeLabel)").textCase(nil)
            }

            Section {
                chart(netIncome, positiveOnly: false)
            } header: {
                Text("Net Income  \(rangeLabel)").textCase(nil)
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chart(_ series: [MonthlyValue], positiveOnly: Bool) -> some View {
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
    }
}

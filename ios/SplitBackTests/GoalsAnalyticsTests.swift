import XCTest
@testable import SplitBackAPI

final class GoalsAnalyticsTests: XCTestCase {
    private func account(type: String?, spending: Bool? = nil, cash: Bool? = nil,
                         balance: Decimal = 0) -> Account {
        Account(id: UUID(), name: "Acct", type: type, balance: balance, currency: "USD",
                includeInSpending: spending, includeInCashFlow: cash,
                createdAt: Date(), updatedAt: Date())
    }

    private func txn(_ amount: Decimal, category: String?, account: Account,
                     source: TransactionSource = .plaid, date: Date = Date()) -> Transaction {
        Transaction(id: UUID(), accountId: account.id, source: source, details: "t",
                    amount: amount, currency: "USD", date: date, category: category,
                    createdAt: Date(), updatedAt: Date())
    }

    // MARK: CategoryMapping

    func testEffectiveCategoryUsesMapThenRaw() {
        let map = [CategoryMap(id: UUID(), rawCategory: "Coffee Shop", canonicalCategory: "Dining",
                              source: "manual", createdAt: Date(), updatedAt: Date())]
        let lookup = CategoryMapping.lookup(map)
        let checking = account(type: "checking")
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "Coffee Shop", account: checking), lookup: lookup), "Dining")
        // Unmapped falls through to the raw label.
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "Groceries", account: checking), lookup: lookup), "Groceries")
        XCTAssertNil(CategoryMapping.effectiveCategory(
            for: txn(5, category: nil, account: checking), lookup: lookup))
    }

    // MARK: Account inclusion defaults + overrides

    func testInclusionDefaultsByKind() {
        XCTAssertTrue(account(type: "checking").countsInSpending)
        XCTAssertTrue(account(type: "checking").countsInCashFlow)
        XCTAssertTrue(account(type: "credit card").countsInSpending)   // credit spend counts
        XCTAssertFalse(account(type: "credit card").countsInCashFlow)  // but not in net income
        XCTAssertFalse(account(type: "investment").countsInSpending)   // holdings excluded
        XCTAssertFalse(account(type: "investment").countsInCashFlow)
        // Override wins over the default.
        XCTAssertTrue(account(type: "investment", cash: true).countsInCashFlow)
        XCTAssertFalse(account(type: "checking", spending: false).countsInSpending)
    }

    // MARK: SpendingAnalytics

    func testByCategoryExcludesTransfersIncomeAndNonSpendingAccounts() {
        let checking = account(type: "checking")
        let card = account(type: "credit card")
        let brokerage = account(type: "investment")
        let txns = [
            txn(20, category: "Dining", account: checking),
            txn(30, category: "Groceries", account: card),     // credit spend counts
            txn(-100, category: "Income", account: checking),  // inflow, not spend
            txn(50, category: "Transfer", account: checking),  // internal move, excluded
            txn(40, category: "Shopping", account: brokerage), // holdings, excluded
        ]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking, card, brokerage], lookup: [:])
        XCTAssertEqual(result.map(\.category), ["Groceries", "Dining"])  // desc by total
        XCTAssertEqual(result.first?.total, 30)
    }

    func testMonthlyNetIncomeCashFlowOnly() {
        let checking = account(type: "checking")
        let card = account(type: "credit card")
        let txns = [
            txn(-2000, category: "Income", account: checking),  // paycheck in
            txn(300, category: "Groceries", account: checking), // spend out
            txn(500, category: "Transfer", account: checking),  // excluded
            txn(150, category: "Dining", account: card),        // liability: not in cash flow
        ]
        let series = SpendingAnalytics.monthlyNetIncome(transactions: txns,
                                                        accounts: [checking, card], lookup: [:],
                                                        months: 1)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.value, 1700)  // 2000 in − 300 out
    }

    func testMonthlySpendingZeroFillsRange() {
        let checking = account(type: "checking")
        let series = SpendingAnalytics.monthlySpending(
            transactions: [txn(25, category: "Dining", account: checking)],
            accounts: [checking], lookup: [:], months: 3)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.last?.value, 25)   // current month
        XCTAssertEqual(series.first?.value, 0)   // two months ago, zero-filled
    }

    // MARK: GoalProgress

    func testBudgetStatusAndFraction() {
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 20, target: 100), .under)
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 90, target: 100), .nearing)
        XCTAssertEqual(GoalProgress.budgetStatus(spent: 120, target: 100), .over)
        XCTAssertEqual(GoalProgress.budgetFraction(spent: 20, target: 100), 0.2, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.budgetFraction(spent: 120, target: 100), 1.0, accuracy: 0.0001)
    }

    func testSaveFractionBalanceAndAmount() {
        XCTAssertEqual(GoalProgress.saveFraction(current: 5000, starting: 4000, target: 6000, type: .balance),
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 5000, starting: 4000, target: 2000, type: .amount),
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 6000, starting: 4000, target: 6000, type: .balance),
                       1.0, accuracy: 0.0001)
        XCTAssertEqual(GoalProgress.saveFraction(current: 4000, starting: 4000, target: 2000, type: .amount),
                       0.0, accuracy: 0.0001)
    }
}

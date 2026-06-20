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

    /// An expense with a single split for `me` owing `owed`, optionally linked to a transaction/archived.
    private func expense(_ amount: Decimal, category: String?, me: String = "me", owed: Decimal,
                         transactionId: UUID? = nil, splitwiseId: String? = nil, archived: Date? = nil,
                         date: Date = Date(), details: String = "e") -> Expense {
        let split = Split(id: UUID(), userIdentifier: me, paidShare: amount, owedShare: owed)
        return Expense(id: UUID(), groupId: UUID(), transactionId: transactionId,
                       splitwiseExpenseId: splitwiseId, details: details,
                       amount: amount, currency: "USD", date: date, category: category,
                       archivedAt: archived, createdAt: Date(), updatedAt: Date(), splits: [split])
    }

    // MARK: CategoryMapping

    func testEffectiveCategoryPrecedence() {
        // Override wins over the built-in Plaid map.
        let map = [CategoryMap(id: UUID(), rawCategory: "FOOD_AND_DRINK_GROCERIES",
                              canonicalCategory: "Household", source: "manual",
                              createdAt: Date(), updatedAt: Date())]
        let lookup = CategoryMapping.lookup(map)
        let checking = account(type: "checking")
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "FOOD_AND_DRINK_GROCERIES", account: checking), lookup: lookup), "Household")
        // No override: the built-in Plaid map resolves a detailed label.
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS", account: checking), lookup: [:]),
            "Personal Care")
        // Unrecognized label falls through to itself; nil category stays nil.
        XCTAssertEqual(CategoryMapping.effectiveCategory(
            for: txn(5, category: "Groceries", account: checking), lookup: [:]), "Groceries")
        XCTAssertNil(CategoryMapping.effectiveCategory(
            for: txn(5, category: nil, account: checking), lookup: [:]))
    }

    func testRefinementUsedOnlyForVagueRows() {
        let checking = account(type: "checking")
        // Confident built-in mapping ignores any refinement.
        let groceries = txn(20, category: "FOOD_AND_DRINK_GROCERIES", account: checking)
        groceries.refinedCategory = "Dining"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: groceries, lookup: [:]), "Groceries")
        // A vague "Other" row uses the refinement when present.
        let vague = txn(20, category: "GENERAL_SERVICES_OTHER", account: checking)
        XCTAssertTrue(CategoryMapping.needsRefinement(vague, lookup: [:]))
        vague.refinedCategory = "Subscriptions"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: [:]), "Subscriptions")
        // A manual override still beats a refinement.
        let lookup = ["GENERAL_SERVICES_OTHER": "Fees"]
        XCTAssertFalse(CategoryMapping.needsRefinement(vague, lookup: lookup))
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: lookup), "Fees")
    }

    func testPerTransactionOverrideWinsAndStopsRefinement() {
        let checking = account(type: "checking")
        // A label map AND a confident built-in would both apply, but the per-transaction override wins.
        let lookup = ["FOOD_AND_DRINK_GROCERIES": "Household"]
        let t = txn(20, category: "FOOD_AND_DRINK_GROCERIES", account: checking)
        t.categoryOverride = "Dining"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: t, lookup: lookup), "Dining")
        // An override on a vague row removes it from the refinement candidates.
        let vague = txn(20, category: "GENERAL_SERVICES_OTHER", account: checking)
        XCTAssertTrue(CategoryMapping.needsRefinement(vague, lookup: [:]))
        vague.categoryOverride = "Subscriptions"
        XCTAssertFalse(CategoryMapping.needsRefinement(vague, lookup: [:]))
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: vague, lookup: [:]), "Subscriptions")
        // An override applies even when the raw category is empty (e.g. a manual transaction).
        let manual = txn(20, category: nil, account: checking, source: .manual)
        manual.categoryOverride = "Pets"
        XCTAssertEqual(CategoryMapping.effectiveCategory(for: manual, lookup: [:]), "Pets")
    }

    func testPlaidCategoryMapping() {
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_GROCERIES"), "Groceries")
        XCTAssertEqual(PlaidCategory.canonical("FOOD_AND_DRINK_FAST_FOOD"), "Dining")  // primary default
        XCTAssertEqual(PlaidCategory.canonical("TRANSPORTATION_GAS"), "Fuel")
        XCTAssertEqual(PlaidCategory.canonical("TRANSPORTATION_PUBLIC_TRANSIT"), "Transport")
        XCTAssertEqual(PlaidCategory.canonical("INCOME_WAGES"), "Income")
        XCTAssertEqual(PlaidCategory.canonical("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"), "Transfer")
        XCTAssertEqual(PlaidCategory.canonical("LOAN_PAYMENTS_MORTGAGE_PAYMENT"), "Mortgage")
        XCTAssertNil(PlaidCategory.canonical("Some Random Merchant"))
        XCTAssertEqual(PlaidCategory.humanized("PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS"),
                       "Personal Care Gyms And Fitness Centers")
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

    // MARK: Expenses↔transactions merge

    func testUnlinkedExpenseCountsAtOwedShare() {
        let checking = account(type: "checking")
        let txns = [txn(30, category: "Dining", account: checking)]
        // A $60 dinner split — my share is $20 — with no linked transaction.
        let exps = [expense(60, category: "Dining", owed: 20)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.first?.category, "Dining")
        XCTAssertEqual(result.first?.total, 50)  // 30 transaction + 20 owed share
        // Monthly spending picks it up too.
        let series = SpendingAnalytics.monthlySpending(transactions: txns, accounts: [checking],
                                                       lookup: [:], months: 1, expenses: exps, me: "me")
        XCTAssertEqual(series.first?.value, 50)
    }

    func testLinkedExpenseNotDoubleCounted() {
        let checking = account(type: "checking")
        let t = txn(60, category: "Dining", account: checking)
        // Expense linked to the transaction — already represented by it, so it must not add again.
        let exps = [expense(60, category: "Dining", owed: 20, transactionId: t.id)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [t],
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.first?.total, 60)  // transaction only
    }

    func testExcludedAndZeroShareExpensesIgnored() {
        let checking = account(type: "checking")
        let exps = [
            expense(100, category: "Settle-up", owed: 50),  // internal, excluded
            expense(100, category: "Income", owed: 50),     // not spend, excluded
            expense(40, category: "Dining", owed: 0),        // you owe nothing → skip
            expense(40, category: "Dining", me: "other", owed: 40),  // no split for me → skip
        ]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: [],
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertTrue(result.isEmpty)
        // And nil `me` means no expenses are attributed at all.
        let archived = [expense(40, category: "Dining", owed: 20, archived: Date())]
        XCTAssertTrue(SpendingAnalytics.byCategory(in: Date(), transactions: [], accounts: [checking],
                                                   lookup: [:], expenses: archived, me: "me").isEmpty)
    }

    func testUnlinkedExpenseReducesNetIncome() {
        let checking = account(type: "checking")
        let txns = [txn(-2000, category: "Income", account: checking)]  // paycheck in
        let exps = [expense(60, category: "Dining", owed: 20)]          // cash dinner share out
        let series = SpendingAnalytics.monthlyNetIncome(transactions: txns, accounts: [checking],
                                                        lookup: [:], months: 1, expenses: exps, me: "me")
        XCTAssertEqual(series.first?.value, 1980)  // 2000 in − 20 owed share
    }

    func testSplitwiseCategoryMapping() {
        XCTAssertEqual(SplitwiseCategory.canonical("Dining out"), "Dining")
        XCTAssertEqual(SplitwiseCategory.canonical("Gas/fuel"), "Fuel")
        XCTAssertEqual(SplitwiseCategory.canonical("Electricity"), "Utilities")
        XCTAssertEqual(SplitwiseCategory.canonical("Medical expenses"), "Health")
        XCTAssertNil(SplitwiseCategory.canonical("Not A Splitwise Category"))
        // Routed through CategoryMapping.canonical (after the Plaid map).
        XCTAssertEqual(CategoryMapping.canonical("Dining out", lookup: [:]), "Dining")
        // A manual override still wins over the Splitwise map.
        XCTAssertEqual(CategoryMapping.canonical("Dining out", lookup: ["Dining out": "Entertainment"]),
                       "Entertainment")
    }

    func testSplitwiseExpenseFoldsIntoCanonicalBucket() {
        let checking = account(type: "checking")
        // A Plaid "Dining" transaction and a Splitwise "Dining out" expense should share one slice.
        let txns = [txn(30, category: "Dining", account: checking)]
        let exps = [expense(60, category: "Dining out", owed: 20)]
        let result = SpendingAnalytics.byCategory(in: Date(), transactions: txns,
                                                  accounts: [checking], lookup: [:], expenses: exps, me: "me")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, "Dining")
        XCTAssertEqual(result.first?.total, 50)  // not fragmented into a separate "Dining out" slice
    }

    func testCategoryDependentsReverseMapping() {
        let checking = account(type: "checking")
        // A Plaid label that resolves to Dining via the built-in primary map (no override row),
        let txns = [
            txn(5, category: "FOOD_AND_DRINK_COFFEE", account: checking),
            txn(5, category: "FOOD_AND_DRINK_GROCERIES", account: checking),  // -> Groceries
        ]
        // a Splitwise name that resolves to Dining via the deterministic Splitwise map,
        let exps = [expense(10, category: "Dining out", owed: 10, splitwiseId: "sw1"),
                    expense(10, category: "Settle-up", owed: 10, splitwiseId: "sw2")]  // excluded
        let grouped = CategoryDependents.grouped(transactions: txns, expenses: exps, categoryMaps: [])
        let dining = (grouped["Dining"] ?? []).map(\.raw).sorted()
        XCTAssertEqual(dining, ["Dining out", "FOOD_AND_DRINK_COFFEE"])  // built-in links, not just overrides
        XCTAssertEqual(grouped["Groceries"]?.map(\.raw), ["FOOD_AND_DRINK_GROCERIES"])
        XCTAssertNil(grouped["Settle-up"])  // settle-up excluded

        // An override re-points a label to a different canonical, moving it in the reverse map.
        let maps = [CategoryMap(id: UUID(), rawCategory: "FOOD_AND_DRINK_COFFEE",
                                canonicalCategory: "Household", source: "manual",
                                createdAt: Date(), updatedAt: Date())]
        let grouped2 = CategoryDependents.grouped(transactions: txns, expenses: exps, categoryMaps: maps)
        XCTAssertEqual(grouped2["Dining"]?.map(\.raw), ["Dining out"])
        XCTAssertEqual(grouped2["Household"]?.map(\.raw), ["FOOD_AND_DRINK_COFFEE"])
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

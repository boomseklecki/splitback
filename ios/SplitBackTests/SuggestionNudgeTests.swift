import XCTest
@testable import SplitBackAPI

/// The "broad" nudge cards: shared-budget candidate, overspend, settle-up.
final class SuggestionNudgeTests: XCTestCase {
    private let me = "me", alex = "alex"

    private func members(_ group: UUID, _ ids: [String]) -> [GroupMember] {
        ids.map { GroupMember(id: UUID(), groupId: group, userIdentifier: $0, createdAt: Date()) }
    }

    private func sharedExpense(_ group: UUID, category: String, splits: [(String, Decimal)]) -> Expense {
        let s = splits.map { Split(id: UUID(), userIdentifier: $0.0, paidShare: 0, owedShare: $0.1) }
        return Expense(id: UUID(), groupId: group, details: "e",
                       amount: splits.reduce(Decimal(0)) { $0 + $1.1 }, currency: "USD", date: Date(),
                       category: category, createdAt: Date(), updatedAt: Date(), splits: s)
    }

    private func goal(_ category: String, target: Decimal, shared: Bool) -> Goal {
        Goal(id: UUID(), kind: "spend", name: category, category: category, targetAmount: target,
             currency: "USD", shared: shared, createdAt: Date(), updatedAt: Date())
    }

    private func nudges(goals: [Goal] = [], transactions: [Transaction] = [], expenses: [Expense] = [],
                        accounts: [Account] = [], groupMembers: [GroupMember] = [],
                        partners: Set<String> = [],
                        friendNets: [(identifier: String, name: String, net: Decimal)] = [],
                        decisions: [SuggestionDecision] = []) -> [Suggestion] {
        SuggestionEngine.nudges(goals: goals, transactions: transactions, expenses: expenses,
                                accounts: accounts, lookup: [:], groupMembers: groupMembers,
                                partners: partners, friendNets: friendNets, decisions: decisions, me: me)
    }

    func testSharedBudgetCandidate() {
        let g = UUID()
        let cards = nudges(expenses: [sharedExpense(g, category: "Dining", splits: [(me, 30), (alex, 30)])],
                           groupMembers: members(g, [me, alex]), partners: [alex])
            .filter { $0.kind == .sharedBudgetCandidate }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.category, "Dining")

        // Suppressed once a shared budget exists for the category.
        let suppressed = nudges(goals: [goal("Dining", target: 100, shared: true)],
                                expenses: [sharedExpense(g, category: "Dining", splits: [(me, 30), (alex, 30)])],
                                groupMembers: members(g, [me, alex]), partners: [alex])
            .filter { $0.kind == .sharedBudgetCandidate }
        XCTAssertTrue(suppressed.isEmpty)
    }

    func testOverspend() {
        let account = Account(id: UUID(), name: "Checking", type: "checking", balance: 0, currency: "USD",
                              createdAt: Date(), updatedAt: Date())
        let txn = Transaction(id: UUID(), accountId: account.id, source: .plaid, details: "Dinner",
                              amount: 100, currency: "USD", date: Date(), category: "FOOD_AND_DRINK",
                              createdAt: Date(), updatedAt: Date())
        let cards = nudges(goals: [goal("Dining", target: 50, shared: false)],
                           transactions: [txn], accounts: [account]).filter { $0.kind == .overspend }
        XCTAssertEqual(cards.count, 1)                       // spent 100 > target 50
        XCTAssertNotNil(cards.first?.goalId)

        let under = nudges(goals: [goal("Dining", target: 500, shared: false)],
                           transactions: [txn], accounts: [account]).filter { $0.kind == .overspend }
        XCTAssertTrue(under.isEmpty)
    }

    func testSettleUp() {
        let over = nudges(friendNets: [(identifier: alex, name: "Alex", net: 20)])
            .filter { $0.kind == .settleUp }
        XCTAssertEqual(over.count, 1)
        XCTAssertEqual(over.first?.friendIdentifier, alex)

        let under = nudges(friendNets: [(identifier: alex, name: "Alex", net: 2)])
            .filter { $0.kind == .settleUp }
        XCTAssertTrue(under.isEmpty)                          // below the threshold
    }

    func testDismissalSuppresses() {
        let decision = SuggestionDecision(key: "settleup:\(alex)", decision: "dismissed")
        let cards = nudges(friendNets: [(identifier: alex, name: "Alex", net: 20)], decisions: [decision])
        XCTAssertTrue(cards.filter { $0.kind == .settleUp }.isEmpty)
    }
}

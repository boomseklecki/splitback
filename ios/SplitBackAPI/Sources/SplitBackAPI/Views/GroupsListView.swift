import SwiftUI
import SwiftData

/// The Expenses tab: your active groups with your per-group net, plus an "All Expenses" link.
/// Settled groups (zero balance or a settle-up as the latest expense) are hidden by default; sort
/// order and the show-settled toggle are user choices.
struct GroupsListView: View {
    enum SortMode: String, CaseIterable, Identifiable {
        case activity = "Recent activity"
        case balance = "Balance"
        case name = "Name"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<ExpenseGroup> { $0.archivedAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query(filter: #Predicate<Expense> { $0.archivedAt == nil },
           sort: \Expense.date, order: .reverse)
    private var expenses: [Expense]

    @AppStorage("expenses.sortMode") private var sortModeRaw = SortMode.activity.rawValue
    @AppStorage("expenses.showSettled") private var showSettled = false

    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var errorText: String?
    /// Your net balance per group (group id → net), keyed by the signed-in user from `/me`.
    @State private var myNets: [UUID: Decimal] = [:]

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .activity }

    /// Re-run the balance load whenever the signed-in user or the set of groups changes.
    private var balanceKey: [String] {
        (env.currentUser.map { [$0.identifier] } ?? []) + groups.map(\.id.uuidString)
    }

    /// Latest expense per group (the `expenses` query is date-descending, so the first match wins).
    private var lastExpenseByGroup: [UUID: Expense] {
        var result: [UUID: Expense] = [:]
        for expense in expenses where result[expense.groupId] == nil {
            result[expense.groupId] = expense
        }
        return result
    }

    /// A group is "settled" (hidden by default) when your net is zero or its most recent expense is a
    /// settle-up. Groups with an unknown balance (not signed in) are never auto-hidden.
    private func isSettled(_ group: ExpenseGroup) -> Bool {
        if lastExpenseByGroup[group.id]?.category == SettleUp.category { return true }
        if let net = myNets[group.id], net == 0 { return true }
        return false
    }

    private var hiddenCount: Int { groups.filter(isSettled).count }

    private var visibleGroups: [ExpenseGroup] {
        let shown = showSettled ? groups : groups.filter { !isSettled($0) }
        switch sortMode {
        case .activity:
            return shown.sorted {
                (lastExpenseByGroup[$0.id]?.date ?? .distantPast) > (lastExpenseByGroup[$1.id]?.date ?? .distantPast)
            }
        case .balance:
            return shown.sorted { abs(myNets[$0.id] ?? 0) > abs(myNets[$1.id] ?? 0) }
        case .name:
            return shown.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Groups") {
                    ForEach(visibleGroups) { group in
                        NavigationLink(value: group) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                    Text(group.backendType == .splitwise ? "Splitwise" : "Self-hosted")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let net = myNets[group.id] {
                                    Text(net.formatted(.currency(code: "USD")))
                                        .monospacedDigit()
                                        .foregroundStyle(net >= 0 ? .green : .red)
                                }
                            }
                        }
                    }
                    if visibleGroups.isEmpty {
                        Text(groups.isEmpty ? "No groups yet. Pull to refresh, or add one with +."
                                            : "All settled up.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink("All Expenses") { AllExpensesView() }
                }
            }
            .navigationTitle("Expenses")
            .navigationDestination(for: ExpenseGroup.self) { GroupDetailView(group: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort by", selection: $sortModeRaw) {
                            ForEach(SortMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        if hiddenCount > 0 || showSettled {
                            Toggle(isOn: $showSettled) {
                                Label("Show settled (\(hiddenCount))", systemImage: "eye")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewGroup = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable {
                do { try await env.groups(context).reconcileAll() }
                catch { errorText = errorMessage(error) }
                await loadMyBalances()
            }
            .task(id: balanceKey) { await loadMyBalances() }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create", action: createGroup)
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .errorAlert($errorText)
        }
    }

    /// Loads your net balance for each group. No-op (clears) when not signed in, so nothing is shown
    /// rather than guessing an identity.
    private func loadMyBalances() async {
        guard let me = env.currentUser?.identifier else { myNets = [:]; return }
        var result: [UUID: Decimal] = [:]
        for group in groups {
            if let net = try? await env.balances.forGroup(group.id).first(where: { $0.identifier == me })?.net {
                result[group.id] = net
            }
        }
        myNets = result
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        newGroupName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await env.groups(context).create(name: name) }
            catch { errorText = errorMessage(error) }
        }
    }
}

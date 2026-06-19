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

    @AppStorage("expenses.sortMode") private var sortModeRaw = SortMode.activity.rawValue
    @AppStorage("expenses.showSettled") private var showSettled = false

    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var errorText: String?
    /// Your net balance per group (group id → net), keyed by the signed-in user from `/me`.
    @State private var myNets: [UUID: Decimal] = [:]
    /// Latest-expense summary per group (date for activity sort, settle-up flag for hiding). Loaded on
    /// demand with a `fetchLimit: 1` query per group rather than materializing every expense.
    @State private var lastExpense: [UUID: (date: Date, isSettleUp: Bool)] = [:]

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .activity }

    /// Re-run the balance load whenever the signed-in user or the set of groups changes.
    private var balanceKey: [String] {
        (env.currentUser.map { [$0.identifier] } ?? []) + groups.map(\.id.uuidString)
    }

    private func isSettled(_ group: ExpenseGroup) -> Bool {
        GroupSummary.isSettled(group, myNets: myNets, lastExpense: lastExpense)
    }

    /// "Trip · Splitwise" when a Splitwise group_type is known, else just the backend label.
    private func subtitle(_ group: ExpenseGroup) -> String {
        let backend = group.backendType == .splitwise ? "Splitwise" : "Self-hosted"
        if let type = group.groupType, !type.isEmpty {
            return "\(type.capitalized) · \(backend)"
        }
        return backend
    }

    private var hiddenCount: Int { groups.filter(isSettled).count }

    private var visibleGroups: [ExpenseGroup] {
        let shown = showSettled ? groups : groups.filter { !isSettled($0) }
        switch sortMode {
        case .activity:
            return GroupSummary.byActivity(shown, lastExpense: lastExpense)
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
                            HStack(spacing: 12) {
                                AvatarView(url: group.avatarURL, name: group.name, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                    Text(subtitle(group))
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
                loadLastExpenses()
            }
            .task(id: balanceKey) {
                await loadMyBalances()
                loadLastExpenses()
            }
            .onChange(of: showSettled) { _, _ in loadLastExpenses() }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create", action: createGroup)
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .errorAlert($errorText)
        }
    }

    private func loadMyBalances() async {
        myNets = await GroupSummary.myNets(groups, me: env.currentUser?.identifier, balances: env.balances)
    }

    private func loadLastExpenses() {
        lastExpense = GroupSummary.lastExpenses(groups, myNets: myNets, includeSettled: showSettled, context: context)
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

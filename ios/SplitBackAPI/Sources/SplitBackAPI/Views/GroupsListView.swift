import SwiftUI
import SwiftData
import PhotosUI
import UIKit

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
    @Query private var members: [GroupMember]
    @Query private var balanceRows: [GroupBalance]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]

    @AppStorage("expenses.sortMode") private var sortModeRaw = SortMode.activity.rawValue
    @AppStorage("expenses.showSettled") private var showSettled = false

    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var errorText: String?
    @State private var showingNewExpense = false
    @State private var showingReceiptScanner = false
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var scan = ReceiptScanModel()
    /// Latest-expense summary per group (date for activity sort, settle-up flag for hiding). Loaded on
    /// demand with a `fetchLimit: 1` query per group rather than materializing every expense.
    @State private var lastExpense: [UUID: (date: Date, isSettleUp: Bool)] = [:]

    private var sortMode: SortMode { SortMode(rawValue: sortModeRaw) ?? .activity }

    /// Your net per group, read instantly from the cached `GroupBalance` rows (refreshed in the background).
    private var myNets: [UUID: Decimal] {
        GroupSummary.myNets(from: balanceRows, me: env.currentUser?.identifier)
    }

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

    /// The group a "+"-launched expense starts in (most-recent active, falling back to any group).
    /// The editor lets you switch from here. Nil when there are no groups, which hides the expense actions.
    private var defaultGroup: ExpenseGroup? { visibleGroups.first ?? groups.first }
    private var defaultMembers: [String] {
        guard let id = defaultGroup?.id else { return [] }
        return members.filter { $0.groupId == id }.map(\.userIdentifier)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Groups") {
                    ForEach(visibleGroups) { group in
                        NavigationLink(value: group) {
                            HStack(spacing: 12) {
                                AvatarView(url: group.avatarURL, name: group.name, size: 36,
                                           systemImage: group.typeSymbol)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.name)
                                    Text(subtitle(group))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let net = myNets[group.id] {
                                    let phrase = BalancePhrase.mine(net)
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(phrase.label).font(.caption2).foregroundStyle(.secondary)
                                        if let amount = phrase.amount {
                                            Text(amount).font(.subheadline).fontWeight(.medium)
                                                .foregroundStyle(phrase.color).monospacedDigit()
                                        }
                                    }
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
            .navigationTitle("Splits")
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
                    Menu {
                        if defaultGroup != nil {
                            Button("Blank Expense", systemImage: "square.and.pencil") { showingNewExpense = true }
                            Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScanner = true }
                            PhotosPicker(selection: $receiptPhoto, matching: .images) {
                                Label("Receipt from Photo", systemImage: "photo")
                            }
                            Divider()
                        }
                        Button("Add Group", systemImage: "person.2.badge.plus") { showingNewGroup = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable {
                if env.splitwiseConnected {
                    do {
                        try await env.splitwise.syncExpenses()
                        try await env.splitwise.syncGroups()
                    } catch { /* best-effort: Splitwise sync never blocks the local refresh */ }
                }
                do { try await env.refreshAll(context) }
                catch { errorText = errorMessage(error) }
                await loadMyBalances()
                loadLastExpenses()
            }
            .task(id: balanceKey) {
                loadLastExpenses()        // renders instantly from the cached balances
                await loadMyBalances()    // refresh the cache in the background
                loadLastExpenses()        // recompute settled-hiding with fresh balances
            }
            .onChange(of: showSettled) { _, _ in loadLastExpenses() }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create", action: createGroup)
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .sheet(isPresented: $showingNewExpense) {
                if let defaultGroup {
                    ExpenseEditView(group: defaultGroup, members: defaultMembers)
                }
            }
            .sheet(isPresented: $showingReceiptScanner) {
                DocumentScannerView(
                    onComplete: { images in
                        showingReceiptScanner = false
                        if let first = images.first {
                            Task { await scan.process(image: first, categories: spendCategories.map(\.name)) }
                        }
                    },
                    onCancel: { showingReceiptScanner = false }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $scan.presentEditor) {
                if let defaultGroup, let prefill = scan.prefill {
                    ExpenseEditView(group: defaultGroup, members: defaultMembers,
                                    prefill: prefill, attachImageData: scan.imageData)
                }
            }
            .onChange(of: receiptPhoto) { _, item in
                guard let item else { return }
                Task {
                    defer { receiptPhoto = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await scan.process(image: image, categories: spendCategories.map(\.name))
                }
            }
            .overlay {
                if scan.isScanning {
                    ProgressView("Reading receipt…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Heads up", isPresented: Binding(
                get: { scan.infoMessage != nil }, set: { if !$0 { scan.infoMessage = nil } }
            )) {
                Button("OK") {}
            } message: { Text(scan.infoMessage ?? "") }
            .errorAlert(Binding(get: { scan.errorText }, set: { scan.errorText = $0 }))
            .errorAlert($errorText)
        }
    }

    /// Refresh the cached balances for all groups in the background; the cache (a @Query) updates the
    /// displayed nets as each group's fetch returns.
    private func loadMyBalances() async {
        await env.balances(context).refreshAll(groups.map(\.id))
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

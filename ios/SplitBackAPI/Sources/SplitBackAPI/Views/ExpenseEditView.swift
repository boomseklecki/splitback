import SwiftUI
import SwiftData

/// Create or edit an expense with split entry. The ±0.01 balance check is enforced client-side only
/// for self-hosted groups; Splitwise groups defer to Splitwise (the backend pushes on save).
struct ExpenseEditView: View {
    enum SplitMode: String, CaseIterable {
        case equal = "Equal"
        case exact = "Exact"
        case percentage = "Percent"
        case shares = "Shares"
        case adjustment = "+/−"
        case reimbursement = "Reimburse"
        case itemized = "Items"
    }

    let editing: Expense?
    let attachImageData: Data?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var users: [User]
    @Query(filter: #Predicate<ExpenseGroup> { $0.archivedAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]
    @Query private var allMembers: [GroupMember]

    @State private var myNets: [UUID: Decimal] = [:]
    @State private var lastExpense: [UUID: GroupSummary.Last] = [:]

    @State private var group: ExpenseGroup
    @State private var details: String
    @State private var amountString: String
    @State private var date: Date
    @State private var category: String?
    @State private var notes: String
    @State private var payer: String
    @State private var mode: SplitMode = .equal
    @State private var customOwed: [String: String]
    @State private var percents: [String: String] = [:]
    @State private var shareCounts: [String: String] = [:]
    @State private var adjustments: [String: String] = [:]
    @State private var itemOwners: [Int: String] = [:]
    @State private var participants: [String]
    @State private var items: [ItemDraft]
    @State private var transactionId: UUID?
    @State private var showingCategoryPicker = false
    @State private var saving = false
    @State private var errorText: String?

    init(group: ExpenseGroup, members: [String], editing: Expense? = nil,
         prefill: ExpensePrefill? = nil, attachImageData: Data? = nil) {
        self.editing = editing
        self.attachImageData = attachImageData
        _group = State(initialValue: group)
        let people = members.isEmpty ? (editing?.splits.map(\.userIdentifier) ?? []) : members
        _participants = State(initialValue: people)
        _details = State(initialValue: editing?.details ?? prefill?.details ?? "")
        let seedAmount = editing.map(\.amount) ?? prefill?.amount
        _amountString = State(initialValue: seedAmount.map(Mapping.decimalString) ?? "")
        _date = State(initialValue: editing?.date ?? prefill?.date ?? Date())
        _category = State(initialValue: editing?.category ?? prefill?.category)
        _notes = State(initialValue: editing?.notes ?? "")
        let payerFromEdit = editing?.splits.first(where: { $0.paidShare > 0 })?.userIdentifier
        _payer = State(initialValue: payerFromEdit ?? people.first ?? "")
        var owed: [String: String] = [:]
        for split in editing?.splits ?? [] { owed[split.userIdentifier] = Mapping.decimalString(split.owedShare) }
        _customOwed = State(initialValue: owed)
        let seedItems = editing?.items.map {
            ItemDraft(name: $0.name, quantity: $0.quantity, price: $0.price, category: $0.category)
        } ?? prefill?.items ?? []
        _items = State(initialValue: seedItems)
        _transactionId = State(initialValue: editing?.transactionId ?? prefill?.transactionId)
        // Preserve a stored split when editing (Reimbursement if marked, else Exact); new expenses
        // start on Equal.
        let editingMode: SplitMode = editing?.category == Reimbursement.category ? .reimbursement : .exact
        _mode = State(initialValue: editing == nil ? .equal : editingMode)
    }

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var isSelfHosted: Bool { group.backendType == .selfHosted }

    /// Groups the expense can be moved to (new expenses only). Same filtered/sorted list the
    /// transaction→expense picker uses (settled hidden, recent-activity first), with the current
    /// group always kept so it shows even when it would otherwise be filtered out.
    private var selectableGroups: [ExpenseGroup] {
        var list = GroupSummary.visible(groups, myNets: myNets, lastExpense: lastExpense, includeSettled: false)
        if !list.contains(where: { $0.id == group.id }) { list.insert(group, at: 0) }
        return list
    }

    /// Reimbursement is self-hosted only: it relies on a local "Reimbursement" marker + inverted shares
    /// that Splitwise can't represent and that's lost when an expense round-trips through Splitwise.
    private var availableModes: [SplitMode] {
        isSelfHosted ? SplitMode.allCases : SplitMode.allCases.filter { $0 != .reimbursement }
    }

    private func displayName(_ identifier: String) -> String { users.displayName(for: identifier) }
    /// "you" for the current user, otherwise the person's display name (for the compact payer button).
    private var payerLabel: String {
        payer == env.currentUser?.identifier ? "you" : displayName(payer)
    }

    private func decimal(_ string: String?) -> Decimal {
        // Tolerate a leading "+" (the adjustment field's placeholder invites it) — Decimal(string:)
        // returns nil for "+6", which would silently drop the adjustment.
        var text = (string ?? "").trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") { text.removeFirst() }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
    private func numeric(_ map: [String: String]) -> [String: Decimal] {
        map.reduce(into: [:]) { $0[$1.key] = decimal($1.value) }
    }
    /// Per-person total of the line items assigned to them (itemized mode).
    private var assignedItemTotals: [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for (index, item) in items.enumerated() {
            if let owner = itemOwners[index] { totals[owner, default: 0] += item.price }
        }
        return totals
    }

    private var splits: [SplitDraft] {
        switch mode {
        case .equal:
            return SplitMath.equalSplit(amount: amount, payer: payer, participants: participants)
        case .exact:
            return participants.map { person in
                SplitDraft(userIdentifier: person,
                           paidShare: person == payer ? amount : 0,
                           owedShare: decimal(customOwed[person]))
            }
        case .percentage:
            return SplitMath.weightedSplit(amount: amount, payer: payer, participants: participants,
                                           weights: numeric(percents))
        case .shares:
            return SplitMath.weightedSplit(amount: amount, payer: payer, participants: participants,
                                           weights: numeric(shareCounts))
        case .adjustment:
            return SplitMath.adjustmentSplit(amount: amount, payer: payer, participants: participants,
                                             adjustments: numeric(adjustments))
        case .reimbursement:
            return SplitMath.reimbursementSplit(amount: amount, payer: payer, participants: participants)
        case .itemized:
            return SplitMath.itemizedSplit(amount: amount, payer: payer, participants: participants,
                                           assigned: assignedItemTotals)
        }
    }

    private func owed(_ person: String) -> Decimal {
        splits.first { $0.userIdentifier == person }?.owedShare ?? 0
    }
    private func owedText(_ person: String) -> String {
        owed(person).formatted(.currency(code: "USD"))
    }
    /// Each person's equal share of the reimbursement ("gets back $50") — the per-person split, shown
    /// like the owed amount in every other mode. (The gross the recipient received is a detail-view
    /// concern, not the editor's.)
    private func reimbursementGetsBackText(_ person: String) -> String {
        let value = splits.first { $0.userIdentifier == person }?.paidShare ?? 0
        return "gets back " + value.formatted(.currency(code: "USD"))
    }

    private func entry(_ map: Binding<[String: String]>, _ key: String) -> Binding<String> {
        Binding(get: { map.wrappedValue[key, default: ""] }, set: { map.wrappedValue[key] = $0 })
    }

    /// The trailing input for one participant, per split mode. Computed-only modes show the owed amount.
    @ViewBuilder
    private func splitInput(_ person: String) -> some View {
        switch mode {
        case .equal, .itemized:
            Text(owedText(person)).foregroundStyle(.secondary)
        case .reimbursement:
            Text(reimbursementGetsBackText(person)).foregroundStyle(.secondary)
        case .exact:
            TextField("0.00", text: entry($customOwed, person))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
        case .percentage:
            HStack(spacing: 4) {
                TextField("0", text: entry($percents, person))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 48)
                Text("%").foregroundStyle(.secondary)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        case .shares:
            HStack(spacing: 8) {
                TextField("0", text: entry($shareCounts, person))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 40)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        case .adjustment:
            HStack(spacing: 8) {
                TextField("+0.00", text: entry($adjustments, person))
                    .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 64)
                Text(owedText(person)).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private var balanced: Bool { SplitMath.isBalanced(amount: amount, splits: splits) }
    private var canSave: Bool {
        !details.trimmingCharacters(in: .whitespaces).isEmpty && amount > 0 && !payer.isEmpty
            && (!isSelfHosted || balanced) && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); groupSelector; Spacer() }
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 12) {
                        if mode != .reimbursement {
                            Button { showingCategoryPicker = true } label: {
                                Image(systemName: categorySymbol(category))
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                        TextField("Description", text: $details)
                            .font(.title3)
                    }
                    HStack(spacing: 8) {
                        Text("$").font(.title2).foregroundStyle(.secondary)
                        TextField("0.00", text: $amountString)
                            .keyboardType(.decimalPad).font(.title2)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if !items.isEmpty {
                    Section("Items") {
                        ForEach(items.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(items[index].name)
                                    Spacer()
                                    Text(items[index].price.formatted(.currency(code: "USD")))
                                        .foregroundStyle(.secondary)
                                }
                                if mode == .itemized {
                                    Picker("Assigned to", selection: Binding(
                                        get: { itemOwners[index] ?? "" },
                                        set: { itemOwners[index] = $0.isEmpty ? nil : $0 }
                                    )) {
                                        Text("Unassigned").tag("")
                                        ForEach(participants, id: \.self) { Text(displayName($0)).tag($0) }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                Section("Split") {
                    splitSentence

                    if mode == .reimbursement {
                        Text("\(payerLabel.capitalized) was reimbursed the full amount and splits it equally — \(payerLabel) owes the others their share.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(participants, id: \.self) { person in
                        HStack {
                            Text(displayName(person))
                            Spacer()
                            splitInput(person)
                        }
                    }

                    if isSelfHosted {
                        Label(
                            balanced ? "Balanced" : "Off by \((amount - SplitMath.owedSum(splits)).formatted(.currency(code: "USD")))",
                            systemImage: balanced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(balanced ? .green : .orange)
                    } else {
                        Text("Splitwise validates this split on save.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Expense" : "Edit Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .sheet(isPresented: $showingCategoryPicker) {
                CategoryPickerView(current: category) { category = $0 }
            }
            .task {
                guard editing == nil else { return }
                // For a new expense, default "Paid by" to you (from /me) when you're a participant —
                // otherwise keep the first member chosen in init.
                if let me = env.currentUser?.identifier, participants.contains(me) { payer = me }
                // Settled-filtering + activity sort for the group switcher (mirrors the transaction picker).
                myNets = await GroupSummary.myNets(groups, me: env.currentUser?.identifier, balances: env.balances)
                lastExpense = GroupSummary.lastExpenses(groups, myNets: myNets, includeSettled: false, context: context)
            }
            .errorAlert($errorText)
        }
    }

    /// Centered group avatar + name; a menu to switch groups when creating a new expense and more
    /// than one is available.
    @ViewBuilder
    private var groupSelector: some View {
        if editing == nil, selectableGroups.count > 1 {
            Menu {
                ForEach(selectableGroups, id: \.id) { g in
                    Button {
                        selectGroup(g)
                    } label: {
                        if g.id == group.id { Label(g.name, systemImage: "checkmark") } else { Text(g.name) }
                    }
                }
            } label: {
                groupLabel(chevron: true)
            }
        } else {
            groupLabel(chevron: false)
        }
    }

    private func groupLabel(chevron: Bool) -> some View {
        HStack(spacing: 8) {
            AvatarView(url: group.avatarURL, name: group.name, size: 28)
            Text(group.name).font(.headline)
            if chevron { Image(systemName: "chevron.up.chevron.down").font(.caption2) }
        }
    }

    /// "Paid by [you] and split [Equally]" with the payer and mode as tappable capsule buttons.
    private var splitSentence: some View {
        HStack(spacing: 6) {
            Text(mode == .reimbursement ? "Reimbursed to" : "Paid by").foregroundStyle(.secondary)
            Menu {
                ForEach(participants, id: \.self) { person in
                    Button(displayName(person)) { payer = person }
                }
            } label: { capsule(payerLabel) }
            Text("and split").foregroundStyle(.secondary)
            Menu {
                ForEach(availableModes, id: \.self) { m in
                    Button(m.rawValue) { mode = m }
                }
            } label: { capsule(mode.rawValue) }
            Spacer(minLength: 0)
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }

    /// Move a new expense to another group: reset participants/payer to that group's members and clear
    /// the per-mode entry maps (they key on identifiers that no longer apply).
    private func selectGroup(_ g: ExpenseGroup) {
        group = g
        let gid = g.id
        let members = allMembers.filter { $0.groupId == gid }.map(\.userIdentifier).sorted()
        participants = members
        payer = (env.currentUser?.identifier).flatMap { members.contains($0) ? $0 : nil } ?? members.first ?? ""
        customOwed = [:]; percents = [:]; shareCounts = [:]; adjustments = [:]; itemOwners = [:]
        if !availableModes.contains(mode) { mode = .equal }
    }

    private func save() {
        saving = true
        let me = env.currentUser?.identifier
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = ExpenseDraft(
            groupId: group.id, details: details, amount: amount,
            date: date, category: mode == .reimbursement ? Reimbursement.category : category,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            createdBy: editing == nil ? me : nil,
            updatedBy: editing != nil ? me : nil,
            transactionId: transactionId,
            splits: splits, items: items
        )
        Task {
            defer { saving = false }
            do {
                if let editing {
                    try await env.expenses(context).update(id: editing.id, draft)
                } else {
                    let newId = try await env.expenses(context).create(draft)
                    if let attachImageData {
                        try await env.receipts(context).upload(expenseId: newId, imageData: attachImageData)
                    }
                }
                dismiss()
            } catch {
                errorText = errorMessage(error)
            }
        }
    }
}

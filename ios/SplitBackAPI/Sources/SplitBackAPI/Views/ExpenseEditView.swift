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

    let group: ExpenseGroup
    let editing: Expense?
    let attachImageData: Data?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

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
    @State private var categories: [String] = []
    @State private var participants: [String]
    @State private var items: [ItemDraft]
    @State private var transactionId: UUID?
    @State private var saving = false
    @State private var errorText: String?

    init(group: ExpenseGroup, members: [String], editing: Expense? = nil,
         prefill: ExpensePrefill? = nil, attachImageData: Data? = nil) {
        self.group = group
        self.editing = editing
        self.attachImageData = attachImageData
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

    /// Reimbursement is self-hosted only: it relies on a local "Reimbursement" marker + inverted shares
    /// that Splitwise can't represent and that's lost when an expense round-trips through Splitwise.
    private var availableModes: [SplitMode] {
        isSelfHosted ? SplitMode.allCases : SplitMode.allCases.filter { $0 != .reimbursement }
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
    /// What each person "gets back" in a reimbursement: the recipient gets the full amount, everyone
    /// else gets their equal share.
    private func reimbursementGetsBackText(_ person: String) -> String {
        let split = splits.first { $0.userIdentifier == person }
        let value = person == payer ? (split?.owedShare ?? 0) : (split?.paidShare ?? 0)
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
                    TextField("Description", text: $details)
                    TextField("Amount", text: $amountString).keyboardType(.decimalPad)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    if mode != .reimbursement {
                        Picker("Category", selection: $category) {
                            Text("None").tag(String?.none)
                            ForEach(categories, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
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
                                        ForEach(participants, id: \.self) { Text($0).tag($0) }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                Section("Split") {
                    Picker(mode == .reimbursement ? "Reimbursed" : "Paid by", selection: $payer) {
                        ForEach(participants, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(availableModes, id: \.self) { Text($0.rawValue).tag($0) }
                    }

                    if mode == .reimbursement {
                        Text("\(payer) was reimbursed the full amount and splits it equally — \(payer) owes the others their share.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(participants, id: \.self) { person in
                        HStack {
                            Text(person)
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
            .task {
                // For a new expense, default "Paid by" to you (from /me) when you're a participant —
                // otherwise fall back to the first member chosen in init. Set before any await so it
                // lands before the user can interact.
                if editing == nil, let me = env.currentUser?.identifier, participants.contains(me) {
                    payer = me
                }
                categories = (try? await env.categories.list()) ?? []
            }
            .errorAlert($errorText)
        }
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

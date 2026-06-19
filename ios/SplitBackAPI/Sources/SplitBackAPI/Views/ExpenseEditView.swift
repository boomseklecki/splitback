import SwiftUI
import SwiftData

/// Create or edit an expense with split entry. The ±0.01 balance check is enforced client-side only
/// for self-hosted groups; Splitwise groups defer to Splitwise (the backend pushes on save).
struct ExpenseEditView: View {
    enum SplitMode: String, CaseIterable { case equal = "Equal", custom = "Custom" }

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
    @State private var payer: String
    @State private var mode: SplitMode = .equal
    @State private var customOwed: [String: String]
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
    }

    private var amount: Decimal { Decimal(string: amountString, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    private var isSelfHosted: Bool { group.backendType == .selfHosted }

    private var splits: [SplitDraft] {
        switch mode {
        case .equal:
            return SplitMath.equalSplit(amount: amount, payer: payer, participants: participants)
        case .custom:
            return participants.map { person in
                SplitDraft(
                    userIdentifier: person,
                    paidShare: person == payer ? amount : 0,
                    owedShare: Decimal(string: customOwed[person] ?? "", locale: Locale(identifier: "en_US_POSIX")) ?? 0
                )
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
                    Picker("Category", selection: $category) {
                        Text("None").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }

                if !items.isEmpty {
                    Section("Items") {
                        ForEach(items.indices, id: \.self) { index in
                            HStack {
                                Text(items[index].name)
                                Spacer()
                                Text(items[index].price.formatted(.currency(code: "USD")))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Split") {
                    Picker("Paid by", selection: $payer) {
                        ForEach(participants, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Mode", selection: $mode) {
                        ForEach(SplitMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ForEach(participants, id: \.self) { person in
                        if mode == .equal {
                            let owed = splits.first(where: { $0.userIdentifier == person })?.owedShare ?? 0
                            HStack { Text(person); Spacer()
                                Text(owed.formatted(.currency(code: "USD"))).foregroundStyle(.secondary) }
                        } else {
                            HStack {
                                Text(person)
                                Spacer()
                                TextField("0.00", text: Binding(
                                    get: { customOwed[person] ?? "" },
                                    set: { customOwed[person] = $0 }
                                ))
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            }
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
        let draft = ExpenseDraft(
            groupId: group.id, details: details, amount: amount,
            date: date, category: category, transactionId: transactionId,
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

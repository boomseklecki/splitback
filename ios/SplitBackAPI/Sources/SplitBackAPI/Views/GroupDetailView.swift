import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// One group: its balances, members, and expenses (with settle-up collapse). Entry point for
/// creating expenses, managing members, and (for Splitwise groups) importing as a local group.
struct GroupDetailView: View {
    let group: ExpenseGroup

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var expenses: [Expense]
    @Query private var members: [GroupMember]
    @Query private var users: [User]

    @State private var balances: [Balance] = []
    @State private var showingNewExpense = false
    @State private var showingAddMember = false
    @State private var showCollapsed = false
    @State private var errorText: String?
    @State private var scan = ReceiptScanModel()
    @State private var showingReceiptScanner = false
    @State private var receiptPhoto: PhotosPickerItem?

    init(group: ExpenseGroup) {
        self.group = group
        let gid = group.id
        _expenses = Query(
            filter: #Predicate<Expense> { $0.groupId == gid && $0.archivedAt == nil },
            sort: \Expense.date, order: .reverse
        )
        _members = Query(
            filter: #Predicate<GroupMember> { $0.groupId == gid },
            sort: \GroupMember.userIdentifier
        )
    }

    private var collapse: (visible: [Expense], collapsed: Int) {
        SettleUp.collapseOlder(expenses)
    }

    var body: some View {
        List {
            if group.avatarURL != nil || group.groupType != nil {
                Section {
                    HStack(spacing: 12) {
                        AvatarView(url: group.avatarURL, name: group.name, size: 48,
                                   systemImage: group.typeSymbol)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.headline)
                            if let type = group.groupType, !type.isEmpty {
                                Text(type.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !balances.isEmpty {
                Section("Balances") {
                    ForEach(balances) { entry in
                        let phrase = BalancePhrase.member(
                            entry.net, isMe: entry.identifier == env.currentUser?.identifier)
                        HStack {
                            Text(entry.displayName?.titleCased ?? users.displayName(for: entry.identifier))
                            Spacer()
                            Text(phrase.label).font(.caption).foregroundStyle(.secondary)
                            if let amount = phrase.amount {
                                Text(amount).foregroundStyle(phrase.color).monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section("Members") {
                ForEach(members) { member in
                    Text(users.displayName(for: member.userIdentifier))
                }
                .onDelete(perform: removeMembers)
                Button {
                    showingAddMember = true
                } label: {
                    Label("Add Member", systemImage: "person.badge.plus")
                }
            }

            Section("Expenses") {
                let data = showCollapsed ? expenses : collapse.visible
                ForEach(data) { expense in
                    NavigationLink(value: expense) {
                        ExpenseRow(expense: expense)
                    }
                }
                if !showCollapsed && collapse.collapsed > 0 {
                    Button("Show \(collapse.collapsed) older expense\(collapse.collapsed == 1 ? "" : "s")") {
                        showCollapsed = true
                    }
                }
                if expenses.isEmpty {
                    Text("No expenses yet.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationDestination(for: Expense.self) { ExpenseDetailView(expense: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Blank Expense", systemImage: "square.and.pencil") { showingNewExpense = true }
                    Button("Scan Receipt", systemImage: "doc.viewfinder") { showingReceiptScanner = true }
                    PhotosPicker("Receipt from Photo", selection: $receiptPhoto, matching: .images)
                } label: {
                    Image(systemName: "plus")
                }
            }
            if group.backendType == .splitwise {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Import as Local Group", systemImage: "square.and.arrow.down", action: importLocal)
                }
            }
        }
        .sheet(isPresented: $showingNewExpense) {
            ExpenseEditView(group: group, members: members.map(\.userIdentifier))
        }
        .sheet(isPresented: $showingAddMember) {
            MemberPickerView(group: group, existing: Set(members.map(\.userIdentifier)))
        }
        .sheet(isPresented: $showingReceiptScanner) {
            DocumentScannerView(
                onComplete: { images in
                    showingReceiptScanner = false
                    if let first = images.first {
                        Task { await scan.process(image: first, categories: []) }
                    }
                },
                onCancel: { showingReceiptScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $scan.presentEditor) {
            if let prefill = scan.prefill {
                ExpenseEditView(group: group, members: members.map(\.userIdentifier),
                                prefill: prefill, attachImageData: scan.imageData)
            }
        }
        .onChange(of: receiptPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { receiptPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                await scan.process(image: image, categories: [])
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
        .refreshable { await reload() }
        .task { await reload() }
        .errorAlert($errorText)
    }

    private func reload() async {
        if env.splitwiseConnected, group.backendType == .splitwise {
            try? await env.splitwise.syncExpenses()
        }
        do {
            try await env.expenses(context).reconcileAll(groupId: group.id)
            try await env.groups(context).refreshMembers(groupId: group.id)
            balances = try await env.balances.forGroup(group.id)
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func removeMembers(_ offsets: IndexSet) {
        let identifiers = offsets.map { members[$0].userIdentifier }
        Task {
            do {
                for identifier in identifiers {
                    try await env.groups(context).removeMember(groupId: group.id, userIdentifier: identifier)
                }
            } catch { errorText = errorMessage(error) }
        }
    }

    private func importLocal() {
        Task {
            do {
                try await env.groups(context).importLocal(groupId: group.id)
                try await env.expenses(context).reconcileAll()
            } catch { errorText = errorMessage(error) }
        }
    }
}

/// A compact expense row: description, date, amount, and a settle-up marker.
struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.details)
                Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(expense.amount.formatted(.currency(code: expense.currency)))
                if expense.category == SettleUp.category {
                    Text("Settle-up").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

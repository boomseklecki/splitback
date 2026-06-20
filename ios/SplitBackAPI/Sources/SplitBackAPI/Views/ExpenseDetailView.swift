import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Full expense detail: a header with a tappable category icon + receipt thumbnail, a "who paid /
/// who owes" split breakdown, line items, receipt management, and edit/delete.
struct ExpenseDetailView: View {
    let expense: Expense

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var users: [User]
    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]

    @State private var showingEdit = false
    @State private var editPrefill: ExpensePrefill?
    @State private var showingCategoryPicker = false
    @State private var showingSplitwiseReceipt = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    @State private var showingScanner = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var viewingReceipt: Receipt?
    @State private var extractAvailable = false
    @State private var extracting = false

    private var hasReceipt: Bool { expense.receipts.first != nil || expense.splitwiseReceiptURL != nil }

    private var meIdentifier: String? { env.currentUser?.identifier }
    private var isSettleUp: Bool { expense.category == SettleUp.category }

    private var group: ExpenseGroup? {
        let gid = expense.groupId
        return try? context.fetch(FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })).first
    }

    /// "Added by Matt on Jun 19" using the real Splitwise added-on date (falling back to our import
    /// time when unknown).
    private var addedText: String {
        let date = (expense.splitwiseCreatedAt ?? expense.createdAt).formatted(date: .abbreviated, time: .omitted)
        if let by = expense.createdByIdentifier {
            return "Added by \(users.displayName(for: by)) on \(date)"
        }
        return "Added \(date)"
    }

    /// "Edited by Nikki on Jun 20" when it was edited after creation; nil otherwise.
    private var editedText: String? {
        guard let updated = expense.splitwiseUpdatedAt else { return nil }
        if let created = expense.splitwiseCreatedAt, abs(updated.timeIntervalSince(created)) < 1 { return nil }
        let date = updated.formatted(date: .abbreviated, time: .omitted)
        if let by = expense.updatedByIdentifier {
            return "Edited by \(users.displayName(for: by)) on \(date)"
        }
        return "Edited \(date)"
    }

    private func currency(_ value: Decimal) -> String { value.formatted(.currency(code: expense.currency)) }
    private func nameOrYou(_ id: String) -> String { id == meIdentifier ? "You" : users.displayName(for: id) }

    private var payers: [Split] {
        expense.splits.filter { $0.paidShare > 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
    }
    private var owers: [Split] {
        expense.splits.filter { $0.owedShare > 0 && $0.paidShare == 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
    }

    private var isReimbursement: Bool { expense.category == Reimbursement.category }
    /// The reimbursed person (encoded with owedShare == the full amount).
    private var reimbursementRecipient: Split? { expense.splits.max { $0.owedShare < $1.owedShare } }
    private func getsBackText(_ split: Split, amount: Decimal) -> String {
        let isMe = split.userIdentifier == meIdentifier
        let name = isMe ? "You" : users.displayName(for: split.userIdentifier)
        return "\(name) \(isMe ? "get back" : "gets back") \(currency(amount))"
    }

    private var settleUpText: String {
        let amount = currency(expense.amount)
        guard let payer = payers.first else { return amount }
        if let recipient = owers.first {
            return "\(nameOrYou(payer.userIdentifier)) paid \(nameOrYou(recipient.userIdentifier)) \(amount)"
        }
        return "\(nameOrYou(payer.userIdentifier)) paid \(amount)"
    }

    var body: some View {
        List {
            Section { header }

            if isReimbursement, let recipient = reimbursementRecipient {
                Section("Reimbursement") {
                    // Main row: the recipient and the gross amount they got back ("Matt got back $100").
                    Text("\(nameOrYou(recipient.userIdentifier)) got back \(currency(recipient.owedShare))")
                        .fontWeight(.medium)
                    // Indented: each other member's equal share ("Nikki gets back $50").
                    ForEach(expense.splits
                        .filter { $0.userIdentifier != recipient.userIdentifier }
                        .sorted { $0.userIdentifier < $1.userIdentifier }, id: \.userIdentifier) { split in
                        Text(getsBackText(split, amount: split.paidShare))
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                }
            } else if isSettleUp {
                Section { Text(settleUpText).fontWeight(.medium) }
            } else {
                Section("Split") {
                    ForEach(payers, id: \.userIdentifier) { split in
                        Text("\(nameOrYou(split.userIdentifier)) paid \(currency(split.paidShare))")
                            .fontWeight(.medium)
                    }
                    ForEach(owers, id: \.userIdentifier) { split in
                        let isMe = split.userIdentifier == meIdentifier
                        Text("\(nameOrYou(split.userIdentifier)) \(isMe ? "owe" : "owes") \(currency(split.owedShare))")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                }
            }

            if let notes = expense.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }

            if !expense.items.isEmpty {
                Section("Items") {
                    ForEach(expense.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: categorySymbol(item.category))
                                .foregroundStyle(categoryColor(item.category)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                HStack(spacing: 4) {
                                    if let category = item.category { Text(category) }
                                    // Item ownership is local-only (see ItemizedSpend); don't show a
                                    // (possibly stale) assignee on Splitwise items.
                                    if expense.splitwiseExpenseId == nil, let owner = item.ownerIdentifier {
                                        Text("· \(nameOrYou(owner))")
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(currency(item.price))
                        }
                    }
                }
            }

            Section("Receipts") {
                if !expense.receipts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(expense.receipts) { receipt in
                                ReceiptThumbnail(receipt: receipt)
                                    .onTapGesture { viewingReceipt = receipt }
                                    .contextMenu {
                                        Button("Delete", role: .destructive) { deleteReceipt(receipt) }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Menu {
                    PhotosPicker("Choose Photo", selection: $pickedPhoto, matching: .images)
                    Button("Scan Document", systemImage: "doc.viewfinder") { showingScanner = true }
                } label: {
                    Label(uploading ? "Uploading…" : "Add Receipt", systemImage: "paperclip")
                }
                .disabled(uploading)
                if extractAvailable && hasReceipt {
                    Button { Task { await extractItems() } } label: {
                        Label(extracting ? "Reading receipt…" : "Extract Items from Receipt",
                              systemImage: "sparkles")
                    }
                    .disabled(extracting)
                }
            }

            Section {
                Text(addedText).font(.caption).foregroundStyle(.secondary)
                if let editedText {
                    Text(editedText).font(.caption).foregroundStyle(.secondary)
                }
                if expense.repeats == true {
                    Label(expense.repeatInterval.map { "Repeats \($0)" } ?? "Repeating",
                          systemImage: "repeat")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let count = expense.commentsCount, count > 0 {
                    Text("\(count) comment\(count == 1 ? "" : "s") on Splitwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if expense.splitwiseExpenseId != nil {
                    Text("From Splitwise").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Expense", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(expense.details)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editPrefill = nil; showingEdit = true }
            }
        }
        .task { extractAvailable = ReceiptExtractor().isAvailable }
        .sheet(isPresented: $showingEdit) {
            if let group {
                ExpenseEditView(group: group, members: [], editing: expense, prefill: editPrefill)
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: expense.category) { newCategory in
                updateCategory(newCategory)
            }
        }
        .sheet(isPresented: $showingSplitwiseReceipt) {
            SplitwiseReceiptViewerView(expenseId: expense.id)
        }
        .confirmationDialog("Delete this expense?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: delete)
        }
        .sheet(isPresented: $showingScanner) {
            DocumentScannerView(
                onComplete: { images in
                    showingScanner = false
                    upload(images.compactMap { ReceiptImage.jpegData($0) })
                },
                onCancel: { showingScanner = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $viewingReceipt) { ReceiptViewerView(receipt: $0) }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { pickedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let jpeg = ReceiptImage.jpegData(from: data) else { return }
                upload([jpeg])
            }
        }
        .errorAlert($errorText)
    }

    /// Header: tappable category icon (→ picker), amount + category + date, receipt thumbnail.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { showingCategoryPicker = true } label: {
                Image(systemName: categorySymbol(expense.category))
                    .font(.title2)
                    .frame(width: 52, height: 52)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                            .background(Circle().fill(Color(.systemBackground)))
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(currency(expense.amount)).font(.title2).fontWeight(.semibold)
                Text(expense.category ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
                Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()
            receiptThumbnail
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var receiptThumbnail: some View {
        if let receipt = expense.receipts.first {
            ReceiptThumbnail(receipt: receipt)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { viewingReceipt = receipt }
        } else if expense.splitwiseReceiptURL != nil {
            SplitwiseReceiptThumbnail(expenseId: expense.id)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { showingSplitwiseReceipt = true }
        }
    }

    private func updateCategory(_ category: String) {
        let id = expense.id
        let me = env.currentUser?.identifier
        Task {
            do { try await env.expenses(context).updateCategory(id: id, category: category, updatedBy: me) }
            catch { errorText = errorMessage(error) }
        }
    }

    /// Run OCR + on-device extraction on the expense's existing receipt and open the editor with the
    /// extracted line items appended for review.
    private func extractItems() async {
        extracting = true
        defer { extracting = false }
        guard let image = await receiptImage() else {
            errorText = "Couldn't load the receipt image."
            return
        }
        do {
            let text = try await ReceiptOCR.recognizeText(in: image)
            let extraction = try await ReceiptExtractor().extract(from: text, categories: spendCategories.map(\.name))
            editPrefill = .from(extraction)
            showingEdit = true
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func receiptImage() async -> UIImage? {
        if let receipt = expense.receipts.first {
            return await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context))
        }
        if expense.splitwiseReceiptURL != nil {
            return await SplitwiseReceiptImageStore.shared.image(expenseId: expense.id)
        }
        return nil
    }

    private func upload(_ images: [Data]) {
        guard !images.isEmpty else { return }
        uploading = true
        let expenseId = expense.id
        Task {
            defer { uploading = false }
            do {
                for jpeg in images {
                    try await env.receipts(context).upload(expenseId: expenseId, imageData: jpeg)
                }
            } catch { errorText = errorMessage(error) }
        }
    }

    private func deleteReceipt(_ receipt: Receipt) {
        let receiptId = receipt.id
        let expenseId = expense.id
        Task {
            do { try await env.receipts(context).delete(receiptId: receiptId, expenseId: expenseId) }
            catch { errorText = errorMessage(error) }
        }
    }

    private func delete() {
        let id = expense.id
        Task {
            do {
                try await env.expenses(context).delete(id: id)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

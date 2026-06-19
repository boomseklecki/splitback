import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Full expense detail: splits, line items, receipts (capture via photo/scan, view, delete);
/// edit + delete the expense.
struct ExpenseDetailView: View {
    let expense: Expense

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var users: [User]

    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    @State private var showingScanner = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var viewingReceipt: Receipt?

    private var group: ExpenseGroup? {
        let gid = expense.groupId
        return try? context.fetch(FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })).first
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Amount", value: expense.amount.formatted(.currency(code: expense.currency)))
                LabeledContent("Date", value: expense.date.formatted(date: .long, time: .omitted))
                if let category = expense.category {
                    LabeledContent("Category", value: category)
                }
                if expense.splitwiseExpenseId != nil {
                    LabeledContent("Source", value: "Splitwise")
                }
            }

            Section("Splits") {
                ForEach(expense.splits.sorted(by: { $0.userIdentifier < $1.userIdentifier })) { split in
                    HStack {
                        Text(users.displayName(for: split.userIdentifier))
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("paid \(split.paidShare.formatted(.currency(code: expense.currency)))")
                            Text("owes \(split.owedShare.formatted(.currency(code: expense.currency)))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            if !expense.items.isEmpty {
                Section("Items") {
                    ForEach(expense.items) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text(item.price.formatted(.currency(code: expense.currency)))
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
            }

            Section {
                Button("Delete Expense", role: .destructive) { confirmingDelete = true }
            }
        }
        .navigationTitle(expense.details)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let group {
                ExpenseEditView(group: group, members: [], editing: expense)
            }
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

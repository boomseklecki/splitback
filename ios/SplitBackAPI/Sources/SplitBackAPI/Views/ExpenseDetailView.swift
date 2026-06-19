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

    @State private var showingEdit = false
    @State private var showingCategoryPicker = false
    @State private var showingSplitwiseReceipt = false
    @State private var confirmingDelete = false
    @State private var errorText: String?
    @State private var showingScanner = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var viewingReceipt: Receipt?

    private var meIdentifier: String? { env.currentUser?.identifier }
    private var isSettleUp: Bool { expense.category == SettleUp.category }

    private var group: ExpenseGroup? {
        let gid = expense.groupId
        return try? context.fetch(FetchDescriptor<ExpenseGroup>(predicate: #Predicate { $0.id == gid })).first
    }

    /// Our backend proxy that fetches the Splitwise receipt with the OAuth token — the raw Splitwise
    /// URL is auth-gated (HTTP 401) and can't be loaded directly by the app. `size` (e.g. "original")
    /// requests a higher resolution for the full-screen view.
    private func splitwiseReceiptProxyURL(size: String? = nil) -> URL? {
        guard expense.splitwiseReceiptURL != nil else { return nil }
        var url = APIConfig.baseURL.appendingPathComponent("splitwise/expenses/\(expense.id.uuidString)/receipt")
        if let size {
            url.append(queryItems: [URLQueryItem(name: "size", value: size)])
        }
        return url
    }

    private func currency(_ value: Decimal) -> String { value.formatted(.currency(code: expense.currency)) }
    private func nameOrYou(_ id: String) -> String { id == meIdentifier ? "You" : users.displayName(for: id) }

    private var payers: [Split] {
        expense.splits.filter { $0.paidShare > 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
    }
    private var owers: [Split] {
        expense.splits.filter { $0.owedShare > 0 && $0.paidShare == 0 }.sorted { $0.userIdentifier < $1.userIdentifier }
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

            if isSettleUp {
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

            if !expense.items.isEmpty {
                Section("Items") {
                    ForEach(expense.items) { item in
                        HStack {
                            Text(item.name)
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
            }

            Section {
                Text("Added \(expense.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
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
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            if let group {
                ExpenseEditView(group: group, members: [], editing: expense)
            }
        }
        .sheet(isPresented: $showingCategoryPicker) {
            CategoryPickerView(current: expense.category) { newCategory in
                updateCategory(newCategory)
            }
        }
        .sheet(isPresented: $showingSplitwiseReceipt) {
            if let url = splitwiseReceiptProxyURL(size: "original") {
                NavigationStack {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFit()
                        case .failure:
                            ContentUnavailableView("Couldn't load receipt", systemImage: "exclamationmark.triangle",
                                                   description: Text("The Splitwise receipt couldn't be fetched."))
                        case .empty:
                            ProgressView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .navigationTitle("Receipt")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingSplitwiseReceipt = false } } }
                }
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
        } else if let url = splitwiseReceiptProxyURL() {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                case .failure: Image(systemName: "doc.text.image").foregroundStyle(.secondary)
                case .empty: ProgressView()
                @unknown default: Color.gray.opacity(0.15)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { showingSplitwiseReceipt = true }
        }
    }

    private func updateCategory(_ category: String) {
        let id = expense.id
        Task {
            do { try await env.expenses(context).updateCategory(id: id, category: category) }
            catch { errorText = errorMessage(error) }
        }
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

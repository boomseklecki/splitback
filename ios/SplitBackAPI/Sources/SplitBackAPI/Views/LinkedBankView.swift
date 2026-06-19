import SwiftUI
import SwiftData

/// The accounts linked through one Plaid item. Each account drills into its transactions and has a
/// refresh button to pull its latest cached transactions; a toolbar Sync fetches new activity for the
/// whole bank from Plaid. Reached from Settings → Linked Banks.
struct LinkedBankView: View {
    let item: Components.Schemas.PlaidItemResponse

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var accounts: [Account]

    @State private var refreshingId: UUID?
    @State private var syncing = false
    @State private var errorText: String?

    /// Local account models for this item, in the item's account order.
    private var linkedAccounts: [Account] {
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (item.accounts ?? []).compactMap { UUID(uuidString: $0.id).flatMap { byId[$0] } }
    }

    var body: some View {
        List {
            Section("Accounts") {
                if linkedAccounts.isEmpty {
                    Text("No accounts cached yet. Try Sync.").foregroundStyle(.secondary)
                }
                ForEach(linkedAccounts) { account in
                    HStack {
                        NavigationLink {
                            TransactionsView(account: account)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    if let type = account.type {
                                        Text(type).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(account.balance.formatted(.currency(code: account.currency)))
                                    .foregroundStyle(AccountKind.classify(account.type).balanceColor)
                            }
                        }
                        Button {
                            refresh(account)
                        } label: {
                            if refreshingId == account.id {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(refreshingId != nil)
                    }
                }
            }
        }
        .navigationTitle(item.institution_name ?? "Bank")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: syncBank) {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(syncing)
            }
        }
        .errorAlert($errorText)
    }

    /// Pull this account's latest cached transactions from the backend.
    private func refresh(_ account: Account) {
        refreshingId = account.id
        Task {
            defer { refreshingId = nil }
            do { try await env.accounts(context).refreshTransactions(accountId: account.id) }
            catch { errorText = errorMessage(error) }
        }
    }

    /// Run a Plaid sync scoped to this bank, fetching new accounts/transactions.
    private func syncBank() {
        guard let itemId = UUID(uuidString: item.id) else { return }
        syncing = true
        Task {
            defer { syncing = false }
            do { try await env.plaid(context).sync(itemId: itemId) }
            catch { errorText = errorMessage(error) }
        }
    }
}

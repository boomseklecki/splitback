import SwiftUI
import SwiftData

/// All linked banks, one section per bank, listing that bank's accounts. Tapping an account opens its
/// editor (rename / type / inclusion) — no transactions. Each bank can be unlinked from its section.
/// Reached from Settings → Plaid → Linked Banks. Linking and Sync All live in the Settings section.
struct LinkedBanksView: View {
    @Binding var items: [Components.Schemas.PlaidItemResponse]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var confirmingUnlink: UnlinkTarget?
    @State private var errorText: String?

    struct UnlinkTarget: Identifiable { let id: String; let name: String }

    var body: some View {
        // Correlate each item's accounts to the cached models once per render (avoid per-row dict builds).
        let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List {
            if items.isEmpty {
                ContentUnavailableView("No Linked Banks", systemImage: "building.columns",
                                       description: Text("Link a bank in Settings to manage its accounts."))
            }
            ForEach(items, id: \.id) { item in
                let linked = (item.accounts ?? []).compactMap { UUID(uuidString: $0.id).flatMap { byId[$0] } }
                Section {
                    if linked.isEmpty {
                        Text("No accounts cached yet. Try Sync All Banks in Settings.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(linked) { account in
                        // Closure-based nav (one level below the Settings stack root) — value-based links
                        // here drop the first tap.
                        NavigationLink {
                            AccountEditView(account: account)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayLabel)
                                    Text(account.kind.label + (account.maskLabel.map { " · \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(account.balance.formatted(.currency(code: account.currency)))
                                    .foregroundStyle(account.kind.balanceColor)
                            }
                        }
                    }
                    Button("Unlink Bank", systemImage: "trash", role: .destructive) {
                        confirmingUnlink = UnlinkTarget(id: item.id, name: item.institution_name ?? "Bank")
                    }
                } header: {
                    HStack(spacing: 8) {
                        AvatarView(url: InstitutionBrand.logoURL(domain: item.institution_domain,
                                                                 name: item.institution_name),
                                   name: item.institution_name ?? "Bank", size: 22,
                                   systemImage: "building.columns")
                        Text(item.institution_name ?? "Bank").textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Linked Banks")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirmingUnlink.map { "Unlink \($0.name)?" } ?? "Unlink bank?",
            isPresented: Binding(get: { confirmingUnlink != nil },
                                 set: { if !$0 { confirmingUnlink = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) { if let t = confirmingUnlink { unlink(t) } }
        } message: {
            Text("Removes this bank and its cached accounts from SplitBack and revokes access at Plaid.")
        }
        .errorAlert($errorText)
    }

    private func unlink(_ target: UnlinkTarget) {
        guard let id = UUID(uuidString: target.id) else { return }
        confirmingUnlink = nil
        Task {
            do {
                try await env.plaid(context).deleteItem(id: id)
                items.removeAll { $0.id == target.id }
            } catch { errorText = errorMessage(error) }
        }
    }
}

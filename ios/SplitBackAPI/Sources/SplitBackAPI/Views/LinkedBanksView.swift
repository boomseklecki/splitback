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
    @State private var confirmingRelink: RelinkTarget?
    @State private var relinkTarget: RelinkTarget?      // the bank being re-linked once Plaid Link starts
    @State private var linkSession: LinkSession?
    @State private var working: String?                 // status while preparing/merging a re-link
    @State private var errorText: String?

    struct UnlinkTarget: Identifiable { let id: String; let name: String }
    struct RelinkTarget: Identifiable { let id: String; let name: String }
    struct LinkSession: Identifiable { let id = UUID(); let token: String }

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
                                    Text(account.kind.label).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(account.balance.formatted(.currency(code: account.currency)))
                                    .foregroundStyle(account.kind.balanceColor)
                            }
                        }
                    }
                    Button("Extend History (Re-link)", systemImage: "clock.arrow.circlepath") {
                        confirmingRelink = RelinkTarget(id: item.id, name: item.institution_name ?? "Bank")
                    }
                    .disabled(working != nil)
                    Button("Unlink Bank", systemImage: "trash", role: .destructive) {
                        confirmingUnlink = UnlinkTarget(id: item.id, name: item.institution_name ?? "Bank")
                    }
                } header: {
                    Text(item.institution_name ?? "Bank").textCase(nil)
                }
            }
            if let working {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text(working).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Linked Banks")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            confirmingRelink.map { "Extend \($0.name)'s history?" } ?? "Extend history?",
            isPresented: Binding(get: { confirmingRelink != nil },
                                 set: { if !$0 { confirmingRelink = nil } }),
            titleVisibility: .visible, presenting: confirmingRelink
        ) { target in
            Button("Re-link") { beginRelink(target) }
        } message: { _ in
            Text("Re-connect this bank to pull up to ~24 months of history. Your account names, types, "
                 + "categories, and expense links are preserved and merged — no duplicates.")
        }
        .fullScreenCover(item: $linkSession) { session in
            PlaidLinkView(
                linkToken: session.token,
                onSuccess: { publicToken in
                    linkSession = nil
                    PlaidLinkSession.shared.finish()
                    if let target = relinkTarget { finishRelink(target, publicToken: publicToken) }
                },
                onExit: { linkSession = nil; relinkTarget = nil; PlaidLinkSession.shared.finish() }
            )
        }
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

    /// Start Plaid Link to re-connect the bank; the public token is merged in `finishRelink`.
    private func beginRelink(_ target: RelinkTarget) {
        confirmingRelink = nil
        guard let me = env.currentUser?.identifier else { errorText = "Sign in first."; return }
        relinkTarget = target
        Task {
            working = "Preparing…"
            defer { working = nil }
            do {
                let token = try await env.plaid(context).linkToken(userIdentifier: me)
                PlaidLinkSession.shared.begin(token: token)
                linkSession = LinkSession(token: token)
            } catch {
                relinkTarget = nil
                errorText = errorMessage(error)
            }
        }
    }

    /// Exchange + full-sync + merge onto the old item (server-side), then refresh the linked-banks list.
    private func finishRelink(_ target: RelinkTarget, publicToken: String) {
        guard let oldId = UUID(uuidString: target.id) else { return }
        relinkTarget = nil
        Task {
            working = "Importing ~24 months & merging… do not close the app"
            defer { working = nil }
            do {
                _ = try await env.plaidSlow(context).relink(oldItemId: oldId, publicToken: publicToken,
                                                            institutionName: target.name)
                try await env.refreshAll(context)
                items = (try? await env.plaid(context).items()) ?? items
            } catch { errorText = errorMessage(error) }
        }
    }
}

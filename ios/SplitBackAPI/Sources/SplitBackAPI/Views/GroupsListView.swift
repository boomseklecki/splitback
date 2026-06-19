import SwiftUI
import SwiftData

/// Lists active (non-archived, non-hidden) groups with a backend-type badge; create + pull-to-refresh.
struct GroupsListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ExpenseGroup> { $0.archivedAt == nil && $0.hidden == false },
           sort: \ExpenseGroup.name)
    private var groups: [ExpenseGroup]

    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var errorText: String?
    /// Your net balance per group (group id → net), keyed by the signed-in user from `/me`.
    @State private var myNets: [UUID: Decimal] = [:]

    /// Re-run the balance load whenever the signed-in user or the set of groups changes.
    private var balanceKey: [String] {
        (env.currentUser.map { [$0.identifier] } ?? []) + groups.map(\.id.uuidString)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    NavigationLink(value: group) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name)
                                Text(group.backendType == .splitwise ? "Splitwise" : "Self-hosted")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let net = myNets[group.id] {
                                Text(net.formatted(.currency(code: "USD")))
                                    .monospacedDigit()
                                    .foregroundStyle(net >= 0 ? .green : .red)
                            }
                            if group.backendType == .splitwise {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Groups")
            .navigationDestination(for: ExpenseGroup.self) { GroupDetailView(group: $0) }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("No Groups", systemImage: "person.2",
                                           description: Text("Pull to refresh, or add one with +."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingNewGroup = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable {
                do { try await env.groups(context).reconcileAll() }
                catch { errorText = errorMessage(error) }
                await loadMyBalances()
            }
            .task(id: balanceKey) { await loadMyBalances() }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create", action: createGroup)
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .errorAlert($errorText)
        }
    }

    /// Loads your net balance for each visible group. No-op (clears) when not signed in, so nothing
    /// is shown rather than guessing an identity.
    private func loadMyBalances() async {
        guard let me = env.currentUser?.identifier else { myNets = [:]; return }
        var result: [UUID: Decimal] = [:]
        for group in groups {
            if let net = try? await env.balances.forGroup(group.id).first(where: { $0.identifier == me })?.net {
                result[group.id] = net
            }
        }
        myNets = result
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        newGroupName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await env.groups(context).create(name: name) }
            catch { errorText = errorMessage(error) }
        }
    }
}

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
                            if group.backendType == .splitwise {
                                Image(systemName: "arrow.triangle.2.circlepath")
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
            }
            .alert("New Group", isPresented: $showingNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create", action: createGroup)
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .errorAlert($errorText)
        }
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

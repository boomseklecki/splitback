import SwiftUI
import SwiftData

/// Adds a roster person to a group. Lists directory users not already members.
struct MemberPickerView: View {
    let group: ExpenseGroup
    let existing: Set<String>

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \User.displayName) private var users: [User]
    @State private var errorText: String?

    private var candidates: [User] { users.filter { !existing.contains($0.identifier) } }

    var body: some View {
        NavigationStack {
            List(candidates) { user in
                Button { add(user.identifier) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName.titleCased)
                        Text(user.identifier).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("No One to Add", systemImage: "person.crop.circle.badge.checkmark",
                                           description: Text("Everyone in the directory is already a member."))
                }
            }
            .navigationTitle("Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .errorAlert($errorText)
        }
    }

    private func add(_ identifier: String) {
        Task {
            do {
                try await env.groups(context).addMember(groupId: group.id, userIdentifier: identifier)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

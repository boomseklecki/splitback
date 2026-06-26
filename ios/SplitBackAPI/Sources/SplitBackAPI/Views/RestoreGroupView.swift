import SwiftUI
import SwiftData

/// Restore a deleted Splitwise group (and its expenses) by its Splitwise group id. Offers recently-deleted
/// groups for one tap, plus a manual id field for older deletions.
struct RestoreGroupView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var recent = RecentlyDeletedGroups.all()
    @State private var manualId = ""
    @State private var restoring = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                if !recent.isEmpty {
                    Section("Recently deleted") {
                        ForEach(recent) { entry in
                            Button {
                                restore(entry.splitwiseGroupId)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text("Deleted \(entry.deletedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(restoring)
                        }
                    }
                }
                Section {
                    TextField("Splitwise group id", text: $manualId)
                        .keyboardType(.numberPad)
                    Button("Restore") { restore(manualId.trimmingCharacters(in: .whitespaces)) }
                        .disabled(restoring || manualId.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("By id")
                } footer: {
                    Text("Restores the group and its expenses on Splitwise, then syncs them back here.")
                }
            }
            .navigationTitle("Restore Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .errorAlert($errorText)
        }
    }

    private func restore(_ splitwiseGroupId: String) {
        guard !splitwiseGroupId.isEmpty else { return }
        restoring = true
        Task {
            defer { restoring = false }
            do {
                try await env.groups(context).restore(splitwiseGroupId: splitwiseGroupId)
                RecentlyDeletedGroups.remove(splitwiseGroupId: splitwiseGroupId)
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

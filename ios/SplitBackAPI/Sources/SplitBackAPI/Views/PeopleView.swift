import SwiftUI
import SwiftData

/// The household directory: everyone known to this instance, with their source and contact info.
/// Reached from Settings → People.
struct PeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \User.displayName) private var users: [User]

    @State private var showingNewUser = false
    @State private var newUserName = ""
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                ForEach(users) { user in
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(url: user.avatarURL, name: user.displayName.titleCased)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(user.displayName.titleCased)
                                if let badge = registrationBadge(user.registrationStatus) {
                                    Text(badge.label)
                                        .font(.caption2).foregroundStyle(badge.color)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(badge.color.opacity(0.15), in: Capsule())
                                }
                                Spacer()
                                Text(sourceLabel(user.source))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            if let email = user.email, !email.isEmpty {
                                Label(email, systemImage: "envelope")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if user.splitwiseUserId != nil {
                                Label("Linked to Splitwise", systemImage: "link")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(user.identifier)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("\(users.count) \(users.count == 1 ? "person" : "people")")
            }
        }
        .navigationTitle("People")
        .refreshable {
            await env.smartRefresh(level: .list, source: .splitwise,
                                   freshness: users.map(\.updatedAt).max(), context: context) {
                try await env.users(context).refresh()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewUser = true } label: { Image(systemName: "person.badge.plus") }
            }
        }
        .alert("Add Person", isPresented: $showingNewUser) {
            TextField("Display name", text: $newUserName)
            Button("Add", action: addUser)
            Button("Cancel", role: .cancel) { newUserName = "" }
        }
        .overlay {
            if users.isEmpty {
                ContentUnavailableView("No People", systemImage: "person.2",
                                       description: Text("Add someone, or import from Splitwise."))
            }
        }
        .errorAlert($errorText)
    }

    /// A tag for Splitwise users who aren't fully registered. Confirmed (and non-Splitwise) users
    /// get no badge.
    private func registrationBadge(_ status: String?) -> (label: String, color: Color)? {
        switch status?.lowercased() {
        case "invited": return ("Invited", .orange)
        case "dummy": return ("Placeholder", .gray)
        default: return nil
        }
    }

    private func sourceLabel(_ source: UserSource) -> String {
        switch source {
        case .splitwise: return "Splitwise"
        case .app: return "App"
        case .manual: return "Manual"
        }
    }

    private func addUser() {
        let name = newUserName.trimmingCharacters(in: .whitespaces)
        newUserName = ""
        guard !name.isEmpty else { return }
        Task {
            do { try await env.users(context).create(UserDraft(displayName: name)) }
            catch { errorText = errorMessage(error) }
        }
    }
}

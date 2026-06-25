import SwiftUI
import UIKit

/// Mint a single-use invite link to enroll a new person, and manage outstanding invites.
/// Shown to admins, or to any member when the `invites_open_to_members` server setting is on.
struct InvitePeopleView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var invites: [Components.Schemas.InviteResponse] = []
    @State private var newInviteURL: URL?
    @State private var creating = false
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                Button {
                    create()
                } label: {
                    Label(creating ? "Creating…" : "Create Invite Link", systemImage: "ticket")
                }
                .disabled(creating)
            } footer: {
                Text("A single-use link. Share it with one person — they tap it, sign in, and join this "
                     + "server. Reusing or revoking it stops it working.")
            }

            if let url = newInviteURL {
                Section("Share This Invite") {
                    QRCodeView(string: url.absoluteString)
                        .frame(maxWidth: .infinity).frame(height: 200).padding(.vertical, 8)
                    ShareLink(item: url,
                              preview: SharePreview(env.serverName ?? "SplitBack", image: Image("AppLogo"))) {
                        Label("Share Invite Link", systemImage: "square.and.arrow.up")
                    }
                    Button { UIPasteboard.general.url = url } label: {
                        Label("Copy Invite Link", systemImage: "doc.on.doc")
                    }
                    Text(url.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            if !invites.isEmpty {
                Section("Invites") {
                    ForEach(invites, id: \.id) { invite in
                        InviteRow(invite: invite)
                            .swipeActions {
                                if invite.status == "active" {
                                    Button("Revoke", role: .destructive) { revoke(invite) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Invite People")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorText)
        .task { if !loaded { loaded = true; await load() } }
    }

    private func load() async {
        do { invites = try await env.invites.list() } catch { errorText = errorMessage(error) }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            do {
                let invite = try await env.invites.create(label: nil)
                newInviteURL = JoinLink.url(apiBaseURL: env.baseURLString, name: env.serverName,
                                            invite: invite.code)
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func revoke(_ invite: Components.Schemas.InviteResponse) {
        guard let id = UUID(uuidString: invite.id) else { return }
        Task {
            do { try await env.invites.revoke(id: id); await load() }
            catch { errorText = errorMessage(error) }
        }
    }
}

private struct InviteRow: View {
    let invite: Components.Schemas.InviteResponse

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.label ?? "Invite").font(.body)
                if let by = invite.redeemed_by {
                    Text("Joined by \(by)").font(.caption).foregroundStyle(.secondary)
                } else if let exp = invite.expires_at, invite.status == "active" {
                    Text("Expires \(exp.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(invite.status.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(color(invite.status))
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "active": return .green
        case "redeemed": return .secondary
        default: return .orange  // revoked / expired
        }
    }
}

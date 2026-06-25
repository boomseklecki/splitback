import SwiftUI

/// Admin-only editor for the server-global runtime settings (formerly `.env` policy). Loads from
/// `GET /server-settings`, saves the full set via `PATCH /server-settings`.
struct ServerSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var loaded = false
    @State private var saving = false
    @State private var saved = false
    @State private var errorText: String?

    @State private var serverName = ""
    @State private var invitesOpenToMembers = false
    @State private var groupsHardDelete = false
    @State private var expensesHardDelete = false
    @State private var splitwiseReceiptDownload = false
    @State private var syncIntervalHours = 0
    @State private var backupIntervalHours = 0
    @State private var backupsRetentionDays = 30
    @State private var backupsRetentionMinKeep = 7

    var body: some View {
        Form {
            Section {
                TextField("Server name", text: $serverName)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("Shown on the join/confirm screen when someone adds this server.")
            }

            Section {
                Toggle("Let any member invite people", isOn: $invitesOpenToMembers)
            } header: {
                Text("Invites")
            } footer: {
                Text("Off: only admins can create invite links. On: any enrolled member can.")
            }

            Section {
                Toggle("Hard-delete groups", isOn: $groupsHardDelete)
                Toggle("Hard-delete expenses", isOn: $expensesHardDelete)
            } header: {
                Text("Delete behavior")
            } footer: {
                Text("Off (default) archives instead of permanently deleting.")
            }

            Section("Splitwise") {
                Toggle("Download Splitwise receipts", isOn: $splitwiseReceiptDownload)
            }

            Section {
                Stepper("Auto-sync: \(intervalLabel(syncIntervalHours))",
                        value: $syncIntervalHours, in: 0...168)
                Stepper("Auto-backup: \(intervalLabel(backupIntervalHours))",
                        value: $backupIntervalHours, in: 0...168)
                Stepper("Keep backups \(backupsRetentionDays) days",
                        value: $backupsRetentionDays, in: 1...365)
                Stepper("Always keep newest \(backupsRetentionMinKeep)",
                        value: $backupsRetentionMinKeep, in: 1...100)
            } header: {
                Text("Automatic sync & backups")
            } footer: {
                Text("0 hours = off. Changes take effect within a minute — no restart.")
            }

            Section {
                Button { save() } label: {
                    Label(saving ? "Saving…" : (saved ? "Saved" : "Save Changes"),
                          systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                }
                .disabled(saving || !loaded)
            }
        }
        .navigationTitle("Server Settings")
        .navigationBarTitleDisplayMode(.inline)
        .errorAlert($errorText)
        .task { if !loaded { await load() } }
    }

    private func intervalLabel(_ hours: Int) -> String { hours <= 0 ? "Off" : "every \(hours)h" }

    private func apply(_ s: Components.Schemas.ServerSettingsResponse) {
        serverName = s.public_hostname
        invitesOpenToMembers = s.invites_open_to_members
        groupsHardDelete = s.groups_hard_delete_enabled
        expensesHardDelete = s.expenses_hard_delete_enabled
        splitwiseReceiptDownload = s.splitwise_receipt_download_enabled
        syncIntervalHours = s.sync_interval_hours
        backupIntervalHours = s.backup_interval_hours
        backupsRetentionDays = s.backups_retention_days
        backupsRetentionMinKeep = s.backups_retention_min_keep
    }

    private func load() async {
        do { apply(try await env.serverSettings.get()); loaded = true }
        catch { errorText = errorMessage(error) }
    }

    private func save() {
        saving = true
        saved = false
        Task {
            defer { saving = false }
            do {
                let updated = try await env.serverSettings.update(.init(
                    invites_open_to_members: invitesOpenToMembers,
                    public_hostname: serverName,
                    groups_hard_delete_enabled: groupsHardDelete,
                    expenses_hard_delete_enabled: expensesHardDelete,
                    splitwise_receipt_download_enabled: splitwiseReceiptDownload,
                    sync_interval_hours: syncIntervalHours,
                    backup_interval_hours: backupIntervalHours,
                    backups_retention_days: backupsRetentionDays,
                    backups_retention_min_keep: backupsRetentionMinKeep))
                apply(updated)
                saved = true
            } catch { errorText = errorMessage(error) }
        }
    }
}

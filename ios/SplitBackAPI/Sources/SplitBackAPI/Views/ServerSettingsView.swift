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
    @State private var splitwiseReceiptDownload = false
    @State private var splitwiseReceiptBackfill = false
    @State private var downloadingReceipts = false
    @State private var downloadSummary: String?
    @State private var syncIntervalHours = 0
    @State private var backupIntervalHours = 0
    @State private var backupsRetentionDays = 30
    @State private var backupsRetentionMinKeep = 7
    @State private var refreshPlaidStale = 60
    @State private var refreshSplitwiseStale = 15
    @State private var notificationsRetention = 100
    @State private var notificationsPollMinutes = 0

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
                Toggle("Download receipts on import to local", isOn: $splitwiseReceiptDownload)
                Toggle("Download all + auto-backfill receipts", isOn: $splitwiseReceiptBackfill)
                Button { downloadAllReceipts() } label: {
                    HStack {
                        Label(downloadingReceipts ? "Starting…" : "Download all receipts now",
                              systemImage: "arrow.down.circle")
                        Spacer()
                        if downloadingReceipts { ProgressView() }
                    }
                }
                .disabled(!splitwiseReceiptBackfill || downloadingReceipts || !loaded)
                if let downloadSummary {
                    Text(downloadSummary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Splitwise receipts")
            } footer: {
                Text("Import-to-local downloads a group's receipts only when you convert it to a local group. "
                     + "All + auto-backfill enables the button below (a one-time background pull of every "
                     + "not-yet-saved receipt, newest first) and trickles new ones in during scheduled syncs. "
                     + "Save before using the button.")
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
                Stepper("Bank (Plaid): \(staleLabel(refreshPlaidStale))",
                        value: $refreshPlaidStale, in: 0...1440)
                Stepper("Splitwise: \(staleLabel(refreshSplitwiseStale))",
                        value: $refreshSplitwiseStale, in: 0...1440)
            } header: {
                Text("Pull-to-refresh freshness")
            } footer: {
                Text("Pull-to-refresh does a live sync only when the data is older than this; otherwise it "
                     + "just refreshes from the server. Bank (Plaid) calls cost money, so sync them less "
                     + "often than free Splitwise. 0 minutes = always sync.")
            }

            Section {
                Stepper("Keep newest \(notificationsRetention)",
                        value: $notificationsRetention, in: 10...1000, step: 10)
                Stepper("Live notification poll: \(pollLabel(notificationsPollMinutes))",
                        value: $notificationsPollMinutes, in: 0...60)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Keep: how many notifications to retain per person (older are pruned on each sync). "
                     + "Live poll: how often to check Splitwise just for new activity so partner-activity "
                     + "pushes arrive promptly instead of waiting for the full auto-sync. 0 = off.")
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

    private func downloadAllReceipts() {
        downloadingReceipts = true
        downloadSummary = nil
        Task {
            defer { downloadingReceipts = false }
            do {
                let result = try await env.splitwise.downloadAllReceipts()
                downloadSummary = result.enabled
                    ? "Downloading \(result.pending.formatted()) receipt\(result.pending == 1 ? "" : "s") in the "
                        + "background — you can leave this screen."
                    : "Turn on “Download all + auto-backfill” and Save first."
            } catch { errorText = errorMessage(error) }
        }
    }

    private func intervalLabel(_ hours: Int) -> String { hours <= 0 ? "Off" : "every \(hours)h" }
    private func staleLabel(_ minutes: Int) -> String { minutes <= 0 ? "always sync" : "\(minutes) min" }
    private func pollLabel(_ minutes: Int) -> String { minutes <= 0 ? "Off" : "every \(minutes) min" }

    private func apply(_ s: Components.Schemas.ServerSettingsResponse) {
        serverName = s.public_hostname
        invitesOpenToMembers = s.invites_open_to_members
        splitwiseReceiptDownload = s.splitwise_receipt_download_enabled
        splitwiseReceiptBackfill = s.splitwise_receipt_backfill_enabled
        syncIntervalHours = s.sync_interval_hours
        backupIntervalHours = s.backup_interval_hours
        backupsRetentionDays = s.backups_retention_days
        backupsRetentionMinKeep = s.backups_retention_min_keep
        refreshPlaidStale = s.refresh_plaid_stale_minutes
        refreshSplitwiseStale = s.refresh_splitwise_stale_minutes
        notificationsRetention = s.notifications_retention_count
        notificationsPollMinutes = s.notifications_poll_minutes
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
                    splitwise_receipt_download_enabled: splitwiseReceiptDownload,
                    splitwise_receipt_backfill_enabled: splitwiseReceiptBackfill,
                    sync_interval_hours: syncIntervalHours,
                    backup_interval_hours: backupIntervalHours,
                    backups_retention_days: backupsRetentionDays,
                    backups_retention_min_keep: backupsRetentionMinKeep,
                    refresh_plaid_stale_minutes: refreshPlaidStale,
                    refresh_splitwise_stale_minutes: refreshSplitwiseStale,
                    notifications_retention_count: notificationsRetention,
                    notifications_poll_minutes: notificationsPollMinutes))
                apply(updated)
                await env.loadRefreshThresholds()  // apply the new thresholds to the running app
                saved = true
            } catch { errorText = errorMessage(error) }
        }
    }
}

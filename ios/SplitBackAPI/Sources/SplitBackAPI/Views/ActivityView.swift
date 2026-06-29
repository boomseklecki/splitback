import SwiftUI

/// One activity-feed row. App-native rows carry a deep-link target → tap drills into the entity (and marks
/// read); Splitwise rows (no entity ref) keep the plain tap-to-read behavior. Shared by the Inbox preview and
/// the full Activity screen — both register `.navigationDestination(for: NotificationTarget.self)`.
struct ActivityRow: View {
    let n: Components.Schemas.NotificationResponse
    let onMarkRead: () -> Void

    var body: some View {
        if let target = NotificationTarget(type: n.entity_type, id: n.entity_id) {
            NavigationLink(value: target) { content }
                .simultaneousGesture(TapGesture().onEnded { onMarkRead() })
        } else {
            content.contentShape(Rectangle()).onTapGesture { onMarkRead() }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: n.source == "splitwise" ? "dollarsign.circle" : "bell")
                .font(.title3).foregroundStyle(n.read ? Color.secondary : Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.content).font(.subheadline)
                    .foregroundStyle(n.read ? .secondary : .primary).lineLimit(3)
                Text(n.created_at.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if !n.read { Circle().fill(.tint).frame(width: 8, height: 8) }
        }
    }
}

/// The full activity / trust log — every shared-group notification (newest first, up to the retention window),
/// deep-linkable and mark-read. Reached from the Inbox's "See All Activity".
struct ActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var activity: [Components.Schemas.NotificationResponse] = []
    @State private var loaded = false

    var body: some View {
        List {
            if activity.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "tray",
                                       description: Text("Shared-group activity will show up here."))
            } else {
                ForEach(activity, id: \.id) { n in ActivityRow(n: n, onMarkRead: { markRead(n) }) }
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: NotificationTarget.self) { NotificationTargetView(target: $0) }
        .task { if !loaded { await reload(); loaded = true } }
        .refreshable { await reload() }
    }

    private func reload() async {
        _ = try? await env.splitwise.syncNotifications()
        if let all = try? await env.notifications.list() {
            activity = all.filter { !NotificationPrefs.shared.isHidden(type: $0._type, source: $0.source) }
        }
    }

    private func markRead(_ n: Components.Schemas.NotificationResponse) {
        guard !n.read, let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        Task {
            try? await env.notifications.markRead(id: id)
            if let all = try? await env.notifications.list() {
                activity = all.filter { !NotificationPrefs.shared.isHidden(type: $0._type, source: $0.source) }
            }
            await env.refreshInboxBadge(context)
        }
    }
}

import SwiftUI
import SwiftData

/// The Inbox tab: on-device AI/heuristic **Suggestions** (recategorize, link, subscription, recurring-split,
/// and the nudges: shared-budget candidate, settle-up, overspend) plus a source-agnostic **Activity** feed
/// (Splitwise now, app-native later). Actionable cards accept/dismiss in place; nudge cards navigate or open
/// a prefilled editor.
struct InboxView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query private var goals: [Goal]

    @State private var suggestions: [Suggestion] = []
    @State private var activity: [Components.Schemas.NotificationResponse] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var budgetPrefill: BudgetPrefill?
    @State private var linkConfirm: Suggestion?

    struct BudgetPrefill: Identifiable { let id = UUID(); let category: String; let amount: Decimal }

    private static let order: [Suggestion.Kind] = [
        .recurringSplit, .overspend, .settleUp, .link, .sharedBudgetCandidate, .categorize, .subscription]
    private var sortedSuggestions: [Suggestion] {
        suggestions.sorted {
            (Self.order.firstIndex(of: $0.kind) ?? 99) < (Self.order.firstIndex(of: $1.kind) ?? 99)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggestions.isEmpty {
                    Section("Suggestions") { ForEach(sortedSuggestions) { row($0) } }
                }
                if !activity.isEmpty {
                    Section("Activity") { ForEach(activity, id: \.id) { activityRow($0) } }
                }
                if suggestions.isEmpty && activity.isEmpty {
                    ContentUnavailableView("Nothing new", systemImage: "tray",
                                           description: Text("Suggestions and activity will show up here."))
                }
            }
            .navigationTitle("Inbox")
            .navigationDestination(for: FriendRow.self) { FriendDetailView(friend: $0) }
            .navigationDestination(for: Goal.self) { GoalDetailView(goal: $0) }
            .sheet(item: $budgetPrefill) { p in
                GoalEditView(prefillCategory: p.category, prefillAmount: p.amount, prefillShared: true)
            }
            .sheet(item: $linkConfirm) { s in
                LinkConfirmSheet(suggestion: s, onConfirm: { accept(s) },
                                 onExternalChange: { Task { await reload() } })
            }
            .task { if !loaded { await reload(); loaded = true } }
            .refreshable { await reload() }
            .errorAlert($errorText)
        }
    }

    @ViewBuilder
    private func row(_ s: Suggestion) -> some View {
        switch s.kind {
        case .settleUp:
            NavigationLink(value: FriendRow(id: s.friendIdentifier ?? "", name: s.title,
                                            net: s.amount ?? 0, groups: [])) { cardLabel(s) }
                .swipeActions { dismissButton(s) }
        case .overspend:
            if let goal = goals.first(where: { $0.id == s.goalId }) {
                NavigationLink(value: goal) { cardLabel(s) }.swipeActions { dismissButton(s) }
            }
        case .sharedBudgetCandidate:
            Button {
                if let c = s.category { budgetPrefill = .init(category: c, amount: s.amount ?? 0) }
            } label: { cardLabel(s) }
                .swipeActions { dismissButton(s) }
        case .link:
            // Heuristic match — confirm before linking instead of committing on one tap.
            SuggestionCard(suggestion: s, accept: { linkConfirm = s }, dismiss: { fm in dismiss(s, fm) })
        default:
            SuggestionCard(suggestion: s, accept: { accept(s) }, dismiss: { fm in dismiss(s, fm) })
        }
    }

    private func cardLabel(_ s: Suggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: s.icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).lineLimit(1)
                Text(s.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func dismissButton(_ s: Suggestion) -> some View {
        Button("Dismiss", role: .destructive) { dismiss(s, false) }
    }

    private func activityRow(_ n: Components.Schemas.NotificationResponse) -> some View {
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
        .contentShape(Rectangle())
        .onTapGesture { markRead(n) }
    }

    private func reload() async {
        let service = env.suggestions(context)
        try? service.learnTemplates()
        await service.refreshAI()
        _ = try? await env.splitwise.syncNotifications()
        suggestions = (try? await service.current()) ?? []
        activity = (try? await env.notifications.list()) ?? []
        updateBadge()
    }

    private func accept(_ s: Suggestion) {
        Task {
            do { try await env.suggestions(context).accept(s); await reload() }
            catch { errorText = errorMessage(error) }
        }
    }

    private func dismiss(_ s: Suggestion, _ forMerchant: Bool) {
        do {
            try env.suggestions(context).dismiss(s, forMerchant: forMerchant)
            suggestions.removeAll { $0.id == s.id }
            updateBadge()
        } catch { errorText = errorMessage(error) }
    }

    private func markRead(_ n: Components.Schemas.NotificationResponse) {
        guard !n.read, let id = try? Mapping.uuid(n.id, field: "Notification.id") else { return }
        Task {
            try? await env.notifications.markRead(id: id)
            activity = (try? await env.notifications.list()) ?? activity
            updateBadge()
        }
    }

    private func updateBadge() {
        env.setInboxBadge(suggestions.count + activity.filter { !$0.read }.count)
    }
}

/// One actionable suggestion row: icon, title/subtitle, a primary Accept, and swipe-to-dismiss (+ "Never for
/// this merchant" when merchant-scoped).
struct SuggestionCard: View {
    let suggestion: Suggestion
    let accept: () -> Void
    let dismiss: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title).lineLimit(1)
                Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(suggestion.acceptLabel, action: accept)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .swipeActions(edge: .trailing) {
            Button("Dismiss", role: .destructive) { dismiss(false) }
            if suggestion.merchantKey != nil {
                Button("Never") { dismiss(true) }.tint(.gray)
            }
        }
    }
}

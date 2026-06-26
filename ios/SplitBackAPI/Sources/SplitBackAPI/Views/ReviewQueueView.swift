import SwiftUI
import SwiftData

/// The review queue: on-device AI + heuristic suggestions (recategorize, link/de-dupe, track subscription,
/// split-like-last-time), each accepted with one tap or dismissed. Generated locally from cached data;
/// accepting routes through the normal repositories.
struct ReviewQueueView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @State private var suggestions: [Suggestion] = []
    @State private var loaded = false
    @State private var errorText: String?

    /// Display order of the card kinds.
    private static let order: [Suggestion.Kind] = [.recurringSplit, .link, .categorize, .subscription]

    private var grouped: [(kind: Suggestion.Kind, items: [Suggestion])] {
        Self.order.compactMap { kind in
            let items = suggestions.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }

    var body: some View {
        List {
            if suggestions.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("No suggestions right now."))
            } else {
                ForEach(grouped, id: \.kind) { group in
                    Section(title(group.kind)) {
                        ForEach(group.items) { s in
                            SuggestionCard(suggestion: s, accept: { accept(s) },
                                           dismiss: { forMerchant in dismiss(s, forMerchant) })
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await reload(runAI: true); loaded = true } }
        .refreshable { await reload(runAI: true) }
        .errorAlert($errorText)
    }

    private func title(_ kind: Suggestion.Kind) -> String {
        switch kind {
        case .recurringSplit: return "Split like last time"
        case .link: return "Possible duplicates"
        case .categorize: return "Recategorize"
        case .subscription: return "Subscriptions"
        }
    }

    private func reload(runAI: Bool) async {
        let service = env.suggestions(context)
        do {
            if runAI {
                try service.learnTemplates()
                await service.refreshAI()
            }
            suggestions = try service.current()
        } catch { errorText = errorMessage(error) }
    }

    private func accept(_ s: Suggestion) {
        Task {
            do {
                try await env.suggestions(context).accept(s)
                await reload(runAI: false)
            } catch { errorText = errorMessage(error) }
        }
    }

    private func dismiss(_ s: Suggestion, _ forMerchant: Bool) {
        do {
            try env.suggestions(context).dismiss(s, forMerchant: forMerchant)
            suggestions = (try? env.suggestions(context).current()) ?? suggestions
        } catch { errorText = errorMessage(error) }
    }
}

/// One suggestion row: icon, title/subtitle, a primary Accept, and swipe-to-dismiss (+ "Never for this
/// merchant" when the suggestion is merchant-scoped).
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

import SwiftUI
import SwiftData

/// Review and edit how raw Plaid transaction categories map to the app's canonical categories. Offers
/// on-device (Apple Intelligence) suggestions for unmapped labels, plus a manual picker per row.
struct CategoryMappingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]

    @State private var mapping = false
    @State private var editing: EditingRaw?
    @State private var errorText: String?

    private struct EditingRaw: Identifiable { let id: String }

    /// Distinct raw categories seen on Plaid transactions.
    private var rawCategories: [String] {
        let raws = transactions.filter { $0.source == .plaid }.compactMap { $0.category }
        return Set(raws).sorted()
    }
    private var mapByRaw: [String: CategoryMap] {
        Dictionary(categoryMaps.map { ($0.rawCategory, $0) }, uniquingKeysWith: { a, _ in a })
    }
    /// How a raw label currently resolves: an explicit override, the built-in Plaid map ("auto"), or
    /// nothing ("unmapped").
    private func resolved(_ raw: String) -> (canonical: String?, source: String) {
        if let m = mapByRaw[raw] { return (m.canonicalCategory, m.source) }
        if let auto = PlaidCategory.canonical(raw) { return (auto, "auto") }
        return (nil, "unmapped")
    }
    private var unmappedCount: Int { rawCategories.filter { resolved($0).source == "unmapped" }.count }
    /// Vague transactions (Other/uncategorized) not yet refined — candidates for a description-based pass.
    private var refinable: [Transaction] {
        let lookup = CategoryMapping.lookup(categoryMaps)
        return transactions.filter {
            $0.refinedCategory == nil && CategoryMapping.needsRefinement($0, lookup: lookup)
        }
    }

    var body: some View {
        List {
            if CategoryMapper.isAvailable {
                let pending = unmappedCount + refinable.count
                Section {
                    Button {
                        Task { await runOnDevice() }
                    } label: {
                        Label(mapping ? "Categorizing…" : "Categorize with Apple Intelligence",
                              systemImage: "sparkles")
                    }
                    .disabled(mapping || pending == 0)
                } footer: {
                    Text("On-device: maps \(unmappedCount) unmapped label\(unmappedCount == 1 ? "" : "s") and refines \(refinable.count) vague transaction\(refinable.count == 1 ? "" : "s") from their merchant. Your manual choices are kept.")
                }
            }

            Section("Categories") {
                if rawCategories.isEmpty {
                    Text("No Plaid transactions yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rawCategories, id: \.self) { raw in
                    Button { editing = EditingRaw(id: raw) } label: { row(raw) }
                }
            }
        }
        .navigationTitle("Spending Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            CategoryPickerView(current: resolved(item.id).canonical) { canonical in
                setManual(raw: item.id, canonical: canonical)
            }
        }
        .errorAlert($errorText)
    }

    private func row(_ raw: String) -> some View {
        let resolution = resolved(raw)
        return HStack(spacing: 10) {
            Text(PlaidCategory.humanized(raw)).foregroundStyle(.primary)
            Spacer()
            if let canonical = resolution.canonical {
                if let icon = sourceIcon(resolution.source) {
                    Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(canonical).foregroundStyle(.secondary)
            } else {
                Text("Unmapped").foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func sourceIcon(_ source: String) -> String? {
        switch source {
        case "manual": return "hand.point.up.left"
        case "ondevice": return "sparkles"
        case "auto": return "wand.and.stars"
        default: return nil
        }
    }

    private func runOnDevice() async {
        mapping = true
        defer { mapping = false }
        // 1) Map any raw category labels the built-in map doesn't cover.
        let unmapped = rawCategories.filter { resolved($0).source == "unmapped" }
        let suggestions = await CategoryMapper.suggest(for: unmapped)
        do {
            for (raw, canonical) in suggestions {
                try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "ondevice")
            }
        } catch {
            errorText = errorMessage(error)
        }
        // 2) Refine vague transactions from their merchant description.
        let items = refinable.map {
            CategoryMapper.Item(id: $0.id, description: $0.details, rawCategory: $0.category)
        }
        let refined = await CategoryMapper.refine(items)
        guard !refined.isEmpty else { return }
        for transaction in transactions where refined[transaction.id] != nil {
            transaction.refinedCategory = refined[transaction.id]
        }
        do { try context.save() } catch { errorText = errorMessage(error) }
    }

    private func setManual(raw: String, canonical: String) {
        Task {
            do { try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "manual") }
            catch { errorText = errorMessage(error) }
        }
    }
}

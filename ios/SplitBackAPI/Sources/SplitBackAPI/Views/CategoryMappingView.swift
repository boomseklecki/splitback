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
    private var unmappedCount: Int { rawCategories.filter { mapByRaw[$0] == nil }.count }

    var body: some View {
        List {
            if CategoryMapper.isAvailable {
                Section {
                    Button {
                        Task { await runOnDevice() }
                    } label: {
                        Label(mapping ? "Mapping…" : "Map with Apple Intelligence", systemImage: "sparkles")
                    }
                    .disabled(mapping || unmappedCount == 0)
                } footer: {
                    Text("Suggests categories on-device for the \(unmappedCount) unmapped label\(unmappedCount == 1 ? "" : "s"). Your manual choices are kept.")
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
            CategoryPickerView(current: mapByRaw[item.id]?.canonicalCategory) { canonical in
                setManual(raw: item.id, canonical: canonical)
            }
        }
        .errorAlert($errorText)
    }

    private func row(_ raw: String) -> some View {
        HStack(spacing: 10) {
            Text(raw).foregroundStyle(.primary)
            Spacer()
            if let m = mapByRaw[raw] {
                Image(systemName: m.source == "ondevice" ? "sparkles" : "hand.point.up.left")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(m.canonicalCategory).foregroundStyle(.secondary)
            } else {
                Text("Unmapped").foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func runOnDevice() async {
        mapping = true
        defer { mapping = false }
        let unmapped = rawCategories.filter { mapByRaw[$0] == nil }
        let suggestions = await CategoryMapper.suggest(for: unmapped)
        do {
            for (raw, canonical) in suggestions {
                try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "ondevice")
            }
        } catch {
            errorText = errorMessage(error)
        }
    }

    private func setManual(raw: String, canonical: String) {
        Task {
            do { try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "manual") }
            catch { errorText = errorMessage(error) }
        }
    }
}

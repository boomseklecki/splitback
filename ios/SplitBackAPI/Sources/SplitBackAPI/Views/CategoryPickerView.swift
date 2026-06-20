import SwiftUI
import SwiftData

/// A searchable category list — each row shows the category's icon next to its name. Reports the
/// chosen category via `onSelect`. Reads the synced, editable taxonomy from the cache.
struct CategoryPickerView: View {
    let current: String?
    /// When set, the source being mapped (a Bank/Splitwise label) — shown so you know what you're mapping.
    var subject: String? = nil
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SpendCategory.position) private var categories: [SpendCategory]
    @State private var query = ""

    private var names: [String] {
        let all = categories.map(\.name)
        return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let subject {
                    Section {
                        HStack(spacing: 6) {
                            Text(subject).fontWeight(.semibold)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text("pick a category").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(names, id: \.self) { category in
                        Button {
                            onSelect(category)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: categorySymbol(category))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 26)
                                Text(category).foregroundStyle(.primary)
                                Spacer()
                                if category == current {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search categories")
            .overlay {
                if categories.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle(subject.map { "Map “\($0)”" } ?? "Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

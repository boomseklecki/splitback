import SwiftUI
import SwiftData

/// A searchable category list — each row shows the category's icon next to its name. Reports the
/// chosen category via `onSelect`. Reads the synced, editable taxonomy from the cache.
struct CategoryPickerView: View {
    let current: String?
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
            List(names, id: \.self) { category in
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
            .searchable(text: $query, prompt: "Search categories")
            .overlay {
                if categories.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

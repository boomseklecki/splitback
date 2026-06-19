import SwiftUI

/// A searchable category list — each row shows the category's icon next to its name. Reports the
/// chosen category via `onSelect`. Reached by tapping the category icon on the expense detail.
struct CategoryPickerView: View {
    let current: String?
    let onSelect: (String) -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var categories: [String] = []
    @State private var query = ""

    private var filtered: [String] {
        query.isEmpty ? categories
            : categories.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { category in
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
            .task { categories = (try? await env.categories.list()) ?? [] }
        }
    }
}

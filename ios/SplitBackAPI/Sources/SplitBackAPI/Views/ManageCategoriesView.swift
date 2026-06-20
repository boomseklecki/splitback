import SwiftUI
import SwiftData

/// Add, rename, delete, and re-icon the canonical categories (full control — built-ins included).
struct ManageCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendCategory.position) private var categories: [SpendCategory]

    @State private var editing: Editing?
    @State private var errorText: String?

    private struct Editing: Identifiable { let id = UUID(); let category: SpendCategory? }

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    Button { editing = Editing(category: category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: categorySymbol(category.name))
                                .foregroundStyle(categoryColor(category.name)).frame(width: 26)
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            if category.builtin {
                                Text("Built-in").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Add your own categories or rename/delete any. Renaming or deleting a built-in won't update existing transactions or the automatic Plaid/Splitwise mappings that use its name.")
            }
        }
        .navigationTitle("Manage Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = Editing(category: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { CategoryEditView(editing: $0.category) }
        .errorAlert($errorText)
    }

    private func delete(_ offsets: IndexSet) {
        let ids = offsets.map { categories[$0].id }
        Task {
            do { for id in ids { try await env.categories(context).delete(id: id) } }
            catch { errorText = errorMessage(error) }
        }
    }
}

/// Create or edit one category: name + a grid of SF Symbol icons.
struct CategoryEditView: View {
    let editing: SpendCategory?  // nil = create

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var saving = false
    @State private var errorText: String?

    init(editing: SpendCategory?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _icon = State(initialValue: editing?.icon ?? "tag")
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }

                Section("Icon") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 10)], spacing: 10) {
                        ForEach(categoryIconChoices, id: \.self) { symbol in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(width: 46, height: 46)
                                    .background(icon == symbol ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(icon == symbol ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if editing?.builtin == true {
                    Text("Built-in category. Renaming it won't update existing data or the automatic Plaid/Splitwise mappings that output its name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editing == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .errorAlert($errorText)
        }
    }

    private func save() {
        saving = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let chosenIcon = icon
        let editing = editing
        Task {
            defer { saving = false }
            do {
                if let editing {
                    try await env.categories(context).update(id: editing.id, name: trimmed, icon: chosenIcon)
                } else {
                    try await env.categories(context).create(name: trimmed, icon: chosenIcon)
                }
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}

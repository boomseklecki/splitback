import SwiftUI
import SwiftData

/// Add, rename, delete, and re-icon the canonical categories (full control — built-ins included).
/// A category can't be deleted while source categories (Bank/Splitwise) map to it; the dependents
/// sheet lists those mappings and lets you reassign them first.
struct ManageCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendCategory.position) private var categories: [SpendCategory]
    @Query private var categoryMaps: [CategoryMap]

    @State private var sheet: Sheet?
    @State private var errorText: String?

    private enum Sheet: Identifiable {
        case edit(SpendCategory?)
        case dependents(SpendCategory)
        var id: String {
            switch self {
            case let .edit(c): "edit-\(c?.id.uuidString ?? "new")"
            case let .dependents(c): "deps-\(c.id.uuidString)"
            }
        }
    }

    private func dependentCount(_ category: SpendCategory) -> Int {
        categoryMaps.filter { $0.canonicalCategory == category.name }.count
    }

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    Button { sheet = .edit(category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: categorySymbol(category.name))
                                .foregroundStyle(categoryColor(category.name)).frame(width: 26)
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            let used = dependentCount(category)
                            if used > 0 {
                                Text("\(used)").font(.caption2).foregroundStyle(.tertiary)
                            }
                            if category.builtin {
                                Text("Built-in").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete(perform: delete)
            } footer: {
                Text("Add your own categories or rename/delete any. A category can't be deleted while source categories map to it — tap it to reassign those. Renaming a built-in won't update the automatic Plaid/Splitwise mappings that output its name.")
            }
        }
        .navigationTitle("Manage Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .edit(nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case let .edit(category): CategoryEditView(editing: category)
            case let .dependents(category): CategoryDependentsView(category: category)
            }
        }
        .errorAlert($errorText)
    }

    private func delete(_ offsets: IndexSet) {
        for category in offsets.map({ categories[$0] }) {
            if dependentCount(category) > 0 {
                sheet = .dependents(category)  // reassign the mappings first
                return
            }
            let id = category.id
            Task {
                do { try await env.categories(context).delete(id: id) }
                catch { errorText = errorMessage(error) }
            }
        }
    }
}

/// Lists the source categories (Bank/Splitwise) currently mapped to `category`, each reassignable, and
/// allows deleting the category once none remain.
struct CategoryDependentsView: View {
    let category: SpendCategory

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categoryMaps: [CategoryMap]
    @State private var errorText: String?

    private var dependents: [CategoryMap] {
        categoryMaps.filter { $0.canonicalCategory == category.name }
            .sorted { $0.rawCategory < $1.rawCategory }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if dependents.isEmpty {
                        Text("No source categories map here anymore.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dependents) { MappingReassignRow(map: $0) }
                } header: {
                    Text("Mapped to \(category.name)")
                } footer: {
                    Text(dependents.isEmpty
                         ? "You can delete “\(category.name)” now."
                         : "Reassign each of these to another category to delete “\(category.name)”.")
                }
            }
            .navigationTitle("Used by \(dependents.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive, action: deleteNow).disabled(!dependents.isEmpty)
                }
            }
            .errorAlert($errorText)
        }
    }

    private func deleteNow() {
        let id = category.id
        Task {
            do { try await env.categories(context).delete(id: id); dismiss() }
            catch { errorText = errorMessage(error) }
        }
    }
}

/// One source→canonical mapping, tappable to reassign it via the category picker.
struct MappingReassignRow: View {
    let map: CategoryMap

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var picking = false
    @State private var errorText: String?

    /// Plaid labels are SCREAMING_SNAKE; anything else is a Splitwise name.
    private var isBankLabel: Bool {
        map.rawCategory == map.rawCategory.uppercased() && map.rawCategory.contains("_")
    }
    private var label: String { isBankLabel ? PlaidCategory.humanized(map.rawCategory) : map.rawCategory }

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 10) {
                Image(systemName: isBankLabel ? "building.columns" : "person.2")
                    .font(.caption2).foregroundStyle(.tertiary).frame(width: 18)
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text(map.canonicalCategory).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $picking) {
            CategoryPickerView(current: map.canonicalCategory) { reassign(to: $0) }
        }
        .errorAlert($errorText)
    }

    private func reassign(to canonical: String) {
        let raw = map.rawCategory
        Task {
            do { try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "manual") }
            catch { errorText = errorMessage(error) }
        }
    }
}

/// Create or edit one category: name + a grid of SF Symbol icons, plus the mappings that point here.
struct CategoryEditView: View {
    let editing: SpendCategory?  // nil = create

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categoryMaps: [CategoryMap]

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
    private var dependents: [CategoryMap] {
        guard let editing else { return [] }
        return categoryMaps.filter { $0.canonicalCategory == editing.name }
            .sorted { $0.rawCategory < $1.rawCategory }
    }

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

                if !dependents.isEmpty {
                    Section {
                        ForEach(dependents) { MappingReassignRow(map: $0) }
                    } header: {
                        Text("Used by \(dependents.count) mapping\(dependents.count == 1 ? "" : "s")")
                    } footer: {
                        Text("Source categories currently mapped to “\(editing?.name ?? "")”.")
                    }
                }

                if editing?.builtin == true {
                    Text("Built-in category. Renaming it won't update the automatic Plaid/Splitwise mappings that output its name.")
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

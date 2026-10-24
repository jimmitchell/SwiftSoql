import SwiftUI

/// The list of SObject types in the org. Expanding a type describes it and lists its fields.
struct SchemaSidebar: View {
    @Bindable var model: ExplorerModel
    /// Called when an item is double-clicked.
    var onOpen: (SchemaItem) -> Void = { _ in }
    @AppStorage("sortFieldsAlphabetically") private var sortFields = false

    var body: some View {
        List(selection: $model.schemaSelection) {
            ForEach(model.filteredSObjects) { sobject in
                DisclosureGroup(isExpanded: expansion(for: sobject.name)) {
                    fieldRows(for: sobject.name)
                } label: {
                    SObjectRow(sobject: sobject, isDescribed: model.cachedDescribe(sobject.name) != nil)
                }
                .tag(SchemaItem.sobject(sobject.name))
            }
        }
        .searchable(text: $model.schemaFilter, placement: .sidebar, prompt: "Filter")
        .contextMenu(forSelectionType: SchemaItem.self) { items in
            if let item = items.first {
                Button("Copy Name") { copyName(of: item) }
            }
            Toggle("Sort Fields Alphabetically", isOn: $sortFields)
        } primaryAction: { items in
            if let item = items.first { onOpen(item) }
        }
        .onChange(of: model.schemaSelection) { _, item in
            if let item {
                Task { await model.ensureDescribed(item.sobjectName) }
            }
        }
        .overlay {
            if model.filteredSObjects.isEmpty && !model.schemaFilter.isEmpty {
                ContentUnavailableView.search(text: model.schemaFilter)
            }
        }
    }

    @ViewBuilder
    private func fieldRows(for sobject: String) -> some View {
        if let describe = model.cachedDescribe(sobject) {
            let fields = sortFields
                ? describe.fields.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                : describe.fields
            ForEach(fields) { field in
                FieldRow(field: field, isHighlighted: model.fieldMatchesFilter(field))
                    .tag(SchemaItem.field(sobject: sobject, field: field.name))
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .task { await model.ensureDescribed(sobject) }
        }
    }

    private func expansion(for sobject: String) -> Binding<Bool> {
        Binding {
            model.expandedSObjects.contains(sobject)
        } set: { expanded in
            if expanded {
                model.expandedSObjects.insert(sobject)
            } else {
                model.expandedSObjects.remove(sobject)
            }
        }
    }

    private func copyName(of item: SchemaItem) {
        let name = switch item {
        case .sobject(let name): name
        case .field(_, let field): field
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }
}

private struct SObjectRow: View {
    let sobject: GlobalSObject
    let isDescribed: Bool

    var body: some View {
        Label {
            Text(sobject.name)
                .foregroundStyle(isDescribed ? .primary : .secondary)
        } icon: {
            Image(systemName: sobject.custom ? "tablecells.badge.ellipsis" : "tablecells")
                .foregroundStyle(sobject.custom ? Color.orange : Color.accentColor)
        }
        .help(sobject.label)
    }
}

private struct FieldRow: View {
    let field: FieldDescribe
    let isHighlighted: Bool

    var body: some View {
        HStack {
            Text(field.name)
                .fontWeight(isHighlighted ? .bold : .regular)
                .foregroundStyle(isHighlighted ? Color.accentColor : .primary)
            Spacer(minLength: 8)
            Text(field.typeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(field.label)
    }
}

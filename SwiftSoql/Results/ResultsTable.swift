import AppKit
import SwiftUI

/// A table of query results with one column per (flattened) field.
///
/// Top-level fields that the user can update are edited in place. When `checkedRows` is given,
/// a first column of checkboxes marks rows for deletion.
struct ResultsTable: View {
    let resultSet: ResultSet
    var model: ExplorerModel
    /// The rows checked for deletion, or nil if rows can't be deleted from this table.
    var checkedRows: Binding<Set<ResultRow.ID>>?
    /// How the rows are sorted. Clicking a column header changes it.
    var sortOrder: Binding<[ResultSortComparator]>
    /// Called when a subquery cell is clicked.
    var onOpenChild: (QueryResult, String, ResultRow.ID) -> Void = { _, _, _ in }

    @State private var selection = Set<ResultRow.ID>()

    private enum Column: Hashable {
        case check
        case error
        case field(String)
    }

    private var tableColumns: [Column] {
        var columns: [Column] = []
        if checkedRows != nil {
            columns.append(.check)
        }
        if !resultSet.rowErrors.isEmpty {
            columns.append(.error)
        }
        return columns + resultSet.columns.map(Column.field)
    }

    var body: some View {
        Table(resultSet.rows, selection: $selection, sortOrder: sortOrder) {
            TableColumnForEach(tableColumns, id: \.self) { column in
                // Every column needs the same kind of sort; the checkbox and error columns sort
                // by the original order.
                switch column {
                case .check:
                    TableColumn("", sortUsing: ResultSortComparator(column: "")) { row in
                        checkbox(row)
                    }
                    .width(22)
                case .error:
                    TableColumn("Error", sortUsing: ResultSortComparator(column: "")) { row in
                        let message = resultSet.rowErrors[row.id] ?? ""
                        Text(message)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(message)
                    }
                    .width(min: 40, ideal: 240)
                case .field(let name):
                    TableColumn(name, sortUsing: ResultSortComparator(column: name)) { row in
                        cell(row, column: name)
                    }
                    .width(min: 40, ideal: resultSet.idealWidth(for: name))
                }
            }
        }
        // A new result set can have entirely different columns, so start the table afresh.
        .id(resultSet.id)
        .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
            Button("Copy") { copy(ids, includeHeader: false) }
                .disabled(ids.isEmpty)
            Button("Copy with Column Names") { copy(ids, includeHeader: true) }
                .disabled(ids.isEmpty)
            Button("Show in Loaded Order") { sortOrder.wrappedValue = [] }
                .disabled(sortOrder.wrappedValue.isEmpty)
            if let checkedRows {
                Divider()
                Button("Check Rows for Deletion") { checkedRows.wrappedValue.formUnion(ids) }
                    .disabled(ids.isEmpty)
                Button("Uncheck Rows") { checkedRows.wrappedValue.subtract(ids) }
                    .disabled(ids.isEmpty)
                Divider()
                Button("Check All Rows") { checkedRows.wrappedValue = Set(resultSet.rows.map(\.id)) }
                Button("Uncheck All Rows") { checkedRows.wrappedValue = [] }
                    .disabled(checkedRows.wrappedValue.isEmpty)
            }
        }
        .onCopyCommand {
            let text = ResultsExport.tabSeparated(resultSet, rowIDs: selection, includeHeader: false)
            return [NSItemProvider(object: text as NSString)]
        }
    }

    private func checkbox(_ row: ResultRow) -> some View {
        Toggle("Delete", isOn: Binding {
            checkedRows?.wrappedValue.contains(row.id) ?? false
        } set: { isOn in
            if isOn {
                checkedRows?.wrappedValue.insert(row.id)
            } else {
                checkedRows?.wrappedValue.remove(row.id)
            }
        })
        .toggleStyle(.checkbox)
        .labelsHidden()
        .help("Check rows, then click Delete Checked to delete them")
    }

    @ViewBuilder
    private func cell(_ row: ResultRow, column: String) -> some View {
        let value = row.record.value(atPath: column.split(separator: "."))
        if let value, let child = QueryResult(nested: value) {
            Button("\(child.totalSize) \(child.totalSize == 1 ? "row" : "rows")") {
                onOpenChild(child, column, row.id)
            }
            .buttonStyle(.link)
            .help("Show these rows below")
        } else if resultSet.isEditable, column != "Id", model.editableFields(of: row).contains(column) {
            EditableCell(value: value?.displayText ?? "", isDisabled: model.isSaving) { text in
                await model.saveEdit(text, field: column, row: row)
            }
        } else {
            Text(value?.displayText ?? "")
                .lineLimit(1)
                .help(value?.displayText ?? "")
        }
    }

    private func copy(_ ids: Set<ResultRow.ID>, includeHeader: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ResultsExport.tabSeparated(resultSet, rowIDs: ids, includeHeader: includeHeader), forType: .string)
    }
}

/// A results cell that saves its value when editing ends with Return or by moving elsewhere.
/// Escape puts the value back.
private struct EditableCell: View {
    let value: String
    var isDisabled = false
    /// Saves the text, returning whether it was saved.
    let save: (String) async -> Bool

    @State private var draft = ""
    @State private var isSavingDraft = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // An empty prompt, so empty values look like the read-only cells.
        TextField(text: $draft, prompt: Text("")) { Text("Value") }
            .labelsHidden()
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($isFocused)
            .disabled(isDisabled)
            .help(value)
            .onAppear { draft = value }
            .onChange(of: value) { draft = value }
            .onSubmit { commit() }
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
            .onExitCommand {
                draft = value
                isFocused = false
            }
    }

    private func commit() {
        guard draft != value, !isSavingDraft else { return }
        isSavingDraft = true
        let text = draft
        Task {
            if !(await save(text)) {
                draft = value
            }
            isSavingDraft = false
        }
    }
}

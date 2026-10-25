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
    /// Identifies the table for UI tests.
    var accessibilityID = "results"
    /// Called when a subquery cell is clicked.
    var onOpenChild: (QueryResult, String, ResultRow.ID) -> Void = { _, _, _ in }

    @State private var selection = Set<ResultRow.ID>()
    /// Hidden and reordered columns, from the header's menu or by dragging. Reset for new results.
    @State private var columnCustomization = TableColumnCustomization<ResultRow>()
    @Environment(\.openURL) private var openURL

    /// More than this many records at once would flood the browser with tabs.
    private static let maxRecordsToOpen = 20

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
        Table(resultSet.visibleRows, selection: $selection, sortOrder: sortOrder, columnCustomization: $columnCustomization) {
            TableColumnForEach(tableColumns, id: \.self) { column in
                // Every column needs the same kind of sort; the checkbox and error columns sort
                // by the original order.
                switch column {
                case .check:
                    TableColumn("", sortUsing: ResultSortComparator(column: "")) { row in
                        checkbox(row)
                    }
                    .width(22)
                    .customizationID("✓")
                    .disabledCustomizationBehavior(.all)
                case .error:
                    TableColumn("Error", sortUsing: ResultSortComparator(column: "")) { row in
                        let message = resultSet.rowErrors[row.id] ?? ""
                        Text(message)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(message)
                    }
                    .width(min: 40, ideal: 240)
                    .customizationID("⚠")
                case .field(let name):
                    TableColumn(name, sortUsing: ResultSortComparator(column: name)) { row in
                        cell(row, column: name)
                    }
                    .width(min: 40, ideal: resultSet.idealWidth(for: name))
                    .customizationID(name)
                }
            }
        }
        // A new result set can have entirely different columns, so start the table afresh.
        .id(resultSet.id)
        .onChange(of: resultSet.id) { columnCustomization = TableColumnCustomization() }
        .accessibilityIdentifier(accessibilityID)
        .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
            Button("Copy") { copy(ids, includeHeader: false) }
                .disabled(ids.isEmpty)
            Button("Copy with Column Names") { copy(ids, includeHeader: true) }
                .disabled(ids.isEmpty)
            Button("Copy as JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ResultsExport.json(resultSet.rows.filter { ids.contains($0.id) }.map(\.record)), forType: .string)
            }
            .disabled(ids.isEmpty)
            Button("Show in Loaded Order") { sortOrder.wrappedValue = [] }
                .disabled(sortOrder.wrappedValue.isEmpty)
            Button("Show All Columns") { columnCustomization = TableColumnCustomization() }
                .disabled(!resultSet.columns.contains { columnCustomization[visibility: $0] == .hidden })
            Divider()
            if ids.count == 1, let row = resultSet.rows.first(where: { ids.contains($0.id) }), row.recordID != nil, row.record.sobjectType != nil {
                Button("Show All Fields") {
                    model.inspectRecord(in: row, api: resultSet.api)
                    AppDefaults.store.set(InspectorPanel.Tab.record.rawValue, forKey: "inspectorTab")
                    AppDefaults.store.set(true, forKey: "showDetailsInspector")
                }
            }
            openInSalesforceItems(ids)
            if resultSet.isEditable, model.canChangeData, ids.count == 1, let row = resultSet.rows.first(where: { ids.contains($0.id) }), row.recordID != nil {
                Button("Clone Record…") {
                    Task { await model.cloneRecord(row) }
                }
                .disabled(model.isSaving)
            }
            if let checkedRows {
                Divider()
                Button(resultSet.includesDeleted ? "Check Rows" : "Check Rows for Deletion") { checkedRows.wrappedValue.formUnion(ids) }
                    .disabled(ids.isEmpty)
                Button("Uncheck Rows") { checkedRows.wrappedValue.subtract(ids) }
                    .disabled(ids.isEmpty)
                Divider()
                Button(resultSet.filter.isEmpty ? "Check All Rows" : "Check All Shown Rows") { checkedRows.wrappedValue.formUnion(resultSet.visibleRows.map(\.id)) }
                Button("Uncheck All Rows") { checkedRows.wrappedValue = [] }
                    .disabled(checkedRows.wrappedValue.isEmpty)
            }
        }
        .onChange(of: resultSet.highlightedRowID, initial: true) { _, id in
            if let id { selection = [id] }
        }
        // The inspector's Record tab follows the selected row.
        .onChange(of: selection) {
            if selection.count == 1, let row = resultSet.rows.first(where: { selection.contains($0.id) }) {
                model.inspectRecord(in: row, api: resultSet.api)
            }
        }
        .onCopyCommand {
            let text = ResultsExport.tabSeparated(resultSet, rowIDs: selection, includeHeader: false)
            return [NSItemProvider(object: text as NSString)]
        }
    }

    @ViewBuilder
    private func openInSalesforceItems(_ ids: Set<ResultRow.ID>) -> some View {
        let recordIDs = resultSet.rows.filter { ids.contains($0.id) }.compactMap(\.recordID)
        Button(recordIDs.count > 1 ? "Open \(recordIDs.count) Records in Salesforce" : "Open in Salesforce") {
            for id in recordIDs {
                if let url = model.recordURL(id) { openURL(url) }
            }
        }
        .disabled(recordIDs.isEmpty || recordIDs.count > Self.maxRecordsToOpen)
        if ids.count == 1, let row = resultSet.rows.first(where: { ids.contains($0.id) }) {
            let related = model.relatedRecords(in: row, columns: resultSet.columns)
            if !related.isEmpty {
                Menu("Open Related Record") {
                    ForEach(related, id: \.column) { record in
                        Button("\(record.column) (\(record.type))") {
                            if let url = model.recordURL(record.id) { openURL(url) }
                        }
                    }
                }
            }
        }
    }

    private func checkbox(_ row: ResultRow) -> some View {
        Toggle(resultSet.includesDeleted ? "Check row" : "Check row for deletion", isOn: Binding {
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
        .help(resultSet.includesDeleted ? "Check rows, then click Restore Checked or Delete Checked" : "Check rows, then click Delete Checked to delete them")
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
        } else if resultSet.isEditable, let field = model.editableField(column, of: row) {
            FieldEditor(field: field, value: value, isDisabled: model.isSaving) { text in
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

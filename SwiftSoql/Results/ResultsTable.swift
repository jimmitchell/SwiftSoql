import AppKit
import SwiftUI

/// A table of query results with one column per (flattened) field.
struct ResultsTable: View {
    let resultSet: ResultSet
    /// Called when a subquery cell is clicked.
    var onOpenChild: (QueryResult, String) -> Void = { _, _ in }

    @State private var selection = Set<ResultRow.ID>()

    var body: some View {
        Table(resultSet.rows, selection: $selection) {
            TableColumnForEach(resultSet.columns, id: \.self) { column in
                TableColumn(column) { row in
                    cell(row.record.value(atPath: column.split(separator: ".")), column: column)
                }
                .width(min: 40, ideal: resultSet.idealWidth(for: column))
            }
        }
        // A new result set can have entirely different columns, so start the table afresh.
        .id(resultSet.id)
        .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
            Button("Copy") { copy(ids, includeHeader: false) }
                .disabled(ids.isEmpty)
            Button("Copy with Column Names") { copy(ids, includeHeader: true) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = ResultsExport.tabSeparated(resultSet, rowIDs: selection, includeHeader: false)
            return [NSItemProvider(object: text as NSString)]
        }
    }

    @ViewBuilder
    private func cell(_ value: JSONValue?, column: String) -> some View {
        if let value, let child = QueryResult(nested: value) {
            Button("\(child.totalSize) \(child.totalSize == 1 ? "row" : "rows")") {
                onOpenChild(child, column)
            }
            .buttonStyle(.link)
            .help("Show these rows below")
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

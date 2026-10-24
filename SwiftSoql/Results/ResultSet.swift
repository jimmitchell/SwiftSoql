import Foundation

/// Loaded query results, with the columns to display them.
struct ResultSet: Identifiable {
    let id = UUID()
    private(set) var columns: [String]
    private(set) var rows: [ResultRow]
    /// The number of rows the query matched, which can be more than are loaded.
    private(set) var totalSize: Int
    /// The URL of the next batch of rows, if there is one.
    private(set) var nextRecordsURL: String?
    let isSearchResult: Bool
    /// The SObject types of the rows.
    private(set) var sobjectTypes: Set<String>
    /// For subquery results, the column they came from.
    var title: String?
    /// For subquery results, the row of the parent results they came from.
    var parentRowID: ResultRow.ID?

    /// How the rows are sorted; empty for the order they were loaded in.
    private(set) var sortOrder: [ResultSortComparator] = []

    /// Whether the query included deleted rows, which can then be restored.
    var includesDeleted = false

    /// Rows checked for deletion (or, when the query included deleted rows, for restoring).
    var checkedRows: Set<ResultRow.ID> = []
    /// Why rows couldn't be deleted.
    var rowErrors: [ResultRow.ID: String] = [:]

    private var nextRowID = 0

    init(result: QueryResult, title: String? = nil, parentRowID: ResultRow.ID? = nil) {
        self.title = title
        self.parentRowID = parentRowID
        totalSize = result.totalSize
        nextRecordsURL = result.nextRecordsURL
        isSearchResult = result.isSearchResult
        columns = []
        rows = []
        sobjectTypes = []
        add(result.records)
    }

    /// Whether the rows can be edited and deleted, which needs their Ids. The same rule as SoqlXplorer.
    var isEditable: Bool { columns.contains("Id") }

    /// A starting width for a column that fits its name and the values in the first rows.
    func idealWidth(for column: String) -> CGFloat {
        let path = column.split(separator: ".")
        let longest = rows.prefix(100).reduce(column.count) { longest, row in
            max(longest, row.record.value(atPath: path)?.displayText?.count ?? 0)
        }
        return min(max(CGFloat(longest) * 7 + 16, 50), 320)
    }

    mutating func append(_ batch: QueryResult) {
        totalSize = batch.totalSize
        nextRecordsURL = batch.nextRecordsURL
        add(batch.records)
    }

    private mutating func add(_ records: [JSONObject]) {
        for record in records {
            rows.append(ResultRow(id: nextRowID, record: record))
            nextRowID += 1
            if let type = record.sobjectType {
                sobjectTypes.insert(type)
            }
        }
        // A later batch can resolve columns that were null in every earlier row.
        columns = QueryColumns.names(for: rows.map(\.record), isSearchResult: isSearchResult)
        if !sortOrder.isEmpty {
            rows.sort(using: sortOrder)
        }
    }

    /// Sorts the rows, or puts them back in the order they were loaded if `order` is empty.
    mutating func sort(by order: [ResultSortComparator]) {
        sortOrder = order
        rows.sort(using: order.isEmpty ? [ResultSortComparator(column: "")] : order)
    }

    /// Removes deleted rows.
    mutating func removeRows(_ ids: Set<ResultRow.ID>) {
        let before = rows.count
        rows.removeAll { ids.contains($0.id) }
        totalSize -= before - rows.count
        checkedRows.subtract(ids)
        for id in ids {
            rowErrors[id] = nil
        }
    }

    /// Records a saved change in every copy of the record: its row, and wherever it appears as a
    /// related record or subquery row.
    mutating func applyUpdate(recordID: String, field: String, value: JSONValue) {
        for i in rows.indices {
            if case .object(let updated) = JSONValue.object(rows[i].record).updatingRecords(id: recordID, field: field, value: value) {
                rows[i].record = updated
            }
        }
    }
}

struct ResultRow: Identifiable {
    let id: Int
    var record: JSONObject

    /// The record's Id, if it was queried.
    var recordID: String? { record["Id"]?.string }
}

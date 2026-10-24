import SwiftUI
import UniformTypeIdentifiers

/// Text formats for query results.
enum ResultsExport {
    /// RFC 4180 CSV of every loaded row, with a header row of column names.
    static func csv(_ resultSet: ResultSet) -> String {
        var lines = [resultSet.columns.map(quoted).joined(separator: ",")]
        for row in resultSet.rows {
            lines.append(resultSet.columns.map { quoted(text(row.record, column: $0)) }.joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Tab-separated rows for the clipboard, in table order.
    static func tabSeparated(_ resultSet: ResultSet, rowIDs: Set<ResultRow.ID>, includeHeader: Bool) -> String {
        var lines = includeHeader ? [resultSet.columns.joined(separator: "\t")] : []
        for row in resultSet.rows where rowIDs.contains(row.id) {
            lines.append(resultSet.columns.map {
                text(row.record, column: $0).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func text(_ record: JSONObject, column: String) -> String {
        guard let value = record.value(atPath: column.split(separator: ".")) else { return "" }
        if let child = QueryResult(nested: value) {
            return "[\(child.totalSize) child rows]"
        }
        return value.displayText ?? ""
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// A CSV file for `fileExporter`.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

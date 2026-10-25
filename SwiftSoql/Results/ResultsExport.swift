import SwiftUI
import UniformTypeIdentifiers

/// Text formats for query results.
enum ResultsExport {
    /// RFC 4180 CSV of every loaded row, with a header row of column names.
    static func csv(_ resultSet: ResultSet) -> String {
        csvHeader(resultSet.columns) + resultSet.rows.map { csvLine($0.record, columns: resultSet.columns) }.joined()
    }

    static func csvHeader(_ columns: [String]) -> String {
        columns.map { quoted($0) }.joined(separator: ",") + "\r\n"
    }

    /// One record as a CSV line, ending in CRLF.
    static func csvLine(_ record: JSONObject, columns: [String]) -> String {
        columns.map { quoted(csvText(record, column: $0)) }.joined(separator: ",") + "\r\n"
    }

    /// Rewrites CSV from the Bulk API (LF line endings, values quoted only when needed) in the
    /// same form as `csv`: every value quoted, CRLF line endings, and text that a spreadsheet
    /// would run as a formula prefixed with an apostrophe. Returns the text and the number of
    /// records, not counting the header row, which is left out if `includeHeader` is false.
    static func bulkCSV(_ data: Data, includeHeader: Bool) -> (text: String, records: Int) {
        let rows = CSV.rows(String(decoding: data, as: UTF8.self))
        var out = includeHeader ? rows.first.map { CSV.line($0) } ?? "" : ""
        for row in rows.dropFirst() {
            out += CSV.line(row.map(neutralized))
        }
        return (out, max(0, rows.count - 1))
    }

    /// Text that a spreadsheet would treat as a formula gets a leading apostrophe; numbers,
    /// including negative ones, are left alone.
    static func neutralized(_ value: String) -> String {
        guard let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first), Double(value) == nil else { return value }
        return "'" + value
    }

    /// Records as an indented JSON array, as Salesforce returned them but with each
    /// `attributes` object cut down to the record's type. Subquery results keep their
    /// totalSize, done and records.
    static func json(_ records: [JSONObject]) -> String {
        JSONValue.array(records.map { trimmed(.object($0)) }).prettyPrinted() + "\n"
    }

    /// One record for a JSON file of many: indented one level, without a trailing newline.
    static func jsonElement(_ record: JSONObject) -> String {
        "  " + trimmed(.object(record)).prettyPrinted(indent: "  ")
    }

    private static func trimmed(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let o):
            var out = JSONObject()
            for key in o.keys {
                guard let child = o[key] else { continue }
                if key == "attributes", let type = child["type"] {
                    var attributes = JSONObject()
                    attributes["type"] = type
                    out[key] = .object(attributes)
                } else {
                    out[key] = trimmed(child)
                }
            }
            return .object(out)
        case .array(let a):
            return .array(a.map(trimmed))
        default:
            return value
        }
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

    /// Like `text`, but text values that a spreadsheet would treat as a formula get a leading
    /// apostrophe, so record data can't run formulas when the file is opened in Excel or Numbers.
    /// Numbers, and text that reads as a number, are left alone, so negative values stay numeric.
    private static func csvText(_ record: JSONObject, column: String) -> String {
        let value = text(record, column: column)
        guard case .string = record.value(atPath: column.split(separator: ".")) else { return value }
        return neutralized(value)
    }

    private static func quoted(_ s: String) -> String {
        CSV.quoted(s)
    }
}

/// An exported CSV or JSON file for `fileExporter`.
struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .json]

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

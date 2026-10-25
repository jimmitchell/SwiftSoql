import Foundation

/// Reading and writing RFC 4180 CSV.
nonisolated enum CSV {
    /// The rows of CSV text, each a list of values. Quoted values can contain commas, quotes
    /// (doubled) and line breaks; lines can end in LF, CRLF or CR. Blank lines are skipped, and a
    /// leading byte order mark is ignored.
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = (text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).makeIterator()
        func endRow() {
            row.append(field)
            field = ""
            if row != [""] { rows.append(row) }
            row = []
        }
        while let c = chars.next() {
            if inQuotes {
                if c == "\"" {
                    // A doubled quote is a literal quote; otherwise the quoted value ends.
                    var lookahead = chars
                    if lookahead.next() == "\"" {
                        field.append("\"")
                        chars = lookahead
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == "," {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// One row as a CSV line with every value quoted, ending in `lineEnding`.
    static func line(_ values: [String], lineEnding: String = "\r\n") -> String {
        values.map(quoted).joined(separator: ",") + lineEnding
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

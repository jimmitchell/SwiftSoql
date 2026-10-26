import Foundation

/// Writes an Excel workbook (.xlsx) of text and number cells. Each sheet's first row is a bold,
/// frozen header with a filter; text is stored as text, so nothing is run as a formula.
nonisolated enum XLSX {
    struct Sheet {
        /// A name from `sheetNames`.
        var name: String
        var header: [String]
        var rows: [[Cell]]
    }

    enum Cell {
        case text(String)
        case number(Int)
        /// Text linking to cell A1 of the named sheet.
        case link(String, sheet: String)
    }

    static let maxCellLength = 32_767

    /// Names Excel accepts for sheets with the given names, in order: at most 31 characters,
    /// without `[ ] : * ? / \`, not starting or ending with an apostrophe, and unique ignoring
    /// case. "History" is reserved by Excel.
    static func sheetNames(_ names: [String]) -> [String] {
        var taken: Set<String> = ["history"]
        return names.map { name in
            var base = String(name.map { "[]:*?/\\".contains($0) ? "_" : $0 })
            base = String(base.trimmingCharacters(in: CharacterSet(charactersIn: "'")).prefix(31))
            if base.isEmpty { base = "Sheet" }
            var unique = base
            var n = 2
            while taken.contains(unique.lowercased()) {
                let suffix = " (\(n))"
                unique = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            taken.insert(unique.lowercased())
            return unique
        }
    }

    static func workbook(_ sheets: [Sheet]) -> Data {
        var entries = [
            Zip.Entry(path: "[Content_Types].xml", data: contentTypes(sheets.count)),
            Zip.Entry(path: "_rels/.rels", data: xml("""
            <Relationships xmlns="\(relationshipsNamespace)">\
            <Relationship Id="rId1" Type="\(officeNamespace)/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """)),
            Zip.Entry(path: "xl/workbook.xml", data: workbookXML(sheets)),
            Zip.Entry(path: "xl/_rels/workbook.xml.rels", data: workbookRelationships(sheets.count)),
            Zip.Entry(path: "xl/styles.xml", data: styles),
        ]
        for (i, sheet) in sheets.enumerated() {
            entries.append(Zip.Entry(path: "xl/worksheets/sheet\(i + 1).xml", data: worksheet(sheet, selected: i == 0)))
        }
        return Zip.archive(entries)
    }

    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let officeNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let relationshipsNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"

    private static func xml(_ body: String) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + body).utf8)
    }

    private static func contentTypes(_ sheetCount: Int) -> Data {
        let sheets = (1...max(sheetCount, 1)).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return xml("""
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets.joined())</Types>
        """)
    }

    private static func workbookXML(_ sheets: [Sheet]) -> Data {
        let entries = sheets.enumerated().map { i, sheet in
            "<sheet name=\"\(escaped(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        // Excel expects a hidden name for each sheet's filter range.
        let filters = sheets.enumerated().map { i, sheet in
            "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">\(escaped(reference(sheet.name)))!\(filterRange(sheet, absolute: true))</definedName>"
        }
        return xml("""
        <workbook xmlns="\(mainNamespace)" xmlns:r="\(officeNamespace)">\
        <sheets>\(entries.joined())</sheets>\
        <definedNames>\(filters.joined())</definedNames>\
        </workbook>
        """)
    }

    private static func workbookRelationships(_ sheetCount: Int) -> Data {
        var relationships = (0..<sheetCount).map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"\(officeNamespace)/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }
        relationships.append("<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"\(officeNamespace)/styles\" Target=\"styles.xml\"/>")
        return xml("<Relationships xmlns=\"\(relationshipsNamespace)\">\(relationships.joined())</Relationships>")
    }

    /// Cell styles: 0 plain, 1 bold header, 2 link.
    private static let styles = xml("""
    <styleSheet xmlns="\(mainNamespace)">\
    <fonts count="3">\
    <font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
    <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
    <font><u/><sz val="11"/><color rgb="FF0563C1"/><name val="Calibri"/><family val="2"/></font>\
    </fonts>\
    <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
    <cellXfs count="3">\
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
    </cellXfs>\
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
    </styleSheet>
    """)

    private static func worksheet(_ sheet: Sheet, selected: Bool) -> Data {
        var xml = "<worksheet xmlns=\"\(mainNamespace)\" xmlns:r=\"\(officeNamespace)\">"
        xml += "<sheetViews><sheetView\(selected ? " tabSelected=\"1\"" : "") workbookViewId=\"0\">"
        xml += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        xml += "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/></sheetView></sheetViews>"
        xml += "<cols>"
        for (i, width) in columnWidths(sheet).enumerated() {
            xml += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }
        xml += "</cols><sheetData>"
        xml += row(1, sheet.header.map(Cell.text), style: 1)
        var links: [String] = []
        for (r, cells) in sheet.rows.enumerated() {
            xml += row(r + 2, cells, style: 0)
            for (c, cell) in cells.enumerated() {
                if case .link(let text, let target) = cell {
                    links.append("<hyperlink ref=\"\(column(c))\(r + 2)\" location=\"\(escaped(reference(target)))!A1\" display=\"\(escaped(text))\"/>")
                }
            }
        }
        xml += "</sheetData>"
        xml += "<autoFilter ref=\"\(filterRange(sheet, absolute: false))\"/>"
        if !links.isEmpty { xml += "<hyperlinks>\(links.joined())</hyperlinks>" }
        xml += "</worksheet>"
        return self.xml(xml)
    }

    private static func row(_ number: Int, _ cells: [Cell], style: Int) -> String {
        var xml = "<row r=\"\(number)\">"
        for (i, cell) in cells.enumerated() {
            let ref = "\(column(i))\(number)"
            switch cell {
            case .number(let value):
                xml += "<c r=\"\(ref)\"\(style == 0 ? "" : " s=\"\(style)\"")><v>\(value)</v></c>"
            case .text(let text), .link(let text, _):
                guard !text.isEmpty else { continue }
                let s = if case .link = cell { 2 } else { style }
                let text = String(text.prefix(maxCellLength))
                let space = text.first?.isWhitespace == true || text.last?.isWhitespace == true || text.contains("\n") ? " xml:space=\"preserve\"" : ""
                xml += "<c r=\"\(ref)\"\(s == 0 ? "" : " s=\"\(s)\"") t=\"inlineStr\"><is><t\(space)>\(escaped(text))</t></is></c>"
            }
        }
        return xml + "</row>"
    }

    /// Widths in characters that fit each column's longest line, between 8 and 60.
    private static func columnWidths(_ sheet: Sheet) -> [Int] {
        sheet.header.indices.map { i in
            let longest = sheet.rows.reduce(sheet.header[i].count + 3) { longest, cells in
                guard i < cells.count else { return longest }
                return switch cells[i] {
                case .number(let value): max(longest, String(value).count)
                case .text(let text), .link(let text, _): max(longest, text.split(separator: "\n").map(\.count).max() ?? 0)
                }
            }
            return min(max(longest + 2, 8), 60)
        }
    }

    private static func filterRange(_ sheet: Sheet, absolute: Bool) -> String {
        let last = column(max(sheet.header.count, 1) - 1)
        let rows = sheet.rows.count + 1
        return absolute ? "$A$1:$\(last)$\(rows)" : "A1:\(last)\(rows)"
    }

    /// A sheet name as a formula reference: quoted, with apostrophes doubled.
    private static func reference(_ sheetName: String) -> String {
        "'" + sheetName.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The column letters for a zero-based index: A, B, … Z, AA, AB, …
    static func column(_ index: Int) -> String {
        var n = index + 1
        var letters = ""
        while n > 0 {
            let remainder = (n - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            n = (n - 1) / 26
        }
        return letters
    }

    /// Text escaped for XML, without the control characters XML can't hold.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: break
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

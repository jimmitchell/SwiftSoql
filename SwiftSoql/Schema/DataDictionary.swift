import Foundation
import UniformTypeIdentifiers

/// A data dictionary: every field of some SObjects, with the details admins get asked for, as
/// CSV, Markdown or an Excel workbook.
nonisolated enum DataDictionary {
    enum Format: String, CaseIterable {
        case csv
        case markdown
        case xlsx

        var title: String {
            switch self {
            case .csv: "CSV"
            case .markdown: "Markdown"
            case .xlsx: "Excel"
            }
        }

        var fileExtension: String {
            switch self {
            case .csv: "csv"
            case .markdown: "md"
            case .xlsx: "xlsx"
            }
        }

        var contentType: UTType {
            switch self {
            case .csv: .commaSeparatedText
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .xlsx: UTType("org.openxmlformats.spreadsheetml.sheet") ?? .spreadsheet
            }
        }
    }

    static let columns = ["SObject", "Field", "Label", "Type", "Required", "Unique", "External Id", "Custom", "Help Text", "Picklist Values", "Formula"]

    static func data(_ describes: [SObjectDescribe], format: Format) -> Data {
        format == .xlsx ? workbook(describes) : Data(text(describes, format: format).utf8)
    }

    /// The CSV or Markdown text of a data dictionary.
    static func text(_ describes: [SObjectDescribe], format: Format) -> String {
        switch format {
        case .csv, .xlsx:
            // Help text, picklist values and formulas come from the org, so text a spreadsheet
            // would run as a formula gets a leading apostrophe.
            CSV.line(columns) + describes.flatMap { describe in
                describe.fields.map { CSV.line(values(describe, $0).map(ResultsExport.neutralized)) }
            }.joined()
        case .markdown:
            describes.map(markdown).joined(separator: "\n")
        }
    }

    /// One field's row of `columns`.
    static func values(_ describe: SObjectDescribe, _ field: FieldDescribe) -> [String] {
        [
            describe.name,
            field.name,
            field.label,
            typeText(field),
            field.isRequiredOnCreate ? "Yes" : "",
            field.unique ? "Yes" : "",
            field.externalId ? "Yes" : "",
            field.custom ? "Yes" : "",
            field.json["inlineHelpText"]?.string ?? "",
            field.picklistValues.filter(\.active).map(\.value).joined(separator: "; "),
            field.json["calculatedFormula"]?.string ?? "",
        ]
    }

    /// The field's API type with its size: "string(80)", "double(18, 2)", "reference(User)".
    static func typeText(_ field: FieldDescribe) -> String {
        let json = field.json
        switch field.type {
        case "string", "textarea", "email", "url", "phone", "encryptedstring", "picklist", "multipicklist", "combobox":
            if let length = json["length"]?.int, length > 0 { return "\(field.type)(\(length))" }
        case "double", "currency", "percent":
            if let precision = json["precision"]?.int, precision > 0 { return "\(field.type)(\(precision), \(json["scale"]?.int ?? 0))" }
        case "int":
            if let digits = json["digits"]?.int, digits > 0 { return "int(\(digits))" }
        case "reference":
            if !field.referenceTo.isEmpty { return "reference(\(field.referenceTo.joined(separator: ", ")))" }
        default:
            break
        }
        return field.type
    }

    /// A workbook with an Objects sheet linking to a sheet of fields for each SObject.
    private static func workbook(_ describes: [SObjectDescribe]) -> Data {
        let names = XLSX.sheetNames(["Objects"] + describes.map(\.name))
        let objects = XLSX.Sheet(name: names[0], header: ["SObject", "Label", "Custom", "Fields"], rows: zip(describes, names.dropFirst()).map { describe, sheet in
            [.link(describe.name, sheet: sheet), .text(describe.json["label"]?.string ?? ""), .text(describe.json["custom"]?.bool == true ? "Yes" : ""), .number(describe.fields.count)]
        })
        let sheets = zip(describes, names.dropFirst()).map { describe, sheet in
            XLSX.Sheet(name: sheet, header: Array(columns.dropFirst()), rows: describe.fields.map { field in
                values(describe, field).dropFirst().map(XLSX.Cell.text)
            })
        }
        return XLSX.workbook([objects] + sheets)
    }

    private static func markdown(_ describe: SObjectDescribe) -> String {
        let label = describe.json["label"]?.string ?? describe.name
        var lines = ["## \(label) (`\(describe.name)`)", ""]
        let shown = ["Field", "Label", "Type", "Required", "Help Text", "Picklist Values"]
        lines.append("| " + shown.joined(separator: " | ") + " |")
        lines.append("|" + String(repeating: " --- |", count: shown.count))
        for field in describe.fields {
            let all = values(describe, field)
            let row = ["`\(field.name)`", all[2], all[3], all[4], all[8], all[9]].map(cell)
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Text for a Markdown table cell: pipes escaped and line breaks as spaces.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

import Foundation

/// A data dictionary: every field of some SObjects, with the details admins get asked for, as
/// CSV or Markdown.
nonisolated enum DataDictionary {
    enum Format: String, CaseIterable {
        case csv
        case markdown

        var title: String { self == .csv ? "CSV" : "Markdown" }
        var fileExtension: String { self == .csv ? "csv" : "md" }
    }

    static let columns = ["SObject", "Field", "Label", "Type", "Required", "Unique", "External Id", "Custom", "Help Text", "Picklist Values", "Formula"]

    static func text(_ describes: [SObjectDescribe], format: Format) -> String {
        switch format {
        case .csv:
            CSV.line(columns) + describes.flatMap { describe in
                describe.fields.map { CSV.line(values(describe, $0)) }
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

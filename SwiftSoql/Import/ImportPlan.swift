import Foundation

/// What an import does with each row.
nonisolated enum ImportOperation: String, CaseIterable, Sendable {
    case insert
    case update
    case upsert

    var title: String { rawValue.capitalized }
}

/// A CSV file to import: its column names and its rows, each padded or cut to the header's width.
nonisolated struct ImportFile: Sendable {
    let name: String
    let header: [String]
    let rows: [[String]]

    struct Unreadable: LocalizedError {
        let errorDescription: String?
    }

    init(name: String, text: String) throws {
        self.name = name
        let all = CSV.rows(text)
        guard let header = all.first?.map({ $0.trimmingCharacters(in: .whitespaces) }), header.contains(where: { !$0.isEmpty }) else {
            throw Unreadable(errorDescription: "\(name) has no header row of column names.")
        }
        guard all.count > 1 else {
            throw Unreadable(errorDescription: "\(name) has column names but no rows to import.")
        }
        self.header = header
        rows = all.dropFirst().map { row in
            row.count == header.count ? row : Array((row + Array(repeating: "", count: header.count)).prefix(header.count))
        }
    }
}

/// Which field each CSV column goes to.
nonisolated struct ImportMapping: Equatable, Sendable {
    /// The field for each column, by position, or nil to skip the column.
    var fields: [String?]

    /// Matches columns to fields by API name, then by label, ignoring case.
    static func automatic(header: [String], fields: [FieldDescribe]) -> ImportMapping {
        ImportMapping(fields: header.map { column in
            let key = column.trimmingCharacters(in: .whitespaces)
            return (fields.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
                ?? fields.first { $0.label.caseInsensitiveCompare(key) == .orderedSame })?.name
        })
    }

    private static func storageKey(sobject: String, header: [String]) -> String {
        "importMapping-\(sobject.lowercased())-\(header.map { $0.lowercased() }.joined(separator: ","))"
    }

    /// The mapping last used for files with these columns, keeping only fields still allowed.
    static func remembered(sobject: String, header: [String], allowed: Set<String>, store: UserDefaults) -> ImportMapping? {
        guard let saved = store.stringArray(forKey: storageKey(sobject: sobject, header: header)), saved.count == header.count else { return nil }
        return ImportMapping(fields: saved.map { $0.isEmpty || !allowed.contains($0) ? nil : $0 })
    }

    func remember(sobject: String, header: [String], store: UserDefaults) {
        store.set(fields.map { $0 ?? "" }, forKey: Self.storageKey(sobject: sobject, header: header))
    }
}

/// How to import a file's rows into an SObject, and the conversions that need.
nonisolated struct ImportPlan: Sendable {
    let describe: SObjectDescribe
    var operation: ImportOperation
    /// For upserts, the field that finds existing records: Id or an external Id field.
    var matchField = "Id"
    var mapping: ImportMapping
    /// Whether empty cells clear their fields, rather than leaving them alone.
    var clearEmpty = false

    /// The fields columns can be mapped to for an operation, by name.
    static func mappableFields(_ describe: SObjectDescribe, operation: ImportOperation) -> [FieldDescribe] {
        describe.fields.filter { field in
            switch operation {
            case .insert: field.createable
            case .update: field.updateable || field.name == "Id"
            case .upsert: field.createable || field.updateable || field.name == "Id"
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The fields an upsert can match records on.
    static func matchFields(_ describe: SObjectDescribe) -> [String] {
        ["Id"] + describe.fields.filter(\.externalId).map(\.name)
    }

    /// The field that finds each row's existing record, if the operation needs one.
    var keyField: String? {
        switch operation {
        case .insert: nil
        case .update: "Id"
        case .upsert: matchField
        }
    }

    /// Why the import can't run yet, or nil if it can.
    var problem: String? {
        let mapped = mapping.fields.compactMap { $0 }
        if mapped.isEmpty { return "Map at least one column to a field." }
        if let duplicate = Dictionary(grouping: mapped, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            return "More than one column is mapped to \(duplicate)."
        }
        if let key = keyField, !mapped.contains(key) {
            return "Map a column to \(key) to find the records to \(operation == .update ? "update" : "upsert")."
        }
        if operation == .insert, let missing = describe.fields.first(where: { $0.isRequiredOnCreate && !mapped.contains($0.name) }) {
            return "Map a column to \(missing.name), which new records need."
        }
        return nil
    }

    private var mappedColumns: [(index: Int, field: FieldDescribe)] {
        mapping.fields.enumerated().compactMap { i, name in
            name.flatMap(describe.field(exactly:)).map { (i, $0) }
        }
    }

    /// One row's field values to send. Empty cells are left out, or sent as null when
    /// `clearEmpty` is set. The key field can't be empty, except that an upsert on Id creates
    /// the rows that have none.
    func record(_ row: [String]) throws -> JSONObject {
        var record = JSONObject()
        for (index, field) in mappedColumns {
            let text = index < row.count ? row[index] : ""
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                if field.name == keyField {
                    if operation == .upsert, field.name == "Id" { continue }
                    throw InvalidFieldValue(errorDescription: "\(field.name) is empty.")
                }
                if clearEmpty { record[field.name] = .null }
                continue
            }
            record[field.name] = try field.value(fromText: text)
        }
        return record
    }

    /// The mapped columns' field names, the header of a Bulk API upload.
    var uploadHeader: [String] { mappedColumns.map(\.field.name) }

    /// A row's values for a Bulk API upload, checked and in Salesforce's text forms. "#N/A"
    /// clears a field.
    func uploadValues(_ row: [String]) throws -> [String] {
        let record = try record(row)
        return mappedColumns.map { _, field in
            switch record[field.name] {
            case nil: ""
            case .null?: "#N/A"
            case let value?: value.displayText ?? ""
            }
        }
    }
}

/// The outcome of an import: each row with its record Id, whether it was created, and its
/// error, ready to save as CSV so failed rows can be fixed and imported again.
nonisolated struct ImportOutcome: Sendable {
    var header: [String]
    var rows: [[String]] = []
    private(set) var created = 0
    private(set) var updated = 0
    private(set) var failed = 0
    /// The first few errors, with the row they came from (counting from 1 after the header) when known.
    private(set) var errors: [(row: Int?, message: String)] = []

    init(header: [String]) {
        self.header = header + ["Id", "Created", "Error"]
    }

    mutating func add(_ values: [String], row: Int?, id: String?, created: Bool, error: String?) {
        rows.append(values + [id ?? "", error == nil ? (created ? "true" : "false") : "", error ?? ""])
        if let error {
            failed += 1
            if errors.count < 50 { errors.append((row, error)) }
        } else if created {
            self.created += 1
        } else {
            updated += 1
        }
    }

    /// The rows as CSV. Values are written as they are, so the file can be imported again.
    var csv: String {
        CSV.line(header) + rows.map { CSV.line($0) }.joined()
    }
}

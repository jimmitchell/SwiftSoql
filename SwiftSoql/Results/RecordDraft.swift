import Foundation

/// A record being filled in to create, either new or copied from another record.
struct RecordDraft: Identifiable {
    let id = UUID()
    var sobject: String
    /// The text entered for each field, by field name. Empty text isn't sent, so Salesforce
    /// leaves the field empty or fills in its default.
    var values: [String: String] = [:]
    /// The Id of the record this is a copy of.
    var clonedFrom: String?

    init(sobject: String) {
        self.sobject = sobject
    }

    /// A copy of a record's values for the fields a new record can set. Unique and external Id
    /// fields are left empty, since a copy can't share them.
    init(cloning record: JSONObject, id: String, describe: SObjectDescribe) {
        sobject = describe.name
        clonedFrom = id
        for field in Self.fields(of: describe) where !field.unique && !field.externalId {
            if let text = record[field.name]?.displayText, !text.isEmpty {
                values[field.name] = text
            }
        }
    }

    /// The fields a new record can set: required ones first, then by importance and name.
    static func fields(of describe: SObjectDescribe) -> [FieldDescribe] {
        describe.fields.filter(\.createable).sorted { a, b in
            if a.isRequiredOnCreate != b.isRequiredOnCreate { return a.isRequiredOnCreate }
            if a.importance != b.importance { return a.importance < b.importance }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The required fields that are still empty.
    func missingFields(_ describe: SObjectDescribe) -> [FieldDescribe] {
        describe.fields.filter { $0.isRequiredOnCreate && (values[$0.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The field values to send to Salesforce.
    func fieldValues(_ describe: SObjectDescribe) throws -> JSONObject {
        var fields = JSONObject()
        for field in Self.fields(of: describe) {
            guard let text = values[field.name], !text.isEmpty else { continue }
            fields[field.name] = try field.value(fromText: text)
        }
        return fields
    }
}

/// A record to show in the inspector.
struct RecordReference: Hashable {
    let sobject: String
    let id: String
    let api: SalesforceAPI
}

import Foundation

/// An entry from the global describe: one SObject type in the org.
nonisolated struct GlobalSObject: Sendable, Identifiable, Hashable {
    let name: String
    let label: String
    let custom: Bool
    let queryable: Bool

    var id: String { name }

    init(json: JSONObject) {
        name = json["name"]?.string ?? ""
        label = json["label"]?.string ?? ""
        custom = json["custom"]?.bool ?? false
        queryable = json["queryable"]?.bool ?? false
    }
}

/// The full describe of an SObject type. The raw JSON is kept for the details inspector.
nonisolated struct SObjectDescribe: Sendable {
    let json: JSONObject
    let name: String
    let fields: [FieldDescribe]
    let childRelationships: [ChildRelationship]
    /// The names of the fields that can be changed on existing records.
    let updateableFields: Set<String>

    init(json: JSONObject) {
        self.json = json
        name = json["name"]?.string ?? ""
        fields = (json["fields"]?.array ?? []).compactMap { $0.object.map(FieldDescribe.init) }
        childRelationships = (json["childRelationships"]?.array ?? []).compactMap { $0.object.map(ChildRelationship.init) }
        updateableFields = Set(fields.filter(\.updateable).map(\.name))
    }

    func field(named name: String) -> FieldDescribe? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

nonisolated struct FieldDescribe: Sendable, Identifiable {
    let json: JSONObject
    let name: String
    let label: String
    let type: String
    let custom: Bool
    let referenceTo: [String]
    let relationshipName: String?

    var id: String { name }

    init(json: JSONObject) {
        self.json = json
        name = json["name"]?.string ?? ""
        label = json["label"]?.string ?? ""
        type = json["type"]?.string ?? ""
        custom = json["custom"]?.bool ?? false
        referenceTo = (json["referenceTo"]?.array ?? []).compactMap(\.string)
        relationshipName = json["relationshipName"]?.string
    }

    var aggregatable: Bool { json["aggregatable"]?.bool ?? false }
    var groupable: Bool { json["groupable"]?.bool ?? false }
    var updateable: Bool { json["updateable"]?.bool ?? false }
    var nameField: Bool { json["nameField"]?.bool ?? false }
    var externalId: Bool { json["externalId"]?.bool ?? false }

    /// How central the field is to the SObject, lowest first: Id, then the name field, external
    /// Ids, ordinary fields, owner-style references, and audit fields. From SoqlXplorer.
    var importance: Int {
        if name == "Id" { return 1 }
        if nameField { return 2 }
        if externalId { return 3 }
        if type == "reference", referenceTo.contains("User") {
            return referenceTo.count == 1 ? 6 : 5
        }
        switch name {
        case "CreatedDate": return 7
        case "LastModifiedDate": return 8
        case "SystemModstamp": return 9
        default: return 4
        }
    }
    /// A polymorphic relationship whose related record's fields come from the Name SObject.
    var namePointing: Bool { json["namePointing"]?.bool ?? false }

    /// Address and geolocation fields that also have individual component fields.
    var isCompound: Bool { type == "address" || type == "location" }

    var typeDescription: String {
        if type == "reference", !referenceTo.isEmpty {
            return "→ " + referenceTo.joined(separator: ", ")
        }
        return type
    }

    var picklistValues: [(value: String, label: String, active: Bool)] {
        (json["picklistValues"]?.array ?? []).compactMap { v in
            guard let value = v["value"]?.string else { return nil }
            return (value, v["label"]?.string ?? value, v["active"]?.bool ?? true)
        }
    }
}

nonisolated struct InvalidFieldValue: LocalizedError {
    let errorDescription: String?
}

nonisolated extension FieldDescribe {
    /// The value to save for text typed into a results cell. Empty text clears the field.
    func value(fromText text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "boolean":
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0", "": return .bool(false)
            default: throw InvalidFieldValue(errorDescription: "\(name) must be true or false.")
            }
        case "int", "double", "currency", "percent":
            if trimmed.isEmpty { return .null }
            guard trimmed.wholeMatch(of: #/-?[0-9]+(\.[0-9]+)?/#) != nil else {
                throw InvalidFieldValue(errorDescription: "\(name) must be a number, like 1234.5.")
            }
            return .number(trimmed)
        default:
            return text.isEmpty ? .null : .string(text)
        }
    }
}

nonisolated struct ChildRelationship: Sendable {
    let childSObject: String
    let field: String
    let relationshipName: String?

    init(json: JSONObject) {
        childSObject = json["childSObject"]?.string ?? ""
        field = json["field"]?.string ?? ""
        relationshipName = json["relationshipName"]?.string
    }
}

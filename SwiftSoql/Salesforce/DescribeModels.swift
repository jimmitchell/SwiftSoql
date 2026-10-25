import Foundation

/// An entry from the global describe: one SObject type in the org.
nonisolated struct GlobalSObject: Sendable, Identifiable, Hashable {
    let name: String
    let label: String
    let custom: Bool
    let queryable: Bool
    /// Whether the user can create records of this type.
    let createable: Bool
    let updateable: Bool
    /// The first three characters of this SObject's record Ids, if it has records.
    let keyPrefix: String?

    var id: String { name }

    init(json: JSONObject) {
        name = json["name"]?.string ?? ""
        label = json["label"]?.string ?? ""
        custom = json["custom"]?.bool ?? false
        queryable = json["queryable"]?.bool ?? false
        createable = json["createable"]?.bool ?? false
        updateable = json["updateable"]?.bool ?? false
        keyPrefix = json["keyPrefix"]?.string
    }
}

/// The full describe of an SObject type. The raw JSON is kept for the details inspector.
///
/// Every SObject in an org can be described, so the fields' and child relationships' properties
/// that are null, false or empty lists are dropped to save memory: a missing property reads the
/// same, and the inspector shows them all as blank.
nonisolated struct SObjectDescribe: Sendable {
    let json: JSONObject
    let name: String
    let fields: [FieldDescribe]
    let childRelationships: [ChildRelationship]
    /// The names of the fields that can be changed on existing records.
    let updateableFields: Set<String>
    private let fieldIndexes: [String: Int]

    init(json: JSONObject) {
        var json = json
        let fieldsJSON = (json["fields"]?.array ?? []).compactMap(\.object).map(Self.pruned)
        let relationshipsJSON = (json["childRelationships"]?.array ?? []).compactMap(\.object).map(Self.pruned)
        json["fields"] = .array(fieldsJSON.map(JSONValue.object))
        json["childRelationships"] = .array(relationshipsJSON.map(JSONValue.object))
        self.json = json
        name = json["name"]?.string ?? ""
        fields = fieldsJSON.map(FieldDescribe.init)
        childRelationships = relationshipsJSON.map(ChildRelationship.init)
        updateableFields = Set(fields.filter(\.updateable).map(\.name))
        fieldIndexes = Dictionary(fields.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// The field with exactly this name, as query results spell it. Faster than `field(named:)`.
    func field(exactly name: String) -> FieldDescribe? {
        fieldIndexes[name].map { fields[$0] }
    }

    private static func pruned(_ obj: JSONObject) -> JSONObject {
        let kept = obj.keys.compactMap { key -> (String, JSONValue)? in
            switch obj[key] {
            case nil, .null, .bool(false): nil
            case .array(let items) where items.isEmpty: nil
            case let value?: (key, value)
            }
        }
        var out = JSONObject(minimumCapacity: kept.count)
        for (key, value) in kept {
            out[key] = value
        }
        return out
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
    var createable: Bool { json["createable"]?.bool ?? false }
    /// Whether Salesforce fills in the field when a record is created without it.
    var defaultedOnCreate: Bool { json["defaultedOnCreate"]?.bool ?? false }
    var unique: Bool { json["unique"]?.bool ?? false }
    /// Whether a new record needs a value for the field. Checkboxes are never empty, so they
    /// don't count.
    var isRequiredOnCreate: Bool { createable && !nillable && !defaultedOnCreate && type != "boolean" }
    var nillable: Bool { json["nillable"]?.bool ?? false }
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

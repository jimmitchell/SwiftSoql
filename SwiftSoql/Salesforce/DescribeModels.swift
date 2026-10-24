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

    init(json: JSONObject) {
        self.json = json
        name = json["name"]?.string ?? ""
        fields = (json["fields"]?.array ?? []).compactMap { $0.object.map(FieldDescribe.init) }
        childRelationships = (json["childRelationships"]?.array ?? []).compactMap { $0.object.map(ChildRelationship.init) }
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

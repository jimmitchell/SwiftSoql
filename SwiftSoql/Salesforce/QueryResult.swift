import Foundation

/// One batch of query results, plus the URL for the next batch if there is one.
nonisolated struct QueryResult: Sendable {
    var totalSize: Int
    var done: Bool
    var nextRecordsURL: String?
    var records: [JSONObject]
    /// SOSL results mix SObject types, so their columns are worked out per type.
    var isSearchResult = false

    init(json: JSONValue) {
        totalSize = json["totalSize"]?.int ?? 0
        done = json["done"]?.bool ?? true
        nextRecordsURL = json["nextRecordsUrl"]?.string
        records = (json["records"]?.array ?? []).compactMap(\.object)
    }

    init(searchResponse json: JSONValue) {
        records = (json["searchRecords"]?.array ?? []).compactMap(\.object)
        totalSize = records.count
        done = true
        nextRecordsURL = nil
        isSearchResult = true
    }

    /// A nested subquery result, e.g. the Contacts in `SELECT (SELECT Name FROM Contacts) FROM Account`.
    init?(nested value: JSONValue) {
        guard let obj = value.object, obj["records"] != nil, obj["totalSize"] != nil else { return nil }
        self.init(json: value)
    }

    mutating func append(_ next: QueryResult) {
        records.append(contentsOf: next.records)
        done = next.done
        nextRecordsURL = next.nextRecordsURL
    }
}

nonisolated extension JSONObject {
    /// The SObject type from a record's `attributes`, if it is a record.
    var sobjectType: String? { self["attributes"]?["type"]?.string }

    /// Field names in query order, without the `attributes` metadata.
    var fieldNames: [String] { keys.filter { $0 != "attributes" } }

    /// Follows a dotted path such as `Account.Owner.Name` or `BillingAddress.city`.
    func value<Key: StringProtocol>(atPath path: some Sequence<Key>) -> JSONValue? {
        var current: JSONValue = .object(self)
        for key in path {
            guard let next = current[String(key)] else { return nil }
            current = next
        }
        return current
    }

    func value(atPath path: String) -> JSONValue? {
        value(atPath: path.split(separator: "."))
    }
}

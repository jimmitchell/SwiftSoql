import Foundation

/// One way Salesforce could run a query, from the REST API's explain. The plan with the lowest
/// cost is the one it uses.
nonisolated struct QueryPlan: Identifiable, Sendable {
    let id: Int
    /// How it finds the rows: Index, Sharing, TableScan or Other.
    let leadingOperationType: String
    /// The cost relative to Salesforce's selectivity threshold; above 1 means the query isn't
    /// selective with this plan.
    let relativeCost: Double
    /// The estimated number of rows the plan returns.
    let cardinality: Int
    /// The number of rows in the SObject.
    let sobjectCardinality: Int
    let sobjectType: String
    /// The indexed fields the plan uses.
    let fields: [String]
    let notes: [String]

    init(id: Int, json: JSONValue) {
        self.id = id
        leadingOperationType = json["leadingOperationType"]?.string ?? ""
        relativeCost = json["relativeCost"].flatMap { if case .number(let n) = $0 { Double(n) } else { nil } } ?? 0
        cardinality = json["cardinality"]?.int ?? 0
        sobjectCardinality = json["sobjectCardinality"]?.int ?? 0
        sobjectType = json["sobjectType"]?.string ?? ""
        fields = (json["fields"]?.array ?? []).compactMap(\.string)
        notes = (json["notes"]?.array ?? []).map { note in
            let fields = (note["fields"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
            let text = note["description"]?.string ?? ""
            return fields.isEmpty ? text : "\(text) (\(fields))"
        }
    }
}

/// The plans for a query, cheapest first.
nonisolated struct QueryPlanResult: Identifiable, Sendable {
    let id = UUID()
    let query: String
    let plans: [QueryPlan]
}

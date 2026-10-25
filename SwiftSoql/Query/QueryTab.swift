import Foundation
import Observation

/// One query tab: its SOQL, its results, and the status line above the results.
@Observable
final class QueryTab: Identifiable {
    let id = UUID()
    var soql: String
    /// The API the tab's queries go to.
    var api: SalesforceAPI
    var results: ResultSet?
    /// A subquery result opened from a cell of `results`.
    var childResults: ResultSet?
    var isQuerying = false
    var statusText = ""

    init(soql: String, api: SalesforceAPI = .data) {
        self.soql = soql
        self.api = api
    }

    /// A short name for the tab: the SObject the query is FROM (not a subquery's), "Search" for
    /// SOSL, or "New Query".
    var title: String {
        let text = soql.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "New Query" }
        if text.lowercased().hasPrefix("find") { return "Search" }
        // Leave out parenthesized subqueries, then find the FROM.
        var outer = ""
        var depth = 0
        for c in text {
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) } else if depth == 0 { outer.append(c) }
        }
        if let match = outer.firstMatch(of: #/(?i)\bFROM\s+([A-Za-z0-9_]+)/#) {
            return String(match.1)
        }
        return "Query"
    }
}

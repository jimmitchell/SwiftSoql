import Foundation

/// One of an org's limits from the REST API's limits resource, such as daily API requests or
/// data storage.
nonisolated struct OrgLimit: Identifiable, Sendable, Equatable {
    let name: String
    let max: Int
    let remaining: Int

    var id: String { name }
    var used: Int { Swift.max(0, max - remaining) }
    /// The share used, from 0 to 1.
    var fraction: Double { max > 0 ? Double(used) / Double(max) : 0 }

    /// The name with spaces between its words: "DailyApiRequests" becomes "Daily Api Requests".
    var title: String {
        var words = ""
        let chars = Array(name)
        var capitals = 0
        for (i, c) in chars.enumerated() {
            let previous = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            // A word starts at a capital after a lowercase letter or digit, or at the last capital
            // of a run of three or more followed by lowercase: "APIRequests" splits as
            // "API Requests", while "OData" stays whole.
            if c.isUppercase, let previous {
                if previous.isLowercase || previous.isNumber || (capitals >= 3 && next?.isLowercase == true) {
                    words.append(" ")
                }
            }
            capitals = c.isUppercase ? capitals + 1 : 0
            words.append(c)
        }
        return words
    }

    /// Storage limits are in megabytes.
    var unit: String { name.hasSuffix("MB") ? " MB" : "" }

    /// The limits in a `/limits` response, most used first, then by name.
    static func limits(from json: JSONValue) -> [OrgLimit] {
        guard let object = json.object else { return [] }
        return object.keys.compactMap { name in
            guard let max = object[name]?["Max"]?.int, let remaining = object[name]?["Remaining"]?.int else { return nil }
            return OrgLimit(name: name, max: max, remaining: remaining)
        }
        .sorted { a, b in
            a.fraction != b.fraction ? a.fraction > b.fraction : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

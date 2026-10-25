import Foundation

/// One of the org's debug logs, from the ApexLog object.
nonisolated struct ApexLogEntry: Identifiable, Sendable, Equatable {
    let id: String
    let userID: String
    let userName: String
    /// What produced the log, such as "/apex/MyPage" or "Api".
    let operation: String
    let request: String
    let status: String
    /// The size of the log in bytes.
    let length: Int
    let startTime: Date?
    let durationMilliseconds: Int

    static let fields = "Id, LogUserId, LogUser.Name, Operation, Request, Status, LogLength, StartTime, DurationMilliseconds"

    init?(json: JSONObject) {
        guard let id = json["Id"]?.string else { return nil }
        self.id = id
        userID = json["LogUserId"]?.string ?? ""
        userName = json["LogUser"]?["Name"]?.string ?? ""
        operation = json["Operation"]?.string ?? ""
        request = json["Request"]?.string ?? ""
        status = json["Status"]?.string ?? ""
        length = json["LogLength"]?.int ?? 0
        startTime = json["StartTime"]?.string.flatMap(SalesforceDateTime.parse)
        durationMilliseconds = json["DurationMilliseconds"]?.int ?? 0
    }
}

/// A trace flag that makes Salesforce record debug logs for a user until it expires.
nonisolated struct TraceFlagInfo: Sendable, Equatable {
    let id: String
    let userID: String
    let expiration: Date?

    var isActive: Bool { (expiration ?? .distantPast) > Date() }
}

/// Salesforce's date-time text: 2024-05-01T17:30:00.000+0000, always written in UTC.
nonisolated enum SalesforceDateTime {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    static func parse(_ text: String) -> Date? {
        formatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ").date(from: text)
    }

    static func format(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").string(from: date)
    }
}

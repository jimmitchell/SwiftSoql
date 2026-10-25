import Foundation
import Testing
@testable import SwiftSoql

struct DebugLogTests {
    @Test func readsLogEntries() throws {
        let json = try #require(try JSONValue.parse(Data(#"""
        {"Id": "07L000000000001AAA", "LogUserId": "005000000000001AAA", "LogUser": {"Name": "Jim"}, "Operation": "/services/Soap/s/68.0",
         "Request": "Api", "Status": "Success", "LogLength": 2048, "StartTime": "2026-10-25T20:30:15.000+0000", "DurationMilliseconds": 42}
        """#.utf8)).object)
        let log = try #require(ApexLogEntry(json: json))
        #expect(log.userName == "Jim" && log.length == 2048 && log.durationMilliseconds == 42)
        #expect(log.startTime == SalesforceDateTime.parse("2026-10-25T20:30:15.000+0000"))
        #expect(log.startTime?.timeIntervalSince1970 == 1_792_960_215)
    }

    @Test func writesDateTimesInUTC() {
        let date = Date(timeIntervalSince1970: 1_792_960_215)
        #expect(SalesforceDateTime.format(date) == "2026-10-25T20:30:15.000Z")
        #expect(TraceFlagInfo(id: "x", userID: "y", expiration: Date().addingTimeInterval(60)).isActive)
        #expect(!TraceFlagInfo(id: "x", userID: "y", expiration: date.addingTimeInterval(-86_400 * 365 * 20)).isActive)
    }
}

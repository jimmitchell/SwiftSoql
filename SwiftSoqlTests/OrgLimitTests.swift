import Foundation
import Testing
@testable import SwiftSoql

struct OrgLimitTests {
    @Test func parsesSortsAndNames() throws {
        let json = try JSONValue.parse(Data(#"""
        {"DailyApiRequests": {"Max": 15000, "Remaining": 13500, "Salesforce Mobile Dashboards": {"Max": 0, "Remaining": 0}},
         "DataStorageMB": {"Max": 5, "Remaining": 0},
         "HourlyODataCallout": {"Max": 20000, "Remaining": 20000},
         "ActiveScratchOrgs": {"Max": 3, "Remaining": 3}}
        """#.utf8))
        let limits = OrgLimit.limits(from: json)
        #expect(limits.map(\.name) == ["DataStorageMB", "DailyApiRequests", "ActiveScratchOrgs", "HourlyODataCallout"], "Most used first, then by name")
        #expect(limits[0].fraction == 1 && limits[0].unit == " MB")
        #expect(limits[1].used == 1500)
        #expect(limits.map(\.title) == ["Data Storage MB", "Daily Api Requests", "Active Scratch Orgs", "Hourly OData Callout"])
        #expect(OrgLimit(name: "DailyAPIRequests", max: 1, remaining: 1).title == "Daily API Requests")
    }
}

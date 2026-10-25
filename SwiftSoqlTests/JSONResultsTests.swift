import Foundation
import Testing
@testable import SwiftSoql

struct JSONResultsTests {
    private let json = """
    {"totalSize": 2, "done": true, "records": [
      {"attributes": {"type": "Account", "url": "/services/data/v62.0/sobjects/Account/001A"}, "Id": "001A", "Name": "Acme \\"One\\"", "NumberOfEmployees": 250, "IsActive": true, "Parent": null,
       "Contacts": {"totalSize": 1, "done": true, "records": [{"attributes": {"type": "Contact", "url": "/x"}, "LastName": "Lee"}]}},
      {"attributes": {"type": "Account", "url": "/services/data/v62.0/sobjects/Account/001B"}, "Id": "001B", "Name": "Globex", "NumberOfEmployees": 1.5e3, "IsActive": false, "Parent": null, "Contacts": null}
    ]}
    """

    private func records() throws -> [JSONObject] {
        QueryResult(json: try JSONValue.parse(Data(json.utf8))).records
    }

    @Test func prettyPrintsAndTrimsAttributes() throws {
        let text = ResultsExport.json(try records())
        #expect(text.hasPrefix("[\n  {\n    \"attributes\": {\n      \"type\": \"Account\"\n    },\n    \"Id\": \"001A\""))
        #expect(!text.contains("/services/data"), "Attribute URLs are left out")
        #expect(text.contains("\"NumberOfEmployees\": 1.5e3"), "Numbers stay as Salesforce wrote them")
        #expect(text.contains("\"Contacts\": {\n      \"totalSize\": 1"), "Subquery results keep their shape")

        // It parses back to the same records, less the URLs.
        let parsed = try JSONValue.parse(Data(text.utf8))
        #expect(parsed.array?.count == 2)
        #expect(parsed.array?.first?["Name"]?.string == "Acme \"One\"")
        #expect(parsed.array?.first?["Contacts"]?["records"]?.array?.first?["LastName"]?.string == "Lee")
        #expect(JSONValue.array([]).prettyPrinted() == "[]" && JSONValue.object(JSONObject()).prettyPrinted() == "{}")
    }

    @Test func exportWritesValidJSON() async throws {
        let session = OrgSession(username: "a@example.com", alias: nil, instanceURL: URL(string: "https://example.my.salesforce.com")!, apiVersion: "62.0", accessToken: "unused")
        let client = SalesforceClient(session: session) { session }
        let results = ResultSet(result: QueryResult(json: try JSONValue.parse(Data(json.utf8))))
        let url = FileManager.default.temporaryDirectory.appending(path: "JSONResultsTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = try await ResultsExporter(client: client) { _ in }.paged(results, format: .json, to: url)
        #expect(rows == 2)
        let parsed = try JSONValue.parse(try Data(contentsOf: url))
        #expect(parsed.array?.map { $0["Id"]?.string } == ["001A", "001B"])
    }
}

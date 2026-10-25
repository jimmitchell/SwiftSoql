import Foundation
import Testing
@testable import SwiftSoql

struct DataDictionaryTests {
    private func describe() throws -> SObjectDescribe {
        let json = #"""
        {"name": "Account", "label": "Account", "fields": [
          {"name": "Name", "label": "Account Name", "type": "string", "length": 255, "createable": true, "nillable": false},
          {"name": "AnnualRevenue", "label": "Annual Revenue", "type": "currency", "precision": 18, "scale": 0, "nillable": true, "inlineHelpText": "Yearly | total"},
          {"name": "OwnerId", "label": "Owner ID", "type": "reference", "referenceTo": ["User"], "createable": true, "nillable": false, "defaultedOnCreate": true},
          {"name": "Tier__c", "label": "Tier", "type": "picklist", "length": 255, "custom": true, "nillable": true,
           "picklistValues": [{"value": "Gold", "active": true}, {"value": "Old", "active": false}, {"value": "Silver", "active": true}]},
          {"name": "Score__c", "label": "Score", "type": "double", "precision": 5, "scale": 2, "custom": true, "calculatedFormula": "1 +\n2", "inlineHelpText": "=HYPERLINK(\"http://example.com\")"}
        ]}
        """#
        return SObjectDescribe(json: try #require(try JSONValue.parse(Data(json.utf8)).object))
    }

    @Test func typesIncludeSizes() throws {
        let fields = try describe().fields
        #expect(fields.map(DataDictionary.typeText) == ["string(255)", "currency(18, 0)", "reference(User)", "picklist(255)", "double(5, 2)"])
    }

    @Test func csvHasARowPerField() throws {
        let d = try describe()
        let rows = CSV.rows(DataDictionary.text([d], format: .csv))
        #expect(rows.first == DataDictionary.columns)
        #expect(rows.count == 6)
        #expect(rows[1] == ["Account", "Name", "Account Name", "string(255)", "Yes", "", "", "", "", "", ""])
        #expect(rows[4][9] == "Gold; Silver", "Only active picklist values")
        #expect(rows[5][10] == "1 +\n2")
        #expect(rows[5][8] == "'=HYPERLINK(\"http://example.com\")", "Text a spreadsheet would run as a formula is neutralized")
    }

    @Test func markdownEscapesCells() throws {
        let text = DataDictionary.text([try describe()], format: .markdown)
        #expect(text.hasPrefix("## Account (`Account`)\n\n| Field | Label | Type | Required | Help Text | Picklist Values |\n| --- | --- | --- | --- | --- | --- |\n"))
        #expect(text.contains("| `AnnualRevenue` | Annual Revenue | currency(18, 0) |  | Yearly \\| total |  |"))
    }
}

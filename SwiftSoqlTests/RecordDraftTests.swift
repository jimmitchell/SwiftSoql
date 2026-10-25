import Foundation
import Testing
@testable import SwiftSoql

struct RecordDraftTests {
    private func describe() throws -> SObjectDescribe {
        let json = """
        {"name": "Account", "fields": [
          {"name": "Id", "type": "id", "createable": false, "nillable": false, "defaultedOnCreate": true},
          {"name": "Name", "type": "string", "createable": true, "nillable": false, "nameField": true},
          {"name": "OwnerId", "type": "reference", "createable": true, "nillable": false, "defaultedOnCreate": true, "referenceTo": ["User"]},
          {"name": "Industry", "type": "picklist", "createable": true, "nillable": true},
          {"name": "NumberOfEmployees", "type": "int", "createable": true, "nillable": true},
          {"name": "Active__c", "type": "boolean", "createable": true, "nillable": false, "defaultedOnCreate": true},
          {"name": "Code__c", "type": "string", "createable": true, "nillable": true, "unique": true},
          {"name": "Legacy__c", "type": "string", "createable": true, "nillable": true, "externalId": true},
          {"name": "CreatedDate", "type": "datetime", "createable": false, "nillable": false, "defaultedOnCreate": true}
        ]}
        """
        return SObjectDescribe(json: try #require(try JSONValue.parse(Data(json.utf8)).object))
    }

    @Test func requiredFieldsComeFirst() throws {
        let d = try describe()
        let names = RecordDraft.fields(of: d).map(\.name)
        #expect(names.first == "Name")
        #expect(!names.contains("Id") && !names.contains("CreatedDate"))
        #expect(d.fields.filter(\.isRequiredOnCreate).map(\.name) == ["Name"], "Defaulted fields and checkboxes aren't required")
    }

    @Test func valuesAndMissingFields() throws {
        let d = try describe()
        var draft = RecordDraft(sobject: "Account")
        #expect(draft.missingFields(d).map(\.name) == ["Name"])
        draft.values = ["Name": "Acme", "NumberOfEmployees": "250", "Industry": "", "Active__c": "true"]
        #expect(draft.missingFields(d).isEmpty)
        let values = try draft.fieldValues(d)
        #expect(values.keys.sorted() == ["Active__c", "Name", "NumberOfEmployees"], "Empty text isn't sent")
        #expect(values["NumberOfEmployees"] == .number("250") && values["Active__c"] == .bool(true))
        draft.values["NumberOfEmployees"] = "lots"
        #expect(throws: InvalidFieldValue.self) { try draft.fieldValues(d) }
    }

    @Test func cloneCopiesCreateableFieldsExceptUniqueOnes() throws {
        let d = try describe()
        let record = try #require(try JSONValue.parse(Data("""
        {"attributes": {"type": "Account"}, "Id": "001000000000001AAA", "Name": "Acme", "OwnerId": "005000000000001AAA",
         "Industry": "Banking", "NumberOfEmployees": 250, "Active__c": false, "Code__c": "A-1", "Legacy__c": "L1",
         "CreatedDate": "2026-01-01T00:00:00.000+0000"}
        """.utf8)).object)
        let draft = RecordDraft(cloning: record, id: "001000000000001AAA", describe: d)
        #expect(draft.clonedFrom == "001000000000001AAA" && draft.sobject == "Account")
        #expect(draft.values == ["Name": "Acme", "OwnerId": "005000000000001AAA", "Industry": "Banking", "NumberOfEmployees": "250", "Active__c": "false"])
    }
}

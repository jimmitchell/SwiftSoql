import Foundation
import Testing
@testable import SwiftSoql

struct ImportTests {
    private func describe() throws -> SObjectDescribe {
        let json = """
        {"name": "Account", "fields": [
          {"name": "Id", "label": "Account ID", "type": "id", "nillable": false, "defaultedOnCreate": true},
          {"name": "Name", "label": "Account Name", "type": "string", "createable": true, "updateable": true},
          {"name": "NumberOfEmployees", "label": "Employees", "type": "int", "createable": true, "updateable": true, "nillable": true},
          {"name": "Legacy__c", "label": "Legacy Id", "type": "string", "createable": true, "updateable": true, "nillable": true, "externalId": true},
          {"name": "CreatedDate", "label": "Created Date", "type": "datetime", "nillable": false, "defaultedOnCreate": true}
        ]}
        """
        return SObjectDescribe(json: try #require(try JSONValue.parse(Data(json.utf8)).object))
    }

    @Test func parsesQuotedValuesLineEndingsAndBOM() {
        let text = "\u{FEFF}Name,Notes\r\n\"Acme, Inc.\",\"Said \"\"hi\"\"\nthen left\"\r\n\r\nGlobex,\rInitech,x"
        #expect(CSV.rows(text) == [["Name", "Notes"], ["Acme, Inc.", "Said \"hi\"\nthen left"], ["Globex", ""], ["Initech", "x"]])
        #expect(CSV.line(["a\"b", "c"], lineEnding: "\n") == "\"a\"\"b\",\"c\"\n")
    }

    @Test func fileRowsAreSquaredToTheHeader() throws {
        let file = try ImportFile(name: "a.csv", text: "Name, Employees \nAcme\nGlobex,5,extra")
        #expect(file.header == ["Name", "Employees"])
        #expect(file.rows == [["Acme", ""], ["Globex", "5"]])
        #expect(throws: ImportFile.Unreadable.self) { try ImportFile(name: "b.csv", text: "Name\n") }
    }

    @Test func mapsByNameOrLabelAndRemembers() throws {
        let d = try describe()
        let header = ["ID", "Account Name", "employees", "Whatever"]
        let mapping = ImportMapping.automatic(header: header, fields: ImportPlan.mappableFields(d, operation: .update))
        #expect(mapping.fields == ["Id", "Name", "NumberOfEmployees", nil])
        #expect(ImportMapping.automatic(header: header, fields: ImportPlan.mappableFields(d, operation: .insert)).fields[0] == nil, "Inserts can't set Id")

        let store = try #require(UserDefaults(suiteName: "ImportTests-\(UUID().uuidString)"))
        var changed = mapping
        changed.fields[3] = "Legacy__c"
        changed.remember(sobject: "Account", header: header, store: store)
        #expect(ImportMapping.remembered(sobject: "account", header: header, allowed: ["Id", "Name", "Legacy__c"], store: store)?.fields == ["Id", "Name", nil, "Legacy__c"])
        #expect(ImportMapping.remembered(sobject: "Account", header: ["Other"], allowed: [], store: store) == nil)
    }

    @Test func problemsBeforeRunning() throws {
        let d = try describe()
        var plan = ImportPlan(describe: d, operation: .update, mapping: ImportMapping(fields: [nil, "Name"]))
        #expect(plan.problem?.contains("Id") == true)
        plan.mapping.fields = ["Id", "Id"]
        #expect(plan.problem?.contains("More than one") == true)
        plan.operation = .insert
        plan.mapping.fields = ["NumberOfEmployees", nil]
        #expect(plan.problem?.contains("Name") == true)
        plan.operation = .upsert
        plan.matchField = "Legacy__c"
        plan.mapping.fields = ["Legacy__c", "Name"]
        #expect(plan.problem == nil)
    }

    @Test func deletesNeedOnlyIds() throws {
        let d = try describe()
        #expect(ImportPlan.mappableFields(d, operation: .delete).map(\.name) == ["Id"])
        var plan = ImportPlan(describe: d, operation: .hardDelete, mapping: ImportMapping(fields: [nil, "Name"]))
        #expect(plan.problem?.contains("hard delete") == true)
        plan.mapping.fields = ["Id", nil]
        #expect(plan.problem == nil)
        #expect(try plan.uploadValues(["001000000000001AAA", "Acme"]) == ["001000000000001AAA"])
        #expect(throws: InvalidFieldValue.self) { try plan.record(["", "Acme"]) }
    }

    @Test func rowsBecomeRecordsAndUploads() throws {
        let d = try describe()
        var plan = ImportPlan(describe: d, operation: .update, mapping: ImportMapping(fields: ["Id", "Name", "NumberOfEmployees", nil]))
        let row = ["001000000000001AAA", "Acme", "", "ignored"]
        #expect(try plan.record(row).keys == ["Id", "Name"], "Empty cells are left out")
        #expect(try plan.uploadValues(row) == ["001000000000001AAA", "Acme", ""])
        plan.clearEmpty = true
        #expect(try plan.record(row)["NumberOfEmployees"] == .null)
        #expect(try plan.uploadValues(row) == ["001000000000001AAA", "Acme", "#N/A"])
        #expect(throws: InvalidFieldValue.self) { try plan.record(["", "Acme", "", ""]) }
        #expect(throws: InvalidFieldValue.self) { try plan.record(["001000000000001AAA", "Acme", "many", ""]) }
        #expect(plan.uploadHeader == ["Id", "Name", "NumberOfEmployees"])
        plan.operation = .upsert
        #expect(try plan.record(["", "Acme", "", ""]).keys == ["Name", "NumberOfEmployees"], "An upsert on Id creates rows without one")
    }

    @Test func outcomeCountsAndCSV() throws {
        var outcome = ImportOutcome(header: ["Name"])
        outcome.add(["Acme"], row: 1, id: "001A", created: true, error: nil)
        outcome.add(["Globex"], row: 2, id: "001B", created: false, error: nil)
        outcome.add(["=Bad"], row: 3, id: nil, created: false, error: "REQUIRED_FIELD_MISSING: Name")
        #expect(outcome.created == 1 && outcome.updated == 1 && outcome.failed == 1)
        #expect(outcome.errors.first?.row == 3)
        #expect(outcome.csv == "\"Name\",\"Id\",\"Created\",\"Error\"\r\n\"Acme\",\"001A\",\"true\",\"\"\r\n\"Globex\",\"001B\",\"false\",\"\"\r\n\"=Bad\",\"\",\"\",\"REQUIRED_FIELD_MISSING: Name\"\r\n", "Values are kept as they were, so the file can be imported again")

        let json = try JSONValue.parse(Data(#"[{"id":"001A","success":true,"errors":[],"created":true},{"success":false,"errors":[{"statusCode":"DUPLICATE_VALUE","message":"dup"}]}]"#.utf8))
        let results = (json.array ?? []).map(SaveResult.init)
        #expect(results[0].id == "001A" && results[0].created && results[1].message == "DUPLICATE_VALUE: dup")
    }
}

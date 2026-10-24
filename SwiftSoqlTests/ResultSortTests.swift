import Foundation
import Testing
@testable import SwiftSoql

struct ResultSortTests {
    private func resultSet() throws -> ResultSet {
        let json = #"""
        {"totalSize":6,"done":false,"nextRecordsUrl":"/next","records":[
         {"attributes":{"type":"Account"},"Name":"Item 10","Amount":100.5,"Active":true,"Owner":{"attributes":{"type":"User"},"Name":"zed"}},
         {"attributes":{"type":"Account"},"Name":"Item 2","Amount":-3,"Active":false,"Owner":{"attributes":{"type":"User"},"Name":"Amy"}},
         {"attributes":{"type":"Account"},"Name":null,"Amount":null,"Active":true,"Owner":null},
         {"attributes":{"type":"Account"},"Name":"item 1","Amount":20,"Active":false,"Owner":{"attributes":{"type":"User"},"Name":"bob"}}
        ]}
        """#
        return ResultSet(result: QueryResult(json: try JSONValue.parse(Data(json.utf8))))
    }

    private func names(_ rs: ResultSet) -> [String] {
        rs.rows.map { $0.record["Name"]?.string ?? "–" }
    }

    @Test func textInNaturalOrderWithBlanksLast() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Name")])
        #expect(names(rs) == ["item 1", "Item 2", "Item 10", "–"])
        rs.sort(by: [ResultSortComparator(column: "Name", order: .reverse)])
        #expect(names(rs) == ["Item 10", "Item 2", "item 1", "–"])
    }

    @Test func numbersAsNumbers() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Amount")])
        #expect(names(rs) == ["Item 2", "item 1", "Item 10", "–"])
    }

    @Test func relatedFields() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Owner.Name")])
        #expect(names(rs) == ["Item 2", "item 1", "Item 10", "–"])
    }

    @Test func tiesKeepLoadedOrder() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Active")])
        #expect(names(rs) == ["Item 2", "item 1", "Item 10", "–"])
    }

    @Test func backToLoadedOrder() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Name")])
        rs.sort(by: [])
        #expect(names(rs) == ["Item 10", "Item 2", "–", "item 1"])
    }

    @Test func appendedRowsAreSortedIn() throws {
        var rs = try resultSet()
        rs.sort(by: [ResultSortComparator(column: "Name")])
        let more = #"{"totalSize":6,"done":true,"records":[{"attributes":{"type":"Account"},"Name":"Item 3"},{"attributes":{"type":"Account"},"Name":"a"}]}"#
        rs.append(QueryResult(json: try JSONValue.parse(Data(more.utf8))))
        #expect(names(rs) == ["a", "item 1", "Item 2", "Item 3", "Item 10", "–"])
    }

    @Test func removingRowsUpdatesTotals() throws {
        var rs = try resultSet()
        let ids = Set(rs.rows.prefix(2).map(\.id))
        rs.checkedRows = ids
        rs.removeRows(ids)
        #expect(rs.rows.count == 2 && rs.totalSize == 4 && rs.checkedRows.isEmpty)
    }

    @Test func updatesReachRelatedRecordsAndSubqueries() throws {
        let json = #"""
        {"totalSize":1,"done":true,"records":[{"attributes":{"type":"Account"},"Id":"001A","Name":"Acme",
          "Contacts":{"totalSize":1,"done":true,"records":[{"attributes":{"type":"Contact"},"Id":"003B","LastName":"Old"}]}}]}
        """#
        var rs = ResultSet(result: QueryResult(json: try JSONValue.parse(Data(json.utf8))))
        rs.applyUpdate(recordID: "003B", field: "LastName", value: .string("New"))
        #expect(rs.rows[0].record.value(atPath: "Contacts")?["records"]?.array?.first?["LastName"] == .string("New"))
        rs.applyUpdate(recordID: "001A", field: "Missing", value: .string("x"))
        #expect(rs.rows[0].record["Missing"] == nil)
    }
}

import Foundation
import Testing
@testable import SwiftSoql

struct BulkExportTests {
    @Test func whichQueriesCanUseTheBulkAPI() {
        #expect(BulkExport.canRun("SELECT Id, Name, Owner.Name FROM Account WHERE Name LIKE 'A%' ORDER BY Name"))
        #expect(BulkExport.canRun("SELECT Id FROM Account WHERE Id IN (SELECT AccountId FROM Contact)") == false)
        #expect(!BulkExport.canRun("SELECT Id, (SELECT Id FROM Contacts) FROM Account"))
        #expect(!BulkExport.canRun("SELECT COUNT(Id) FROM Account"))
        #expect(!BulkExport.canRun("SELECT Industry, MAX(AnnualRevenue) FROM Account GROUP BY Industry"))
        #expect(!BulkExport.canRun("SELECT TYPEOF What WHEN Account THEN Name END FROM Event"))
        #expect(!BulkExport.canRun("SELECT Id FROM Account OFFSET 10"))
        #expect(!BulkExport.canRun("SELECT Id FROM Account FOR VIEW"))
        #expect(!BulkExport.canRun("FIND {acme}"))
    }

    @Test func rewritesBulkCSV() {
        let bulk = "\"Id\",\"Description\",\"N\"\n\"1\",\"=SUM(1,2)\",\"5\"\n\"2\",\"Says \"\"hi\"\"\nand more\",\"-42\"\n\"3\",,\"\"\n"
        let first = ResultsExport.bulkCSV(Data(bulk.utf8), includeHeader: true)
        #expect(first.records == 3)
        #expect(first.text == "\"Id\",\"Description\",\"N\"\r\n\"1\",\"'=SUM(1,2)\",\"5\"\r\n\"2\",\"Says \"\"hi\"\"\nand more\",\"-42\"\r\n\"3\",\"\",\"\"\r\n")
        let later = ResultsExport.bulkCSV(Data(bulk.utf8), includeHeader: false)
        #expect(later.records == 3 && !later.text.hasPrefix("\"Id\""))
    }
}

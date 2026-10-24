import Foundation
import Testing
@testable import SwiftSoql

struct SoqlFormatterTests {
    /// Every SOQL query in the golden files keeps its tokens, and formatting twice changes nothing.
    @Test(arguments: SoqlGoldenTests.files)
    func keepsTokensAndIsIdempotent(_ file: String) throws {
        let text = try String(contentsOf: try SoqlGoldenTests.resource(file, "txt"), encoding: .utf8)
        var atStart = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { atStart = line.isEmpty }
            guard atStart, !line.isEmpty, let formatted = SoqlFormatter.format(String(line)) else { continue }
            #expect(SoqlFormatter.lex(formatted) == SoqlFormatter.lex(String(line)), "\(line)")
            #expect(SoqlFormatter.format(formatted) == formatted, "\(line)")
        }
    }

    @Test func layout() {
        let query = "select id, name, (select id, lastname, email from contacts where email != null order by lastname), owner.name, billingcity, industry from account where industry = 'Energy' and (rating = 'Hot' or rating = 'Warm') order by name limit 10"
        #expect(SoqlFormatter.format(query) == """
            select id,
                   name,
                   (select id, lastname, email
                    from contacts
                    where email != null
                    order by lastname),
                   owner.name,
                   billingcity,
                   industry
            from account
            where industry = 'Energy'
              and (rating = 'Hot' or rating = 'Warm')
            order by name
            limit 10
            """)
    }

    @Test func shortQueriesStayCompact() {
        #expect(SoqlFormatter.format("SELECT Id, Name FROM Account WHERE Name = 'x' LIMIT 5") == "SELECT Id, Name\nFROM Account\nWHERE Name = 'x'\nLIMIT 5")
        #expect(SoqlFormatter.format("SELECT COUNT(Id) cnt FROM Opportunity GROUP BY StageName") == "SELECT COUNT(Id) cnt\nFROM Opportunity\nGROUP BY StageName")
    }

    @Test func longTypeOfBreaksAtWhen() {
        let formatted = SoqlFormatter.format("SELECT TYPEOF What WHEN Account THEN Phone, NumberOfEmployees WHEN Opportunity THEN Amount, CloseDate ELSE Name, Email END, Subject FROM Event")
        #expect(formatted == """
            SELECT TYPEOF What
                       WHEN Account THEN Phone, NumberOfEmployees
                       WHEN Opportunity THEN Amount, CloseDate
                       ELSE Name, Email
                   END,
                   Subject
            FROM Event
            """)
    }

    @Test func leavesOtherTextAlone() {
        #expect(SoqlFormatter.format("FIND {acme} IN ALL FIELDS RETURNING Account(Id)") == nil)
        #expect(SoqlFormatter.format("SELECT Id FROM Account WHERE Name = 'unterminated") == nil)
        #expect(SoqlFormatter.format("SELECT (Id FROM Account") == nil)
    }
}

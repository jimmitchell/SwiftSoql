import Foundation
import Testing
@testable import SwiftSoql

struct ApexSourceTests {
    @Test func findsInlineQueriesOutsideStringsAndComments() {
        let code = """
        // [SELECT Id FROM Ignored]
        String s = '[SELECT Id FROM AlsoIgnored]';
        List<Account> a = [SELECT Id, (SELECT Id FROM Contacts) FROM Account WHERE Id IN :ids];
        Integer[] n = new Integer[3];
        /* [SELECT x FROM y] */ List<List<SObject>> r = [FIND 'acme' RETURNING Account];
        """ as NSString
        let queries = ApexSource.inlineQueries(in: code).map { code.substring(with: $0) }
        #expect(queries == ["SELECT Id, (SELECT Id FROM Contacts) FROM Account WHERE Id IN :ids", "FIND 'acme' RETURNING Account"])
    }

    @Test func masksBindVariablesWithoutMovingAnything() {
        let query = "SELECT Id FROM Account WHERE Id IN :ids AND Name = :acc.Name LIMIT :n"
        let masked = ApexSource.maskingBinds(in: query)
        #expect(masked.query == "SELECT Id FROM Account WHERE Id IN (1)  AND Name = null      LIMIT 1 ")
        #expect(masked.query.utf16.count == query.utf16.count)
        #expect(masked.binds.map { (query as NSString).substring(with: $0) } == [":ids", ":acc.Name", ":n"])
    }

    @Test func maskedBindsPassTheSOQLChecker() {
        let masked = ApexSource.maskingBinds(in: "SELECT Id FROM Account WHERE Id IN :ids AND Name = :acc.Name LIMIT :limit")
        let tokens = SoqlAnalyzer().parseAndResolve(masked.query)
        // Without a describer the SObject itself is unknown; the binds must not be errors.
        let errors = tokens.tokens.filter { $0.type == .error }.map(\.tokenTxt)
        #expect(errors == ["Account"])
    }

    @Test func sobjectVariables() {
        let code = "Account a = new Account(); for (Contact c : contacts) {} List<Account> accs; Integer i = 1;"
        let types = ApexSource.sobjectVariables(in: code) { ["account": "Account", "contact": "Contact"][$0.lowercased()] }
        #expect(types == ["a": "Account", "c": "Contact"])
    }

    @Test func completionContexts() {
        func context(_ text: String) -> ApexSource.CompletionContext {
            let ns = text as NSString
            // The partial word is everything after the last space, dot or parenthesis.
            let start = (text.lastIndex { " .(,".contains($0) }.map { text.distance(from: text.startIndex, to: $0) + 1 }) ?? 0
            return ApexSource.completionContext(in: ns, wordRange: NSRange(location: start, length: ns.length - start))
        }
        #expect(context("a.Na") == .afterDot("a"))
        #expect(context("System.debug(acc.") == .afterDot("acc"))
        #expect(context("insert new Account(Name = 'x', Indu") == .newObject("Account"))
        #expect(context("Integer x = Math.max(1, Acc") == .word)
        #expect(context("Acc") == .word)
    }

    @Test func logLineFilters() {
        let model = ApexModel()
        #expect(ApexModel.LogLines.debug.includes("12:00|USER_DEBUG|[4]|DEBUG|hi"))
        #expect(ApexModel.LogLines.soql.includes("12:00|SOQL_EXECUTE_BEGIN|[2]|Aggregations:0|SELECT Id FROM User"))
        #expect(ApexModel.LogLines.dml.includes("12:00|DML_BEGIN|[3]|Op:Insert"))
        #expect(ApexModel.LogLines.exceptions.includes("12:00|FATAL_ERROR|System.MathException"))
        #expect(!ApexModel.LogLines.debug.includes("12:00|SOQL_EXECUTE_END|[2]|Rows:1"))
        model.reveal(line: 4)
        let first = model.revealLine
        model.reveal(line: 4)
        #expect(first?.line == 4 && model.revealLine?.id != first?.id, "Clicking the same line again still moves to it")
    }
}

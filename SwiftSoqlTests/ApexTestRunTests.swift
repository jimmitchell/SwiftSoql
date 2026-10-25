import Foundation
import Testing
@testable import SwiftSoql

struct ApexTestRunTests {
    @Test func findsTestClasses() {
        #expect(ApexTestClass.hasTests("@IsTest\nprivate class AccountTest {}"))
        #expect(ApexTestClass.hasTests("public class Old { static testMethod void t() {} }"))
        #expect(!ApexTestClass.hasTests("public class Account { }"))
    }

    @Test func readsStackTraces() {
        let trace = "Class.AccountService.save: line 42, column 1\nClass.AccountTest.testSave: line 12, column 1\nAnonymous: line 3"
        #expect(StackFrame.frames(in: trace) == [StackFrame(className: "AccountService", line: 42), StackFrame(className: "AccountTest", line: 12)])
    }

    private func object(_ json: String) throws -> JSONObject {
        try #require(try JSONValue.parse(Data(json.utf8)).object)
    }

    @Test func coverageAndQueueStatus() throws {
        let coverage = try #require(ClassCoverage(json: try object(#"{"ApexClassOrTriggerId": "01p1", "ApexClassOrTrigger": {"Name": "A"}, "NumLinesCovered": 3, "NumLinesUncovered": 1}"#)))
        #expect(coverage.total == 4 && coverage.fraction == 0.75)
        let empty = try #require(ClassCoverage(json: try object(#"{"ApexClassOrTriggerId": "01p2", "NumLinesCovered": 0, "NumLinesUncovered": 0}"#)))
        #expect(empty.fraction == nil)
        let item = try #require(TestQueueItem(json: try object(#"{"Id": "709", "ApexClass": {"Name": "ATest"}, "Status": "Processing", "ExtendedStatus": "(1/2)"}"#)))
        #expect(!item.isFinished && item.className == "ATest")
    }
}

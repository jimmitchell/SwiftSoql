import Foundation

/// An Apex class with tests in it.
nonisolated struct ApexTestClass: Identifiable, Sendable, Equatable {
    let id: String
    let name: String

    /// Whether Apex source declares tests: an @IsTest annotation or the old testMethod keyword.
    static func hasTests(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("@istest") || lowered.contains("testmethod")
    }
}

/// One class of a test run, as it waits, runs and finishes.
nonisolated struct TestQueueItem: Identifiable, Sendable, Equatable {
    let id: String
    let className: String
    /// Holding, Queued, Preparing, Processing, Completed, Failed or Aborted.
    let status: String
    /// Progress such as "(2/3)", and why it failed.
    let extendedStatus: String

    static let fields = "Id, ApexClass.Name, Status, ExtendedStatus"

    init?(json: JSONObject) {
        guard let id = json["Id"]?.string else { return nil }
        self.id = id
        className = json["ApexClass"]?["Name"]?.string ?? ""
        status = json["Status"]?.string ?? ""
        extendedStatus = json["ExtendedStatus"]?.string ?? ""
    }

    var isFinished: Bool { ["Completed", "Failed", "Aborted"].contains(status) }
}

/// The outcome of one test method.
nonisolated struct ApexTestMethodResult: Identifiable, Sendable, Equatable {
    let id: String
    let classID: String
    let className: String
    let methodName: String
    /// Pass, Fail, CompileFail or Skip.
    let outcome: String
    let message: String
    let stackTrace: String
    let runTimeMilliseconds: Int

    static let fields = "Id, ApexClassId, ApexClass.Name, MethodName, Outcome, Message, StackTrace, RunTime"

    init?(json: JSONObject) {
        guard let id = json["Id"]?.string else { return nil }
        self.id = id
        classID = json["ApexClassId"]?.string ?? ""
        className = json["ApexClass"]?["Name"]?.string ?? ""
        methodName = json["MethodName"]?.string ?? ""
        outcome = json["Outcome"]?.string ?? ""
        message = json["Message"]?.string ?? ""
        stackTrace = json["StackTrace"]?.string ?? ""
        runTimeMilliseconds = json["RunTime"]?.int ?? 0
    }

    var passed: Bool { outcome == "Pass" }
}

/// How much of a class or trigger the org's tests cover.
nonisolated struct ClassCoverage: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let covered: Int
    let uncovered: Int

    init?(json: JSONObject) {
        guard let id = json["ApexClassOrTriggerId"]?.string else { return nil }
        self.id = id
        name = json["ApexClassOrTrigger"]?["Name"]?.string ?? id
        covered = json["NumLinesCovered"]?.int ?? 0
        uncovered = json["NumLinesUncovered"]?.int ?? 0
    }

    var total: Int { covered + uncovered }
    /// The share of lines covered, from 0 to 1, or nil if there's nothing to cover.
    var fraction: Double? { total > 0 ? Double(covered) / Double(total) : nil }
}

/// A frame of a test's stack trace, such as "Class.AccountTest.testInsert: line 12, column 1".
nonisolated struct StackFrame: Equatable {
    let className: String
    let line: Int

    /// The frames that point into classes, in order.
    static func frames(in trace: String) -> [StackFrame] {
        trace.matches(of: #/Class\.([A-Za-z0-9_]+)(?:\.[A-Za-z0-9_<>]+)*: line (\d+)/#).compactMap { match in
            Int(match.output.2).map { StackFrame(className: String(match.output.1), line: $0) }
        }
    }
}

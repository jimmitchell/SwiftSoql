import Foundation
import Observation

/// The Tests workspace: the org's test classes, the latest test run and its results, code
/// coverage, and a class's source with its covered lines.
@Observable
final class TestsModel {
    private(set) var classes: [ApexTestClass] = []
    private(set) var hasLoadedClasses = false
    /// The classes checked to run.
    var checked: Set<ApexTestClass.ID> = []

    /// The run in progress or last finished.
    private(set) var jobID: String?
    private(set) var queue: [TestQueueItem] = []
    private(set) var results: [ApexTestMethodResult] = []
    private(set) var isRunning = false
    var selectedResultID: ApexTestMethodResult.ID?

    private(set) var coverage: [ClassCoverage] = []

    /// A class's source, open in a sheet.
    struct Source: Identifiable {
        let id: String
        let name: String
        let body: String
        let covered: Set<Int>
        let uncovered: Set<Int>
        /// A line to show first, such as where a test failed.
        let line: Int?
    }
    var source: Source?

    func reset() {
        classes = []
        hasLoadedClasses = false
        checked = []
        jobID = nil
        queue = []
        results = []
        isRunning = false
        selectedResultID = nil
        coverage = []
        source = nil
    }

    var selectedResult: ApexTestMethodResult? { results.first { $0.id == selectedResultID } }
    var passed: Int { results.count { $0.passed } }
    var failed: Int { results.count { !$0.passed } }
    var finishedClasses: Int { queue.count { $0.isFinished } }

    func loadClasses(using client: SalesforceClient) async throws {
        classes = try await client.apexTestClasses()
        hasLoadedClasses = true
        checked.formIntersection(classes.map(\.id))
    }

    /// Loads coverage, least covered first; classes with nothing to cover go last.
    func loadCoverage(using client: SalesforceClient) async throws {
        coverage = try await client.codeCoverage().sorted { a, b in
            (a.fraction ?? 2) != (b.fraction ?? 2) ? (a.fraction ?? 2) < (b.fraction ?? 2) : a.name < b.name
        }
    }

    /// Runs the checked classes' tests, or with `allLocal`, every test outside managed
    /// packages, checking on them every 3 seconds until they finish or are stopped.
    func run(allLocal: Bool, using client: SalesforceClient, didCallAPI: () async -> Void) async throws {
        guard !isRunning, allLocal || !checked.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }
        queue = []
        results = []
        selectedResultID = nil
        let ids = allLocal ? [] : classes.map(\.id).filter(checked.contains)
        let job = try await client.runTests(classIDs: ids)
        jobID = job
        var checks = 0
        repeat {
            try await Task.sleep(for: .seconds(3))
            queue = try await client.testQueue(jobID: job)
            results = try await client.testResults(jobID: job)
            await didCallAPI()
            checks += 1
            if queue.isEmpty, checks >= 20 {
                throw SalesforceError(statusCode: 200, errorCode: "", message: "Salesforce didn't queue the tests within a minute.")
            }
        } while queue.isEmpty || !queue.allSatisfy(\.isFinished)
        try await loadCoverage(using: client)
    }

    /// Stops the classes of the current run that haven't finished.
    func stop(using client: SalesforceClient) async throws {
        try await client.abortTests(queue)
    }

    /// Opens a class's source with its coverage, optionally at a line.
    func openSource(classID: String, line: Int? = nil, using client: SalesforceClient) async throws {
        let (name, body) = try await client.apexSource(id: classID)
        let lines = try await client.coveredLines(classID: classID)
        source = Source(id: classID, name: name, body: body, covered: lines.covered, uncovered: lines.uncovered, line: line)
    }

    /// The Id of a class named in a stack trace, if it's a test class or has coverage.
    func classID(named name: String) -> String? {
        classes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            ?? coverage.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }
}

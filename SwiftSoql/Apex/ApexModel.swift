import Foundation
import Observation

/// The anonymous Apex workspace: the code, the log levels, and the runs so far, newest first.
@Observable
final class ApexModel {
    var code = AppDefaults.store.string(forKey: "apex") ?? "System.debug('Hello from ' + UserInfo.getUserName());"
    private(set) var runs: [ApexExecution] = []
    var selectedRunID: ApexExecution.ID?
    private(set) var isRunning = false
    /// Shows only the log lines that contain this text.
    var logFilter = ""
    /// Which kind of log lines to show.
    var logLines = LogLines.all
    /// A line of the code to move to, set when a line reference in the log is clicked.
    private(set) var revealLine: LineRequest?

    /// The kinds of debug log lines the log can be narrowed to.
    enum LogLines: String, CaseIterable, Identifiable {
        case all = "All"
        case debug = "Debug"
        case soql = "SOQL"
        case dml = "DML"
        case exceptions = "Exceptions"

        var id: String { rawValue }

        func includes(_ line: Substring) -> Bool {
            switch self {
            case .all: true
            case .debug: line.contains("|USER_DEBUG|")
            case .soql: line.contains("|SOQL_EXECUTE_")
            case .dml: line.contains("|DML_")
            case .exceptions: line.contains("|EXCEPTION_THROWN|") || line.contains("|FATAL_ERROR|")
            }
        }
    }

    /// A request to move the editor to a line; the id makes repeated clicks on one line count.
    struct LineRequest: Equatable {
        let line: Int
        let id = UUID()
    }

    func reveal(line: Int) {
        revealLine = LineRequest(line: line)
    }

    var logLevels: [ApexLogCategory: ApexLogLevel] {
        didSet {
            for (category, level) in logLevels {
                AppDefaults.store.set(level.rawValue, forKey: Self.defaultsKey(category))
            }
        }
    }

    init() {
        var levels: [ApexLogCategory: ApexLogLevel] = [:]
        for category in ApexLogCategory.allCases {
            levels[category] = AppDefaults.store.string(forKey: Self.defaultsKey(category)).flatMap(ApexLogLevel.init) ?? category.defaultLevel
        }
        logLevels = levels
    }

    private static func defaultsKey(_ category: ApexLogCategory) -> String {
        "apexLogLevel.\(category.rawValue)"
    }

    var selectedRun: ApexExecution? {
        runs.first { $0.id == selectedRunID }
    }

    /// The most recent run, if it failed on code that is still in the editor, for marking the error.
    var currentError: ApexExecution? {
        guard let run = runs.first, !run.success, run.code == code, run.line > 0 else { return nil }
        return run
    }

    /// Runs the code in the editor and selects the new run.
    func execute(using client: SalesforceClient) async throws {
        let code = code
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        AppDefaults.store.set(code, forKey: "apex")
        let run = try await client.executeAnonymous(code, logLevels: logLevels)
        runs.insert(run, at: 0)
        selectedRunID = run.id
    }

    func clearRuns() {
        runs = []
        selectedRunID = nil
    }

    /// The selected run's log, filtered.
    var displayedLog: String {
        guard let log = selectedRun?.debugLog else { return "" }
        let filter = logFilter.trimmingCharacters(in: .whitespaces)
        guard logLines != .all || !filter.isEmpty else { return log }
        return log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                logLines.includes(line)
                    && (filter.isEmpty || line.localizedCaseInsensitiveContains(filter))
            }
            .joined(separator: "\n")
    }
}

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
    /// Shows only System.debug output.
    var showDebugOnly = false

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
        guard showDebugOnly || !filter.isEmpty else { return log }
        return log.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                (!showDebugOnly || line.contains("|USER_DEBUG|"))
                    && (filter.isEmpty || line.localizedCaseInsensitiveContains(filter))
            }
            .joined(separator: "\n")
    }
}

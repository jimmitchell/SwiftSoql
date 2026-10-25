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
    /// The selection or insertion point in the editor. Execute runs only selected code.
    var selectedRange: NSRange?
    /// Set to show the sheet for managing snippets.
    var isManagingSnippets = false
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
        guard let run = runs.first, !run.success, (run.editorCode ?? run.code) == code, run.line > 0 else { return nil }
        return run
    }

    /// The selected part of the code, if any.
    var selectedCode: String? {
        let ns = code as NSString
        guard let range = selectedRange, range.length > 0, NSMaxRange(range) <= ns.length else { return nil }
        let text = ns.substring(with: range)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Runs the selected code, or all of it, and selects the new run.
    func execute(using client: SalesforceClient) async throws {
        let code = code
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        AppDefaults.store.set(code, forKey: "apex")
        if let part = selectedCode, let range = selectedRange {
            var run = try await client.executeAnonymous(part, logLevels: logLevels)
            (run.lineOffset, run.columnOffset) = Self.offsets(before: range.location, in: code)
            run.editorCode = code
            runs.insert(run, at: 0)
            selectedRunID = run.id
        } else {
            let run = try await client.executeAnonymous(code, logLevels: logLevels)
            runs.insert(run, at: 0)
            selectedRunID = run.id
        }
    }

    /// The lines before a position in the code, and the columns before it on its line, to turn
    /// a selection run's lines and columns into the editor's.
    static func offsets(before location: Int, in code: String) -> (lines: Int, columns: Int) {
        let before = (code as NSString).substring(to: location)
        let lastLine = before.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return (before.count { $0 == "\n" }, lastLine.utf16.count)
    }

    /// Puts a snippet in place of the selection, or at the insertion point.
    func insert(_ snippet: String) {
        let ns = code as NSString
        let range = selectedRange.flatMap { NSMaxRange($0) <= ns.length ? $0 : nil } ?? NSRange(location: ns.length, length: 0)
        code = ns.replacingCharacters(in: range, with: snippet)
        selectedRange = NSRange(location: range.location + (snippet as NSString).length, length: 0)
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

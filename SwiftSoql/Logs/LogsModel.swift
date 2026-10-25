import Foundation
import Observation

/// The Logs workspace: the org's debug logs, the selected log's text, and the trace flag that
/// makes Salesforce record them.
@Observable
final class LogsModel {
    /// Whose logs are listed.
    enum Scope: Hashable {
        case mine
        case everyone
        case user(id: String, name: String)
    }

    var scope = Scope.mine
    private(set) var logs: [ApexLogEntry] = []
    var selectedLogID: ApexLogEntry.ID?
    /// The selected log's text, once it has loaded.
    private(set) var body: String?
    private(set) var bodyLogID: ApexLogEntry.ID?
    private(set) var isLoading = false
    /// Checks for new logs every few seconds while the workspace shows.
    var isFollowing = false
    /// The users who have logs, for the scope menu.
    private(set) var logUsers: [(id: String, name: String)] = []
    /// This session's user, once known.
    private(set) var myUserID: String?
    /// The trace flag most recently started or found, for the status line.
    private(set) var traceFlag: TraceFlagInfo?
    private(set) var traceFlagUserName: String?
    /// Which log lines to show, and text they must contain.
    var logLines = ApexModel.LogLines.all
    var logFilter = ""

    /// Forgets everything, e.g. on disconnecting.
    func reset() {
        logs = []
        selectedLogID = nil
        body = nil
        bodyLogID = nil
        logUsers = []
        myUserID = nil
        traceFlag = nil
        traceFlagUserName = nil
        isFollowing = false
        scope = .mine
    }

    var selectedLog: ApexLogEntry? { logs.first { $0.id == selectedLogID } }

    /// Fetches the logs for the scope, and the first time, the user's trace flag.
    func refresh(using client: SalesforceClient) async throws {
        isLoading = true
        defer { isLoading = false }
        if myUserID == nil {
            let id = try await client.currentUserID()
            myUserID = id
            if let flag = try await client.traceFlag(for: id) {
                traceFlag = flag
                traceFlagUserName = nil
            }
        }
        let userID: String? = switch scope {
        case .mine: myUserID
        case .everyone: nil
        case .user(let id, _): id
        }
        logs = try await client.apexLogs(userID: userID)
        logUsers = try await client.apexLogUsers()
        if let selectedLogID, !logs.contains(where: { $0.id == selectedLogID }) {
            self.selectedLogID = nil
        }
    }

    /// Fetches the selected log's text, unless it's already showing.
    func loadBody(using client: SalesforceClient) async throws {
        guard let id = selectedLogID, id != bodyLogID else { return }
        body = nil
        let text = try await client.apexLogBody(id)
        guard selectedLogID == id else { return }
        body = text
        bodyLogID = id
    }

    /// Deletes logs, 200 at a time, and removes them from the list.
    func delete(_ ids: [ApexLogEntry.ID], using client: SalesforceClient) async throws {
        for start in stride(from: 0, to: ids.count, by: 200) {
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            let results = try await client.delete(ids: batch)
            let deleted = Set(zip(batch, results).filter { $0.1.success }.map(\.0))
            logs.removeAll { deleted.contains($0.id) }
            if let failure = results.first(where: { !$0.success }) {
                throw SalesforceError(statusCode: 200, errorCode: "", message: failure.message)
            }
        }
        if let selectedLogID, !logs.contains(where: { $0.id == selectedLogID }) {
            self.selectedLogID = nil
        }
    }

    /// Deletes every log of this session's user, not just the ones listed.
    func deleteAllMine(using client: SalesforceClient) async throws {
        guard let myUserID else { return }
        // A few rounds, in case logs keep arriving while they're deleted.
        for _ in 0..<5 {
            let ids = try await client.apexLogs(userID: myUserID, limit: 2000).map(\.id)
            guard !ids.isEmpty else { break }
            try await delete(ids, using: client)
        }
    }

    /// Records debug logs for a user (this session's, by default) for some minutes.
    func startLogging(for user: (id: String, name: String)?, minutes: Int, levels: [ApexLogCategory: ApexLogLevel], using client: SalesforceClient) async throws {
        guard let userID = user?.id ?? myUserID else { return }
        traceFlag = try await client.startTraceFlag(for: userID, until: Date().addingTimeInterval(Double(minutes) * 60), levels: levels)
        traceFlagUserName = user?.name
    }

    func stopLogging(using client: SalesforceClient) async throws {
        guard let traceFlag else { return }
        try await client.stopTraceFlag(traceFlag.id)
        self.traceFlag = nil
        traceFlagUserName = nil
    }

    /// The selected log's text, narrowed to the chosen kind of lines and the filter.
    var displayedBody: String {
        guard let body, bodyLogID == selectedLogID else { return "" }
        let filter = logFilter.trimmingCharacters(in: .whitespaces)
        guard logLines != .all || !filter.isEmpty else { return body }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { logLines.includes($0) && (filter.isEmpty || $0.localizedCaseInsensitiveContains(filter)) }
            .joined(separator: "\n")
    }
}

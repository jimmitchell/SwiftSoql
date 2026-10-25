import Foundation

/// The Logs workspace's actions, reporting failures in an alert. Starting and stopping logging
/// and deleting logs change the org, so a locked window can't.
extension ExplorerModel {
    func refreshLogs() async {
        guard let client else { return }
        do {
            try await logs.refresh(using: client)
        } catch {
            self.error = DisplayedError("Unable to load the debug logs", error)
        }
        await refreshAPIUsage()
    }

    func loadSelectedLog() async {
        guard let client else { return }
        do {
            try await logs.loadBody(using: client)
        } catch is CancellationError {
        } catch {
            self.error = DisplayedError("Unable to load the log", error)
        }
        await refreshAPIUsage()
    }

    func deleteLogs(_ ids: [ApexLogEntry.ID]) async {
        guard let client, canChangeData, !ids.isEmpty else { return }
        do {
            try await logs.delete(ids, using: client)
        } catch {
            self.error = DisplayedError("Unable to delete the logs", error)
        }
        await refreshAPIUsage()
    }

    func deleteAllMyLogs() async {
        guard let client, canChangeData else { return }
        do {
            try await logs.deleteAllMine(using: client)
            try await logs.refresh(using: client)
        } catch {
            self.error = DisplayedError("Unable to delete the logs", error)
        }
        await refreshAPIUsage()
    }

    /// Records debug logs at the Apex workspace's log levels.
    func startLogging(for user: (id: String, name: String)? = nil, minutes: Int) async {
        guard let client, canChangeData else { return }
        do {
            try await logs.startLogging(for: user, minutes: minutes, levels: apex.logLevels, using: client)
        } catch {
            self.error = DisplayedError("Unable to start logging", error)
        }
        await refreshAPIUsage()
    }

    func stopLogging() async {
        guard let client, canChangeData else { return }
        do {
            try await logs.stopLogging(using: client)
        } catch {
            self.error = DisplayedError("Unable to stop logging", error)
        }
        await refreshAPIUsage()
    }

    func findUsers(_ text: String) async -> [(id: String, name: String, username: String)] {
        guard let client else { return [] }
        defer { Task { await refreshAPIUsage() } }
        do {
            return try await client.users(matching: text)
        } catch {
            self.error = DisplayedError("Unable to find users", error)
            return []
        }
    }
}

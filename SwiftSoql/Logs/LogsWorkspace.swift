import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The org's debug logs: a list on the left, the selected log on the right, and controls to
/// choose whose logs show, start logging, follow new logs and delete them.
struct LogsWorkspace: View {
    var model: ExplorerModel
    @Bindable var logs: LogsModel

    @State private var isChoosingUser = false
    @State private var isConfirmingDeleteAll = false

    init(model: ExplorerModel) {
        self.model = model
        logs = model.logs
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                logList
                    .frame(minWidth: 240, idealWidth: 380, maxWidth: 560)
                Divider()
                logPane
                    .frame(minWidth: 220)
            }
        }
        .frame(minWidth: 461, minHeight: 240)
        .task { await model.refreshLogs() }
        .task(id: logs.scope) { await model.refreshLogs() }
        .task(id: logs.selectedLogID) { await model.loadSelectedLog() }
        // While following, check for new logs every 10 seconds: one API request each time.
        .task(id: logs.isFollowing) {
            while logs.isFollowing, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard logs.isFollowing, !Task.isCancelled else { break }
                await model.refreshLogs()
            }
        }
        .sheet(isPresented: $isChoosingUser) {
            UserPicker(model: model)
        }
        .confirmationDialog("Delete all of your debug logs?", isPresented: $isConfirmingDeleteAll) {
            Button("Delete All", role: .destructive) {
                Task { await model.deleteAllMyLogs() }
            }
        } message: {
            Text("This deletes every debug log of yours in \(model.session?.displayName ?? "the org"), not only the ones listed.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Logs", selection: $logs.scope) {
                Text("My Logs").tag(LogsModel.Scope.mine)
                Text("All Users").tag(LogsModel.Scope.everyone)
                if !logs.logUsers.isEmpty {
                    Divider()
                    ForEach(logs.logUsers, id: \.id) { user in
                        Text(user.name).tag(LogsModel.Scope.user(id: user.id, name: user.name))
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("logScope")
            traceFlagStatus
            Spacer(minLength: 0)
            if logs.isLoading {
                ProgressView().controlSize(.small)
            }
            Toggle("Follow", isOn: $logs.isFollowing)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Check for new logs every 10 seconds while this shows (one API request each time)")
            Button {
                Task { await model.refreshLogs() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Menu {
                Button("Delete Selected Log") {
                    if let id = logs.selectedLogID { Task { await model.deleteLogs([id]) } }
                }
                .disabled(logs.selectedLogID == nil)
                Button("Delete All of My Logs…") { isConfirmingDeleteAll = true }
            } label: {
                Image(systemName: "trash")
            }
            .fixedSize()
            .disabled(!model.canChangeData)
            .help(model.isLocked ? "Unlock the window to delete logs" : "Delete logs")
            .accessibilityLabel("Delete Logs")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    @ViewBuilder
    private var traceFlagStatus: some View {
        if let flag = logs.traceFlag, flag.isActive, let expiration = flag.expiration {
            HStack(spacing: 4) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                Text("Logging\(logs.traceFlagUserName.map { " for \($0)" } ?? "") until \(expiration.formatted(date: .omitted, time: .shortened))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { Task { await model.stopLogging() } }
                    .disabled(!model.canChangeData)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("loggingStatus")
        } else {
            Menu("Start Logging") {
                Section("For Me") {
                    ForEach([30, 60, 240, 1440], id: \.self) { minutes in
                        Button(Self.duration(minutes)) { Task { await model.startLogging(minutes: minutes) } }
                    }
                }
                Divider()
                Button("For Another User…") { isChoosingUser = true }
            }
            .fixedSize()
            .disabled(!model.canChangeData)
            .help(model.isLocked ? "Unlock the window to start logging" : "Have Salesforce record debug logs, at the log levels set in the Apex workspace")
            .accessibilityIdentifier("startLogging")
        }
    }

    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "For \(minutes) Minutes" : minutes == 60 ? "For 1 Hour" : "For \(minutes / 60) Hours"
    }

    // MARK: List

    private var logList: some View {
        Table(logs.logs, selection: $logs.selectedLogID) {
            TableColumn("Time") { log in
                Text(log.startTime?.formatted(date: .abbreviated, time: .standard) ?? "")
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 150)
            TableColumn("User") { log in
                Text(log.userName)
            }
            .width(min: 50, ideal: 100)
            TableColumn("Operation") { log in
                Text(log.operation)
                    .help(log.operation)
            }
            .width(min: 60, ideal: 140)
            TableColumn("Status") { log in
                Text(log.status)
                    .foregroundStyle(log.status == "Success" ? .primary : Color.red)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Size") { log in
                Text(ByteCountFormatter.string(fromByteCount: Int64(log.length), countStyle: .file))
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 70)
            TableColumn("Duration") { log in
                Text("\(log.durationMilliseconds.formatted()) ms")
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 80)
        }
        .accessibilityIdentifier("debugLogs")
        .contextMenu(forSelectionType: ApexLogEntry.ID.self) { ids in
            Button(ids.count > 1 ? "Delete \(ids.count) Logs" : "Delete Log") { Task { await model.deleteLogs(Array(ids)) } }
                .disabled(ids.isEmpty || !model.canChangeData)
        }
        .overlay {
            if logs.logs.isEmpty, !logs.isLoading {
                ContentUnavailableView("No Debug Logs", systemImage: "doc.plaintext", description: Text("Salesforce records logs only for users with an active trace flag. Choose Start Logging, then use the org."))
            }
        }
    }

    // MARK: Log

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Show", selection: $logs.logLines) {
                    ForEach(ApexModel.LogLines.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show all log lines, or only System.debug output, queries, DML or exceptions")
                TextField("Filter", text: $logs.logFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70, maxWidth: 220)
                Spacer(minLength: 0)
                Button {
                    saveLog()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(logs.body == nil)
                .help("Save the whole log to a file")
                .accessibilityLabel("Save Log")
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            LogTextView(text: logs.displayedBody)
                .accessibilityIdentifier("debugLogBody")
                .overlay {
                    if logs.selectedLogID == nil {
                        ContentUnavailableView("No Log Selected", systemImage: "doc.plaintext", description: Text("Select a log to read it."))
                    } else if logs.body == nil {
                        ProgressView()
                    }
                }
        }
    }

    private func saveLog() {
        guard let body = logs.body, let log = logs.selectedLog else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log]
        panel.nameFieldStringValue = "\(log.id).log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.error = DisplayedError("Unable to save the log", error)
            }
        }
    }
}

/// Finds an active user to record debug logs for.
private struct UserPicker: View {
    let model: ExplorerModel

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var users: [(id: String, name: String, username: String)] = []
    /// The search the listed users were found with, so "no match" shows only once it's done.
    @State private var searched: String?
    @State private var chosen: String?
    @State private var minutes = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start Logging for a User")
                .font(.headline)
            TextField("Name or username", text: $search)
                .textFieldStyle(.roundedBorder)
            List(users, id: \.id, selection: $chosen) { user in
                VStack(alignment: .leading) {
                    Text(user.name)
                    Text(user.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 220)
            .overlay {
                if users.isEmpty, searched == search {
                    Text("No active users match.")
                        .foregroundStyle(.secondary)
                }
            }
            // Searches as you type, once typing pauses, and picks the first match so a search
            // that finds the one user is ready to start.
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let found = await model.findUsers(search)
                guard !Task.isCancelled else { return }
                users = found
                searched = search
                if !found.contains(where: { $0.id == chosen }) {
                    chosen = found.first?.id
                }
            }
            Picker("For", selection: $minutes) {
                ForEach([30, 60, 240, 1440], id: \.self) { Text(LogsWorkspace.duration($0).replacingOccurrences(of: "For ", with: "")).tag($0) }
            }
            .fixedSize()
            HStack {
                Text("Choose whose actions to log.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Logging") {
                    guard let user = users.first(where: { $0.id == chosen }) else { return }
                    Task {
                        await model.startLogging(for: (user.id, user.name), minutes: minutes)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

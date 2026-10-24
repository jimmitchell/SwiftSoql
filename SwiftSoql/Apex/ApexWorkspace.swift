import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Runs anonymous Apex: the code above, and below it the runs so far beside the selected run's debug log.
struct ApexWorkspace: View {
    var model: ExplorerModel
    @Bindable var apex: ApexModel

    init(model: ExplorerModel) {
        self.model = model
        apex = model.apex
    }

    var body: some View {
        VSplitView {
            ApexEditor(text: $apex.code, error: apex.currentError, model: model, schemaGeneration: model.schemaGeneration, revealLine: apex.revealLine)
                .frame(minHeight: 80, idealHeight: 220)

            // An HSplitView here loops forever laying out the runs table, so the list has a fixed width.
            HStack(spacing: 0) {
                runsList
                    .frame(width: 300)
                Divider()
                logPane
                    .frame(minWidth: 300)
            }
            .frame(minHeight: 120, idealHeight: 450)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ApexLogCategory.allCases) { category in
                        Picker(category.label, selection: Binding {
                            apex.logLevels[category] ?? category.defaultLevel
                        } set: {
                            apex.logLevels[category] = $0
                        }) {
                            ForEach(ApexLogLevel.allCases) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                    }
                } label: {
                    Label("Log Levels", systemImage: "slider.horizontal.3")
                }
                .help("How much each part of the platform writes to the debug log")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.executeApex() }
                } label: {
                    Label("Execute", systemImage: "play.fill")
                }
                .help("Execute Apex (⌘↩)")
                .disabled(apex.isRunning)
            }
        }
    }

    private var runsList: some View {
        VStack(spacing: 0) {
            HStack {
                if apex.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running…")
                } else {
                    Text(apex.runs.isEmpty ? "No runs yet" : "\(apex.runs.count) \(apex.runs.count == 1 ? "run" : "runs")")
                }
                Spacer()
                if let usage = model.apiUsage {
                    Text("API \(usage)")
                        .help("Daily API requests used / limit")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            Table(apex.runs, selection: $apex.selectedRunID) {
                TableColumn("") { run in
                    Image(systemName: run.success ? "checkmark.circle.fill" : run.compiled ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(run.success ? .green : run.compiled ? .orange : .red)
                        .help(run.success ? "Succeeded" : run.compiled ? "Threw an exception" : "Didn't compile")
                        .accessibilityLabel(run.success ? "Succeeded" : run.compiled ? "Threw an exception" : "Didn't compile")
                }
                .width(18)
                TableColumn("Time") { run in
                    Text(run.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 50, ideal: 70)
                TableColumn("Result") { run in
                    Text(summary(run))
                        .lineLimit(1)
                        .help(details(run))
                }
            }
            .accessibilityIdentifier("apexRuns")
            .contextMenu(forSelectionType: ApexExecution.ID.self) { ids in
                Button("Restore Code") {
                    if let run = apex.runs.first(where: { ids.contains($0.id) }) {
                        apex.code = run.code
                    }
                }
                .disabled(ids.count != 1)
                Button("Copy Result") {
                    let text = apex.runs.filter { ids.contains($0.id) }.map(details).joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .disabled(ids.isEmpty)
                Divider()
                Button("Clear All Runs") { apex.clearRuns() }
                    .disabled(apex.runs.isEmpty)
            }
            .overlay {
                if apex.runs.isEmpty && !apex.isRunning {
                    ContentUnavailableView("No Runs", systemImage: "chevron.left.forwardslash.chevron.right", description: Text("Write some Apex and press ⌘↩ to run it."))
                }
            }
        }
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $apex.logLines) {
                    ForEach(ApexModel.LogLines.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show all log lines, or only System.debug output, queries, DML or exceptions")
                TextField("Filter", text: $apex.logFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                if let run = apex.selectedRun {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(run.debugLog.utf8.count), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                Button("Save Log…") { saveLog() }
                    .disabled(apex.selectedRun?.debugLog.isEmpty ?? true)
                    .help("Save the whole debug log to a file")
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 28)
            Divider()
            if let run = apex.selectedRun, !run.success {
                failureBanner(run)
                Divider()
            }
            LogTextView(text: apex.displayedLog) { apex.reveal(line: $0) }
                .accessibilityIdentifier("debugLog")
                .overlay {
                    if let run = apex.selectedRun, run.debugLog.isEmpty {
                        ContentUnavailableView("No Debug Log", systemImage: "doc.plaintext", description: Text(run.compiled ? "Turn up the log levels in the toolbar to see more." : "Code that doesn't compile doesn't run, so there's no log."))
                    }
                }
        }
    }

    private func failureBanner(_ run: ApexExecution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(details(run))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(Color.red.opacity(0.08))
    }

    private func saveLog() {
        guard let run = apex.selectedRun else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log]
        panel.nameFieldStringValue = "Apex Debug Log.log"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try run.debugLog.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.error = DisplayedError("Unable to save the log", error)
            }
        }
    }

    private func summary(_ run: ApexExecution) -> String {
        guard !run.success, run.line > 0 else { return run.resultText }
        return "Line \(run.line): \(run.resultText)"
    }

    /// The full result, with where it happened and the stack trace.
    private func details(_ run: ApexExecution) -> String {
        var lines = [run.resultText]
        if !run.success, run.line > 0 {
            lines.append("Line \(run.line), column \(run.column)")
        }
        if let trace = run.exceptionStackTrace, !trace.isEmpty {
            lines.append(trace)
        }
        return lines.joined(separator: "\n")
    }
}

/// A read-only text view for debug logs, which can run to megabytes. Line references such as
/// `|[4]|` are links that move the editor to that line of the code.
struct LogTextView: NSViewRepresentable {
    let text: String
    var onLine: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("debugLogText")
        // Long log lines scroll sideways rather than wrapping.
        scrollView.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.show(text, in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onLine = onLine
        guard let textView = scrollView.documentView as? NSTextView, context.coordinator.shown != text else { return }
        context.coordinator.show(text, in: textView)
        textView.scrollToBeginningOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLine: onLine)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLine: (Int) -> Void
        fileprivate var shown = ""
        private static let lineReference = try! NSRegularExpression(pattern: #"\|\[(\d+)\]\|"#)

        init(onLine: @escaping (Int) -> Void) {
            self.onLine = onLine
        }

        func show(_ text: String, in textView: NSTextView) {
            shown = text
            let styled = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ])
            for match in Self.lineReference.matches(in: text, range: NSRange(location: 0, length: styled.length)) {
                let number = match.range(at: 1)
                styled.addAttribute(.link, value: "apexline:\((text as NSString).substring(with: number))", range: number)
            }
            textView.textStorage?.setAttributedString(styled)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let link = link as? String, link.hasPrefix("apexline:"), let line = Int(link.dropFirst("apexline:".count)) else { return false }
            onLine(line)
            return true
        }
    }
}

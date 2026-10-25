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

    @AppStorage("apexEditorHeight") private var editorHeight = 220.0

    var body: some View {
        // A VSplitView here kept the window from getting narrower than about 960 points, so the
        // editor and the runs are split by a divider of our own.
        GeometryReader { geometry in
            let heights = 80...max(80, Double(geometry.size.height) - 160)
            VStack(spacing: 0) {
                ApexEditor(text: $apex.code, error: apex.currentError, model: model, schemaGeneration: model.dataSchema.schemaGeneration, revealLine: apex.revealLine)
                    .frame(height: editorHeight.clamped(to: heights))
                SplitDivider(height: $editorHeight, range: heights)
                runsAndLog
            }
        }
        // The runs list and log's minimums, which the GeometryReader doesn't pass on.
        .frame(minWidth: 401, minHeight: 240)
        .sheet(isPresented: $apex.isManagingSnippets) {
            ApexSnippetsSheet(apex: apex)
        }
        .toolbar {
            toolbarContent
        }
    }

    private var runsAndLog: some View {
        // An HSplitView here loops forever laying out the runs table, so this is an HStack,
        // with the runs list between 180 and 300 points wide.
        HStack(spacing: 0) {
            runsList
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 300)
            Divider()
            logPane
                .frame(minWidth: 220)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            snippetsMenu
        }
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
                Label(apex.selectedCode == nil ? "Execute" : "Execute Selection", systemImage: "play.fill")
            }
            .help(model.isLocked ? "Unlock the window to run Apex in this org" : apex.selectedCode == nil ? "Execute Apex (⌘↩)" : "Execute the selected code (⌘↩)")
            .disabled(apex.isRunning || !model.canChangeData)
        }
    }

    private var snippetsMenu: some View {
        let snippets = ApexSnippets.shared
        return Menu {
            ForEach(snippets.snippets) { snippet in
                Button(snippet.name) { apex.insert(snippet.code) }
            }
            if !snippets.snippets.isEmpty {
                Divider()
            }
            Button(apex.selectedCode == nil ? "Save Code as Snippet" : "Save Selection as Snippet") {
                snippets.add(apex.selectedCode ?? apex.code)
            }
            .disabled(apex.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Manage Snippets…") { apex.isManagingSnippets = true }
        } label: {
            Label("Snippets", systemImage: "text.badge.plus")
        }
        .help("Insert a saved piece of Apex, or save the selection as one")
        .accessibilityIdentifier("apexSnippets")
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
                Spacer(minLength: 4)
                if let usage = model.apiUsage {
                    Button("API \(usage)") { model.isShowingLimits = true }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .help("Daily API requests used / limit. Click to see all of the org's limits.")
                }
            }
            .lineLimit(1)
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
                        apex.code = run.editorCode ?? run.code
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
            // Narrow windows get a menu instead of the segmented control, and an icon for Save Log.
            ViewThatFits(in: .horizontal) {
                logHeader(compact: false)
                logHeader(compact: true)
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
            LogTextView(text: apex.displayedLog) { apex.reveal(line: $0 + (apex.selectedRun?.lineOffset ?? 0)) }
                .accessibilityIdentifier("debugLog")
                .overlay {
                    if let run = apex.selectedRun, run.debugLog.isEmpty {
                        ContentUnavailableView("No Debug Log", systemImage: "doc.plaintext", description: Text(run.compiled ? "Turn up the log levels in the toolbar to see more." : "Code that doesn't compile doesn't run, so there's no log."))
                    }
                }
        }
    }

    private var logLinesPicker: some View {
        Picker("Show", selection: $apex.logLines) {
            ForEach(ApexModel.LogLines.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private func logHeader(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            Group {
                if compact {
                    logLinesPicker.pickerStyle(.menu)
                } else {
                    logLinesPicker.pickerStyle(.segmented)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show all log lines, or only System.debug output, queries, DML or exceptions")
            TextField("Filter", text: $apex.logFilter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 70, maxWidth: 220)
            Spacer(minLength: 0)
            if !compact, let run = apex.selectedRun {
                Text(ByteCountFormatter.string(fromByteCount: Int64(run.debugLog.utf8.count), countStyle: .file))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button {
                saveLog()
            } label: {
                if compact {
                    Image(systemName: "square.and.arrow.down")
                } else {
                    Text("Save Log…")
                }
            }
            .fixedSize()
            .disabled(apex.selectedRun?.debugLog.isEmpty ?? true)
            .help("Save the whole debug log to a file")
            .accessibilityLabel("Save Log")
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
        return "Line \(run.editorLine): \(run.resultText)"
    }

    /// The full result, with where it happened and the stack trace.
    private func details(_ run: ApexExecution) -> String {
        var lines = [run.resultText]
        if !run.success, run.line > 0 {
            lines.append("Line \(run.editorLine), column \(run.editorColumn)")
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

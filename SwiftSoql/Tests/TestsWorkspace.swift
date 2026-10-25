import AppKit
import SwiftUI

/// Runs the org's Apex tests: the test classes to check on the left; the run's results, or the
/// org's code coverage, on the right.
struct TestsWorkspace: View {
    var model: ExplorerModel
    @Bindable var tests: TestsModel

    @State private var classFilter = ""
    @AppStorage("testsPane") private var pane = Pane.results

    enum Pane: String, CaseIterable {
        case results = "Results"
        case coverage = "Coverage"
    }

    init(model: ExplorerModel) {
        self.model = model
        tests = model.tests
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                classList
                    .frame(minWidth: 180, idealWidth: 260, maxWidth: 360)
                Divider()
                Group {
                    switch pane {
                    case .results: resultsPane
                    case .coverage: coveragePane
                    }
                }
                .frame(minWidth: 260)
            }
        }
        .frame(minWidth: 441, minHeight: 240)
        .task {
            if !tests.hasLoadedClasses { await model.loadTestClasses() }
        }
        .sheet(item: $tests.source) { source in
            ApexSourceView(source: source)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            if tests.isRunning {
                ProgressView().controlSize(.small)
                Text(tests.queue.isEmpty ? "Starting the tests…" : "Ran \(tests.finishedClasses) of \(tests.queue.count) classes")
                    .lineLimit(1)
                Button("Stop") { Task { await model.stopTests() } }
            } else {
                Button("Run Checked (\(tests.checked.count))") { Task { await model.runTests(allLocal: false) } }
                    .disabled(tests.checked.isEmpty)
                    .help("Run the checked classes' tests (⌘↩)")
                Button("Run All Local Tests") { Task { await model.runTests(allLocal: true) } }
                    .help("Run every test outside managed packages")
            }
            if !tests.results.isEmpty {
                Text("\(tests.passed) passed, \(tests.failed) failed")
                    .foregroundStyle(tests.failed > 0 ? .red : .secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("testSummary")
            }
            Spacer(minLength: 0)
            Picker("Show", selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button {
                Task { await model.loadTestClasses() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(tests.isRunning)
            .help("Reload the test classes and coverage")
            .accessibilityLabel("Reload")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    // MARK: Classes

    private var classList: some View {
        let shown = tests.classes.filter { classFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(classFilter) }
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter Classes", text: $classFilter)
                    .textFieldStyle(.roundedBorder)
                Button(shown.allSatisfy { tests.checked.contains($0.id) } && !shown.isEmpty ? "None" : "All") {
                    if shown.allSatisfy({ tests.checked.contains($0.id) }) {
                        tests.checked.subtract(shown.map(\.id))
                    } else {
                        tests.checked.formUnion(shown.map(\.id))
                    }
                }
                .fixedSize()
                .help("Check or uncheck every class shown")
            }
            .controlSize(.small)
            .padding(6)
            Divider()
            List(shown) { testClass in
                Toggle(isOn: Binding {
                    tests.checked.contains(testClass.id)
                } set: { isOn in
                    if isOn { tests.checked.insert(testClass.id) } else { tests.checked.remove(testClass.id) }
                }) {
                    HStack(spacing: 4) {
                        Text(testClass.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let outcome = classOutcome(testClass.name) {
                            Image(systemName: outcome ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(outcome ? .green : .red)
                                .accessibilityLabel(outcome ? "Passed" : "Failed")
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .contextMenu {
                    Button("Show Source") { Task { await model.openApexSource(classID: testClass.id) } }
                }
            }
            .accessibilityIdentifier("testClasses")
            .overlay {
                if tests.hasLoadedClasses && tests.classes.isEmpty {
                    ContentUnavailableView("No Test Classes", systemImage: "checkmark.seal", description: Text("This org has no Apex test classes outside managed packages."))
                } else if !tests.hasLoadedClasses {
                    ProgressView()
                }
            }
        }
    }

    /// Whether every method of a class passed in the latest run, if it ran.
    private func classOutcome(_ name: String) -> Bool? {
        let methods = tests.results.filter { $0.className == name }
        return methods.isEmpty ? nil : methods.allSatisfy(\.passed)
    }

    // MARK: Results

    private var resultsPane: some View {
        VStack(spacing: 0) {
            Table(tests.results, selection: $tests.selectedResultID) {
                TableColumn("") { result in
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                        .accessibilityLabel(result.outcome)
                }
                .width(18)
                TableColumn("Class") { Text($0.className) }
                    .width(min: 60, ideal: 160)
                TableColumn("Method") { Text($0.methodName) }
                    .width(min: 60, ideal: 180)
                TableColumn("Time") { Text("\($0.runTimeMilliseconds.formatted()) ms").monospacedDigit() }
                    .width(min: 50, ideal: 70)
                TableColumn("Message") { result in
                    Text(result.message)
                        .lineLimit(1)
                        .help(result.message)
                }
            }
            .accessibilityIdentifier("testResults")
            .overlay {
                if tests.results.isEmpty, !tests.isRunning {
                    ContentUnavailableView("No Results", systemImage: "checkmark.seal", description: Text("Check some test classes and click Run Checked, or run all local tests."))
                }
            }
            if let result = tests.selectedResult, !result.passed {
                Divider()
                failureDetails(result)
            }
        }
    }

    private func failureDetails(_ result: ApexTestMethodResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.message)
                    .textSelection(.enabled)
                ForEach(Array(result.stackTrace.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    let frame = StackFrame.frames(in: String(line)).first
                    if let frame, let classID = tests.classID(named: frame.className) {
                        Button(String(line)) {
                            Task { await model.openApexSource(classID: classID, line: frame.line) }
                        }
                        .buttonStyle(.link)
                        .help("Show \(frame.className) at line \(frame.line)")
                    } else {
                        Text(line)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(minHeight: 80, idealHeight: 140, maxHeight: 200)
        .accessibilityIdentifier("testFailure")
    }

    // MARK: Coverage

    private var coveragePane: some View {
        Table(tests.coverage) {
            TableColumn("Class or Trigger") { coverage in
                Text(coverage.name)
            }
            .width(min: 80, ideal: 220)
            TableColumn("Covered") { coverage in
                HStack {
                    if let fraction = coverage.fraction {
                        ProgressView(value: fraction)
                            .tint(fraction >= 0.75 ? .green : fraction >= 0.5 ? .orange : .red)
                            .frame(width: 60)
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 80, ideal: 120)
            TableColumn("Lines") { coverage in
                Text("\(coverage.covered) of \(coverage.total)")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: ClassCoverage.ID.self) { ids in
            Button("Show Source") {
                if let id = ids.first { Task { await model.openApexSource(classID: id) } }
            }
            .disabled(ids.count != 1)
        } primaryAction: { ids in
            if let id = ids.first { Task { await model.openApexSource(classID: id) } }
        }
        .accessibilityIdentifier("codeCoverage")
        .overlay {
            if tests.coverage.isEmpty {
                ContentUnavailableView("No Coverage Yet", systemImage: "chart.bar", description: Text("Coverage appears after tests run. Double-click a class to see which lines are covered."))
            }
        }
    }
}

/// An Apex class's source, read-only, with covered lines in green and uncovered ones in red.
struct ApexSourceView: View {
    let source: TestsModel.Source

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(source.name)
                    .font(.headline)
                if !source.covered.isEmpty || !source.uncovered.isEmpty {
                    let total = source.covered.count + source.uncovered.count
                    Text("\(source.covered.count) of \(total) lines covered")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            SourceTextView(source: source)
                .accessibilityIdentifier("apexSource")
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 640)
    }
}

/// The source with line numbers and coverage colors, scrolled to the source's line.
private struct SourceTextView: NSViewRepresentable {
    let source: TestsModel.Source

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.setAccessibilityIdentifier("apexSourceText")
        let lines = source.body.split(separator: "\n", omittingEmptySubsequences: false)
        let width = String(lines.count).count
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var targetRange: NSRange?
        for (index, line) in lines.enumerated() {
            let number = index + 1
            let numberText = String(repeating: " ", count: width - String(number).count) + "\(number)  "
            let start = text.length
            text.append(NSAttributedString(string: numberText, attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            if source.covered.contains(number) {
                attributes[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
            } else if source.uncovered.contains(number) {
                attributes[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.18)
            }
            text.append(NSAttributedString(string: String(line) + "\n", attributes: attributes))
            if number == source.line {
                targetRange = NSRange(location: start, length: text.length - start)
            }
        }
        textView.textStorage?.setAttributedString(text)
        if let targetRange {
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(targetRange)
                textView.setSelectedRange(targetRange)
                textView.showFindIndicator(for: targetRange)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Chooses a CSV file to import.
enum ImportPanel {
    static func chooseFile(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a CSV file whose first row names its columns."
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
}

/// The steps of a CSV import: choose the SObject, operation and column mapping; confirm; watch
/// it run; then see what happened and save the results.
struct ImportSheet: View {
    let model: ExplorerModel
    @Bindable var csvImport: CSVImport

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            switch csvImport.phase {
            case .editing:
                editing
            case .running(let status, let fraction):
                running(status, fraction)
            case .finished(let outcome, let stopped):
                finished(outcome, stopped: stopped)
            case .failed(let message):
                ContentUnavailableView("The import failed", systemImage: "exclamationmark.triangle", description: Text(message))
                    .textSelection(.enabled)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(width: 680, height: 620)
        .interactiveDismissDisabled(csvImport.isRunning)
        .task(id: csvImport.sobject) {
            await csvImport.prepare()
        }
    }

    // MARK: Editing

    private var rowCount: String {
        "\(csvImport.file.rows.count.formatted()) \(csvImport.file.rows.count == 1 ? "row" : "rows")"
    }

    private var editing: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import \(csvImport.file.name) (\(rowCount))")
                    .font(.headline)
                HStack(spacing: 12) {
                    Picker("Into", selection: $csvImport.sobject) {
                        Text("Choose…").tag("")
                        ForEach(model.importableSObjects, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("importSObject")
                    Picker("Operation", selection: $csvImport.operation) {
                        ForEach(ImportOperation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("importOperation")
                }
                if let describe = csvImport.describe {
                    HStack(spacing: 12) {
                        if csvImport.operation == .upsert {
                            Picker("Match on", selection: $csvImport.matchField) {
                                ForEach(ImportPlan.matchFields(describe), id: \.self) { Text($0).tag($0) }
                            }
                            .frame(maxWidth: 260)
                            .help("The field that finds existing records: Id, or an external Id field")
                        }
                        if csvImport.operation != .insert {
                            Toggle("Empty cells clear fields", isOn: $csvImport.clearEmpty)
                                .help("Off: an empty cell leaves the field as it is. On: it clears the field.")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .onChange(of: csvImport.operation) { csvImport.operationChanged() }
            Divider()
            if let describe = csvImport.describe {
                mappingList(describe)
            } else if let error = csvImport.describeError {
                ContentUnavailableView("Unable to describe \(csvImport.sobject)", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if csvImport.sobject.isEmpty {
                ContentUnavailableView("Choose an SObject", systemImage: "square.and.arrow.down", description: Text("Pick the type of record to import the rows into."))
            } else {
                ProgressView("Describing \(csvImport.sobject)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            editingFooter
        }
    }

    private func mappingList(_ describe: SObjectDescribe) -> some View {
        let fields = ImportPlan.mappableFields(describe, operation: csvImport.operation)
        let sample = csvImport.file.rows.first ?? []
        return Form {
            Section {
                ForEach(Array(csvImport.file.header.enumerated()), id: \.offset) { index, column in
                    LabeledContent {
                        Picker(column, selection: Binding {
                            csvImport.mapping.fields[index] ?? ""
                        } set: {
                            csvImport.mapping.fields[index] = $0.isEmpty ? nil : $0
                        }) {
                            Text("Don't import").tag("")
                            Divider()
                            ForEach(fields) { field in
                                Text(field.name + (field.isRequiredOnCreate && csvImport.operation != .update ? " *" : "")).tag(field.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .accessibilityIdentifier("importMapping.\(column)")
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(column.isEmpty ? "Column \(index + 1)" : column)
                            Text(index < sample.count ? sample[index] : "")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Columns and the fields they go to")
            }
        }
        .formStyle(.grouped)
    }

    private var editingFooter: some View {
        HStack {
            if let problem = csvImport.plan?.problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if csvImport.plan != nil {
                Text(csvImport.file.rows.count > ExplorerModel.bulkExportThreshold ? "Uses a Bulk API job." : "Sends 200 rows at a time.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("\(csvImport.operation.title) \(rowCount)…") { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(csvImport.plan?.problem != nil || csvImport.plan == nil)
                .accessibilityIdentifier("startImport")
        }
        .padding(12)
        .confirmationDialog(confirmationTitle, isPresented: $isConfirming) {
            Button(csvImport.operation.title) { csvImport.start() }
        } message: {
            Text("This changes records in \(model.session?.displayName ?? "the org")\(model.isGuarded ? ", a \(model.orgKind?.title.lowercased() ?? "production") org" : ""). It can't be undone from SwiftSoql.")
        }
    }

    private var confirmationTitle: String {
        "\(csvImport.operation.title) \(rowCount) of \(csvImport.sobject)?"
    }

    // MARK: Running

    private func running(_ status: String, _ fraction: Double?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: 360)
            } else {
                ProgressView()
            }
            Text(status)
                .foregroundStyle(.secondary)
            Button("Stop") { csvImport.stop() }
                .help("Stop after the rows already sent to Salesforce")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Finished

    private func finished(_ outcome: ImportOutcome, stopped: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(stopped ? "Import stopped" : "Import finished")
                    .font(.headline)
                Text(summary(outcome))
                    .accessibilityIdentifier("importSummary")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            if outcome.errors.isEmpty {
                ContentUnavailableView("No errors", systemImage: "checkmark.circle")
            } else {
                List(Array(outcome.errors.enumerated()), id: \.offset) { _, error in
                    HStack(alignment: .firstTextBaseline) {
                        Text(error.row.map { "Row \($0)" } ?? "Row")
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .leading)
                        Text(error.message)
                            .textSelection(.enabled)
                    }
                }
            }
            Divider()
            HStack {
                if outcome.failed > outcome.errors.count {
                    Text("The results file lists every error.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Results…") { saveResults(outcome) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private func summary(_ outcome: ImportOutcome) -> String {
        var parts: [String] = []
        if outcome.created > 0 { parts.append("\(outcome.created.formatted()) created") }
        if outcome.updated > 0 { parts.append("\(outcome.updated.formatted()) updated") }
        parts.append("\(outcome.failed.formatted()) failed")
        return parts.joined(separator: ", ")
    }

    private func saveResults(_ outcome: ImportOutcome) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (csvImport.file.name as NSString).deletingPathExtension + " results.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(outcome.csv.utf8).write(to: url)
            } catch {
                model.error = DisplayedError("Unable to save the results", error)
            }
        }
    }
}

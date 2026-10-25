import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The query editor above the results, with any opened subquery results below those.
struct QueryWorkspace: View {
    @Bindable var model: ExplorerModel

    @State private var exportDocument: ExportDocument?
    @State private var exportFormat = ExportFormat.csv
    @State private var isConfirmingExport = false
    @AppStorage("showResultsAsJSON") private var showJSON = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                QueryTabBar(model: model)
                Divider()
                SOQLEditor(text: $model.soql, describer: model.schema, schemaGeneration: model.schema.schemaGeneration)
                    // Each tab gets its own editor, so undo stays within the tab.
                    .id(model.selectedTabID)
            }
            .frame(minHeight: 90, idealHeight: 170)

            VStack(spacing: 0) {
                resultsHeader
                Divider()
                results
            }
            .frame(minHeight: 120, idealHeight: 500)

            if let child = model.childResults {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(child.title ?? "Child rows") — \(child.rows.count) of \(child.totalSize) rows")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Button {
                            model.childResults = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Close")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    Divider()
                    ResultsTable(resultSet: child, model: model, sortOrder: Binding {
                        model.childResults?.sortOrder ?? []
                    } set: {
                        model.childResults?.sort(by: $0)
                    }, accessibilityID: "childResults")
                }
                .frame(minHeight: 100, idealHeight: 220)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.runQuery() }
                } label: {
                    Label("Run Query", systemImage: "play.fill")
                }
                .help("Run Query (⌘↩)")
                .disabled(model.isQuerying)
            }
        }
        .fileExporter(
            isPresented: Binding { exportDocument != nil } set: { if !$0 { exportDocument = nil } },
            document: exportDocument,
            contentType: exportFormat == .json ? .json : .commaSeparatedText,
            defaultFilename: "Query Results"
        ) { result in
            if case .failure(let error) = result {
                model.error = DisplayedError("Unable to save results", error)
            }
        }
        .confirmationDialog("Export which rows?", isPresented: $isConfirmingExport) {
            Button("All \((model.results?.totalSize ?? 0).formatted()) Rows…") { chooseFileForAllRows() }
            Button("Loaded \((model.results?.rows.count ?? 0).formatted()) Rows") { prepareExport() }
        } message: {
            Text(exportFormat == .json
                ? "Exporting all rows fetches the rest from Salesforce and writes them straight to the file."
                : "Exporting all rows fetches the rest from Salesforce and writes them straight to the file, using the Bulk API for large exports when the query allows it.")
        }
        .sheet(item: $model.queryPlan) { plan in
            QueryPlanView(result: plan)
        }
        .sheet(item: $model.recordDraft) { draft in
            RecordForm(model: model, draft: draft)
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: $model.isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteCheckedRows() }
            }
        } message: {
            Text((model.isGuarded ? "This is a \(model.orgKind?.title.lowercased() ?? "production") org. " : "")
                + "Salesforce moves most deleted records to the Recycle Bin, where they can be restored.")
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 10) {
            if model.isQuerying {
                ProgressView().controlSize(.small)
            }
            Text(model.currentTab.statusText)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            if let results = model.results, results.isEditable, results.includesDeleted, model.canChangeData {
                Button("Restore Checked") {
                    Task { await model.restoreCheckedRows() }
                }
                .disabled(results.checkedRows.isEmpty || model.isSaving)
                .help("Restore the checked rows' records from the Recycle Bin")
            }
            if model.currentTab.api == .data, model.canChangeData {
                Button {
                    model.newRecord()
                } label: {
                    Label("New Record", systemImage: "plus")
                }
                .disabled(model.isSaving)
                .help("Create a record (⌃⌘N)")
            }
            if let results = model.results, results.isEditable, model.canChangeData {
                Button("Delete Checked") {
                    model.isConfirmingDelete = true
                }
                .disabled(results.checkedRows.isEmpty || model.isSaving)
                .help("Delete the checked rows' records")
            }
            if model.canLoadMore {
                Button("Load More") {
                    Task { await model.loadMore() }
                }
                .disabled(model.isQuerying)
            }
            if model.results != nil {
                Picker("Show", selection: $showJSON) {
                    Text("Table").tag(false)
                    Text("JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show the loaded rows as a table or as JSON")
                .accessibilityIdentifier("resultsFormat")
            }
            Menu {
                Button("CSV…") { export(.csv) }
                Button("JSON…") { export(.json) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            .disabled(model.results == nil || model.isQuerying)
            .accessibilityIdentifier("export")
            if let usage = model.apiUsage {
                Text("API \(usage)")
                    .foregroundStyle(.secondary)
                    .help("Daily API requests used / limit")
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var results: some View {
        if let results = model.results, showJSON {
            ResultsJSONView(resultSet: results)
        } else if let results = model.results {
            ResultsTable(resultSet: results, model: model, checkedRows: results.isEditable && model.canChangeData ? checkedRows : nil, sortOrder: Binding {
                model.results?.sortOrder ?? []
            } set: {
                model.results?.sort(by: $0)
            }) { child, column, rowID in
                model.showChildResults(child, column: column, parentRowID: rowID)
            }
        } else {
            ContentUnavailableView("No Results", systemImage: "tablecells", description: Text("Write a query and press ⌘↩ to run it. Double-click an SObject or field in the sidebar to build one."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var checkedRows: Binding<Set<ResultRow.ID>> {
        Binding { model.results?.checkedRows ?? [] } set: { model.results?.checkedRows = $0 }
    }

    private var deleteConfirmationTitle: String {
        let count = model.results?.checkedRows.count ?? 0
        return "Delete \(count) \(count == 1 ? "record" : "records")?"
    }

    /// Exports the loaded rows, or asks whether to export them all when there are more.
    private func export(_ format: ExportFormat) {
        exportFormat = format
        if model.results?.nextRecordsURL != nil {
            isConfirmingExport = true
        } else {
            prepareExport()
        }
    }

    /// Asks where to save, then exports every row there.
    private func chooseFileForAllRows() {
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = "Query Results." + format.rawValue
        let export = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.exportAll(to: url, format: format) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: export)
        } else {
            panel.begin(completionHandler: export)
        }
    }

    private func prepareExport() {
        guard let results = model.results else { return }
        exportDocument = ExportDocument(text: exportFormat == .json ? ResultsExport.json(results.rows.map(\.record)) : ResultsExport.csv(results))
    }
}

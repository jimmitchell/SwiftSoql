import SwiftUI
import UniformTypeIdentifiers

/// The query editor above the results, with any opened subquery results below those.
struct QueryWorkspace: View {
    @Bindable var model: ExplorerModel

    @State private var exportDocument: CSVDocument?
    @State private var isConfirmingExport = false

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                QueryTabBar(model: model)
                Divider()
                SOQLEditor(text: $model.soql, describer: model, schemaGeneration: model.schemaGeneration)
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
            contentType: .commaSeparatedText,
            defaultFilename: "Query Results"
        ) { result in
            if case .failure(let error) = result {
                model.error = DisplayedError("Unable to save results", error)
            }
        }
        .confirmationDialog("Export which rows?", isPresented: $isConfirmingExport) {
            Button("All \(model.results?.totalSize ?? 0) Rows") {
                Task {
                    await model.loadAll()
                    prepareExport()
                }
            }
            Button("Loaded \(model.results?.rows.count ?? 0) Rows") { prepareExport() }
        } message: {
            Text("Exporting all rows fetches the rest of the results from Salesforce first.")
        }
        .sheet(item: $model.queryPlan) { plan in
            QueryPlanView(result: plan)
        }
        .confirmationDialog(deleteConfirmationTitle, isPresented: $model.isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteCheckedRows() }
            }
        } message: {
            Text("Salesforce moves most deleted records to the Recycle Bin, where they can be restored.")
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
            if let results = model.results, results.isEditable, results.includesDeleted {
                Button("Restore Checked") {
                    Task { await model.restoreCheckedRows() }
                }
                .disabled(results.checkedRows.isEmpty || model.isSaving)
                .help("Restore the checked rows' records from the Recycle Bin")
            }
            if let results = model.results, results.isEditable {
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
            Button {
                if model.canLoadMore {
                    isConfirmingExport = true
                } else {
                    prepareExport()
                }
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .disabled(model.results == nil || model.isQuerying)
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
        if let results = model.results {
            ResultsTable(resultSet: results, model: model, checkedRows: results.isEditable ? checkedRows : nil, sortOrder: Binding {
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

    private func prepareExport() {
        guard let results = model.results else { return }
        exportDocument = CSVDocument(text: ResultsExport.csv(results))
    }
}

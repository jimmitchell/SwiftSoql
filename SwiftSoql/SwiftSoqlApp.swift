import Sparkle
import SwiftUI

@main
struct SwiftSoqlApp: App {
    /// Checks for and installs updates, from the appcast in Info.plist's SUFeedURL. Not started
    /// while testing.
    private let updater = SPUStandardUpdaterController(startingUpdater: !AppDefaults.isTesting, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // The same defaults as SoqlXplorer.
        AppDefaults.store.register(defaults: [
            "sortFieldsInGeneratedQueries": true,
            "skipCompoundFieldsInGeneratedQueries": false,
            "soqlSyntaxHighlighting": true,
            "soqlPopupCompletions": true,
            "soqlUppercaseKeywords": true,
            "maxRecentQueries": 25,
            "describeAllInBackground": true,
            "tableRowLimit": 50_000,
            "bulkExportThreshold": 10_000,
        ])
    }

    var body: some Scene {
        WindowGroup(for: WindowOrg.self) { $windowOrg in
            ContentView(windowOrg: $windowOrg)
                .defaultAppStorage(AppDefaults.store)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
            FileCommands()
            QueryCommands()
        }

        Settings {
            SettingsView()
                .defaultAppStorage(AppDefaults.store)
        }
    }
}

extension FocusedValues {
    /// The model of the frontmost explorer window, for menu commands.
    @Entry var explorerModel: ExplorerModel?
}

struct FileCommands: Commands {
    @FocusedValue(\.explorerModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Window for \(model?.session?.displayName ?? "This Org")") {
                openWindow(value: WindowOrg(username: model?.session?.username))
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(model?.session == nil)

            Divider()

            Button("Open…") {
                model?.isOpeningFile = true
            }
            .keyboardShortcut("o")
            .disabled(model?.isConnected != true)
        }
        CommandGroup(replacing: .saveItem) {
            Button(model?.workspace == .apex ? "Save Apex…" : "Save Query…") {
                model?.isSavingFile = true
            }
            .keyboardShortcut("s")
            .disabled(model?.isConnected != true || model?.workspace == .schema)
        }
    }
}

struct QueryCommands: Commands {
    @FocusedValue(\.explorerModel) private var model

    var body: some Commands {
        CommandMenu("Query") {
            Button("New Query Tab") {
                model?.newTab()
            }
            .keyboardShortcut("t")
            .disabled(model?.isConnected != true)

            Button("Close Query Tab") {
                if let model { model.closeTab(model.selectedTabID) }
            }
            .disabled(model?.isConnected != true || model?.workspace != .query)

            Button("Show Next Tab") {
                model?.selectTab(offset: 1)
            }
            .keyboardShortcut(.tab, modifiers: .control)
            .disabled(model?.isConnected != true || (model?.tabs.count ?? 0) < 2)

            Button("Show Previous Tab") {
                model?.selectTab(offset: -1)
            }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
            .disabled(model?.isConnected != true || (model?.tabs.count ?? 0) < 2)

            Divider()

            Button(model?.workspace == .apex ? "Execute Apex" : "Run Query") {
                Task { await model?.run() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model?.canRun != true)

            Button("Run Query Including Deleted Rows") {
                Task { await model?.runQuery(includeDeleted: true) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model?.isConnected != true || model?.isQuerying == true || model?.workspace != .query)

            Divider()

            Picker("Workspace", selection: Binding { model?.workspace ?? .query } set: { model?.workspace = $0 }) {
                Text("Query").tag(Workspace.query).keyboardShortcut("1", modifiers: .command)
                Text("Anonymous Apex").tag(Workspace.apex).keyboardShortcut("2", modifiers: .command)
                Text("Schema Diagram").tag(Workspace.schema).keyboardShortcut("3", modifiers: .command)
            }
            .pickerStyle(.inline)
            .disabled(model?.isConnected != true)

            Button("Format Query") {
                model?.formatQuery()
            }
            .keyboardShortcut("i", modifiers: .control)
            .disabled(model?.isConnected != true || model?.workspace != .query)

            Button("Show Query Plan") {
                Task { await model?.explainQuery() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(model?.isConnected != true || model?.isQuerying == true || model?.workspace != .query)

            Divider()

            Button("Load More Rows") {
                Task { await model?.loadMore() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model?.canLoadMore != true || model?.isQuerying == true)

            Divider()

            Button("Restore Checked Rows") {
                Task { await model?.restoreCheckedRows() }
            }
            .disabled(model?.results?.includesDeleted != true || model?.results?.checkedRows.isEmpty != false || model?.isSaving == true)

            Button("Delete Checked Rows…") {
                model?.isConfirmingDelete = true
            }
            .disabled(model?.results?.checkedRows.isEmpty != false || model?.isSaving == true)
        }
    }
}

struct SettingsView: View {
    @AppStorage("soqlSyntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("soqlPopupCompletions") private var popupCompletions = true
    @AppStorage("soqlUppercaseKeywords") private var uppercaseKeywords = true
    @AppStorage("sortFieldsInGeneratedQueries") private var sortGeneratedFields = true
    @AppStorage("skipCompoundFieldsInGeneratedQueries") private var skipCompoundFields = false
    @AppStorage("maxRecentQueries") private var maxRecentQueries = 25
    @AppStorage("describeAllInBackground") private var describeAllInBackground = true

    var body: some View {
        Form {
            Section("Query Editor") {
                Toggle("Highlight syntax and check queries", isOn: $syntaxHighlighting)
                Toggle("Show completions while typing", isOn: $popupCompletions)
                    .disabled(!syntaxHighlighting)
                Toggle("Make keywords uppercase", isOn: $uppercaseKeywords)
                    .disabled(!syntaxHighlighting)
            }
            Section("Generated Queries") {
                Toggle("Sort fields alphabetically", isOn: $sortGeneratedFields)
                Toggle("Use address parts instead of compound address fields", isOn: $skipCompoundFields)
            }
            Section("Schema") {
                Toggle("Describe every SObject after connecting", isOn: $describeAllInBackground)
                Text("Lets the sidebar filter find fields in every SObject, at the cost of about one API request per 25 SObjects. Takes effect the next time you connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recent Queries") {
                Stepper("Remember the last \(maxRecentQueries) queries for each org", value: $maxRecentQueries, in: 5...200, step: 5)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

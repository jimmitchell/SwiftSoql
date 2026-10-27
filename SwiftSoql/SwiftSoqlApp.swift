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
            "importBatchSize": 200,
        ])
    }

    var body: some Scene {
        WindowGroup(for: WindowOrg.self) { $windowOrg in
            ContentView(windowOrg: $windowOrg)
                .defaultAppStorage(AppDefaults.store)
                .background(WindowFrameSaver())
        }
        .defaultSize(width: 1200, height: 800)
        // New windows open centered on their screen, no bigger than it.
        .defaultWindowPlacement { _, context in
            let screen = context.defaultDisplay.visibleRect.size
            return WindowPlacement(.center, size: CGSize(width: min(1200, screen.width), height: min(800, screen.height)))
        }
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

            Button("Import CSV…") {
                guard let model else { return }
                ImportPanel.chooseFile { url in
                    Task { await model.beginImport(of: url) }
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model?.canChangeData != true || model?.csvImport != nil)

            Button("Export Data Dictionary…") {
                model?.isExportingDictionary = true
            }
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

            Button(model?.workspace == .apex ? (model?.apex.selectedCode == nil ? "Execute Apex" : "Execute Selected Apex") : model?.workspace == .tests ? "Run Checked Tests" : "Run Query") {
                Task { await model?.run() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model?.canRun != true)

            Button("Run Query Including Deleted Rows") {
                Task { await model?.runQuery(includeDeleted: true) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model?.isConnected != true || model?.isQuerying == true || model?.workspace != .query || model?.currentTab.api == .tooling)

            Toggle("Use Tooling API in This Tab", isOn: Binding { model?.currentTab.api == .tooling } set: { _ in model?.toggleTabAPI() })
                .keyboardShortcut("t", modifiers: [.control, .command])
                .disabled(model?.isConnected != true || model?.workspace != .query)

            Divider()

            Picker("Workspace", selection: Binding { model?.workspace ?? .query } set: { model?.workspace = $0 }) {
                Text("Query").tag(Workspace.query).keyboardShortcut("1", modifiers: .command)
                Text("Anonymous Apex").tag(Workspace.apex).keyboardShortcut("2", modifiers: .command)
                Text("Schema Diagram").tag(Workspace.schema).keyboardShortcut("3", modifiers: .command)
                Text("Debug Logs").tag(Workspace.logs).keyboardShortcut("4", modifiers: .command)
                Text("Apex Tests").tag(Workspace.tests).keyboardShortcut("5", modifiers: .command)
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

            Button("Org Limits…") {
                model?.isShowingLimits = true
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(model?.isConnected != true)

            Divider()

            Button("Load More Rows") {
                Task { await model?.loadMore() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model?.canLoadMore != true || model?.isQuerying == true)

            Divider()

            Button("New Record…") {
                model?.newRecord()
            }
            .keyboardShortcut("n", modifiers: [.control, .command])
            .disabled(model?.canChangeData != true || model?.workspace != .query || model?.currentTab.api != .data || model?.isSaving == true)

            Button("Restore Checked Rows") {
                Task { await model?.restoreCheckedRows() }
            }
            .disabled(model?.canChangeData != true || model?.results?.includesDeleted != true || model?.results?.checkedRows.isEmpty != false || model?.isSaving == true)

            Button("Delete Checked Rows…") {
                model?.isConfirmingDelete = true
            }
            .disabled(model?.canChangeData != true || model?.results?.checkedRows.isEmpty != false || model?.isSaving == true)

            if model?.isGuarded == true {
                Divider()
                Toggle("Allow Changes in This Window", isOn: Binding { model?.isLocked == false } set: { model?.setLocked(!$0) })
            }
        }
    }
}

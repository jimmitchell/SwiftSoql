import SwiftUI

@main
struct SwiftSoqlApp: App {
    init() {
        // The same defaults as SoqlXplorer.
        UserDefaults.standard.register(defaults: [
            "sortFieldsInGeneratedQueries": true,
            "skipCompoundFieldsInGeneratedQueries": false,
            "soqlSyntaxHighlighting": true,
            "soqlPopupCompletions": true,
            "soqlUppercaseKeywords": true,
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            QueryCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

extension FocusedValues {
    /// The model of the frontmost explorer window, for menu commands.
    @Entry var explorerModel: ExplorerModel?
}

struct QueryCommands: Commands {
    @FocusedValue(\.explorerModel) private var model

    var body: some Commands {
        CommandMenu("Query") {
            Button("Run Query") {
                Task { await model?.runQuery() }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model?.isConnected != true || model?.isQuerying == true)

            Button("Run Query Including Deleted Rows") {
                Task { await model?.runQuery(includeDeleted: true) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(model?.isConnected != true || model?.isQuerying == true)

            Divider()

            Button("Load More Rows") {
                Task { await model?.loadMore() }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model?.canLoadMore != true || model?.isQuerying == true)
        }
    }
}

struct SettingsView: View {
    @AppStorage("soqlSyntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("soqlPopupCompletions") private var popupCompletions = true
    @AppStorage("soqlUppercaseKeywords") private var uppercaseKeywords = true
    @AppStorage("sortFieldsInGeneratedQueries") private var sortGeneratedFields = true
    @AppStorage("skipCompoundFieldsInGeneratedQueries") private var skipCompoundFields = false

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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

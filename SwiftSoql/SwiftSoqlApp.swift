import SwiftUI

@main
struct SwiftSoqlApp: App {
    init() {
        // The same defaults as SoqlXplorer.
        UserDefaults.standard.register(defaults: [
            "sortFieldsInGeneratedQueries": true,
            "skipCompoundFieldsInGeneratedQueries": false,
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

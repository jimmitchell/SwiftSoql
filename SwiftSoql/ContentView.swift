import SwiftUI

/// One explorer window: the login screen until connected, then the explorer.
struct ContentView: View {
    @State private var model = ExplorerModel()

    var body: some View {
        Group {
            if let session = model.session {
                ExplorerView(model: model)
                    .navigationTitle(session.displayName)
                    .navigationSubtitle(session.instanceURL.host() ?? "")
            } else {
                LoginView(model: model)
                    .navigationTitle("SwiftSoql")
            }
        }
        .alert(item: $model.error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}

/// The connected explorer: schema sidebar, workspace, and details inspector.
struct ExplorerView: View {
    @Bindable var model: ExplorerModel
    @AppStorage("showDetailsInspector") private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SchemaSidebar(model: model) { item in
                Task { await model.buildQuery(for: item) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 500)
        } detail: {
            switch model.workspace {
            case .query: QueryWorkspace(model: model)
            case .apex: ApexWorkspace(model: model)
            }
        }
        .focusedSceneValue(\.explorerModel, model)
        .inspector(isPresented: $showInspector) {
            DetailsInspector(model: model)
                .inspectorColumnWidth(min: 240, ideal: 300, max: 500)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .help("Disconnect and choose another org")
            }
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $model.workspace) {
                    ForEach(Workspace.allCases) { workspace in
                        Text(workspace.rawValue).tag(workspace)
                    }
                }
                .pickerStyle(.segmented)
                .help("Switch between running queries and anonymous Apex")
            }
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show or hide details")
            }
        }
    }
}

#Preview {
    ContentView()
}

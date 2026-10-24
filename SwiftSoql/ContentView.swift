import SwiftUI

/// Identifies a window and the org it's connected to, so windows reopen connected after a relaunch.
/// The id lets several windows be connected to the same org.
struct WindowOrg: Codable, Hashable {
    var id = UUID()
    var username: String?
}

/// One explorer window: the login screen until connected, then the explorer.
struct ContentView: View {
    @Binding var windowOrg: WindowOrg?
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
        .task {
            if let username = windowOrg?.username, !model.isConnected, !model.isConnecting {
                await model.connect(username: username)
            }
        }
        .onChange(of: model.session?.username) { _, username in
            if windowOrg == nil {
                windowOrg = WindowOrg()
            }
            windowOrg?.username = username
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
            case .schema: SchemaWorkspace(model: model)
            }
        }
        .focusedSceneValue(\.explorerModel, model)
        .background(ToolbarDisplayModeKeeper())
        .modifier(CodeFileHandling(model: model))
        .inspector(isPresented: $showInspector) {
            InspectorPanel(model: model)
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
    ContentView(windowOrg: .constant(nil))
}

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
    @Environment(\.openWindow) private var openWindow

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
        .background(ExplorerWindowObserver(isConnected: model.session != nil) {
            openWindow(value: WindowOrg())
        })
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
            Group {
                switch model.workspace {
                case .query: QueryWorkspace(model: model)
                case .apex: ApexWorkspace(model: model)
                case .schema: SchemaWorkspace(model: model)
                case .logs: LogsWorkspace(model: model)
                case .tests: TestsWorkspace(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.isGuarded && !model.isLocked {
                    UnlockedBanner(model: model)
                }
            }
            .inspector(isPresented: $showInspector) {
                InspectorPanel(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 500)
            }
        }
        .focusedSceneValue(\.explorerModel, model)
        // The Tooling API's SObjects load when a Tooling API tab first shows.
        .task(id: model.schemaAPI) {
            await model.loadSchemaIfNeeded()
        }
        .background(ToolbarDisplayModeKeeper())
        .modifier(CodeFileHandling(model: model))
        .sheet(item: $model.csvImport) { csvImport in
            ImportSheet(model: model, csvImport: csvImport)
        }
        .sheet(isPresented: $model.isShowingLimits) {
            OrgLimitsView(model: model)
        }
        .sheet(isPresented: $model.isExportingDictionary) {
            DataDictionarySheet(model: model)
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
            if let kind = model.orgKind {
                ToolbarItem(placement: .navigation) {
                    OrgKindBadge(kind: kind)
                }
                .withoutSharedBackground()
            }
            if model.isGuarded {
                ToolbarItem(placement: .navigation) {
                    Button {
                        model.setLocked(!model.isLocked)
                    } label: {
                        Label(model.isLocked ? "Read Only" : "Changes Allowed", systemImage: model.isLocked ? "lock.fill" : "lock.open.fill")
                    }
                    .help(model.isLocked ? "This org's data can't be changed from this window. Click to allow changes." : "Changes are allowed in this window. Click to make it read-only again.")
                    .accessibilityIdentifier("changesLock")
                }
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

private extension ToolbarContent {
    /// Leaves the item out of the glass background macOS 26 puts behind toolbar items, for one
    /// that is a label rather than a control.
    @ToolbarContentBuilder
    func withoutSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// The kind of org, as a small colored label in the toolbar.
private struct OrgKindBadge: View {
    let kind: OrgKind

    var body: some View {
        Text(kind.title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(kind.color))
            .fixedSize()
            .help(kind == .unknown ? "SwiftSoql couldn't read this org's type, so it's treated as production." : "This window is connected to a \(kind.title) org.")
            .accessibilityLabel("\(kind.title) org")
            .accessibilityIdentifier("orgKind")
    }
}

/// Shown across the top of a guarded org's window while changes are allowed.
private struct UnlockedBanner: View {
    let model: ExplorerModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Changes are allowed in this \(model.orgKind?.title.lowercased() ?? "production") org.")
                .fontWeight(.medium)
            Spacer()
            Button("Lock") { model.setLocked(true) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.red)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unlockedBanner")
    }
}

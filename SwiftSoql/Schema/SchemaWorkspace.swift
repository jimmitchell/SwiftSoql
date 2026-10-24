import SwiftUI

/// The schema diagram for the SObject selected in the sidebar.
struct SchemaWorkspace: View {
    var model: ExplorerModel

    @AppStorage("schemaFieldMode") private var fieldMode = SchemaFieldMode.important
    @AppStorage("schemaHideSystemChildren") private var hideSystemChildren = true

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Fields", selection: $fieldMode) {
                            ForEach(SchemaFieldMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        Toggle("Hide History, Share, Feed and Change Event SObjects", isOn: $hideSystemChildren)
                    } label: {
                        Label("Diagram Options", systemImage: "slider.horizontal.3")
                    }
                    .help("Choose what the diagram shows")
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let name = model.schemaSelection?.sobjectName {
            if let describe = model.cachedDescribe(name) {
                SchemaDiagram(describe: describe, fieldMode: fieldMode, hideSystemChildren: hideSystemChildren) { related in
                    model.schemaSelection = .sobject(related)
                }
            } else {
                ProgressView("Describing \(name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: name) { await model.ensureDescribed(name) }
            }
        } else {
            ContentUnavailableView("No SObject Selected", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Select an SObject in the sidebar to see how it relates to others. Double-click a related SObject to move to it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

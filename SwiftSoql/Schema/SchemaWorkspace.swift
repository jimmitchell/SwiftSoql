import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                        Divider()
                        Button("Export as PDF…") { export(pdf: true) }
                            .disabled(currentDescribe == nil)
                        Button("Export as PNG…") { export(pdf: false) }
                            .disabled(currentDescribe == nil)
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
                SchemaDiagram(describe: describe, fieldMode: fieldMode, hideSystemChildren: hideSystemChildren,
                              icon: { model.icons.icon(for: $0) }, iconsVersion: model.icons.version) { related in
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

    private var currentDescribe: SObjectDescribe? {
        model.schemaSelection.flatMap { model.cachedDescribe($0.sobjectName) }
    }

    /// Saves the whole diagram, not just the visible part, as a PDF or PNG.
    private func export(pdf: Bool) {
        guard let describe = currentDescribe else { return }
        let layout = SchemaLayout(describe: describe, fieldMode: fieldMode, hideSystemChildren: hideSystemChildren, visibleSize: .zero)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : .png]
        panel.nameFieldStringValue = "\(describe.name) Schema.\(pdf ? "pdf" : "png")"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let icon = { (name: String) in model.icons.icon(for: name) }
                if pdf {
                    try SchemaExport.writePDF(layout, icon: icon, to: url)
                } else {
                    try SchemaExport.writePNG(layout, icon: icon, to: url)
                }
            } catch {
                model.error = DisplayedError("Unable to export the diagram", error)
            }
        }
    }
}

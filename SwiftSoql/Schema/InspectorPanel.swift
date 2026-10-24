import AppKit
import SwiftUI

/// The inspector: details of the schema selection, or the queries run recently.
struct InspectorPanel: View {
    let model: ExplorerModel

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details"
        case recent = "Recent Queries"

        var id: String { rawValue }
    }

    @AppStorage("inspectorTab") private var tab = Tab.details

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch tab {
            case .details: DetailsInspector(model: model)
            case .recent: RecentQueriesList(model: model)
            }
        }
    }
}

/// Queries run in this org, newest first. Click one to put it in the editor; double-click to run it.
struct RecentQueriesList: View {
    let model: ExplorerModel

    @State private var selection = Set<String>()

    var body: some View {
        List(model.recentQueries, id: \.self, selection: $selection) { query in
            Text(query)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
                .padding(.vertical, 2)
                .help(query)
        }
        .contextMenu(forSelectionType: String.self) { queries in
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.recentQueries.filter(queries.contains).joined(separator: "\n\n"), forType: .string)
            }
            .disabled(queries.isEmpty)
            Button("Remove") { model.removeRecentQueries(queries) }
                .disabled(queries.isEmpty)
            Divider()
            Button("Clear All") { model.removeRecentQueries(Set(model.recentQueries)) }
                .disabled(model.recentQueries.isEmpty)
        } primaryAction: { queries in
            if queries.count == 1, let query = queries.first {
                Task { await model.useRecentQuery(query, run: true) }
            }
        }
        .onChange(of: selection) {
            if selection.count == 1, let query = selection.first {
                Task { await model.useRecentQuery(query, run: false) }
            }
        }
        .overlay {
            if model.recentQueries.isEmpty {
                ContentUnavailableView("No Recent Queries", systemImage: "clock", description: Text("Queries you run in this org appear here."))
            }
        }
    }
}

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
            Group {
                switch tab {
                case .details: DetailsInspector(model: model)
                case .recent: RecentQueriesList(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Pinned queries, marked with a pin, then the queries run recently in this org, newest first.
/// Click one to put it in the editor; double-click to run it. Pinned queries can be dragged into order.
struct RecentQueriesList: View {
    let model: ExplorerModel

    @State private var selection = Set<String>()

    var body: some View {
        List(selection: $selection) {
            ForEach(model.pinnedQueries, id: \.self) { query in
                row(query, isPinned: true)
            }
            .onMove { model.movePinnedQueries(fromOffsets: $0, toOffset: $1) }
            ForEach(model.recentQueries, id: \.self) { query in
                row(query, isPinned: false)
            }
        }
        .contextMenu(forSelectionType: String.self) { queries in
            let pinned = queries.filter(model.pinnedQueries.contains)
            let recent = queries.subtracting(pinned)
            if !recent.isEmpty {
                Button("Pin") { model.pinQueries(recent) }
            }
            if !pinned.isEmpty {
                Button("Unpin") { model.unpinQueries(pinned) }
            }
            Button("Copy") {
                let all = model.pinnedQueries + model.recentQueries
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all.filter(queries.contains).joined(separator: "\n\n"), forType: .string)
            }
            .disabled(queries.isEmpty)
            Button("Remove") { model.removeQueries(queries) }
                .disabled(queries.isEmpty)
            Divider()
            Button("Clear Recent Queries") { model.clearRecentQueries() }
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
            if model.recentQueries.isEmpty && model.pinnedQueries.isEmpty {
                ContentUnavailableView("No Recent Queries", systemImage: "clock", description: Text("Queries you run in this org appear here. Right-click one to pin it, so it's always kept."))
            }
        }
    }

    private func row(_ query: String, isPinned: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Recent queries keep the pin's space, so all the queries line up.
            Image(systemName: "pin.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .opacity(isPinned ? 1 : 0)
                .accessibilityLabel(isPinned ? "Pinned" : "")
                .accessibilityHidden(!isPinned)
            Text(query)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(4)
        }
        .padding(.vertical, 2)
        .help(query)
            .swipeActions(edge: .trailing) {
                if isPinned {
                    Button("Unpin", systemImage: "pin.slash") { model.unpinQueries([query]) }
                } else {
                    Button("Pin", systemImage: "pin") { model.pinQueries([query]) }
                        .tint(.orange)
                }
            }
    }
}

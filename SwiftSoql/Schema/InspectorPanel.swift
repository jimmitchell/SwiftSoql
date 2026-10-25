import AppKit
import SwiftUI

/// The inspector: details of the schema selection, every field of the selected record, or the
/// queries run recently.
struct InspectorPanel: View {
    let model: ExplorerModel

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details"
        case record = "Record"
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
                case .record: RecordInspector(model: model)
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
            ForEach(model.history.pinned, id: \.self) { query in
                row(query, isPinned: true)
            }
            .onMove { model.history.movePinned(fromOffsets: $0, toOffset: $1) }
            ForEach(model.history.recent, id: \.self) { query in
                row(query, isPinned: false)
            }
        }
        .accessibilityIdentifier("recentQueries")
        .contextMenu(forSelectionType: String.self) { queries in
            let pinned = queries.filter(model.history.pinned.contains)
            let recent = queries.subtracting(pinned)
            if !recent.isEmpty {
                Button("Pin") { model.history.pin(recent) }
            }
            if !pinned.isEmpty {
                Button("Unpin") { model.history.unpin(pinned) }
            }
            Button("Copy") {
                let all = model.history.pinned + model.history.recent
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(all.filter(queries.contains).joined(separator: "\n\n"), forType: .string)
            }
            .disabled(queries.isEmpty)
            Button("Remove") { model.history.remove(queries) }
                .disabled(queries.isEmpty)
            Divider()
            Button("Clear Recent Queries") { model.history.clearRecent() }
                .disabled(model.history.recent.isEmpty)
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
            if model.history.recent.isEmpty && model.history.pinned.isEmpty {
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
                    Button("Unpin", systemImage: "pin.slash") { model.history.unpin([query]) }
                } else {
                    Button("Pin", systemImage: "pin") { model.history.pin([query]) }
                        .tint(.orange)
                }
            }
    }
}

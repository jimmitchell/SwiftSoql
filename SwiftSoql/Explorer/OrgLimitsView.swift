import SwiftUI

/// The org's limits, most used first, with a bar for each.
struct OrgLimitsView: View {
    let model: ExplorerModel

    @Environment(\.dismiss) private var dismiss
    @State private var limits: [OrgLimit]?
    @State private var loadError: String?
    @State private var filter = ""
    @State private var reloads = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Limits for \(model.session?.displayName ?? "this org")")
                    .font(.headline)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Button {
                    reloads += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .accessibilityLabel("Reload")
            }
            .padding(12)
            Divider()
            if let limits {
                let shown = limits.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.name.localizedCaseInsensitiveContains(filter) }
                List(shown) { limit in
                    row(limit)
                }
                .accessibilityIdentifier("orgLimits")
            } else if let loadError {
                ContentUnavailableView("Unable to load the limits", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("Most used first. Salesforce updates some limits only every few minutes.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
        .task(id: reloads) {
            loadError = nil
            do {
                limits = try await model.orgLimits()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func row(_ limit: OrgLimit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                Spacer()
                Text("\(limit.used.formatted()) of \(limit.max.formatted())\(limit.unit) used")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: limit.fraction)
                .tint(limit.fraction >= 0.9 ? .red : limit.fraction >= 0.75 ? .orange : .accentColor)
        }
        .padding(.vertical, 3)
        .help(limit.name)
        .accessibilityElement(children: .combine)
    }
}

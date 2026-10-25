import SwiftUI

/// Every field of the record selected in the results, with labels. Fields can be edited when
/// the window allows changes, and lookups lead to the related record, with Back to return.
struct RecordInspector: View {
    let model: ExplorerModel

    @State private var describe: SObjectDescribe?
    @State private var fields: JSONObject?
    @State private var loadError: String?
    @State private var filter = ""
    @AppStorage("recordInspectorHidesEmptyFields") private var hideEmpty = false
    @Environment(\.openURL) private var openURL

    private var record: RecordReference? { model.inspectedRecords.last }

    var body: some View {
        Group {
            if let record {
                VStack(spacing: 0) {
                    header(record)
                    Divider()
                    content(record)
                }
            } else {
                ContentUnavailableView("No Record", systemImage: "doc.text.magnifyingglass", description: Text("Select a row in the results to see every field of its record."))
            }
        }
        // Waits a moment, so moving through rows with the arrow keys doesn't fetch each one.
        .task(id: record) {
            describe = nil
            fields = nil
            loadError = nil
            guard let record else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let loaded = try await model.fetchRecord(record)
                describe = loaded.describe
                fields = loaded.fields
            } catch is CancellationError {
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func header(_ record: RecordReference) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.inspectedRecords.count > 1 {
                    Button {
                        model.inspectedRecords.removeLast()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to \(model.inspectedRecords[model.inspectedRecords.count - 2].sobject)")
                    .accessibilityLabel("Back")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(fields?["Name"]?.displayText ?? record.sobject)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(record.sobject) \(record.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button {
                    if let url = model.recordURL(record.id) { openURL(url) }
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.borderless)
                .help("Open in Salesforce")
                .accessibilityLabel("Open in Salesforce")
            }
            HStack {
                TextField("Filter Fields", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Hide Empty", isOn: $hideEmpty)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    @ViewBuilder
    private func content(_ record: RecordReference) -> some View {
        if let describe, let fields {
            let shown = describe.fields
                .filter { field in
                    (filter.isEmpty || field.name.localizedCaseInsensitiveContains(filter) || field.label.localizedCaseInsensitiveContains(filter))
                        && (!hideEmpty || !(fields[field.name]?.displayText ?? "").isEmpty)
                }
                .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            List(shown) { field in
                row(field, value: fields[field.name], record: record)
            }
            .accessibilityIdentifier("recordFields")
        } else if let loadError {
            ContentUnavailableView("Unable to load \(record.id)", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ field: FieldDescribe, value: JSONValue?, record: RecordReference) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.label)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(field.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            valueView(field, value: value, record: record)
                .font(.callout)
        }
        .padding(.vertical, 2)
        .help(field.typeDescription)
    }

    @ViewBuilder
    private func valueView(_ field: FieldDescribe, value: JSONValue?, record: RecordReference) -> some View {
        let text = value?.displayText ?? ""
        if record.api == .data, model.canChangeData, field.updateable, field.type != "reference" {
            FieldEditor(field: field, value: value, isDisabled: model.isSaving) { newText in
                guard let saved = await model.saveField(newText, field: field.name, sobject: record.sobject, id: record.id) else { return false }
                fields?[field.name] = saved
                return true
            }
        } else if field.type == "reference", !text.isEmpty, let type = model.sobjectType(ofRecordID: text) {
            Button(text) {
                model.inspectedRecords.append(RecordReference(sobject: type, id: text, api: record.api))
            }
            .buttonStyle(.link)
            .help("Show this \(type)")
        } else {
            Text(text.isEmpty ? "—" : text)
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(6)
        }
    }
}

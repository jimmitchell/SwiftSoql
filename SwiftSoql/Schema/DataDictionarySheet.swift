import AppKit
import SwiftUI

/// Chooses SObjects and a format, then writes their data dictionary to a file.
struct DataDictionarySheet: View {
    let model: ExplorerModel

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var filter = ""
    @State private var format = DataDictionary.Format.csv
    @State private var progress: (done: Int, total: Int)?
    @State private var task: Task<Void, Never>?

    private var shown: [GlobalSObject] {
        model.dataSchema.sobjects.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.label.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Data Dictionary")
                    .font(.headline)
                HStack {
                    TextField("Filter SObjects", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose Shown") { chosen.formUnion(shown.map(\.name)) }
                    Button("Clear") { chosen = [] }
                        .disabled(chosen.isEmpty)
                }
            }
            .padding(12)
            Divider()
            List(shown) { sobject in
                Toggle(isOn: Binding { chosen.contains(sobject.name) } set: { isOn in
                    if isOn { chosen.insert(sobject.name) } else { chosen.remove(sobject.name) }
                }) {
                    HStack {
                        Text(sobject.name)
                        Text(sobject.label)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .accessibilityIdentifier("dictionarySObjects")
            Divider()
            HStack {
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 160)
                    Text("Describing \(progress.done) of \(progress.total)…")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Format", selection: $format) {
                        ForEach(DataDictionary.Format.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Text("\(chosen.count) chosen")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseFile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || progress != nil)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            if let selected = model.schemaSelection?.sobjectName, model.schemaAPI == .data {
                chosen = [selected]
            }
        }
    }

    private func chooseFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = (chosen.count == 1 ? chosen.first! : "Data Dictionary") + "." + format.fileExtension
        let names = model.dataSchema.sobjects.map(\.name).filter(chosen.contains)
        let format = format
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            task = Task { await export(names, format: format, to: url) }
        }
    }

    private func export(_ names: [String], format: DataDictionary.Format, to url: URL) async {
        progress = (0, names.count)
        defer { progress = nil }
        do {
            try await model.exportDataDictionary(names, format: format, to: url) { progress = ($0, names.count) }
            dismiss()
        } catch is CancellationError {
        } catch {
            model.error = DisplayedError("Unable to export the data dictionary", error)
        }
    }
}

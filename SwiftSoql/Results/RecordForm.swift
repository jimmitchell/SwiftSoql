import SwiftUI

/// The form for creating a record: the SObject's fields that a new record can set, required ones
/// first, each with a control that suits its type.
struct RecordForm: View {
    let model: ExplorerModel
    @State var draft: RecordDraft

    @Environment(\.dismiss) private var dismiss
    @State private var describe: SObjectDescribe?
    @State private var filter = ""
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let describe {
                fieldList(describe)
            } else if draft.sobject.isEmpty {
                ContentUnavailableView("Choose an SObject", systemImage: "plus.rectangle", description: Text("Pick the type of record to create."))
            } else {
                ProgressView("Describing \(draft.sobject)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 660)
        .task(id: draft.sobject) {
            describe = nil
            guard !draft.sobject.isEmpty else { return }
            describe = try? await model.dataSchema.describe(draft.sobject)
        }
    }

    private var header: some View {
        HStack {
            if let source = draft.clonedFrom {
                Text("Copy of \(draft.sobject) \(source)")
                    .font(.headline)
            } else {
                Picker("New", selection: $draft.sobject) {
                    Text("Choose…").tag("")
                    ForEach(model.createableSObjects, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 300)
                .accessibilityIdentifier("newRecordSObject")
            }
            Spacer()
            TextField("Filter Fields", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
        .padding(12)
    }

    private func fieldList(_ describe: SObjectDescribe) -> some View {
        let fields = RecordDraft.fields(of: describe).filter {
            filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.label.localizedCaseInsensitiveContains(filter)
        }
        let required = fields.filter(\.isRequiredOnCreate)
        let others = fields.filter { !$0.isRequiredOnCreate }
        return Form {
            if !required.isEmpty {
                Section("Required") {
                    ForEach(required) { row($0) }
                }
            }
            Section(required.isEmpty ? "Fields" : "Other Fields") {
                ForEach(others) { row($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ field: FieldDescribe) -> some View {
        LabeledContent {
            RecordFieldInput(field: field, text: Binding { draft.values[field.name] ?? "" } set: { draft.values[field.name] = $0 })
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(field.label + (field.isRequiredOnCreate ? " *" : ""))
                Text(field.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .help(field.typeDescription)
    }

    private var footer: some View {
        HStack {
            if let saveError {
                Text(saveError)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let describe, !draft.missingFields(describe).isEmpty {
                Text("Fill in \(draft.missingFields(describe).map(\.label).formatted()).")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(describe.map { !draft.missingFields($0).isEmpty } ?? true || model.isSaving)
        }
        .padding(12)
    }

    private func save() {
        saveError = nil
        Task {
            do {
                try await model.createRecord(draft)
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// The control for one field of a new record, editing the field's text.
private struct RecordFieldInput: View {
    let field: FieldDescribe
    @Binding var text: String

    @State private var isPicking = false
    @State private var picked = Date()

    var body: some View {
        switch field.type {
        case "boolean":
            // Unset, it shows the field's default, which Salesforce fills in.
            Toggle(field.label, isOn: Binding {
                text.isEmpty ? field.json["defaultValue"]?.bool ?? false : text == "true"
            } set: {
                text = $0 ? "true" : "false"
            })
            .toggleStyle(.checkbox)
            .labelsHidden()
        case "picklist":
            Picker(field.label, selection: $text) {
                Text("None").tag("")
                ForEach(field.picklistValues.filter(\.active), id: \.value) { item in
                    Text(item.label).tag(item.value)
                }
                // A cloned value that's no longer active still shows.
                if !text.isEmpty, !field.picklistValues.contains(where: { $0.value == text && $0.active }) {
                    Text(text).tag(text)
                }
            }
            .labelsHidden()
        case "date", "datetime":
            let includesTime = field.type == "datetime"
            HStack(spacing: 4) {
                textField(includesTime ? "2026-01-31T17:30:00.000Z" : "2026-01-31")
                Button {
                    picked = SalesforceDates.parse(text, includesTime: includesTime) ?? Date()
                    isPicking = true
                } label: {
                    Image(systemName: "calendar")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Choose \(field.label)")
                .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                    VStack(alignment: .trailing, spacing: 10) {
                        DatePicker(field.label, selection: $picked, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                        Button("Use Date") {
                            text = SalesforceDates.format(picked, includesTime: includesTime)
                            isPicking = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
            }
        case "textarea":
            TextField(field.label, text: $text, prompt: Text(""), axis: .vertical)
                .lineLimit(1...5)
                .labelsHidden()
        case "reference":
            textField("Id of a " + field.referenceTo.joined(separator: " or "))
        case "int", "double", "currency", "percent":
            textField("Number")
        case "email":
            textField("name@example.com")
        case "url":
            textField("https://")
        default:
            textField(field.isRequiredOnCreate ? "Required" : "Text")
        }
    }

    private func textField(_ prompt: String) -> some View {
        TextField(field.label, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .accessibilityIdentifier("field." + field.name)
    }
}

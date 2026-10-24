import SwiftUI

/// Edits a results cell in a way that suits its field: a checkbox for true/false fields, a menu
/// of values for picklists, text with a date picker for dates, and text for everything else.
struct FieldEditor: View {
    let field: FieldDescribe
    let value: JSONValue?
    var isDisabled = false
    /// Saves text for the field, returning whether it was saved. Empty text clears the field.
    let save: (String) async -> Bool

    var body: some View {
        switch field.type {
        case "boolean":
            Toggle(field.name, isOn: Binding {
                value?.bool ?? false
            } set: { isOn in
                Task { await save(isOn ? "true" : "false") }
            })
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(isDisabled)
        case "picklist":
            PicklistCell(field: field, value: value?.string, isDisabled: isDisabled, save: save)
        case "date", "datetime":
            DateCell(field: field, value: value?.string, isDisabled: isDisabled, save: save)
        default:
            EditableCell(value: value?.displayText ?? "", isDisabled: isDisabled, save: save)
        }
    }
}

/// A picklist value shown as text, with a menu of the field's active values to change it.
private struct PicklistCell: View {
    let field: FieldDescribe
    let value: String?
    var isDisabled = false
    let save: (String) async -> Bool

    var body: some View {
        Menu {
            if field.nillable {
                Button("None") { choose("") }
                Divider()
            }
            ForEach(field.picklistValues.filter(\.active), id: \.value) { item in
                Button(item.label == item.value ? item.value : "\(item.label) (\(item.value))") { choose(item.value) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(value ?? "")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isDisabled)
        .help(value ?? "Choose a value")
    }

    private func choose(_ newValue: String) {
        guard newValue != (value ?? "") else { return }
        Task { await save(newValue) }
    }
}

/// A date or date-time cell: the value can be typed, or picked from a calendar that appears while
/// the pointer is over the cell.
private struct DateCell: View {
    let field: FieldDescribe
    let value: String?
    var isDisabled = false
    let save: (String) async -> Bool

    @State private var isHovering = false
    @State private var isPicking = false
    @State private var picked = Date()

    private var includesTime: Bool { field.type == "datetime" }

    var body: some View {
        HStack(spacing: 2) {
            EditableCell(value: value ?? "", isDisabled: isDisabled, save: save)
            if isHovering || isPicking {
                Button {
                    picked = value.flatMap { SalesforceDates.parse($0, includesTime: includesTime) } ?? Date()
                    isPicking = true
                } label: {
                    Image(systemName: "calendar")
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
                .help("Choose a date")
                .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                    picker
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var picker: some View {
        VStack(alignment: .trailing, spacing: 10) {
            DatePicker(field.name, selection: $picked, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if field.nillable {
                    Button("Clear") { finish("") }
                }
                Spacer()
                Button("Cancel") { isPicking = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { finish(SalesforceDates.format(picked, includesTime: includesTime)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func finish(_ text: String) {
        isPicking = false
        guard text != (value ?? "") else { return }
        Task { await save(text) }
    }
}

/// Salesforce's text formats for dates (2024-05-01, a calendar day with no time zone) and
/// date-times (2024-05-01T17:30:00.000+0000, in UTC).
enum SalesforceDates {
    private static func formatter(includesTime: Bool, forParsing: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if includesTime {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = forParsing ? "yyyy-MM-dd'T'HH:mm:ss.SSSZ" : "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        } else {
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
        }
        return f
    }

    static func parse(_ text: String, includesTime: Bool) -> Date? {
        formatter(includesTime: includesTime, forParsing: true).date(from: text)
    }

    static func format(_ date: Date, includesTime: Bool) -> String {
        formatter(includesTime: includesTime, forParsing: false).string(from: date)
    }
}

/// A results cell that saves its value when editing ends with Return or by moving elsewhere.
/// Escape puts the value back.
struct EditableCell: View {
    let value: String
    var isDisabled = false
    /// Saves the text, returning whether it was saved.
    let save: (String) async -> Bool

    @State private var draft = ""
    @State private var isSavingDraft = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // An empty prompt, so empty values look like the read-only cells.
        TextField(text: $draft, prompt: Text("")) { Text("Value") }
            .labelsHidden()
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($isFocused)
            .disabled(isDisabled)
            .help(value)
            .onAppear { draft = value }
            .onChange(of: value) { draft = value }
            .onSubmit { commit() }
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
            .onExitCommand {
                draft = value
                isFocused = false
            }
    }

    private func commit() {
        guard draft != value, !isSavingDraft else { return }
        isSavingDraft = true
        let text = draft
        Task {
            if !(await save(text)) {
                draft = value
            }
            isSavingDraft = false
        }
    }
}

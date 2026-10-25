import SwiftUI

/// Renames, reorders, edits and deletes the saved Apex snippets.
struct ApexSnippetsSheet: View {
    let apex: ApexModel

    @Environment(\.dismiss) private var dismiss
    @Bindable private var snippets = ApexSnippets.shared
    @State private var selection: ApexSnippets.Snippet.ID?

    var body: some View {
        VStack(spacing: 0) {
            Text("Apex Snippets")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            Divider()
            if snippets.snippets.isEmpty {
                ContentUnavailableView("No Snippets", systemImage: "text.badge.plus", description: Text("Select some Apex and choose Snippets ▸ Save Selection as Snippet."))
            } else {
                List(selection: $selection) {
                    ForEach($snippets.snippets) { $snippet in
                        TextField("Name", text: $snippet.name)
                            .tag(snippet.id)
                    }
                    .onMove { snippets.snippets.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { snippets.snippets.remove(atOffsets: $0) }
                }
                .frame(height: 200)
                Divider()
                if let index = snippets.snippets.firstIndex(where: { $0.id == selection }) {
                    TextEditor(text: $snippets.snippets[index].code)
                        .font(.system(size: 12, design: .monospaced))
                        .accessibilityIdentifier("snippetCode")
                } else {
                    Text("Select a snippet to edit its code.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Button("Delete") {
                    snippets.snippets.removeAll { $0.id == selection }
                    selection = nil
                }
                .disabled(selection == nil)
                Button("Insert") {
                    if let snippet = snippets.snippets.first(where: { $0.id == selection }) {
                        apex.insert(snippet.code)
                        dismiss()
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 520)
    }
}

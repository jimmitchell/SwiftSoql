import AppKit
import SwiftUI

/// Loaded results as colored, indented JSON, in the table's order.
struct ResultsJSONView: View {
    let resultSet: ResultSet

    /// Showing more than this would make the text view slow; exporting writes them all.
    static let rowLimit = 1_000

    @State private var text = ""

    /// Changes when the rows or their order do.
    private var contentKey: String {
        "\(resultSet.id) \(resultSet.rows.count) \(resultSet.sortOrder.map { "\($0.column) \($0.order == .forward)" })"
    }

    var body: some View {
        VStack(spacing: 0) {
            if resultSet.rows.count > Self.rowLimit {
                Text("Showing the first \(Self.rowLimit.formatted()) of \(resultSet.rows.count.formatted()) loaded rows. Export JSON writes them all.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                Divider()
            }
            JSONTextView(text: text)
        }
        .task(id: contentKey) {
            text = ResultsExport.json(resultSet.rows.prefix(Self.rowLimit).map(\.record))
        }
    }
}

/// Read-only, selectable JSON text with keys, strings and numbers colored like the query editor.
private struct JSONTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.setAccessibilityLabel("Results as JSON")
        textView.setAccessibilityIdentifier("resultsJSON")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.textStorage?.setAttributedString(Self.colored(text))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Strings (group 1), followed by a colon if they're keys (group 2), and numbers and
    /// literals (group 3).
    private static let tokens = try! NSRegularExpression(pattern: #"("(?:[^"\\\n]|\\.)*")(\s*:)?|(-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|\btrue\b|\bfalse\b|\bnull\b)"#)

    private static func colored(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ])
        for match in tokens.matches(in: text, range: NSRange(location: 0, length: out.length)) {
            if match.range(at: 1).location != NSNotFound {
                let isKey = match.range(at: 2).location != NSNotFound
                out.addAttribute(.foregroundColor, value: isKey ? SOQLStyle.field : SOQLStyle.literal, range: match.range(at: 1))
            } else {
                out.addAttribute(.foregroundColor, value: SOQLStyle.keyword, range: match.range(at: 3))
            }
        }
        return out
    }
}

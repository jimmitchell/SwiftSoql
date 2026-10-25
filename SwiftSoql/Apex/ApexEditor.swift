import AppKit
import SwiftUI

/// The anonymous Apex editor: syntax coloring, a marker on the line that failed, inline SOQL
/// checked like the query editor, and completions of SObject and field names.
struct ApexEditor: NSViewRepresentable {
    @Binding var text: String
    /// The failed run to mark, if any.
    var error: ApexExecution?
    /// Supplies describes for inline SOQL and completions.
    var model: ExplorerModel
    /// Changes when new describes are available, so inline SOQL is checked again.
    var schemaGeneration = 0
    /// A line to move to, e.g. one clicked in the debug log.
    var revealLine: ApexModel.LineRequest?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        let textView = SOQLTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.configureForCode()
        textView.completionsProvider = { [weak coordinator = context.coordinator, weak textView] range in
            guard let coordinator, let textView else { return [] }
            return coordinator.completions(for: range, in: textView.string as NSString)
        }
        textView.setAccessibilityIdentifier("apexEditor")
        textView.setAccessibilityLabel("Anonymous Apex")
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.parent = self
        context.coordinator.colorize(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: fullRange, replacementString: text) {
                textView.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            }
        } else if coordinator.markedError?.id != error?.id || coordinator.colorizedGeneration != schemaGeneration {
            let errorChanged = coordinator.markedError?.id != error?.id
            coordinator.colorize(textView)
            if errorChanged, let error {
                coordinator.reveal(error, in: textView)
            }
        }
        if let revealLine, coordinator.revealedLine != revealLine.id {
            coordinator.revealedLine = revealLine.id
            coordinator.reveal(line: revealLine.line, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ApexEditor
        fileprivate var markedError: ApexExecution?
        fileprivate var colorizedGeneration = -1
        fileprivate var revealedLine: UUID?
        private let analyzer = SoqlAnalyzer()
        /// Completions for the inline SOQL, by position in the code.
        private var queryCompletions = CompletionLocations()
        /// The inline queries' ranges, from the last time the code was checked.
        private var queryRanges: [NSRange] = []

        init(parent: ApexEditor) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            // The selection can change while SwiftUI updates the view, so record it afterwards.
            Task { @MainActor [parent] in
                if parent.model.apex.selectedRange != selection {
                    parent.model.apex.selectedRange = selection
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            colorize(textView)
        }

        func colorize(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
            for key: NSAttributedString.Key in [.toolTip, .underlineStyle, .underlineColor] {
                storage.removeAttribute(key, range: all)
            }
            for match in ApexSyntax.tokens.matches(in: storage.string, range: all) {
                let range = match.range
                let token = (storage.string as NSString).substring(with: range)
                let color: NSColor? = if match.range(at: 1).location != NSNotFound {
                    .secondaryLabelColor
                } else if match.range(at: 2).location != NSNotFound || match.range(at: 3).location != NSNotFound {
                    SOQLStyle.literal
                } else if ApexSyntax.keywords.contains(token.lowercased()) {
                    SOQLStyle.keyword
                } else {
                    nil
                }
                if let color {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            colorInlineQueries(storage)
            markedError = parent.error
            if let error = parent.error, let range = Self.errorRange(error, in: storage.string as NSString) {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor.systemRed,
                    .toolTip: error.resultText,
                ], range: range)
            }
            storage.endEditing()
        }

        /// Checks and colors each `[SELECT …]` in the code as the query editor would, with its bind
        /// variables masked so they aren't reported as errors.
        private func colorInlineQueries(_ storage: NSTextStorage) {
            colorizedGeneration = parent.schemaGeneration
            queryCompletions.clear()
            queryRanges = ApexSource.inlineQueries(in: storage.string as NSString)
            analyzer.describer = parent.model.dataSchema
            for range in queryRanges {
                let query = (storage.string as NSString).substring(with: range)
                let masked = ApexSource.maskingBinds(in: query)
                storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                let binds = masked.binds.map { NSRange(location: $0.location + range.location, length: $0.length) }
                SOQLHighlighter.apply(analyzer.parseAndResolve(masked.query), to: storage, offset: range.location,
                                      uppercaseKeywords: false, ignoringErrorsIn: binds) { completions, loc in
                    self.queryCompletions.add(completions, at: loc)
                }
                // The binds were checked as placeholders; show them as plain Apex.
                for bind in binds {
                    storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: bind)
                }
            }
        }

        /// SOQL completions inside an inline query; elsewhere, an SObject's fields after `name.`
        /// or inside `new Name(…)`, and SObject names for a word that starts like one.
        func completions(for range: NSRange, in text: NSString) -> [Completion] {
            if queryRanges.contains(where: { NSLocationInRange(range.location, $0) || NSMaxRange($0) == range.location }) {
                return queryCompletions.completions(in: range)
            }
            // Apex works with the data API's SObjects, whatever the query tab uses.
            let schema = parent.model.dataSchema
            func sobjectNamed(_ name: String) -> String? {
                schema.sobjects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name
            }
            func fields(of sobject: String) -> [Completion] {
                guard let describe = schema.cachedDescribe(sobject) else {
                    // Fetch it for next time; the popup shows once it's described.
                    _ = schema.schemaObject(sobject)
                    return []
                }
                return describe.fields.map { Completion($0.name, type: .field) }
            }
            switch ApexSource.completionContext(in: text, wordRange: range) {
            case .afterDot(let name):
                let variables = ApexSource.sobjectVariables(in: text as String, sobjectNamed: sobjectNamed)
                guard let sobject = sobjectNamed(name) ?? variables[name.lowercased()] else { return [] }
                return fields(of: sobject)
            case .newObject(let name):
                return sobjectNamed(name).map(fields) ?? []
            case .word:
                let typed = text.substring(with: range)
                guard typed.count >= 2 else { return [] }
                return schema.sobjects.filter { $0.name.lowercased().hasPrefix(typed.lowercased()) }
                    .map { Completion($0.name, type: .sobject) }
            }
        }

        /// Selects a line (counting from 1) and scrolls to it.
        func reveal(line: Int, in textView: NSTextView) {
            let text = textView.string as NSString
            var start = 0
            for _ in 1..<max(line, 1) {
                let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
                guard newline.location != NSNotFound else { return }
                start = NSMaxRange(newline)
            }
            let lineRange = text.lineRange(for: NSRange(location: start, length: 0))
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(lineRange)
            textView.scrollRangeToVisible(lineRange)
        }

        /// Puts the insertion point where the error is.
        func reveal(_ error: ApexExecution, in textView: NSTextView) {
            guard let range = Self.errorRange(error, in: textView.string as NSString) else { return }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
        }

        /// From the error's column to the end of its line. Lines and columns count from 1.
        private static func errorRange(_ error: ApexExecution, in text: NSString) -> NSRange? {
            guard error.editorLine > 0 else { return nil }
            var lineStart = 0
            for _ in 1..<error.editorLine {
                let newline = text.range(of: "\n", range: NSRange(location: lineStart, length: text.length - lineStart))
                guard newline.location != NSNotFound else { return nil }
                lineStart = NSMaxRange(newline)
            }
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineEnd = NSMaxRange(lineRange)
            while lineEnd > lineStart, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) {
                lineEnd -= 1
            }
            let start = min(lineStart + max(error.editorColumn - 1, 0), lineEnd)
            // An error at the end of a line still needs something to underline.
            if start == lineEnd {
                return lineEnd > lineStart ? NSRange(location: lineEnd - 1, length: 1) : nil
            }
            return NSRange(location: start, length: lineEnd - start)
        }
    }
}

private enum ApexSyntax {
    /// Comments (group 1), strings (group 2), numbers (group 3) and words.
    static let tokens = try! NSRegularExpression(pattern: #"(//[^\n]*|/\*[\s\S]*?(?:\*/|$))|('(?:[^'\\\n]|\\.)*'?)|(\b\d+(?:\.\d+)?[lLdD]?\b)|\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static let keywords: Set<String> = [
        "abstract", "after", "and", "as", "asc", "before", "break", "by", "catch", "class", "continue",
        "delete", "desc", "do", "else", "enum", "extends", "false", "final", "finally", "for", "from",
        "global", "group", "having", "if", "implements", "in", "inherited", "insert", "instanceof",
        "interface", "like", "limit", "merge", "new", "not", "null", "offset", "on", "or", "order",
        "override", "private", "protected", "public", "return", "select", "sharing", "static", "super",
        "switch", "testmethod", "this", "throw", "transient", "trigger", "true", "try", "undelete",
        "update", "upsert", "virtual", "void", "webservice", "when", "where", "while", "with", "without",
    ]
}

extension NSTextView {
    /// Settings for editing code: plain text, monospaced, and no smart quotes, dashes or
    /// autocorrect, which would otherwise corrupt it as it's typed.
    func configureForCode() {
        isRichText = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 4, height: 6)
    }
}

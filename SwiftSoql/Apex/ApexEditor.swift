import AppKit
import SwiftUI

/// The anonymous Apex editor, with simple syntax coloring and a marker on the line that failed.
struct ApexEditor: NSViewRepresentable {
    @Binding var text: String
    /// The failed run to mark, if any.
    var error: ApexExecution?

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        let textView = scrollView.documentView as! NSTextView
        textView.configureForCode()
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
        } else if coordinator.markedError?.id != error?.id {
            coordinator.colorize(textView)
            if let error {
                coordinator.reveal(error, in: textView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ApexEditor
        fileprivate var markedError: ApexExecution?

        init(parent: ApexEditor) {
            self.parent = parent
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

        /// Puts the insertion point where the error is.
        func reveal(_ error: ApexExecution, in textView: NSTextView) {
            guard let range = Self.errorRange(error, in: textView.string as NSString) else { return }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
        }

        /// From the error's column to the end of its line. Lines and columns count from 1.
        private static func errorRange(_ error: ApexExecution, in text: NSString) -> NSRange? {
            guard error.line > 0 else { return nil }
            var lineStart = 0
            for _ in 1..<error.line {
                let newline = text.range(of: "\n", range: NSRange(location: lineStart, length: text.length - lineStart))
                guard newline.location != NSNotFound else { return nil }
                lineStart = NSMaxRange(newline)
            }
            let lineRange = text.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineEnd = NSMaxRange(lineRange)
            while lineEnd > lineStart, [0x0A, 0x0D].contains(text.character(at: lineEnd - 1)) {
                lineEnd -= 1
            }
            let start = min(lineStart + max(error.column - 1, 0), lineEnd)
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

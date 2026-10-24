import AppKit
import SwiftUI

/// The SOQL editor, with syntax highlighting, error checking against the org's schema, and
/// completions.
///
/// Wraps an NSTextView so smart quotes, dashes and autocorrect can be turned off; they would
/// otherwise corrupt queries as they're typed.
struct SOQLEditor: NSViewRepresentable {
    @Binding var text: String
    /// Supplies describes for checking the query and for completions.
    var describer: SoqlDescriber?
    /// Changes when new describes are available, so the query is checked again.
    var schemaGeneration = 0

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
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.completionsProvider = { [weak coordinator = context.coordinator] range in
            coordinator?.completions.completions(in: range) ?? []
        }
        textView.string = text
        scrollView.documentView = textView

        context.coordinator.parent = self
        context.coordinator.isUpdatingView = true
        context.coordinator.colorize(textView)
        context.coordinator.isUpdatingView = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? SOQLTextView else { return }
        coordinator.isUpdatingView = true
        defer { coordinator.isUpdatingView = false }
        if textView.string != text {
            // Replace through the text storage so the change can be undone; didChangeText recolors.
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: fullRange, replacementString: text) {
                textView.replaceCharacters(in: fullRange, with: text)
                textView.didChangeText()
            }
        } else if coordinator.colorizedGeneration != schemaGeneration {
            coordinator.colorize(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SOQLEditor
        private let analyzer = SoqlAnalyzer()
        fileprivate var completions = CompletionLocations()
        fileprivate var colorizedGeneration = -1
        /// True while SwiftUI is updating the view, when the binding can't be changed directly.
        fileprivate var isUpdatingView = false
        private var coloredLastTime = false

        init(parent: SOQLEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            colorize(textView)
            updateBinding(textView.string)
        }

        /// Updates the binding, deferring it if SwiftUI is in the middle of updating the view.
        private func updateBinding(_ newText: String) {
            guard newText != parent.text else { return }
            if isUpdatingView {
                // During a view update the editor only changes the case of keywords, so skip the
                // deferred write if the text has since been changed to something else.
                DispatchQueue.main.async { [self] in
                    if parent.text.caseInsensitiveCompare(newText) == .orderedSame {
                        parent.text = newText
                    }
                }
            } else {
                parent.text = newText
            }
        }

        // Suppress the standard completions (F5 / ⌥⎋); SOQLTextView shows its own.
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            []
        }

        /// Checks the query and applies syntax colors, error underlines and completions.
        func colorize(_ textView: NSTextView) {
            colorizedGeneration = parent.schemaGeneration
            guard let storage = textView.textStorage else { return }
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "soqlSyntaxHighlighting") else {
                if coloredLastTime {
                    storage.beginEditing()
                    removeAttributes(storage)
                    storage.endEditing()
                    coloredLastTime = false
                }
                return
            }
            analyzer.describer = parent.describer
            let tokens = analyzer.parseAndResolve(storage.string)
            let selection = textView.selectedRanges
            storage.beginEditing()
            removeAttributes(storage)
            apply(tokens, to: storage,
                  uppercaseKeywords: defaults.bool(forKey: "soqlUppercaseKeywords"),
                  addCompletions: defaults.bool(forKey: "soqlPopupCompletions"))
            storage.endEditing()
            textView.selectedRanges = selection
            coloredLastTime = true
            // Uppercasing keywords changes the text.
            updateBinding(textView.string)
        }

        private func removeAttributes(_ storage: NSTextStorage) {
            let all = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
            for key: NSAttributedString.Key in [.toolTip, .cursor, .underlineStyle, .underlineColor] {
                storage.removeAttribute(key, range: all)
            }
            completions.clear()
        }

        private func apply(_ tokens: Tokens, to storage: NSTextStorage, uppercaseKeywords: Bool, addCompletions: Bool) {
            for t in tokens.tokens where NSMaxRange(t.loc) <= storage.length {
                if addCompletions && !t.completions.isEmpty {
                    completions.add(t.completions, at: t.loc)
                }
                switch t.type {
                case .error:
                    storage.addAttributes([
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: SOQLStyle.error,
                    ], range: t.loc)
                    if let message = t.errorMessage {
                        storage.addAttributes([.toolTip: message, .cursor: NSCursor.pointingHand], range: t.loc)
                    }
                case .keyword, .operator:
                    let upper = t.tokenTxt.uppercased()
                    if uppercaseKeywords, upper != t.tokenTxt, upper.utf16.count == t.loc.length {
                        storage.replaceCharacters(in: t.loc, with: upper)
                    }
                    storage.addAttribute(.foregroundColor, value: SOQLStyle.keyword, range: t.loc)
                default:
                    if let color = SOQLStyle.color(for: t.type) {
                        storage.addAttribute(.foregroundColor, value: color, range: t.loc)
                    }
                }
                // Only these token types color their children; e.g. FIELDS(STANDARD) turns a field path
                // into a keyword, and its unresolved field shouldn't show as an error.
                let containers: TokenType = [.fieldPath, .sobject, .function, .typeOf, .childSelect, .semiJoinSelect]
                if containers.contains(t.type), let children = t.value.tokens {
                    apply(children, to: storage, uppercaseKeywords: uppercaseKeywords, addCompletions: addCompletions)
                }
            }
        }
    }
}

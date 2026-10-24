import AppKit

/// Applies the SOQL analyzer's tokens to text: syntax colors, error underlines with their messages
/// as tooltips, keyword case, and completions. Used for the query editor and for SOQL inside Apex.
enum SOQLHighlighter {
    /// - Parameters:
    ///   - offset: Where the tokens' text starts in `storage`.
    ///   - ignoringErrorsIn: Ranges of `storage` where errors aren't shown, such as Apex bind variables.
    ///   - addCompletions: Called with each token's completions and its range in `storage`.
    static func apply(_ tokens: Tokens, to storage: NSTextStorage, offset: Int, uppercaseKeywords: Bool,
                      ignoringErrorsIn ignored: [NSRange] = [], addCompletions: (([Completion], NSRange) -> Void)?) {
        for t in tokens.tokens {
            let loc = NSRange(location: t.loc.location + offset, length: t.loc.length)
            guard NSMaxRange(loc) <= storage.length else { continue }
            if let addCompletions, !t.completions.isEmpty {
                addCompletions(t.completions, loc)
            }
            switch t.type {
            case .error:
                guard !ignored.contains(where: { NSIntersectionRange($0, loc).length > 0 || NSLocationInRange(loc.location, $0) }) else { break }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: SOQLStyle.error,
                ], range: loc)
                if let message = t.errorMessage {
                    storage.addAttributes([.toolTip: message, .cursor: NSCursor.pointingHand], range: loc)
                }
            case .keyword, .operator:
                let upper = t.tokenTxt.uppercased()
                if uppercaseKeywords, upper != t.tokenTxt, upper.utf16.count == loc.length {
                    storage.replaceCharacters(in: loc, with: upper)
                }
                storage.addAttribute(.foregroundColor, value: SOQLStyle.keyword, range: loc)
            default:
                if let color = SOQLStyle.color(for: t.type) {
                    storage.addAttribute(.foregroundColor, value: color, range: loc)
                }
            }
            // Only these token types color their children; e.g. FIELDS(STANDARD) turns a field path
            // into a keyword, and its unresolved field shouldn't show as an error.
            let containers: TokenType = [.fieldPath, .sobject, .function, .typeOf, .childSelect, .semiJoinSelect]
            if containers.contains(t.type), let children = t.value.tokens {
                apply(children, to: storage, offset: offset, uppercaseKeywords: uppercaseKeywords, ignoringErrorsIn: ignored, addCompletions: addCompletions)
            }
        }
    }
}

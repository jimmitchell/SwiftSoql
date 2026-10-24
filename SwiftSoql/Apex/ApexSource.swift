import Foundation

/// Reads the parts of anonymous Apex that the editor checks and completes: inline SOQL queries,
/// and which variables hold SObjects. All ranges are in UTF-16 units, as NSString and NSTextView
/// count them.
nonisolated enum ApexSource {
    /// The text inside each `[SELECT …]` in the code, skipping strings and comments.
    static func inlineQueries(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var i = 0
        var openBrackets: [Int] = []
        let length = text.length
        // Character codes: / 0x2F, * 0x2A, ' 0x27, \ 0x5C, [ 0x5B, ] 0x5D, newline 0x0A.
        func char(_ j: Int) -> unichar { j < length ? text.character(at: j) : 0 }
        while i < length {
            let c = char(i)
            if c == 0x2F, char(i + 1) == 0x2F {
                while i < length, char(i) != 0x0A { i += 1 }
            } else if c == 0x2F, char(i + 1) == 0x2A {
                i += 2
                while i < length, !(char(i) == 0x2A && char(i + 1) == 0x2F) { i += 1 }
                i += 2
            } else if c == 0x27 {
                i += 1
                while i < length, char(i) != 0x27 {
                    i += char(i) == 0x5C ? 2 : 1
                }
                i += 1
            } else {
                if c == 0x5B {
                    openBrackets.append(i)
                } else if c == 0x5D, let start = openBrackets.popLast() {
                    let inner = NSRange(location: start + 1, length: i - start - 1)
                    let content = text.substring(with: inner).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if content.hasPrefix("select") || content.hasPrefix("find") {
                        ranges.append(inner)
                    }
                }
                i += 1
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

    /// The query with each bind variable (`:ids`, `:acc.Name`) replaced by a literal of the same
    /// length, so the SOQL checker can read it and positions don't move, and the binds' ranges.
    static func maskingBinds(in query: String) -> (query: String, binds: [NSRange]) {
        let ns = query as NSString
        var masked = ""
        var binds: [NSRange] = []
        var last = 0
        let pattern = try! NSRegularExpression(pattern: #"(\b(?:IN|INCLUDES|EXCLUDES)\s+)?:\s*[A-Za-z_][A-Za-z0-9_.]*(?:\[[^\]]*\])?(?:\([^)]*\))?"#, options: [.caseInsensitive])
        for match in pattern.matches(in: query, range: NSRange(location: 0, length: ns.length)) {
            let listContext = match.range(at: 1).location != NSNotFound
            let bindStart = listContext ? NSMaxRange(match.range(at: 1)) : match.range.location
            let bind = NSRange(location: bindStart, length: NSMaxRange(match.range) - bindStart)
            masked += ns.substring(with: NSRange(location: last, length: bind.location - last))
            // A list after IN, a number after LIMIT or OFFSET, otherwise null (or 1 if there's no
            // room); padded to the same length.
            let before = ns.substring(to: bind.location).trimmingCharacters(in: .whitespaces).lowercased()
            let wantsNumber = before.hasSuffix("limit") || before.hasSuffix("offset")
            let literal = listContext && bind.length >= 3 ? "(1)" : !wantsNumber && bind.length >= 4 ? "null" : "1"
            masked += literal + String(repeating: " ", count: max(0, bind.length - literal.count))
            binds.append(bind)
            last = NSMaxRange(bind)
        }
        masked += ns.substring(from: last)
        return (masked, binds)
    }

    /// Variables declared with an SObject type, such as `Account a = …` or
    /// `for (Contact c : contacts)`, keyed by lowercased name.
    static func sobjectVariables(in text: String, sobjectNamed: (String) -> String?) -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|;|:|,|\))"#)
        var types: [String: String] = [:]
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let ns = text as NSString
            if let sobject = sobjectNamed(ns.substring(with: match.range(at: 1))) {
                types[ns.substring(with: match.range(at: 2)).lowercased()] = sobject
            }
        }
        return types
    }

    enum CompletionContext: Equatable {
        /// After `name.`: the fields of the SObject that `name` is, or holds.
        case afterDot(String)
        /// Inside `new Name(…)`, where fields can be set by name.
        case newObject(String)
        /// Any other word.
        case word
    }

    /// What the partial word at `wordRange` is being typed in.
    static func completionContext(in text: NSString, wordRange: NSRange) -> CompletionContext {
        let before = text.substring(to: wordRange.location)
        if before.hasSuffix("."), let match = before.dropLast().firstMatch(of: #/([A-Za-z_][A-Za-z0-9_]*)$/#) {
            return .afterDot(String(match.1))
        }
        // Inside new X( … ) if the nearest unclosed parenthesis follows `new X`.
        var depth = 0
        for (offset, c) in before.reversed().enumerated() {
            if c == ")" { depth += 1 }
            if c == "(" {
                if depth == 0 {
                    let head = before.dropLast(offset + 1)
                    if let match = head.firstMatch(of: #/(?i)\bnew\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/#) {
                        return .newObject(String(match.1))
                    }
                    break
                }
                depth -= 1
            }
            if c == ";" || c == "{" || c == "}" { break }
        }
        return .word
    }
}

import Foundation

/// Lays a SOQL query out on several lines:
///
///     SELECT Id,
///            Name,
///            (SELECT Id FROM Contacts)
///     FROM Account
///     WHERE Industry = 'Energy'
///       AND (Rating = 'Hot' OR Rating = 'Warm')
///     ORDER BY Name
///
/// Each clause starts a line. A select list that doesn't fit on one line gets a line per item,
/// and each top-level AND or OR in a WHERE or HAVING starts a line. Subqueries stay on one line if
/// they fit, and are laid out the same way, aligned inside their parentheses, if they don't. Only
/// whitespace changes: the words and literals, and their case, are kept as they were.
nonisolated enum SoqlFormatter {
    static let maxWidth = 80

    /// The formatted query, or nil if the text isn't a SOQL query it can read (SOSL, say, or
    /// unbalanced parentheses or quotes).
    static func format(_ soql: String) -> String? {
        guard let lexemes = lex(soql), let nodes = tree(lexemes),
              case .lexeme(.word(let first))? = nodes.first, first.lowercased() == "select"
        else { return nil }
        return query(nodes, column: 0)
    }

    // MARK: Reading

    enum Lexeme: Equatable {
        case word(String)
        /// A quoted string, including its quotes.
        case string(String)
        case symbol(String)
    }

    indirect enum Node {
        case lexeme(Lexeme)
        /// The contents of a pair of parentheses.
        case group([Node])
    }

    /// Splits the text into words, quoted strings, parentheses, commas and comparison operators.
    static func lex(_ text: String) -> [Lexeme]? {
        let chars = Array(text)
        var lexemes: [Lexeme] = []
        var i = 0
        let breaks: Set<Character> = ["(", ")", ",", "'", "=", "<", ">", "!"]
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "'" {
                var j = i + 1
                while j < chars.count, chars[j] != "'" {
                    j += chars[j] == "\\" ? 2 : 1
                }
                guard j < chars.count else { return nil }
                lexemes.append(.string(String(chars[i...j])))
                i = j + 1
            } else if c == "(" || c == ")" || c == "," {
                lexemes.append(.symbol(String(c)))
                i += 1
            } else if "=<>!".contains(c) {
                let two = i + 1 < chars.count ? String(chars[i...i + 1]) : ""
                if ["!=", "<=", ">=", "<>"].contains(two) {
                    lexemes.append(.symbol(two))
                    i += 2
                } else {
                    lexemes.append(.symbol(String(c)))
                    i += 1
                }
            } else {
                var j = i
                while j < chars.count, !chars[j].isWhitespace, !breaks.contains(chars[j]) {
                    j += 1
                }
                lexemes.append(.word(String(chars[i..<j])))
                i = j
            }
        }
        return lexemes
    }

    /// Groups the lexemes by their parentheses, or returns nil if they don't balance.
    static func tree(_ lexemes: [Lexeme]) -> [Node]? {
        var stack: [[Node]] = [[]]
        for lexeme in lexemes {
            switch lexeme {
            case .symbol("("):
                stack.append([])
            case .symbol(")"):
                guard stack.count > 1 else { return nil }
                let group = stack.removeLast()
                stack[stack.count - 1].append(.group(group))
            default:
                stack[stack.count - 1].append(.lexeme(lexeme))
            }
        }
        return stack.count == 1 ? stack[0] : nil
    }

    // MARK: Writing

    private enum ClauseKind { case select, conditions, other }

    private struct Clause {
        var keyword: String
        var kind: ClauseKind
        var body: [Node]
    }

    /// A query whose first line starts at `column`; later lines are indented to line up with it.
    private static func query(_ nodes: [Node], column: Int) -> String {
        var lines: [String] = []
        for clause in clauses(nodes) {
            switch clause.kind {
            case .select:
                lines += selectLines(clause, column: column)
            case .conditions:
                lines += conditionLines(clause, column: column)
            case .other:
                let body = clause.body.isEmpty ? "" : " " + inline(clause.body, column: column + clause.keyword.count + 1)
                lines.append(clause.keyword + body)
            }
        }
        let pad = String(repeating: " ", count: column)
        return lines.enumerated().map { $0.offset == 0 ? $0.element : pad + $0.element }.joined(separator: "\n")
    }

    private static func clauses(_ nodes: [Node]) -> [Clause] {
        var clauses: [Clause] = []
        var i = 0
        while i < nodes.count {
            if let length = clauseKeywordLength(nodes, at: i) {
                let words = nodes[i..<i + length].compactMap { node -> String? in
                    if case .lexeme(.word(let w)) = node { return w }
                    return nil
                }
                let first = words[0].lowercased()
                let kind: ClauseKind = first == "select" ? .select : (first == "where" || first == "having") ? .conditions : .other
                clauses.append(Clause(keyword: words.joined(separator: " "), kind: kind, body: []))
                i += length
            } else {
                if clauses.isEmpty {
                    clauses.append(Clause(keyword: "", kind: .other, body: []))
                }
                clauses[clauses.count - 1].body.append(nodes[i])
                i += 1
            }
        }
        return clauses
    }

    /// How many words start a clause at `i`, if one does: SELECT, FROM, WHERE, GROUP BY, ORDER BY,
    /// USING SCOPE, UPDATE TRACKING and so on.
    private static func clauseKeywordLength(_ nodes: [Node], at i: Int) -> Int? {
        func word(_ j: Int) -> String? {
            guard j >= 0, j < nodes.count, case .lexeme(.word(let w)) = nodes[j] else { return nil }
            return w.lowercased()
        }
        guard let w = word(i) else { return nil }
        switch w {
        case "select", "from", "where", "having", "limit", "offset", "with", "for":
            return 1
        case "group", "order":
            return word(i + 1) == "by" ? 2 : nil
        case "using":
            return word(i + 1) == "scope" ? 2 : nil
        case "update":
            return word(i - 1) != "for" && ["tracking", "viewstat"].contains(word(i + 1) ?? "") ? 2 : nil
        default:
            return nil
        }
    }

    private static func selectLines(_ clause: Clause, column: Int) -> [String] {
        let items = selectItems(clause.body)
        let oneLine = clause.keyword + " " + items.map { inline($0, column: nil) }.joined(separator: ", ")
        if column + oneLine.count <= maxWidth {
            return [oneLine]
        }
        let indent = String(repeating: " ", count: clause.keyword.count + 1)
        let itemColumn = column + indent.count
        return items.enumerated().map { i, item in
            let text = selectItem(item, column: itemColumn) + (i < items.count - 1 ? "," : "")
            return (i == 0 ? clause.keyword + " " : indent) + text
        }
    }

    /// One item of a select list. A TYPEOF that doesn't fit gets a line for each WHEN and ELSE.
    private static func selectItem(_ nodes: [Node], column: Int) -> String {
        let text = inline(nodes, column: column)
        guard case .lexeme(.word(let w))? = nodes.first, w.lowercased() == "typeof", column + text.count > maxWidth else {
            return text
        }
        var lines: [[Node]] = [[]]
        for node in nodes {
            if case .lexeme(.word(let w)) = node, ["when", "else", "end"].contains(w.lowercased()) {
                lines.append([])
            }
            lines[lines.count - 1].append(node)
        }
        let pad = String(repeating: " ", count: column)
        return lines.enumerated().map { i, line in
            let isCase = i > 0 && i < lines.count - 1
            let lineColumn = column + (isCase ? 4 : 0)
            return (i == 0 ? "" : pad + (isCase ? "    " : "")) + inline(line, column: lineColumn)
        }.joined(separator: "\n")
    }

    /// Splits a select list at its commas, keeping each TYPEOF … END together.
    private static func selectItems(_ nodes: [Node]) -> [[Node]] {
        var items: [[Node]] = [[]]
        var typeOfDepth = 0
        for node in nodes {
            if case .lexeme(.word(let w)) = node {
                if w.lowercased() == "typeof" { typeOfDepth += 1 }
                if w.lowercased() == "end" { typeOfDepth = max(0, typeOfDepth - 1) }
            }
            if case .lexeme(.symbol(",")) = node, typeOfDepth == 0 {
                items.append([])
            } else {
                items[items.count - 1].append(node)
            }
        }
        return items.filter { !$0.isEmpty }
    }

    /// A WHERE or HAVING, with a line for each top-level AND or OR, lined up after the keyword.
    private static func conditionLines(_ clause: Clause, column: Int) -> [String] {
        var parts: [(connector: String?, nodes: [Node])] = [(nil, [])]
        for node in clause.body {
            if case .lexeme(.word(let w)) = node, ["and", "or"].contains(w.lowercased()), !parts[parts.count - 1].nodes.isEmpty {
                parts.append((w, []))
            } else {
                parts[parts.count - 1].nodes.append(node)
            }
        }
        let width = clause.keyword.count
        let conditionColumn = column + width + 1
        return parts.map { part in
            let text = inline(part.nodes, column: conditionColumn)
            guard let connector = part.connector else { return clause.keyword + " " + text }
            return String(repeating: " ", count: max(0, width - connector.count)) + connector + " " + text
        }
    }

    /// Words that are followed by a space before an opening parenthesis; other words are function
    /// names, as in COUNT(Id).
    private static let spacedBeforeParenthesis: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "includes", "excludes", "having", "by",
        "with", "when", "then", "else", "at", "above", "below", "above_or_below", "like",
    ]

    /// The nodes on one line, starting at `column`. A subquery that would run past the line's
    /// width is laid out over several lines inside its parentheses; with a nil column nothing is
    /// broken.
    private static func inline(_ nodes: [Node], column: Int?) -> String {
        var out = ""
        var previous: Node?
        for node in nodes {
            var spaced = previous != nil
            if case .lexeme(.symbol(let s)) = node, s == "," { spaced = false }
            if case .group = node, case .lexeme(.word(let w))? = previous, !spacedBeforeParenthesis.contains(w.lowercased()) {
                spaced = false
            }
            if spaced { out += " " }
            switch node {
            case .lexeme(.word(let w)), .lexeme(.string(let w)), .lexeme(.symbol(let w)):
                out += w
            case .group(let children):
                let flat = "(" + inline(children, column: nil) + ")"
                if let column, isSubquery(children), currentColumn(of: out, startingAt: column) + flat.count > maxWidth {
                    out += "(" + query(children, column: currentColumn(of: out, startingAt: column) + 1) + ")"
                } else {
                    out += flat
                }
            }
            previous = node
        }
        return out
    }

    private static func isSubquery(_ nodes: [Node]) -> Bool {
        if case .lexeme(.word(let w))? = nodes.first { return w.lowercased() == "select" }
        return false
    }

    /// The column the next character of `text` goes in, given where its first line started.
    private static func currentColumn(of text: String, startingAt column: Int) -> Int {
        if let newline = text.lastIndex(of: "\n") {
            return text.distance(from: text.index(after: newline), to: text.endIndex)
        }
        return column + text.count
    }
}

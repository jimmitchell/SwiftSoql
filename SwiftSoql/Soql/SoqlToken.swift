import Foundation

// Tokens produced by parsing SOQL, ported from SoqlXplorer's SoqlToken (MIT license).

struct TokenType: OptionSet, Hashable {
    let rawValue: UInt32

    static let keyword = TokenType(rawValue: 1)
    /// A field path gets resolved into alias, relationship and field tokens.
    static let fieldPath = TokenType(rawValue: 1 << 1)
    static let alias = TokenType(rawValue: 1 << 2)
    static let relationship = TokenType(rawValue: 1 << 3)
    static let field = TokenType(rawValue: 1 << 4)
    static let function = TokenType(rawValue: 1 << 5)
    static let childSelect = TokenType(rawValue: 1 << 6)
    static let typeOf = TokenType(rawValue: 1 << 7)
    static let sobject = TokenType(rawValue: 1 << 8)
    static let aliasDecl = TokenType(rawValue: 1 << 9)
    static let sobjectRelation = TokenType(rawValue: 1 << 10)
    static let `operator` = TokenType(rawValue: 1 << 11)
    static let semiJoinSelect = TokenType(rawValue: 1 << 12)
    static let usingScope = TokenType(rawValue: 1 << 13)
    static let dataCategory = TokenType(rawValue: 1 << 14)
    static let dataCategoryValue = TokenType(rawValue: 1 << 15)
    static let literal = TokenType(rawValue: 1 << 16)
    static let literalList = TokenType(rawValue: 1 << 17)
    static let literalString = TokenType(rawValue: 1 << 18)
    static let literalNumber = TokenType(rawValue: 1 << 19)
    static let literalDate = TokenType(rawValue: 1 << 20)
    static let literalDateTime = TokenType(rawValue: 1 << 21)
    static let literalNamedDateTime = TokenType(rawValue: 1 << 22)
    static let literalBoolean = TokenType(rawValue: 1 << 23)
    static let literalNull = TokenType(rawValue: 1 << 24)
    static let literalCurrency = TokenType(rawValue: 1 << 25)
    static let listViewName = TokenType(rawValue: 1 << 26)
    static let error = TokenType(rawValue: 1 << 27)

    static let all = TokenType(rawValue: .max)

    static let literals: TokenType = [
        .literal, .literalList, .literalString, .literalNumber, .literalDate, .literalDateTime,
        .literalNamedDateTime, .literalBoolean, .literalNull, .literalCurrency,
    ]

    /// The name of a single type.
    var name: String {
        switch self {
        case .keyword: "Keyword"
        case .fieldPath: "FieldPath"
        case .alias: "Aias" // sic, matches SoqlXplorer's test output
        case .relationship: "Relationship"
        case .field: "Field"
        case .function: "Function"
        case .childSelect: "ChildSelect"
        case .typeOf: "TypeOf"
        case .sobject: "SObject"
        case .aliasDecl: "AliasDecl"
        case .sobjectRelation: "RelatedSObj"
        case .operator: "Op"
        case .semiJoinSelect: "SemiJoinSelect"
        case .usingScope: "Scope"
        case .dataCategory: "Category"
        case .dataCategoryValue: "CategoryVal"
        case .literal: "Literal"
        case .literalList: "LiteralList"
        case .literalString: "String"
        case .literalNumber: "Number"
        case .literalDate: "Date"
        case .literalDateTime: "DateTime"
        case .literalNamedDateTime: "NamedDateTime"
        case .literalBoolean: "Boolean"
        case .literalNull: "Null"
        case .error: "Error"
        case .literalCurrency: "Currency"
        case .listViewName: "ListViewName"
        default: "<unknown>"
        }
    }

    /// The names of all the types in the set.
    var names: String {
        var names: [String] = []
        var m: UInt32 = 1
        while m < TokenType.error.rawValue {
            if rawValue & m != 0 {
                names.append(TokenType(rawValue: m).name)
            }
            m <<= 1
        }
        return names.joined(separator: ",")
    }
}

enum TokenValue {
    case none
    case text(String)
    /// The steps of an unresolved field path.
    case path([String])
    /// Child tokens, e.g. a function's arguments or a resolved field path.
    case tokens(Tokens)
    case field(FieldDescribe)

    var tokens: Tokens? {
        if case .tokens(let t) = self { return t }
        return nil
    }
}

final class Token {
    let source: NSString
    var type: TokenType
    let loc: NSRange
    var value: TokenValue = .none
    var completions: [Completion] = []

    init(_ source: NSString, loc: NSRange, type: TokenType = []) {
        self.source = source
        self.loc = loc
        self.type = type
    }

    private(set) lazy var tokenTxt: String = source.substring(with: loc)

    /// Case-insensitive comparison with the token's text.
    func matches(_ s: String) -> Bool {
        tokenTxt.caseInsensitiveCompare(s) == .orderedSame
    }

    /// Creates another token from the same source text.
    func token(of r: NSRange, type: TokenType = []) -> Token {
        Token(source, loc: r, type: type)
    }

    /// The error message of an error token.
    var errorMessage: String? {
        guard type == .error, case .text(let msg) = value else { return nil }
        return msg
    }

    func dump(depth: Int = 0) -> String {
        let indent = String(repeating: " ", count: depth * 4)
        let loc = String(format: "%4lu-%-4lu", self.loc.location, self.loc.length)
        let typeName = type.name.padding(toLength: 15, withPad: " ", startingAt: 0)
        let txt = tokenTxt.padding(toLength: 30, withPad: " ", startingAt: 0)
        var s = "\(indent)\(loc): \(typeName) \(txt) completions \(completions.count) \(type == .error ? errorMessage ?? "" : "")"
        let hasChildren: TokenType = [.childSelect, .semiJoinSelect, .sobject, .typeOf, .function, .fieldPath]
        if hasChildren.contains(type) {
            switch value {
            case .tokens(let children):
                for t in children.tokens {
                    s += "\n" + t.dump(depth: depth + 1)
                }
            case .path(let steps):
                s += "\n\(indent)              strings:\(steps.joined(separator: ","))"
            default:
                break
            }
        }
        return s
    }
}

/// Tokens sorted by position. Tokens at the same position are sorted longest first.
final class Tokens {
    private(set) var tokens: [Token] = []

    var count: Int { tokens.count }

    private static func precedes(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location == b.location ? a.length > b.length : a.location < b.location
    }

    /// The index of the first token that doesn't sort before `loc`.
    private func lowerBound(_ loc: NSRange) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(tokens[mid].loc, loc) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    func add(_ t: Token) {
        tokens.insert(t, at: lowerBound(t.loc))
    }

    func add(contentsOf ts: [Token]) {
        for t in ts {
            add(t)
        }
    }

    /// Removes a range of tokens (by index) and returns them.
    func cut(_ r: Range<Int>) -> Tokens {
        let s = Tokens()
        s.tokens = Array(tokens[r])
        tokens.removeSubrange(r)
        return s
    }

    /// Removes the tokens that start within the given text range and returns them.
    func cut(positionRange r: NSRange) -> Tokens {
        guard !tokens.isEmpty else { return Tokens() }
        let start = lowerBound(r)
        var end = start
        while end < tokens.count && NSLocationInRange(tokens[end].loc.location, r) {
            end += 1
        }
        return cut(start..<end)
    }

    var description: String {
        tokens.map { $0.dump() + "\n" }.joined()
    }
}

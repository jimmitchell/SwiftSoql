import Foundation

// A parser combinator library, ported from ZKParser by Simon Fell (MIT license).
//
// Parsers work on UTF-16 offsets so that token locations line up with NSTextView ranges.
// The cut, backtracking and error reporting rules match ZKParser exactly, because the SOQL
// grammar and its error messages depend on them.

/// The value produced by a parser.
enum ParseValue {
    case null
    case string(String)
    case results([ParseResult])
    case token(Token)

    var token: Token? {
        if case .token(let t) = self { return t }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Shared state for one parse: the text being parsed and the tokens found so far.
final class ParseContext {
    let text: NSString
    let tokens = Tokens()

    init(text: NSString) {
        self.text = text
    }
}

final class ParseResult {
    var val: ParseValue
    var loc: NSRange
    let ctx: ParseContext

    init(_ val: ParseValue, ctx: ParseContext, loc: NSRange) {
        self.val = val
        self.ctx = ctx
        self.loc = loc
    }

    var children: [ParseResult] {
        if case .results(let r) = val { return r }
        return []
    }

    func child(_ idx: Int) -> ParseResult {
        children[idx]
    }

    func childIsNull(_ idx: Int) -> Bool {
        children[idx].val.isNull
    }

    /// The string values of the child results.
    var childStrings: [String] {
        children.compactMap(\.val.string)
    }
}

final class ParserError {
    var msg: String {
        get {
            if let message { return message }
            guard let expected else { return "" }
            // pos is zero based internally, but one based to the user.
            return expectedClass ? "expecting \(expected) at position \(pos + 1)" : "expecting '\(expected)' at position \(pos + 1)"
        }
        set { message = newValue }
    }
    private var message: String?
    var pos = 0
    var completions: [Completion]?
    var expected: String?
    var expectedClass = false

    fileprivate func reset(pos: Int, message: String?, expected: String?, expectedClass: Bool) {
        self.pos = pos
        self.message = message
        self.expected = expected
        self.expectedClass = expectedClass
        completions = nil
    }
}

final class ParsingState {
    let input: NSString
    let ctx: ParseContext
    var pos = 0
    private(set) var cut = 0
    private(set) var hasError = false
    let currentError = ParserError()

    init(ctx: ParseContext) {
        self.ctx = ctx
        input = ctx.text
    }

    /// The remaining length.
    var length: Int { input.length - pos }
    var hasMoreInput: Bool { pos < input.length }
    var currentChar: unichar { input.character(at: pos) }

    func consume(_ s: String, caseInsensitive: Bool) -> String? {
        let len = (s as NSString).length
        guard length >= len else { return nil }
        let rng = NSRange(location: pos, length: len)
        guard input.compare(s, options: caseInsensitive ? .caseInsensitive : .literal, range: rng) == .orderedSame else { return nil }
        pos += len
        return input.substring(with: rng)
    }

    func consumeCharacters(in set: CharacterSet) -> Int {
        var count = 0
        while hasMoreInput, let scalar = Unicode.Scalar(currentChar), set.contains(scalar) {
            pos += 1
            count += 1
        }
        return count
    }

    func markCut() {
        cut = pos
    }

    func canMove(to target: Int) -> Bool {
        target >= cut
    }

    func move(to target: Int) {
        pos = target
    }

    @discardableResult
    func expected(_ expected: String) -> ParserError {
        hasError = true
        currentError.reset(pos: pos, message: nil, expected: expected, expectedClass: false)
        return currentError
    }

    /// Like `expected`, but for a class of input such as whitespace, so it isn't quoted in the message.
    @discardableResult
    func expectedClass(_ expected: String) -> ParserError {
        hasError = true
        currentError.reset(pos: pos, message: nil, expected: expected, expectedClass: true)
        return currentError
    }

    @discardableResult
    func error(_ msg: String) -> ParserError {
        hasError = true
        currentError.reset(pos: pos, message: msg, expected: nil, expectedClass: false)
        return currentError
    }

    func clearError() {
        hasError = false
    }

    struct Failure: Error {
        let message: String
        /// One based, like the message.
        let position: Int
        let completions: [Completion]?
    }

    /// Runs the parser over all of the input, failing if it errors or doesn't consume everything.
    func parse(_ parser: Parser) -> Result<ParseValue, Failure> {
        let res = parser.parse(self)
        if hasError {
            return .failure(Failure(message: currentError.msg, position: currentError.pos + 1, completions: currentError.completions))
        }
        if length > 0 {
            let rest = input.substring(from: pos)
            return .failure(Failure(message: "Unexpected input '\(rest)' at position \(pos + 1)", position: pos + 1, completions: nil))
        }
        return .success(res?.val ?? .null)
    }
}

class Parser {
    /// Runs the parser. On error the position is restored to where it started.
    func parse(_ input: ParsingState) -> ParseResult? {
        input.clearError()
        let start = input.pos
        let r = parseImpl(input)
        if input.hasError {
            input.move(to: start)
        }
        return r
    }

    func parseImpl(_ input: ParsingState) -> ParseResult? {
        fatalError("subclasses implement parseImpl")
    }
}

private final class MatchMapperParser: Parser {
    let inner: Parser
    let mapper: (ParseResult) -> ParseResult

    init(_ inner: Parser, _ mapper: @escaping (ParseResult) -> ParseResult) {
        self.inner = inner
        self.mapper = mapper
    }

    override func parse(_ input: ParsingState) -> ParseResult? {
        let r = inner.parse(input)
        if !input.hasError, let r {
            return mapper(r)
        }
        return r
    }
}

private final class ErrorMapperParser: Parser {
    let inner: Parser
    let mapper: (ParsingState) -> Void

    init(_ inner: Parser, _ mapper: @escaping (ParsingState) -> Void) {
        self.inner = inner
        self.mapper = mapper
    }

    override func parse(_ input: ParsingState) -> ParseResult? {
        let r = inner.parse(input)
        if input.hasError {
            mapper(input)
        }
        return r
    }
}

private final class ExactParser: Parser {
    let match: String
    let caseInsensitive: Bool

    init(_ match: String, caseInsensitive: Bool) {
        self.match = match
        self.caseInsensitive = caseInsensitive
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        if let res = input.consume(match, caseInsensitive: caseInsensitive) {
            return ParseResult(.string(res), ctx: input.ctx, loc: NSRange(location: start, length: input.pos - start))
        }
        input.expected(match)
        return nil
    }
}

private final class CharSetParser: Parser {
    let set: CharacterSet
    let minMatches: Int
    let name: String

    init(_ set: CharacterSet, name: String, min: Int) {
        self.set = set
        self.name = name
        minMatches = min
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        let count = input.consumeCharacters(in: set)
        if count < minMatches {
            input.expectedClass(name).pos = start
            return nil
        }
        let rng = NSRange(location: start, length: count)
        return ParseResult(.string(input.input.substring(with: rng)), ctx: input.ctx, loc: rng)
    }
}

private final class IntegerParser: Parser {
    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        var first = true
        var valid = false
        while input.hasMoreInput {
            let c = input.currentChar
            if first {
                first = false
                if c == unichar(ascii: "-") || c == unichar(ascii: "+") {
                    input.pos += 1
                    continue
                }
            }
            guard c >= unichar(ascii: "0") && c <= unichar(ascii: "9") else { break }
            input.pos += 1
            valid = true
        }
        if !valid {
            input.expectedClass("integer").pos = start
            return nil
        }
        let rng = NSRange(location: start, length: input.pos - start)
        return ParseResult(.string(input.input.substring(with: rng)), ctx: input.ctx, loc: rng)
    }
}

private final class DecimalParser: Parser {
    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        var first = true
        var valid = false
        var seenDot = false
        while input.hasMoreInput {
            let c = input.currentChar
            if first {
                first = false
                if c == unichar(ascii: "-") || c == unichar(ascii: "+") {
                    input.pos += 1
                    continue
                }
            }
            if !seenDot && c == unichar(ascii: ".") {
                seenDot = true
                valid = false // there has to be a digit after the .
                input.pos += 1
                continue
            }
            guard c >= unichar(ascii: "0") && c <= unichar(ascii: "9") else { break }
            input.pos += 1
            valid = true
        }
        if !valid {
            input.expectedClass("decimal").pos = start
            return nil
        }
        let rng = NSRange(location: start, length: input.pos - start)
        return ParseResult(.string(input.input.substring(with: rng)), ctx: input.ctx, loc: rng)
    }
}

private final class RegexParser: Parser {
    let regex: NSRegularExpression
    let name: String

    init(_ regex: NSRegularExpression, name: String) {
        self.regex = regex
        self.name = name
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let match = regex.rangeOfFirstMatch(in: input.input as String, options: .anchored, range: NSRange(location: input.pos, length: input.length))
        if match.location == NSNotFound {
            input.expectedClass(name)
            return nil
        }
        input.pos += match.length
        return ParseResult(.string(input.input.substring(with: match)), ctx: input.ctx, loc: match)
    }
}

private final class FirstOfParser: Parser {
    let items: [Parser]

    init(_ items: [Parser]) {
        self.items = items
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        for child in items {
            let r = child.parse(input)
            if !input.hasError {
                return r
            }
            // The cut point moved past our start, so no other option can be tried.
            if !input.canMove(to: start) {
                return nil
            }
            input.move(to: start)
        }
        return nil
    }
}

private final class SeqParser: Parser {
    let items: [Parser]

    init(_ items: [Parser]) {
        self.items = items
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        var results: [ParseResult] = []
        results.reserveCapacity(items.count)
        for child in items {
            let res = child.parse(input)
            if input.hasError {
                return nil
            }
            results.append(res ?? ParseResult(.null, ctx: input.ctx, loc: NSRange(location: input.pos, length: 0)))
        }
        return ParseResult(.results(results), ctx: input.ctx, loc: NSRange(location: start, length: input.pos - start))
    }
}

private final class RepeatParser: Parser {
    let parser: Parser
    let separator: Parser?
    let min: Int
    let max: Int

    init(_ parser: Parser, separator: Parser?, min: Int, max: Int) {
        self.parser = parser
        self.separator = separator
        self.min = min
        self.max = max
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        var results: [ParseResult] = []
        let first = parser.parse(input)
        if !input.hasError, let first {
            results.append(first)
            while results.count < max {
                let thisStart = input.pos
                if let separator {
                    _ = separator.parse(input)
                    if input.hasError {
                        break
                    }
                }
                let next = parser.parse(input)
                if input.hasError {
                    // Unconsume the separator.
                    if input.canMove(to: thisStart) {
                        input.move(to: thisStart)
                        break
                    }
                    return nil
                }
                results.append(next ?? ParseResult(.null, ctx: input.ctx, loc: NSRange(location: input.pos, length: 0)))
            }
        }
        if results.count >= min {
            input.clearError()
            return ParseResult(.results(results), ctx: input.ctx, loc: NSRange(location: start, length: input.pos - start))
        }
        return nil
    }
}

private final class OptionalParser: Parser {
    let optional: Parser

    init(_ optional: Parser) {
        self.optional = optional
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        let start = input.pos
        let res = optional.parse(input)
        if !input.hasError {
            return res
        }
        if input.canMove(to: start) {
            input.clearError()
            input.move(to: start)
            return ParseResult(.null, ctx: input.ctx, loc: NSRange(location: start, length: 0))
        }
        return nil
    }
}

extension unichar {
    init(ascii c: Unicode.Scalar) {
        self = unichar(c.value)
    }
}

/// A placeholder for a parser that's defined later, for recursive grammars.
final class ParserRef: Parser {
    var parser: Parser?

    override func parse(_ input: ParsingState) -> ParseResult? {
        parser!.parse(input)
    }
}

private final class BlockParser: Parser {
    let block: (ParsingState) -> ParseResult?

    init(_ block: @escaping (ParsingState) -> ParseResult?) {
        self.block = block
    }

    override func parseImpl(_ input: ParsingState) -> ParseResult? {
        block(input)
    }
}

/// Builds parsers. Matching is case-insensitive.
final class ParserFactory {
    var whitespace: Parser
    var maybeWhitespace: Parser

    init() {
        whitespace = CharSetParser(.whitespaces, name: "whitespace", min: 1)
        maybeWhitespace = CharSetParser(.whitespaces, name: "whitespace", min: 0)
    }

    func eq(_ s: String) -> Parser {
        ExactParser(s, caseInsensitive: true)
    }

    func characters(_ set: CharacterSet, name: String, min: Int) -> Parser {
        CharSetParser(set, name: name, min: min)
    }

    func integerNumber() -> Parser {
        IntegerParser()
    }

    func decimalNumber() -> Parser {
        DecimalParser()
    }

    func regex(_ regex: NSRegularExpression, name: String) -> Parser {
        RegexParser(regex, name: name)
    }

    func firstOf(_ items: [Parser]) -> Parser {
        FirstOfParser(items)
    }

    /// Matches one of the strings, longest first.
    func oneOfTokens(_ list: [String]) -> Parser {
        let sorted = list.enumerated()
            .sorted { $0.element.utf16.count != $1.element.utf16.count ? $0.element.utf16.count > $1.element.utf16.count : $0.offset < $1.offset }
            .map(\.element)
        return firstOf(sorted.map { s in
            onMatch(eq(s)) { r in
                r.val = .string(s)
                return r
            }
        })
    }

    func seq(_ items: [Parser]) -> Parser {
        SeqParser(items)
    }

    func zeroOrOne(_ p: Parser) -> Parser {
        OptionalParser(p)
    }

    func zeroOrMore(_ p: Parser, separator: Parser? = nil) -> Parser {
        RepeatParser(p, separator: separator, min: 0, max: .max)
    }

    func oneOrMore(_ p: Parser, separator: Parser? = nil) -> Parser {
        RepeatParser(p, separator: separator, min: 1, max: .max)
    }

    func fromBlock(_ block: @escaping (ParsingState) -> ParseResult?) -> Parser {
        BlockParser(block)
    }

    func parserRef() -> ParserRef {
        ParserRef()
    }

    /// Once parsed, the parser can't backtrack to before this point.
    func cut() -> Parser {
        fromBlock { input in
            input.markCut()
            return ParseResult(.null, ctx: input.ctx, loc: NSRange(location: input.pos, length: 0))
        }
    }

    func onMatch(_ p: Parser, perform mapper: @escaping (ParseResult) -> ParseResult) -> Parser {
        MatchMapperParser(p, mapper)
    }

    func onError(_ p: Parser, perform mapper: @escaping (ParsingState) -> Void) -> Parser {
        ErrorMapperParser(p, mapper)
    }
}

/// A result mapper that picks one child of a sequence.
func pick(_ idx: Int) -> (ParseResult) -> ParseResult {
    { $0.child(idx) }
}

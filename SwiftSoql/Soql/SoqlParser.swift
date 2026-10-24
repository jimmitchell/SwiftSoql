import Foundation

// The SOQL and SOSL grammar, ported from SoqlXplorer's SoqlParser (MIT license).
//
// Parsing produces a flat, position-sorted list of tokens. A later pass (SoqlAnalyzer)
// resolves them against the schema.

struct SoqlParseFailure {
    let message: String
    /// One based.
    let position: Int
    let completions: [Completion]?
}

final class SoqlParser {
    private let parser: Parser

    init() {
        parser = Self.buildParser()
    }

    /// Parses the text, returning the tokens found and the error if it isn't valid.
    func parse(_ input: NSString) -> (tokens: Tokens, failure: SoqlParseFailure?) {
        let ctx = ParseContext(text: input)
        let state = ParsingState(ctx: ctx)
        switch state.parse(parser) {
        case .success:
            return (ctx.tokens, nil)
        case .failure(let f):
            return (ctx.tokens, SoqlParseFailure(message: f.message, position: f.position, completions: f.completions))
        }
    }

    /// A mapper that turns the match into a token of the given type and records it.
    private static func toToken(_ type: TokenType) -> (ParseResult) -> ParseResult {
        { r in
            let t = Token(r.ctx.text, loc: r.loc, type: type)
            if let s = r.val.string {
                t.value = .text(s)
            }
            r.ctx.tokens.add(t)
            r.val = .token(t)
            return r
        }
    }

    private static func buildParser() -> Parser {
        let f = ParserFactory()
        let ws = f.characters(.whitespacesAndNewlines, name: "whitespace", min: 1)
        f.whitespace = ws
        let maybeWs = f.characters(.whitespacesAndNewlines, name: "whitespace", min: 0)
        f.maybeWhitespace = maybeWs
        let cut = f.cut()

        let commaSep = f.seq([maybeWs, f.eq(","), maybeWs])
        let ident = f.ident()

        // SELECT list
        let selectStmt = f.parserRef()

        // USING isn't in the docs, but appears not to be allowed.
        // ORDER, OFFSET and UPDATE are issues for this parser, but not the Salesforce one.
        let keywords = Set("ORDER OFFSET UPDATE USING AND ASC DESC EXCLUDES FIRST FROM GROUP HAVING IN INCLUDES LAST LIKE LIMIT NOT NULL NULLS OR SELECT WHERE WITH".split(separator: " ").map(String.init))
        let aliasOnly = f.zeroOrOne(f.onMatch(f.seq([ws, ident]), perform: pick(1)))
        let alias = f.fromBlock { input in
            let start = input.pos
            guard let r = aliasOnly.parse(input) else { return nil }
            if let txt = r.val.string {
                if keywords.contains(txt.uppercased()) {
                    input.move(to: start)
                    input.clearError()
                    return ParseResult(.null, ctx: input.ctx, loc: r.loc)
                }
                let t = Token(r.ctx.text, loc: r.loc, type: .aliasDecl)
                r.ctx.tokens.add(t)
                r.val = .token(t)
            }
            return r
        }
        let fieldPath = f.onMatch(f.oneOrMore(ident, separator: f.eq("."))) { r in
            let t = Token(r.ctx.text, loc: r.loc, type: .fieldPath)
            t.value = .path(r.childStrings)
            r.ctx.tokens.add(t)
            r.val = .token(t)
            return r
        }
        let fieldAndAlias = f.seq([fieldPath, alias])
        let literalValue = f.literalValue()

        let fieldOrFunc = f.parserRef()
        let fn = f.onMatch(f.seq([
            ident, maybeWs, f.eq("("), cut, maybeWs,
            f.zeroOrMore(f.firstOf([fieldOrFunc, literalValue]), separator: commaSep),
            maybeWs, f.eq(")"), alias,
        ])) { r in
            let fnToken = Token(r.ctx.text, loc: r.child(0).loc, type: .function)
            // The arguments are the tokens between the name and the closing paren; not the alias.
            fnToken.value = .tokens(r.ctx.tokens.cut(positionRange: NSUnionRange(r.child(0).loc, r.child(7).loc)))
            r.ctx.tokens.add(fnToken)
            return r
        }
        fieldOrFunc.parser = f.firstOf([fn, fieldAndAlias])

        let nestedSelectStmt = f.onMatch(f.seq([f.eq("("), selectStmt, f.eq(")")])) { r in
            let t = Token(r.ctx.text, loc: r.loc, type: .childSelect)
            r.ctx.tokens.add(t)
            r.val = .token(t)
            return r
        }
        let sobject = f.onMatch(ident, perform: toToken(.sobject))
        let typeOfWhen = f.seq([f.tokenSeq("WHEN"), cut, ws, sobject, ws, f.tokenSeq("THEN"), ws, f.oneOrMore(fieldPath, separator: commaSep)])
        let typeOfElse = f.seq([f.tokenSeq("ELSE"), ws, f.oneOrMore(fieldPath, separator: commaSep)])
        let typeofRel = f.onMatch(ident, perform: toToken(.relationship))
        let typeOf = f.onMatch(f.seq([
            f.tokenSeq("TYPEOF"), cut, ws, typeofRel, ws,
            f.oneOrMore(typeOfWhen, separator: ws), maybeWs,
            f.zeroOrOne(typeOfElse), maybeWs,
            f.tokenSeq("END"),
        ]), perform: toToken(.typeOf))

        let selectExprs = f.oneOrMore(f.firstOf([fn, typeOf, fieldAndAlias, nestedSelectStmt]), separator: commaSep)

        // FROM
        let objectRef = f.seq([sobject, alias])
        let objectRefs = f.onMatch(f.seq([
            objectRef,
            f.zeroOrOne(f.onMatch(f.seq([commaSep, f.oneOrMore(fieldAndAlias, separator: commaSep)]), perform: pick(1))),
        ])) { r in
            // The tokens generated by fieldAndAlias have the wrong type here.
            if !r.childIsNull(1) {
                for rel in r.child(1).children {
                    rel.children.first?.val.token?.type = .sobjectRelation
                }
            }
            return r
        }

        // WHERE
        let notIn = Completion(display: "NOT IN", insert: "NOT_IN", finalInsertion: "NOT IN", type: .operator)
        let opCompletions = Completion.completions(["<", "<=", ">", ">=", "=", "!=", "LIKE", "INCLUDES", "EXCLUDES", "IN"], type: .operator) + [notIn]
        let op = f.oneOfTokens(["<", "<=", ">", ">=", "=", "!=", "LIKE"], type: .operator, completions: opCompletions, addToContext: true)
        let opIncExcl = f.oneOfTokens(["INCLUDES", "EXCLUDES"], type: .operator, completions: opCompletions, addToContext: true)
        let inOrNotIn = f.firstOf([f.tokenSeq("IN", type: .operator), f.tokenSeq("NOT IN", type: .operator)])
        let inNotInCompletions = Completion.completions(["IN", "NOT IN"], type: .operator)
        let opInNotIn = f.fromBlock { input in
            let r = inOrNotIn.parse(input)
            if !input.hasError {
                r?.val.token?.completions += inNotInCompletions
            } else {
                let expected = opCompletions.map(\.displayText).joined(separator: ",")
                input.error("expecting one of \(expected) at position \(input.pos + 1)").completions = opCompletions
            }
            return r
        }
        let literalList = f.seq([f.eq("("), maybeWs, f.oneOrMore(literalValue, separator: commaSep), maybeWs, f.eq(")")])
        let semiJoinValues = f.onMatch(f.firstOf([nestedSelectStmt, literalList])) { r in
            if let t = r.val.token, t.type == .childSelect {
                t.type = .semiJoinSelect
            }
            return r
        }
        let operatorRHS = f.firstOf([
            f.seq([op, cut, maybeWs, literalValue]),
            f.seq([opIncExcl, cut, maybeWs, literalList]),
            f.seq([opInNotIn, cut, maybeWs, semiJoinValues]),
        ])
        let baseExpr = f.seq([fieldOrFunc, maybeWs, operatorRHS])

        // A ref so that expressions can nest, e.g. x op y and (y op z or z op t).
        let exprList = f.parserRef()
        let parensExpr = f.onMatch(f.seq([f.eq("("), maybeWs, exprList, maybeWs, f.eq(")")]), perform: pick(2))
        // AND/OR isn't added to the tokens straight away because OR is ambiguous with ORDER BY;
        // wait until the whitespace after it has matched.
        let andOrToken = f.oneOfTokens(["AND", "OR"], type: .operator, completions: nil, addToContext: false)
        let andOr = f.onMatch(f.seq([maybeWs, andOrToken, ws])) { r in
            if let t = r.child(1).val.token {
                r.ctx.tokens.add(t)
            }
            return r
        }
        let not = f.seq([f.tokenSeq("NOT", type: .operator), maybeWs])
        exprList.parser = f.seq([f.zeroOrOne(not), f.firstOf([parensExpr, baseExpr]), f.zeroOrOne(f.seq([andOr, exprList]))])

        let whereClause = f.zeroOrOne(f.seq([ws, f.tokenSeq("WHERE"), cut, ws, exprList]))

        // USING SCOPE
        let usingScope = f.onMatch(ident, perform: toToken(.usingScope))
        let filterScope = f.zeroOrOne(f.seq([ws, f.tokenSeq("USING SCOPE"), ws, usingScope]))

        // WITH DATA CATEGORY
        let aCategory = f.onMatch(ident, perform: toToken(.dataCategoryValue))
        let catList = f.seq([f.eq("("), maybeWs, f.oneOrMore(aCategory, separator: commaSep), maybeWs, f.eq(")")])
        let catFilterVal = f.firstOf([catList, aCategory])
        let catName = f.onMatch(ident, perform: toToken(.dataCategory))
        let catFilter = f.seq([
            catName, ws,
            f.oneOfTokens(["AT", "ABOVE", "BELOW", "ABOVE_OR_BELOW"], type: .keyword, completions: nil, addToContext: true),
            cut, maybeWs, catFilterVal,
        ])
        let withDataCat = f.zeroOrOne(f.seq([
            ws, f.tokenSeq("WITH DATA CATEGORY"), cut, ws,
            f.oneOrMore(catFilter, separator: f.seq([ws, f.tokenSeq("AND", type: .operator), ws])),
        ]))

        // GROUP BY
        let groupBy = f.seq([ws, f.tokenSeq("GROUP BY"), cut, ws, f.oneOrMore(fieldOrFunc, separator: commaSep)])
        let groupByFieldList = f.seq([f.eq("("), maybeWs, f.oneOrMore(fieldOrFunc, separator: commaSep), maybeWs, f.eq(")")])
        let groupByRollup = f.seq([ws, f.tokenSeq("GROUP BY ROLLUP"), cut, maybeWs, groupByFieldList])
        let groupByCube = f.seq([ws, f.tokenSeq("GROUP BY CUBE"), cut, maybeWs, groupByFieldList])
        let having = f.zeroOrOne(f.seq([ws, f.tokenSeq("HAVING"), cut, ws, exprList]))
        let groupByClause = f.zeroOrOne(f.seq([f.firstOf([groupByRollup, groupByCube, groupBy]), having]))

        // ORDER BY
        let ascDesc = f.seq([ws, f.oneOfTokens(["ASC", "DESC"], type: .keyword, completions: nil, addToContext: true)])
        let nulls = f.seq([ws, f.tokenSeq("NULLS"), ws, f.oneOfTokens(["FIRST", "LAST"], type: .keyword, completions: nil, addToContext: true)])
        let orderByField = f.seq([fieldOrFunc, f.zeroOrOne(ascDesc), f.zeroOrOne(nulls)])
        let orderByFields = f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("ORDER BY"), cut, ws, f.oneOrMore(orderByField, separator: commaSep)]))

        let litNumber = f.onMatch(f.integerNumber(), perform: toToken(.literalNumber))
        let limit = f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("LIMIT"), cut, maybeWs, litNumber]))
        let offset = f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("OFFSET"), cut, maybeWs, litNumber]))

        let forView = f.zeroOrOne(f.seq([
            maybeWs, f.tokenSeq("FOR"), cut, ws,
            f.oneOfTokens(["VIEW", "REFERENCE"], type: .keyword, completions: nil, addToContext: true),
        ]))

        let trackingCompletions = Completion.completions(["TRACKING", "VIEWSTAT"], type: .keyword)
        let tracking = f.onMatch(f.tokenSeq("TRACKING")) { r in
            r.val.token?.completions += trackingCompletions
            return r
        }
        let viewstat = f.onMatch(f.tokenSeq("VIEWSTAT")) { r in
            r.val.token?.completions += trackingCompletions
            return r
        }
        let trackViewstat = f.firstOf([
            f.seq([tracking, f.zeroOrOne(f.seq([commaSep, viewstat]))]),
            f.seq([viewstat, f.zeroOrOne(f.seq([commaSep, tracking]))]),
        ])
        let updateTracking = f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("UPDATE"), cut, ws, trackViewstat]))

        // SELECT
        selectStmt.parser = f.seq([
            maybeWs, f.tokenSeq("SELECT"), ws, selectExprs, ws, f.tokenSeq("FROM"), ws, objectRefs,
            filterScope, whereClause, withDataCat, groupByClause, orderByFields, limit, offset, forView, updateTracking, maybeWs,
        ])

        // SOSL
        let inExpr = f.zeroOrOne(f.onMatch(f.seq([
            maybeWs, f.tokenSeq("IN"), cut, ws,
            f.oneOfTokens(["ALL", "NAME", "EMAIL", "PHONE", "SIDEBAR"], type: .keyword, completions: nil, addToContext: true),
            f.whitespace, f.tokenSeq("FIELDS"),
        ]), perform: pick(3)))

        let fieldID = f.onMatch(ident) { r in
            // A field path whose value is a single step.
            let t = Token(r.ctx.text, loc: r.loc, type: .fieldPath)
            t.value = .path([r.val.string ?? ""])
            r.ctx.tokens.add(t)
            return r
        }

        // USING LISTVIEW
        let listviewName = f.onMatch(ident, perform: toToken(.listViewName))
        let opEq = f.onMatch(f.eq("="), perform: toToken(.operator))
        let listview = f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("USING LISTVIEW"), maybeWs, cut, opEq, maybeWs, listviewName]))

        let limitOffset = f.seq([f.zeroOrOne(limit), f.zeroOrOne(offset)])
        let fields = f.seq([maybeWs, f.eq("("), maybeWs, f.oneOrMore(fieldID, separator: commaSep), whereClause, listview, orderByFields, limitOffset, f.eq(")")])
        let object = f.onMatch(f.seq([maybeWs, sobject, f.zeroOrOne(fields), limitOffset])) { r in
            let o = r.child(1)
            if !r.childIsNull(2), let objToken = o.val.token {
                // The object's field list becomes its child tokens.
                let objEnd = NSMaxRange(o.loc)
                objToken.value = .tokens(r.ctx.tokens.cut(positionRange: NSRange(location: objEnd, length: NSMaxRange(r.loc) - objEnd)))
            }
            return r
        }

        let returning = f.seq([maybeWs, f.tokenSeq("RETURNING"), f.oneOrMore(object, separator: commaSep)])
        let queryTerm = soslSearchQuery(f)
        let division = f.seq([maybeWs, f.tokenSeq("WITH DIVISION"), maybeWs, cut, opEq, maybeWs, literalValue])
        let metadata = f.seq([maybeWs, f.tokenSeq("WITH METADATA"), maybeWs, cut, opEq, maybeWs, literalValue])
        let pricebook = f.seq([maybeWs, f.tokenSeq("WITH PRICEBOOKID"), maybeWs, cut, opEq, maybeWs, literalValue])
        let spellCorrection = f.seq([maybeWs, f.tokenSeq("WITH SPELL_CORRECTION"), maybeWs, cut, opEq, maybeWs, literalValue])

        let netIn = f.onMatch(f.eq("IN"), perform: toToken(.operator))
        let network = f.seq([
            maybeWs, f.tokenSeq("WITH NETWORK"), maybeWs, cut,
            f.firstOf([f.seq([opEq, maybeWs, literalValue]), f.seq([netIn, maybeWs, literalList])]),
        ])
        let snippet = f.seq([
            maybeWs, f.tokenSeq("WITH SNIPPET"), maybeWs, cut,
            f.zeroOrOne(f.seq([f.eq("("), maybeWs, f.tokenSeq("target_length"), maybeWs, opEq, maybeWs, literalValue, maybeWs, f.eq(")")])),
        ])

        let sosl = f.seq([
            f.maybeWhitespace, f.tokenSeq("FIND"),
            f.maybeWhitespace, queryTerm,
            f.zeroOrOne(inExpr),
            f.zeroOrOne(returning),
            f.zeroOrOne(division),
            f.zeroOrOne(withDataCat),
            f.zeroOrOne(snippet),
            f.zeroOrOne(network),
            f.zeroOrOne(pricebook),
            f.zeroOrOne(metadata),
            f.zeroOrOne(f.seq([maybeWs, f.tokenSeq("WITH HIGHLIGHT")])),
            f.zeroOrOne(spellCorrection),
            updateTracking,
            maybeWs,
        ])

        return f.firstOf([selectStmt, sosl])
    }

    /// The {search terms} of a SOSL query.
    private static func soslSearchQuery(_ f: ParserFactory) -> Parser {
        let oneTerm = f.fromBlock { input in
            let start = input.pos
            var inQuote = false
            while true {
                if !input.hasMoreInput {
                    input.error("reached end of input while parsing the search term at \(input.pos)").pos -= 1
                    return nil
                }
                let c = input.currentChar
                if c == unichar(ascii: "\\") {
                    input.pos += 1
                    if !input.hasMoreInput {
                        input.error("invalid escape sequence at \(input.pos)").pos -= 1
                    }
                    input.pos += 1
                    continue
                }
                if c == unichar(ascii: "\"") {
                    inQuote.toggle()
                    input.pos += 1
                    continue
                }
                if !inQuote {
                    if c == unichar(ascii: "}") || c == unichar(ascii: ")") || isWhitespaceOrNewline(c) {
                        break
                    }
                }
                input.pos += 1
            }
            let range = NSRange(location: start, length: input.pos - start)
            if range.length > 0 {
                let t = Token(input.input, loc: range, type: .literalString)
                input.ctx.tokens.add(t)
                return ParseResult(.token(t), ctx: input.ctx, loc: range)
            }
            input.expectedClass("Search term")
            return nil
        }
        let exprList = f.parserRef()
        let parensExpr = f.seq([f.eq("("), f.maybeWhitespace, exprList, f.maybeWhitespace, f.eq(")")])
        let andOrOp = f.firstOf([f.tokenSeq("OR"), f.seq([f.tokenSeq("AND"), f.maybeWhitespace, f.zeroOrOne(f.tokenSeq("NOT"))])])
        let andOr = f.firstOf([f.seq([andOrOp, f.maybeWhitespace, exprList]), oneTerm])
        exprList.parser = f.seq([f.firstOf([parensExpr, oneTerm]), f.maybeWhitespace, f.zeroOrOne(andOr)])
        return f.seq([f.eq("{"), f.maybeWhitespace, exprList, f.maybeWhitespace, f.eq("}")])
    }
}

private func isWhitespaceOrNewline(_ c: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(c) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
}

private extension ParserFactory {
    /// A sequence of keywords separated by whitespace, e.g. "NULLS LAST" matches "NULLS", whitespace, "LAST".
    func tokenSeq(_ t: String, type: TokenType = .keyword) -> Parser {
        let words = t.split(separator: " ").map(String.init)
        var items: [Parser] = [eq(words[0])]
        for w in words.dropFirst() {
            items.append(whitespace)
            items.append(eq(w))
        }
        let p = items.count == 1 ? items[0] : seq(items)
        return onMatch(p) { r in
            let token = Token(r.ctx.text, loc: r.loc, type: type)
            token.value = .text(t)
            r.val = .token(token)
            r.ctx.tokens.add(token)
            return r
        }
    }

    /// One of the strings, as a token of the given type. Completions default to the list of strings.
    func oneOfTokens(_ tokens: [String], type: TokenType, completions: [Completion]?, addToContext: Bool) -> Parser {
        let completions = completions ?? Completion.completions(tokens, type: type)
        var p = oneOfTokens(tokens)
        p = onError(p) { input in
            input.expectedClass("one of \(tokens.joined(separator: ","))").completions = completions
        }
        return onMatch(p) { r in
            let t = Token(r.ctx.text, loc: r.loc, type: type)
            t.completions += completions
            r.val = .token(t)
            if addToContext {
                r.ctx.tokens.add(t)
            }
            return r
        }
    }

    func ident() -> Parser {
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let identHead = characters(letters, name: "identifier", min: 1)
        let identTail = characters(letters.union(CharacterSet(charactersIn: "0123456789_")), name: "identifier", min: 0)
        return onMatch(seq([identHead, identTail])) { r in
            r.val = .string(r.ctx.text.substring(with: r.loc))
            return r
        }
    }

    func literalStringValue() -> Parser {
        fromBlock { input in
            let start = input.pos
            if !input.hasMoreInput || input.currentChar != unichar(ascii: "'") {
                input.expected("'")
                return nil
            }
            input.pos += 1
            input.markCut()
            while true {
                if !input.hasMoreInput {
                    input.error("reached end of input while parsing a string literal, missing closing ' at \(input.pos)").pos -= 1
                    return nil
                }
                let c = input.currentChar
                if c == unichar(ascii: "\\") {
                    input.pos += 1
                    if !input.hasMoreInput {
                        input.error("invalid escape sequence at \(input.pos)").pos -= 1
                    }
                    input.pos += 1
                    continue
                }
                input.pos += 1
                if c == unichar(ascii: "'") {
                    break
                }
            }
            // The range includes the quotes.
            let range = NSRange(location: start, length: input.pos - start)
            return ParseResult(.token(Token(input.input, loc: range, type: .literalString)), ctx: input.ctx, loc: range)
        }
    }

    func literalValue() -> Parser {
        func literal(_ p: Parser, _ type: TokenType, completions: [Completion] = []) -> Parser {
            onMatch(p) { r in
                let t = Token(r.ctx.text, loc: r.loc, type: type)
                t.completions += completions
                r.val = .token(t)
                return r
            }
        }
        let boolCompletions = Completion.completions(["TRUE", "FALSE"], type: .literalBoolean)
        let dateTimeRegex = try! NSRegularExpression(pattern: #"\d\d\d\d-\d\d-\d\d(?:T\d\d:\d\d:\d\d(?:Z|[+-]\d\d:\d\d))?"#, options: .caseInsensitive)
        let dateTime = onMatch(regex(dateTimeRegex, name: "date/time literal")) { r in
            let t = Token(r.ctx.text, loc: r.loc, type: r.loc.length == 10 ? .literalDate : .literalDateTime)
            r.val = .token(t)
            return r
        }
        let currencyRegex = try! NSRegularExpression(pattern: #"[a-z]{3}\d+(?:\.\d+)?"#, options: .caseInsensitive)
        let namedRegex = try! NSRegularExpression(pattern: #"[a-z][a-z0-9:_\-\.]*"#, options: .caseInsensitive)
        return onMatch(firstOf([
            literalStringValue(),
            literal(eq("null"), .literalNull),
            literal(eq("true"), .literalBoolean, completions: boolCompletions),
            literal(eq("false"), .literalBoolean, completions: boolCompletions),
            dateTime,
            literal(decimalNumber(), .literalNumber),
            literal(regex(currencyRegex, name: "currency"), .literalCurrency),
            literal(regex(namedRegex, name: "named literal"), .literalNamedDateTime),
        ])) { r in
            if let t = r.val.token {
                r.ctx.tokens.add(t)
            }
            return r
        }
    }
}

import Foundation

// Resolves parsed SOQL tokens against the schema: checks fields, relationships, aliases,
// functions and literals, and attaches errors and completions. Ported from SoqlXplorer's
// SoqlTokenizer (MIT license).

/// Supplies SObject describes to the analyzer.
protocol SoqlDescriber: AnyObject {
    /// The describe, if it's available. Implementations can fetch it in the background.
    func schemaObject(_ sobject: String) -> SoqlSchemaObject?
    /// Whether the SObject is in the org's global describe.
    func knownSObject(_ sobject: String) -> Bool
    var allQueryableSObjects: [String] { get }
}

/// The settings that apply to part of a query, e.g. inside a function's arguments.
private final class ContextFilters {
    var primary: SoqlSchemaObject?
    var containerType: TokenType = []
    var fieldCompletionsFilter: FieldFilter?
    var restrictCompletionsToType: TokenType = .all
    var fnCompletionsFilter: FunctionFilter? = SoqlFunction.defaultFilter

    func copy() -> ContextFilters {
        let c = ContextFilters()
        c.primary = primary
        c.containerType = containerType
        c.fieldCompletionsFilter = fieldCompletionsFilter
        c.restrictCompletionsToType = restrictCompletionsToType
        c.fnCompletionsFilter = fnCompletionsFilter
        return c
    }
}

private final class Context {
    /// SObjects by lowercased alias. Nil for SOSL.
    var aliases: [String: SoqlSchemaObject]?
    /// Alias names as written, for completions.
    var aliasNames: [String] = []
    private var filters = [ContextFilters()]

    var filter: ContextFilters { filters[filters.count - 1] }

    @discardableResult
    func createChild() -> ContextFilters {
        let c = filter.copy()
        filters.append(c)
        return c
    }

    func popChild() {
        precondition(filters.count > 1, "too many pops")
        filters.removeLast()
    }

    /// Runs the block with a new child filter, which is thrown away afterwards.
    func withChildFilters(_ block: (ContextFilters) -> Void) {
        let c = createChild()
        block(c)
        popChild()
    }

    func setAlias(_ name: String, _ obj: SoqlSchemaObject?) {
        guard let obj else { return }
        if aliases?[name.lowercased()] == nil {
            aliasNames.append(name)
        }
        aliases?[name.lowercased()] = obj
    }
}

final class SoqlAnalyzer {
    weak var describer: SoqlDescriber?

    private let parser = SoqlParser()
    private let typeOfCompletion: Completion = {
        let c = Completion("TYPEOF", type: .typeOf)
        c.finalInsertionText = "TYPEOF Relation WHEN ObjectType THEN id END"
        c.onFinalInsert = .moveSelection(-28)
        return c
    }()

    /// Parses the query and resolves its tokens. Parse errors are returned as error tokens.
    func parseAndResolve(_ soql: String) -> Tokens {
        let input = soql as NSString
        let (tokens, failure) = parser.parse(input)
        if let failure {
            var word = Self.word(at: failure.position - 1, in: input)
            if word.length == 0 && word.location > 0 {
                word.location -= 1
                word.length += 1
            }
            let t = Token(input, loc: word, type: .error)
            t.value = .text(failure.message)
            t.completions += failure.completions ?? []
            tokens.add(t)
        }
        resolve(tokens)
        return tokens
    }

    private static func isWordBreak(_ c: unichar) -> Bool {
        c == unichar(ascii: " ") || c == unichar(ascii: "\t") || c == unichar(ascii: ",")
            || c == unichar(ascii: ".") || c == unichar(ascii: "(") || c == unichar(ascii: ")")
    }

    private static func word(at idx: Int, in txt: NSString) -> NSRange {
        var sel = NSRange(location: max(0, min(idx, txt.length)), length: 0)
        while sel.location > 0 {
            if isWordBreak(txt.character(at: sel.location - 1)) { break }
            sel.location -= 1
            sel.length += 1
        }
        let maxLen = txt.length - sel.location
        while sel.length < maxLen {
            if isWordBreak(txt.character(at: sel.location + sel.length)) { break }
            sel.length += 1
        }
        return sel
    }

    // MARK: - Resolving

    private func resolve(_ tokens: Tokens) {
        // Move the tokens inside nested selects and TYPEOF into the token's value, to make them easier to deal with.
        var idx = 0
        while idx < tokens.count {
            let t = tokens.tokens[idx]
            if t.type == .childSelect || t.type == .semiJoinSelect || t.type == .typeOf {
                let start = idx + 1
                var end = start
                let selEnd = NSMaxRange(t.loc)
                while end < tokens.count && tokens.tokens[end].loc.location < selEnd {
                    end += 1
                }
                t.value = .tokens(tokens.cut(start..<end))
            }
            idx += 1
        }
        resolve(tokens, parent: nil)
    }

    private func resolve(_ tokens: Tokens, parent: Context?) {
        guard let first = tokens.tokens.first else { return }
        if case .text("SELECT") = first.value {
            let ctx = resolveFrom(tokens, parent: parent)
            resolveTokenList(tokens, ctx: ctx)
        } else {
            resolveSoslReturning(tokens)
        }
    }

    private func resolveTokenList(_ tokens: Tokens, ctx: Context) {
        // count() can only be used on its own.
        var selectExprCount = 0
        var countStar: Token?
        for sel in tokens.tokens {
            if sel.type == .function, (sel.value.tokens?.count ?? 0) == 0, sel.matches("COUNT") {
                countStar = sel
            }
            if [.function, .field, .fieldPath, .typeOf, .childSelect].contains(sel.type) {
                selectExprCount += 1
            }
            if sel.type == .keyword, case .text("FROM") = sel.value {
                break
            }
        }
        if let countStar, selectExprCount > 1 {
            let err = countStar.token(of: countStar.loc, type: .error)
            err.value = .text("A count() query can't select any additional fields")
            tokens.add(err)
        }

        var newTokens: [Token] = []
        var inGroupBy = false
        for sel in tokens.tokens {
            if !inGroupBy, sel.type == .keyword, case .text(let kw) = sel.value, ["GROUP BY", "GROUP BY ROLLUP", "GROUP BY CUBE"].contains(kw) {
                inGroupBy = true
                ctx.createChild().fieldCompletionsFilter = { $0.groupable }
            } else if inGroupBy, sel.type == .keyword {
                inGroupBy = false
                ctx.popChild()
            }
            resolveToken(sel, newTokens: &newTokens, ctx: ctx)
        }
        tokens.add(contentsOf: newTokens)
        if inGroupBy {
            ctx.popChild()
        }
    }

    private func resolveToken(_ expr: Token, newTokens: inout [Token], ctx: Context) {
        switch expr.type {
        case .fieldPath:
            resolveFieldPath(expr, ctx: ctx)
        case .function:
            newTokens += resolveFunc(expr, ctx: ctx)
        case .typeOf:
            resolveTypeOf(expr, ctx: ctx)
        case .childSelect, .semiJoinSelect:
            ctx.withChildFilters { child in
                child.containerType = expr.type
                if let children = expr.value.tokens {
                    resolve(children, parent: ctx)
                }
            }
        case .literalNamedDateTime:
            if let err = resolveNamedDateTime(expr) {
                newTokens.append(err)
            }
        default:
            break
        }
    }

    private func resolveFunc(_ f: Token, ctx: Context) -> [Token] {
        addFieldCompletions(for: ctx.filter.primary, to: f, ctx: ctx)
        let argTokens = f.value.tokens ?? Tokens()
        guard let fn = SoqlFunction.named(f.tokenTxt) else {
            let err = f.token(of: f.loc, type: .error)
            err.value = .text("There is no function named '\(f.tokenTxt)'")
            resolveTokenList(argTokens, ctx: ctx)
            return [err]
        }
        var errors: [Token] = []
        if let fnFilter = ctx.filter.fnCompletionsFilter, !fnFilter(fn) {
            let err = f.token(of: f.loc, type: .error)
            err.value = .text("The function \(fn.name) is not valid at this location")
            errors.append(err)
        }
        if let err = fn.validateArgCount(f) {
            errors.append(err)
        }
        var argsNewTokens: [Token] = []
        var argSpecs = fn.args.makeIterator()
        for argToken in argTokens.tokens {
            let argSpec = argSpecs.next()
            ctx.withChildFilters { child in
                child.fieldCompletionsFilter = argSpec?.fieldFilter
                child.fnCompletionsFilter = argSpec?.funcFilter
                child.restrictCompletionsToType = argSpec?.type ?? []
                resolveToken(argToken, newTokens: &argsNewTokens, ctx: ctx)
                if let err = argSpec?.validate(argToken) {
                    argsNewTokens.append(err)
                }
            }
        }
        argTokens.add(contentsOf: argsNewTokens)
        return errors
    }

    private func resolveTypeOf(_ typeOf: Token, ctx: Context) {
        guard let primary = ctx.filter.primary, let tokens = typeOf.value.tokens else { return }
        var e = tokens.tokens.makeIterator()
        var t = e.next()
        if t?.type == .keyword { t = e.next() } // TYPEOF
        var relField: FieldDescribe?
        if let rel = t, rel.type == .relationship {
            for f in primary.fields where f.referenceTo.count > 1 && !(f.relationshipName ?? "").isEmpty {
                rel.completions.append(Completion(f.relationshipName!, type: .relationship))
                if rel.matches(f.relationshipName!) {
                    relField = f
                }
            }
            if relField == nil {
                rel.type = .error
                rel.value = .text("There is no polymorphic relationship '\(rel.tokenTxt)' on SObject \(primary.name)")
                return
            }
        }
        ctx.withChildFilters { child in
            child.restrictCompletionsToType = child.restrictCompletionsToType.subtracting(.function)
            var t = e.next()
            while let when = t, when.type == .keyword, when.matches("WHEN") {
                t = e.next()
                if let obj = t, obj.type == .sobject {
                    let referenceTo = relField?.referenceTo ?? []
                    obj.completions += Completion.completions(referenceTo, type: .sobject)
                    if !referenceTo.contains(where: { $0.caseInsensitiveCompare(obj.tokenTxt) == .orderedSame }) {
                        obj.type = .error
                        obj.value = .text("Relationship \(relField?.relationshipName ?? "(null)") does not reference SObject \(obj.tokenTxt)")
                        return
                    }
                    child.primary = describer?.schemaObject(obj.tokenTxt)
                    t = e.next()
                    if t?.type == .keyword { t = e.next() } // THEN
                    while let path = t, path.type == .fieldPath {
                        resolveFieldPath(path, ctx: ctx)
                        t = e.next()
                    }
                }
            }
            if let els = t, els.type == .keyword, els.matches("ELSE") {
                child.primary = describer?.schemaObject("Name")
                t = e.next()
                while let path = t, path.type == .fieldPath {
                    resolveFieldPath(path, ctx: ctx)
                    t = e.next()
                }
            }
            if let end = t, end.type != .keyword || !end.matches("END") {
                end.type = .error
                end.value = .text("Expecting keyword END")
            }
            t = e.next()
            while let extra = t {
                extra.type = .error
                extra.value = .text("Unexpected token \(extra.tokenTxt)")
                t = e.next()
            }
        }
    }

    /// Resolves a field path such as `Account.Owner.Name` into alias, relationship and field tokens.
    ///
    /// The first step can be the SObject name (`select account.name from account`), the SObject's
    /// alias (`select a.name from account a`), or the alias of a relationship in the FROM clause
    /// (`SELECT count() FROM Contact c, c.Account a WHERE a.name = 'MyriadPubs'`).
    private func resolveFieldPath(_ fieldPath: Token, ctx: Context) {
        guard case .path(var path) = fieldPath.value, !path.isEmpty else { return }
        let firstStep = path[0]
        var curr = ctx.filter.primary
        var position = fieldPath.loc.location
        let resolved = Tokens()
        fieldPath.value = .tokens(resolved)

        func stepLength(_ s: String) -> Int { s.utf16.count }

        if let primary = ctx.filter.primary, firstStep.caseInsensitiveCompare(primary.name) == .orderedSame {
            path.removeFirst()
            let tStep = fieldPath.token(of: NSRange(location: position, length: stepLength(firstStep)), type: .alias)
            addSObjectAliasCompletions(ctx, to: tStep)
            resolved.add(tStep)
            position += stepLength(firstStep) + 1
        } else if let a = ctx.aliases?[firstStep.lowercased()] {
            // The alias map was populated from the FROM clause by resolveFrom.
            curr = a
            path.removeFirst()
            let tStep = fieldPath.token(of: NSRange(location: position, length: stepLength(firstStep)), type: .alias)
            addSObjectAliasCompletions(ctx, to: tStep)
            resolved.add(tStep)
            position += stepLength(firstStep) + 1
        }
        if path.isEmpty {
            // Just the object name isn't valid.
            let err = fieldPath.token(of: fieldPath.loc, type: .error)
            err.value = .text("Need to add a field to the SObject \(ctx.filter.primary?.name ?? "(null)")")
            addSObjectAliasCompletions(ctx, to: err)
            resolved.add(err)
            return
        }

        ctx.withChildFilters { child in
            for (i, step) in path.enumerated() {
                let isLast = i == path.count - 1
                let tStep = fieldPath.token(of: NSRange(location: position, length: stepLength(step)))
                addFieldCompletions(for: curr, to: tStep, ctx: ctx)
                if let df = curr?.field(named: step) {
                    // A field, which has to be the last step in the path.
                    if !isLast {
                        let err = fieldPath.token(of: NSRange(location: NSMaxRange(tStep.loc), length: 1), type: .error)
                        err.value = .text("\(step) is a field not a relationship, it should be the last item in the field path")
                        resolved.add(err)
                        break
                    }
                    tStep.type = .field
                    tStep.value = .field(df)
                    if let filter = child.fieldCompletionsFilter, !filter(df) {
                        let err = fieldPath.token(of: tStep.loc, type: .error)
                        err.value = .text("Field \(df.name) exists, but is not valid for use here")
                        resolved.add(err)
                    }
                } else {
                    // It might be a relationship instead.
                    let df = curr?.parentRelationshipsByName[step.lowercased()]
                    if let curr {
                        if df == nil {
                            tStep.type = .error
                            tStep.value = .text("There is no field or relationship \(step) on SObject \(curr.name)")
                            resolved.add(tStep)
                            break
                        } else if isLast {
                            tStep.type = .error
                            tStep.value = .text("\(df?.relationshipName ?? step) is a relationship, it should be followed by a field")
                            resolved.add(tStep)
                            break
                        }
                    }
                    guard let df else { break }
                    tStep.type = .relationship
                    tStep.value = .field(df)
                    // For a polymorphic relationship, the valid fields are those of Name, not any of the actual related types.
                    curr = df.namePointing ? describer?.schemaObject("Name") : describer?.schemaObject(df.referenceTo[0])
                }
                resolved.add(tStep)
                position += stepLength(step) + 1
                child.restrictCompletionsToType = child.restrictCompletionsToType.subtracting([.function, .typeOf])
            }
        }
    }

    private func addSObjectAliasCompletions(_ ctx: Context, to t: Token) {
        t.completions.append(Completion(ctx.filter.primary?.name ?? "", type: .alias))
        t.completions += Completion.completions(ctx.aliasNames, type: .alias)
    }

    private func addFieldCompletions(for obj: SoqlSchemaObject?, to t: Token, ctx: Context) {
        let allowed = ctx.filter.restrictCompletionsToType
        if !allowed.isDisjoint(with: [.field, .fieldPath]), let obj {
            if let filter = ctx.filter.fieldCompletionsFilter {
                for (field, completion) in zip(obj.fields, obj.fieldCompletions) where filter(field) {
                    t.completions.append(completion)
                }
            } else {
                t.completions += obj.fieldCompletions
            }
        }
        if !allowed.isDisjoint(with: [.relationship, .fieldPath]), let obj {
            t.completions += obj.parentRelCompletions
        }
        if allowed.contains(.typeOf) {
            t.completions.append(typeOfCompletion)
        }
        if allowed.contains(.function), let obj {
            for fn in SoqlFunction.functions(filteredBy: ctx.filter.fnCompletionsFilter) {
                t.completions.append(obj.completion(for: fn))
            }
        }
    }

    /// Adds SObject completions to the token, and marks it as an error if the SObject doesn't exist.
    @discardableResult
    private func addSObjects(to t: Token) -> Bool {
        let names = describer?.allQueryableSObjects ?? []
        t.completions += Completion.completions(names, type: .sobject)
        if !(describer?.knownSObject(t.tokenTxt) ?? false) {
            t.type = .error
            t.value = .text("The SObject '\(t.tokenTxt)' does not exist or is inaccessible")
            return false
        }
        return true
    }

    private func resolveSoslReturning(_ tokens: Tokens) {
        let ctx = Context()
        for t in tokens.tokens where t.type == .sobject {
            addSObjects(to: t)
            ctx.filter.primary = describer?.schemaObject(t.tokenTxt)
            if let fields = t.value.tokens {
                resolveTokenList(fields, ctx: ctx)
            }
        }
    }

    private func resolveFrom(_ tokens: Tokens, parent: Context?) -> Context {
        let ctx = Context()
        ctx.aliases = [:]
        var skipUntil = 0
        guard let idx = tokens.tokens.firstIndex(where: { t in
            if t.type == .childSelect {
                skipUntil = NSMaxRange(t.loc)
            }
            return t.loc.location >= skipUntil && t.type == .sobject
        }) else { return ctx }

        let tSObject = tokens.tokens[idx]
        if parent == nil || parent?.filter.containerType == .semiJoinSelect {
            ctx.filter.primary = describer?.schemaObject(tSObject.tokenTxt)
            if !addSObjects(to: tSObject) || ctx.filter.primary == nil {
                // Can't do any more without the describe.
                return ctx
            }
        } else {
            // In a nested select, FROM names a child relationship, not an SObject.
            let parentPrimary = parent?.filter.primary
            let children = parentPrimary?.childRelationshipsByName ?? [:]
            tSObject.completions += Completion.completions(children.values.compactMap(\.relationshipName), type: .relationship)
            guard let cr = children[tSObject.tokenTxt.lowercased()] else {
                tSObject.type = .error
                tSObject.value = .text("The SObject '\(parentPrimary?.name ?? "(null)")' does not have a child relationship called \(tSObject.tokenTxt)")
                return ctx
            }
            tSObject.type = .relationship
            ctx.filter.primary = describer?.schemaObject(cr.childSObject)
        }
        // Does the primary SObject have an alias?
        if tokens.count > idx + 1, tokens.tokens[idx + 1].type == .aliasDecl {
            ctx.setAlias(tokens.tokens[idx + 1].tokenTxt, ctx.filter.primary)
        }
        // Related objects with aliases, e.g. FROM Contact c, c.Account a
        var e = tokens.tokens[idx...].makeIterator()
        while let t = e.next(), t.type != .keyword {
            guard t.type == .sobjectRelation, case .path(var path) = t.value, !path.isEmpty else { continue }
            // The first step can be an alias, or a relationship on the primary object.
            var curr = ctx.aliases?[path[0].lowercased()]
            t.completions += Completion.completions(curr?.parentRelationshipsByName.values.compactMap(\.relationshipName) ?? [], type: .sobjectRelation)
            var pos = t.loc.location
            if curr != nil {
                pos += path[0].utf16.count + 1
                path.removeFirst()
            } else {
                curr = ctx.filter.primary
            }
            for step in path {
                guard let df = curr?.parentRelationshipsByName[step.lowercased()] else {
                    let err = t.token(of: NSRange(location: pos, length: step.utf16.count), type: .error)
                    err.completions += Completion.completions(curr?.parentRelationshipsByName.values.compactMap(\.relationshipName) ?? [], type: .sobjectRelation)
                    err.value = .text("There is no relationship \(step) on SObject \(curr?.name ?? "(null)")")
                    tokens.add(err)
                    curr = nil
                    break
                }
                curr = df.namePointing ? describer?.schemaObject("Name") : describer?.schemaObject(df.referenceTo[0])
                pos += step.utf16.count + 1
            }
            // The relationship should have an alias, otherwise there's not much point.
            if let next = e.next(), curr != nil, next.type == .aliasDecl {
                ctx.setAlias(next.tokenTxt, curr)
            }
        }
        return ctx
    }

    private static let namedDates: Set<String> = [
        "YESTERDAY", "TODAY", "TOMORROW", "LAST_WEEK", "THIS_WEEK", "NEXT_WEEK", "LAST_MONTH",
        "THIS_MONTH", "NEXT_MONTH", "LAST_90_DAYS", "NEXT_90_DAYS", "THIS_QUARTER", "LAST_QUARTER", "NEXT_QUARTER",
        "THIS_YEAR", "LAST_YEAR", "NEXT_YEAR", "THIS_FISCAL_QUARTER", "LAST_FISCAL_QUARTER", "NEXT_FISCAL_QUARTER",
        "THIS_FISCAL_YEAR", "LAST_FISCAL_YEAR", "NEXT_FISCAL_YEAR",
    ]

    /// Date literals that take a number, e.g. LAST_N_DAYS:3
    private static let namedDatesWithNumber: Set<String> = [
        "LAST_N_DAYS", "NEXT_N_DAYS", "NEXT_N_WEEKS", "LAST_N_WEEKS", "NEXT_N_MONTHS", "LAST_N_MONTHS",
        "NEXT_N_QUARTERS", "LAST_N_QUARTERS", "NEXT_N_YEARS", "LAST_N_YEARS", "NEXT_N_FISCAL_QUARTERS",
        "LAST_N_FISCAL_QUARTERS", "NEXT_N_FISCAL_YEARS", "LAST_N_FISCAL_YEARS",
    ]

    private static let namedDateCompletions: [Completion] =
        Completion.completions(namedDates.sorted(), type: .literalNamedDateTime)
        + Completion.completions(namedDatesWithNumber.sorted().map { "\($0):1" }, type: .literalNamedDateTime)

    private func resolveNamedDateTime(_ token: Token) -> Token? {
        token.completions += Self.namedDateCompletions
        let val = token.tokenTxt.uppercased()
        if Self.namedDates.contains(val) {
            return nil
        }
        if let colon = val.firstIndex(of: ":"), Self.namedDatesWithNumber.contains(String(val[..<colon])) {
            let number = val[val.index(after: colon)...]
            if !number.isEmpty && number.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                return nil
            }
        }
        let err = token.token(of: token.loc, type: .error)
        err.value = .text("\(token.tokenTxt) is not a valid date literal")
        return err
    }
}

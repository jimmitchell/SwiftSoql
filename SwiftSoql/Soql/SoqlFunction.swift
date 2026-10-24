import Foundation

// SOQL functions and their argument rules, ported from SoqlXplorer's SoqlFunction (MIT license).

typealias FieldFilter = (FieldDescribe) -> Bool
typealias FunctionFilter = (SoqlFunction) -> Bool

class SoqlFuncArg {
    let type: TokenType
    let fieldFilter: FieldFilter?
    var funcFilter: FunctionFilter?
    /// Example text for the argument, used in the function's completion.
    let example: (SoqlSchemaObject) -> String

    init(_ type: TokenType, fieldFilter: FieldFilter? = nil, funcFilter: FunctionFilter? = nil, example: ((SoqlSchemaObject) -> String)? = nil) {
        self.type = type
        self.fieldFilter = fieldFilter
        self.funcFilter = funcFilter
        self.example = example ?? { obj in
            // The first field that's valid for the argument.
            obj.fields.first { fieldFilter?($0) ?? false }?.name ?? "Id"
        }
    }

    /// Returns an error token if the argument isn't valid.
    func validate(_ argToken: Token) -> Token? {
        if type.intersection(argToken.type) != argToken.type {
            let err = argToken.token(of: argToken.loc, type: .error)
            err.value = .text("Function argument of unexpected type \(argToken.type.name), should be \(type.names)")
            return err
        }
        if type.contains(.fieldPath), argToken.type == .fieldPath, let fieldFilter,
           let last = argToken.value.tokens?.tokens.last, last.type == .field, case .field(let f) = last.value,
           !fieldFilter(f) {
            let err = argToken.token(of: argToken.loc, type: .error)
            err.value = .text("Field \(argToken.tokenTxt) is not valid for this function")
            return err
        }
        return nil
    }
}

/// The units argument of DISTANCE.
private final class DistanceMeasureArg: SoqlFuncArg {
    init() {
        super.init(.literalString, example: { _ in "'mi'" })
    }

    override func validate(_ argToken: Token) -> Token? {
        argToken.completions += Completion.completions(["'mi'", "'km'"], type: .literalString)
        var err = super.validate(argToken)
        if err == nil, !argToken.matches("'mi'"), !argToken.matches("'km'") {
            err = argToken.token(of: argToken.loc, type: .error)
            err?.value = .text("Function argument should be 'mi' or 'km'")
        }
        return err
    }
}

/// The argument of FIELDS().
private final class FieldsArg: SoqlFuncArg {
    init() {
        super.init(.keyword, example: { _ in "STANDARD" })
    }

    override func validate(_ argToken: Token) -> Token? {
        let valid = ["STANDARD", "ALL", "CUSTOM"]
        argToken.completions += Completion.completions(valid, type: .keyword)
        if argToken.type == .fieldPath {
            argToken.type = .keyword
        }
        let err = super.validate(argToken)
        if err == nil, !valid.contains(where: argToken.matches) {
            argToken.type = .error
            argToken.value = .text("Fields argument should be one of \(valid.joined(separator: ","))")
        }
        return err
    }
}

class SoqlFunction {
    let name: String
    let args: [SoqlFuncArg]

    init(_ name: String, args: [SoqlFuncArg]) {
        self.name = name
        self.args = args
    }

    /// Returns an error token if the function has the wrong number of arguments.
    func validateArgCount(_ fn: Token) -> Token? {
        let count = fn.value.tokens?.count ?? 0
        if count != args.count {
            let err = fn.token(of: fn.loc, type: .error)
            err.value = .text("The function \(name) should have \(args.count) arguments, but has \(count)")
            return err
        }
        return nil
    }

    /// A completion that inserts the function with example arguments, leaving the cursor after the first one.
    func completion(on primary: SoqlSchemaObject) -> Completion {
        var s = name + "("
        var posAtEndOfFirstArg = 0
        for (i, arg) in args.enumerated() {
            if i > 0 { s += "," }
            s += arg.example(primary)
            if i == 0 { posAtEndOfFirstArg = s.utf16.count }
        }
        s += ")"
        let c = Completion(name, type: .function)
        c.finalInsertionText = s
        if posAtEndOfFirstArg > 0 {
            c.onFinalInsert = .moveSelection(-(s.utf16.count - posAtEndOfFirstArg))
        }
        return c
    }

    // MARK: - The functions

    /// All functions, keyed by lowercased name.
    static let all: [String: SoqlFunction] = {
        let numeric: FieldFilter = { $0.aggregatable && ["double", "int", "percent", "currency"].contains($0.type) }
        let minMax: FieldFilter = { $0.aggregatable && $0.type != "id" && $0.type != "reference" }
        let dateOrDateTime: FieldFilter = { $0.type == "datetime" || $0.type == "date" }
        let dateTimeOnly: FieldFilter = { $0.type == "datetime" }

        let convertTimezone = SoqlFunction("ConvertTimezone", args: [SoqlFuncArg(.fieldPath, fieldFilter: dateOrDateTime)])
        let convertTimezoneOnly: FunctionFilter = { $0.name == "ConvertTimezone" }
        let geolocation = SoqlFunction("Geolocation", args: [
            SoqlFuncArg(.literalNumber, example: { _ in "1.0" }),
            SoqlFuncArg(.literalNumber, example: { _ in "1.0" }),
        ])
        let convertCurrency = SoqlFunction("ConvertCurrency", args: [SoqlFuncArg(.fieldPath, fieldFilter: { $0.type == "currency" })])
        let convertCurrencyOnly: FunctionFilter = { $0.name == "ConvertCurrency" }

        func dateFn(_ name: String, _ filter: @escaping FieldFilter = dateOrDateTime) -> SoqlFunction {
            SoqlFunction(name, args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: filter, funcFilter: convertTimezoneOnly)])
        }

        let fns: [SoqlFunction] = [
            SoqlFunction("Fields", args: [FieldsArg()]),
            SoqlFunction("ToLabel", args: [SoqlFuncArg(.fieldPath, fieldFilter: { $0.type != "id" && $0.type != "reference" })]),
            SoqlCountFunction(),
            SoqlFunction("Count_Distinct", args: [SoqlFuncArg(.fieldPath, fieldFilter: { $0.aggregatable })]),
            SoqlFunction("Avg", args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: numeric, funcFilter: convertCurrencyOnly)]),
            SoqlFunction("Sum", args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: numeric, funcFilter: convertCurrencyOnly)]),
            SoqlFunction("Min", args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: minMax, funcFilter: convertCurrencyOnly)]),
            SoqlFunction("Max", args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: minMax, funcFilter: convertCurrencyOnly)]),
            SoqlFunction("Format", args: [SoqlFuncArg([.fieldPath, .function], fieldFilter: {
                ["datetime", "date", "time", "currency", "double", "int"].contains($0.type)
            })]),
            SoqlFunction("Distance", args: [
                SoqlFuncArg(.fieldPath, fieldFilter: { $0.type == "location" }),
                SoqlFuncArg(.function, funcFilter: { $0.name == "Geolocation" }, example: { _ in "GeoLocation(1.0,1.0)" }),
                DistanceMeasureArg(),
            ]),
            dateFn("Calendar_Month"),
            dateFn("Calendar_Quarter"),
            dateFn("Calendar_Year"),
            dateFn("Day_In_Month"),
            dateFn("Day_In_Week"),
            dateFn("Day_In_Year"),
            dateFn("Day_Only", dateTimeOnly),
            dateFn("Fiscal_Month"),
            dateFn("Fiscal_Quarter"),
            dateFn("Fiscal_Year"),
            dateFn("Hour_In_Day", dateTimeOnly),
            dateFn("Week_In_Month"),
            dateFn("Week_In_Year"),
            SoqlFunction("Grouping", args: [SoqlFuncArg(.fieldPath, fieldFilter: { $0.groupable })]),
            convertCurrency, convertTimezone, geolocation,
        ]
        return Dictionary(uniqueKeysWithValues: fns.map { ($0.name.lowercased(), $0) })
    }()

    static func named(_ name: String) -> SoqlFunction? {
        all[name.lowercased()]
    }

    /// Functions allowed in a select list or filter: everything but those only valid as another function's argument.
    static let defaultFilter: FunctionFilter = { $0.name != "Geolocation" && $0.name != "ConvertTimezone" }

    static let allSorted = all.values.sorted { $0.name < $1.name }

    static func functions(filteredBy filter: FunctionFilter?) -> [SoqlFunction] {
        guard let filter else { return allSorted }
        return allSorted.filter(filter)
    }
}

/// COUNT, which can be used as both count() and count(field).
private final class SoqlCountFunction: SoqlFunction {
    init() {
        super.init("Count", args: [SoqlFuncArg(.fieldPath, fieldFilter: { $0.aggregatable })])
    }

    override func validateArgCount(_ fn: Token) -> Token? {
        if (fn.value.tokens?.count ?? 0) == 0 {
            return nil
        }
        return super.validateArgCount(fn)
    }
}

/// An SObject describe with the lookups the analyzer needs, built on first use.
final class SoqlSchemaObject {
    let describe: SObjectDescribe

    init(_ describe: SObjectDescribe) {
        self.describe = describe
    }

    var name: String { describe.name }
    var fields: [FieldDescribe] { describe.fields }

    private lazy var fieldsByName: [String: FieldDescribe] = {
        var d: [String: FieldDescribe] = [:]
        for f in fields { d[f.name.lowercased()] = f }
        return d
    }()

    func field(named name: String) -> FieldDescribe? {
        fieldsByName[name.lowercased()]
    }

    /// Reference fields keyed by lowercased relationship name.
    private(set) lazy var parentRelationshipsByName: [String: FieldDescribe] = {
        var d: [String: FieldDescribe] = [:]
        for f in fields {
            if let rel = f.relationshipName, !rel.isEmpty, !f.referenceTo.isEmpty {
                d[rel.lowercased()] = f
            }
        }
        return d
    }()

    /// Child relationships keyed by lowercased relationship name.
    private(set) lazy var childRelationshipsByName: [String: ChildRelationship] = {
        var d: [String: ChildRelationship] = [:]
        for r in describe.childRelationships {
            if let rel = r.relationshipName, !rel.isEmpty {
                d[rel.lowercased()] = r
            }
        }
        return d
    }()

    /// Completions for relationship names; choosing one inserts "Relationship.Id" with the Id selected.
    private(set) lazy var parentRelCompletions: [Completion] = parentRelationshipsByName.values.compactMap { f in
        guard let rel = f.relationshipName else { return nil }
        let c = Completion(rel, type: .relationship)
        c.finalInsertionText = rel + ".Id"
        c.onFinalInsert = .selectRelationshipField
        return c
    }

    /// One completion per field, in field order.
    private(set) lazy var fieldCompletions: [Completion] = fields.map { Completion($0.name, type: .field) }

    private var functionCompletions: [String: Completion] = [:]

    func completion(for fn: SoqlFunction) -> Completion {
        if let c = functionCompletions[fn.name] { return c }
        let c = fn.completion(on: self)
        functionCompletions[fn.name] = c
        return c
    }
}

import Foundation

/// The parts of the platform that write to the debug log, as the Apex API's DebuggingHeader names them.
nonisolated enum ApexLogCategory: String, CaseIterable, Identifiable, Sendable {
    case db = "Db"
    case workflow = "Workflow"
    case validation = "Validation"
    case callout = "Callout"
    case apexCode = "Apex_code"
    case apexProfiling = "Apex_profiling"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .db: "Database"
        case .workflow: "Workflow"
        case .validation: "Validation"
        case .callout: "Callouts"
        case .apexCode: "Apex Code"
        case .apexProfiling: "Apex Profiling"
        }
    }

    /// The level used until the user picks one: enough to see System.debug output and DML.
    var defaultLevel: ApexLogLevel {
        switch self {
        case .apexCode: .debug
        case .db: .info
        default: .none
        }
    }
}

nonisolated enum ApexLogLevel: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case error = "Error"
    case warn = "Warn"
    case info = "Info"
    case debug = "Debug"
    case fine = "Fine"
    case finer = "Finer"
    case finest = "Finest"

    var id: String { rawValue }
}

/// The outcome of running anonymous Apex.
nonisolated struct ApexExecution: Identifiable, Sendable {
    let id = UUID()
    let code: String
    let date: Date
    let compiled: Bool
    let success: Bool
    /// Where compilation failed or the exception was thrown; -1 if unknown.
    let line: Int
    let column: Int
    let compileProblem: String?
    let exceptionMessage: String?
    let exceptionStackTrace: String?
    let debugLog: String

    /// A one-line summary, as SoqlXplorer shows it.
    var resultText: String {
        success ? "Success" : compiled ? (exceptionMessage ?? "Failed") : (compileProblem ?? "Didn't compile")
    }
}

/// Builds and reads the SOAP messages for the Apex API's executeAnonymous call. The REST API can
/// also run anonymous Apex, but only the SOAP call returns the debug log with the result.
nonisolated enum AnonymousApex {
    static let apexNamespace = "http://soap.sforce.com/2006/08/apex"

    static func request(code: String, sessionID: String, logLevels: [ApexLogCategory: ApexLogLevel]) -> String {
        var categories = ""
        for category in ApexLogCategory.allCases {
            let level = logLevels[category] ?? category.defaultLevel
            if level != .none {
                categories += "<categories><category>\(category.rawValue)</category><level>\(level.rawValue)</level></categories>"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="\(SOAP.envelopeNamespace)" xmlns="\(apexNamespace)">\
        <s:Header>\
        <SessionHeader><sessionId>\(SOAP.escaped(sessionID))</sessionId></SessionHeader>\
        <DebuggingHeader>\(categories)</DebuggingHeader>\
        </s:Header>\
        <s:Body><executeAnonymous><String>\(SOAP.escaped(code))</String></executeAnonymous></s:Body>\
        </s:Envelope>
        """
    }

    /// Reads an executeAnonymous response.
    static func execution(from root: XMLElement, code: String) throws -> ApexExecution {
        guard let result = root.descendant("executeAnonymousResponse")?.descendant("result") else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Unexpected response to executeAnonymous.")
        }
        func text(_ name: String) -> String? {
            guard let e = result.child(name), e.attribute(forName: "xsi:nil")?.stringValue != "true" else { return nil }
            return e.stringValue
        }
        return ApexExecution(
            code: code,
            date: Date(),
            compiled: text("compiled") == "true",
            success: text("success") == "true",
            line: text("line").flatMap { Int($0) } ?? -1,
            column: text("column").flatMap { Int($0) } ?? -1,
            compileProblem: text("compileProblem"),
            exceptionMessage: text("exceptionMessage"),
            exceptionStackTrace: text("exceptionStackTrace"),
            debugLog: root.descendant("DebuggingInfo")?.descendant("debugLog")?.stringValue ?? ""
        )
    }
}

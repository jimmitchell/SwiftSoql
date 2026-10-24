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
    static let soapNamespace = "http://schemas.xmlsoap.org/soap/envelope/"

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
        <s:Envelope xmlns:s="\(soapNamespace)" xmlns="\(apexNamespace)">\
        <s:Header>\
        <SessionHeader><sessionId>\(escaped(sessionID))</sessionId></SessionHeader>\
        <DebuggingHeader>\(categories)</DebuggingHeader>\
        </s:Header>\
        <s:Body><executeAnonymous><String>\(escaped(code))</String></executeAnonymous></s:Body>\
        </s:Envelope>
        """
    }

    /// Reads an executeAnonymous response, throwing the SOAP fault if there is one.
    static func execution(fromResponse data: Data, code: String, status: Int) throws -> ApexExecution {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data)
        } catch {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            throw SalesforceError(statusCode: status, errorCode: "HTTP \(status)", message: body.isEmpty ? "HTTP \(status)" : body)
        }
        guard let root = doc.rootElement() else {
            throw SalesforceError(statusCode: status, errorCode: "", message: "Salesforce returned an empty response.")
        }
        if let fault = root.descendant("Fault") {
            let code = fault.descendant("faultcode")?.stringValue ?? ""
            // Fault codes look like "sf:INVALID_SESSION_ID".
            let errorCode = code.split(separator: ":").last.map(String.init) ?? code
            throw SalesforceError(statusCode: status, errorCode: errorCode, message: fault.descendant("faultstring")?.stringValue ?? code)
        }
        guard let result = root.descendant("executeAnonymousResponse")?.descendant("result") else {
            throw SalesforceError(statusCode: status, errorCode: "", message: "Unexpected response to executeAnonymous.")
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

    private static func escaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // Keep carriage returns, which XML parsers would otherwise turn into newlines.
            case "\r": out += "&#13;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

private nonisolated extension XMLElement {
    func child(_ localName: String) -> XMLElement? {
        children?.lazy.compactMap { $0 as? XMLElement }.first { $0.localName == localName }
    }

    /// The first element below this one with the given name, ignoring namespaces.
    func descendant(_ localName: String) -> XMLElement? {
        for case let element as XMLElement in children ?? [] {
            if element.localName == localName { return element }
            if let found = element.descendant(localName) { return found }
        }
        return nil
    }
}

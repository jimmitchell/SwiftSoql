import Foundation

/// Helpers for the SOAP calls that have no REST equivalent: running anonymous Apex with its debug
/// log, and undeleting records.
nonisolated enum SOAP {
    static let envelopeNamespace = "http://schemas.xmlsoap.org/soap/envelope/"
    static let partnerNamespace = "urn:partner.soap.sforce.com"

    /// Parses a SOAP response and returns its root element, throwing the SOAP fault if there is one.
    static func root(of data: Data, status: Int) throws -> XMLElement {
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
        return root
    }

    static func escaped(_ s: String) -> String {
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

    /// An undelete request for the partner API.
    static func undeleteRequest(ids: [String], sessionID: String) -> String {
        let idElements = ids.map { "<ids>\(escaped($0))</ids>" }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="\(envelopeNamespace)" xmlns="\(partnerNamespace)">\
        <s:Header><SessionHeader><sessionId>\(escaped(sessionID))</sessionId></SessionHeader></s:Header>\
        <s:Body><undelete>\(idElements)</undelete></s:Body>\
        </s:Envelope>
        """
    }

    /// The results of an undelete, in the same order as the request's ids.
    static func undeleteResults(from root: XMLElement) -> [SaveResult] {
        guard let response = root.descendant("undeleteResponse") else { return [] }
        return response.childElements("result").map { result in
            let errors = result.childElements("errors").map { e in
                let message = e.child("message")?.stringValue ?? ""
                guard let code = e.child("statusCode")?.stringValue, !code.isEmpty else { return message }
                return "\(code): \(message)"
            }
            return SaveResult(success: result.child("success")?.stringValue == "true", message: errors.joined(separator: "\n"))
        }
    }
}

nonisolated extension XMLElement {
    func child(_ localName: String) -> XMLElement? {
        children?.lazy.compactMap { $0 as? XMLElement }.first { $0.localName == localName }
    }

    func childElements(_ localName: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == localName }
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

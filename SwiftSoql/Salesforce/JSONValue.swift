import Foundation

/// A parsed JSON value that keeps object keys in document order.
///
/// Salesforce returns query fields in the order they appear in the SELECT, and the
/// results table relies on that order. Foundation's JSON decoders don't preserve it.
nonisolated enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Numbers keep their source text so values display exactly as Salesforce sent them.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var int: Int? {
        if case .number(let n) = self { return Int(n) ?? Double(n).map { Int($0) } }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var object: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Text for displaying a scalar value; nil for null, arrays and objects.
    var displayText: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null, .array, .object: nil
        }
    }
}

/// A JSON object whose keys are kept in document order.
nonisolated struct JSONObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    init() {}

    init(minimumCapacity: Int) {
        keys.reserveCapacity(minimumCapacity)
        storage.reserveCapacity(minimumCapacity)
    }

    subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if storage.updateValue(newValue ?? .null, forKey: key) == nil {
                keys.append(key)
            }
        }
    }

    var count: Int { keys.count }
}

nonisolated struct JSONParseError: LocalizedError {
    let offset: Int
    let reason: String
    var errorDescription: String? { "Invalid JSON at byte \(offset): \(reason)" }
}

nonisolated extension JSONValue {
    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("unexpected trailing content") }
        return value
    }

    /// The value as JSON text, with object keys in order and numbers as they were given.
    var serialized: String {
        switch self {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n
        case .string(let s): Self.quoted(s)
        case .array(let a): "[" + a.map(\.serialized).joined(separator: ",") + "]"
        case .object(let o): "{" + o.keys.map { Self.quoted($0) + ":" + (o[$0] ?? .null).serialized }.joined(separator: ",") + "}"
        }
    }

    /// The value as JSON text indented by two spaces per level, for reading.
    func prettyPrinted(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .array(let a) where !a.isEmpty:
            return "[\n" + a.map { inner + $0.prettyPrinted(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let o) where !o.keys.isEmpty:
            return "{\n" + o.keys.map { inner + Self.quoted($0) + ": " + (o[$0] ?? .null).prettyPrinted(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
        default:
            return serialized
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

private nonisolated struct JSONParser {
    let bytes: [UInt8]
    var pos = 0
    /// Object keys seen so far. Records and describes repeat the same keys many times, so sharing
    /// one copy of each saves memory for keys too long to be stored inline in a String.
    private var keys: Set<String> = []

    mutating func interned(_ key: String) -> String {
        if let existing = keys.firstIndex(of: key) { return keys[existing] }
        keys.insert(key)
        return key
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var atEnd: Bool { pos >= bytes.count }

    func error(_ reason: String) -> JSONParseError {
        JSONParseError(offset: pos, reason: reason)
    }

    mutating func skipWhitespace() {
        while pos < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[pos]) {
            pos += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard !atEnd else { throw error("unexpected end of input") }
        switch bytes[pos] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard pos < bytes.count, bytes[pos] == b else { throw error("expected \(literal)") }
            pos += 1
        }
    }

    mutating func parseObject() throws -> JSONObject {
        pos += 1
        var obj = JSONObject()
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "}") {
            pos += 1
            return obj
        }
        while true {
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = interned(try parseString())
            skipWhitespace()
            guard pos < bytes.count, bytes[pos] == UInt8(ascii: ":") else { throw error("expected ':'") }
            pos += 1
            skipWhitespace()
            obj[key] = try parseValue()
            skipWhitespace()
            guard pos < bytes.count else { throw error("unterminated object") }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
            } else if bytes[pos] == UInt8(ascii: "}") {
                pos += 1
                return obj
            } else {
                throw error("expected ',' or '}'")
            }
        }
    }

    mutating func parseArray() throws -> [JSONValue] {
        pos += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if pos < bytes.count, bytes[pos] == UInt8(ascii: "]") {
            pos += 1
            return items
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard pos < bytes.count else { throw error("unterminated array") }
            if bytes[pos] == UInt8(ascii: ",") {
                pos += 1
            } else if bytes[pos] == UInt8(ascii: "]") {
                pos += 1
                return items
            } else {
                throw error("expected ',' or ']'")
            }
        }
    }

    mutating func parseString() throws -> String {
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            switch b {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard pos < bytes.count else { throw error("unterminated escape") }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    // Combine a surrogate pair only when the next escape is a valid low surrogate;
                    // a lone surrogate becomes U+FFFD and any following escape is parsed on its own.
                    if (0xD800...0xDBFF).contains(scalar),
                       pos + 5 < bytes.count, bytes[pos] == UInt8(ascii: "\\"), bytes[pos + 1] == UInt8(ascii: "u") {
                        let saved = pos
                        pos += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            pos = saved
                        }
                    }
                    out.append(contentsOf: String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
                default:
                    throw error("invalid escape")
                }
            default:
                out.append(b)
            }
        }
        throw error("unterminated string")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= bytes.count,
              let v = UInt32(String(decoding: bytes[pos..<pos + 4], as: UTF8.self), radix: 16)
        else { throw error("invalid unicode escape") }
        pos += 4
        return v
    }

    mutating func parseNumber() throws -> String {
        let start = pos
        while pos < bytes.count, "+-0123456789.eE".utf8.contains(bytes[pos]) {
            pos += 1
        }
        guard pos > start else { throw error("unexpected character") }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }
}

import Foundation
import Testing
@testable import SwiftSoql

/// Replays SoqlXplorer's SoqlTokenizerTests golden files against the SOQL parser and analyzer.
/// The golden files and describes.xml in Golden are from SoqlXplorer (MIT license).
struct SoqlGoldenTests {
    nonisolated static let files = ["funcs", "select_exprs", "using_scope", "order_by", "where", "literals", "group_by", "with", "limit_offset", "sosl"]

    @Test(arguments: files)
    func goldenFile(_ name: String) throws {
        var golden = try String(contentsOf: try Self.resource(name, "txt"), encoding: .utf8)
        // Known difference: SoqlXplorer compares path steps by pointer, and short strings are tagged
        // pointers, so it misses that the first "name" in account.name.name is a field. We report it.
        golden = golden.replacingOccurrences(
            of: "      15-4   : Field           name                           completions 31 \n      20-4   : Field           name                           completions 5 \n",
            with: "      19-1   : Error           .                              completions 0 name is a field not a relationship, it should be the last item in the field path\n")

        let analyzer = SoqlAnalyzer()
        analyzer.describer = try Self.describer()
        let goldenLines = golden.split(separator: "\n", omittingEmptySubsequences: false)
        var queries: [String] = []
        var atStart = true
        for line in goldenLines {
            if atStart && !line.isEmpty { queries.append(String(line)) }
            atStart = line.isEmpty
        }
        #expect(!queries.isEmpty)
        for query in queries {
            let expected = Self.expectedOutput(for: query, in: goldenLines)
            let actual = analyzer.parseAndResolve(query).description
            #expect(actual == expected, "\(name).txt: \(query)")
        }
    }

    /// The golden lines after a query, up to the blank line that ends its entry.
    private static func expectedOutput(for query: String, in lines: [Substring]) -> String {
        guard let start = lines.firstIndex(where: { $0 == query }) else { return "" }
        var out = ""
        for line in lines[(start + 1)...] {
            out += line + "\n"
            if line.isEmpty { break }
        }
        // parseAndResolve's description ends with a newline, and the entry ends with a blank line.
        return String(out.dropLast())
    }

    static func resource(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: ext), "missing \(name).\(ext)")
    }

    private static var cachedDescriber: TestDescriber?

    static func describer() throws -> TestDescriber {
        if let cachedDescriber { return cachedDescriber }
        let xml = try XMLDocument(contentsOf: try resource("describes", "xml"))
        let describes = try xml.nodes(forXPath: "/describes/describe").compactMap { $0 as? XMLElement }
            .map { SoqlSchemaObject(SObjectDescribe(json: jsonObject(from: $0))) }
        let describer = TestDescriber(describes)
        cachedDescriber = describer
        return describer
    }

    /// SoqlXplorer's describes.xml is SOAP describe output; this turns it into REST-style JSON.
    private static func jsonObject(from element: XMLElement) -> JSONObject {
        var obj = JSONObject()
        let arrayKeys: Set<String> = ["fields", "childRelationships", "referenceTo"]
        for child in element.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            let name = child.name ?? ""
            let hasElementChildren = child.children?.contains { $0 is XMLElement } ?? false
            let value: JSONValue
            if hasElementChildren {
                value = .object(jsonObject(from: child))
            } else {
                let text = child.stringValue ?? ""
                value = text == "true" ? .bool(true) : text == "false" ? .bool(false) : .string(text)
            }
            if arrayKeys.contains(name) {
                var arr = obj[name]?.array ?? []
                arr.append(value)
                obj[name] = .array(arr)
            } else {
                obj[name] = value
            }
        }
        return obj
    }
}

final class BundleToken {}

final class TestDescriber: SoqlDescriber {
    let objects: [SoqlSchemaObject]
    init(_ objects: [SoqlSchemaObject]) { self.objects = objects }
    func schemaObject(_ sobject: String) -> SoqlSchemaObject? {
        objects.first { $0.name.caseInsensitiveCompare(sobject) == .orderedSame }
    }
    func knownSObject(_ sobject: String) -> Bool {
        // Simulates Case being valid, but not yet described.
        sobject.caseInsensitiveCompare("Case") == .orderedSame || schemaObject(sobject) != nil
    }
    var allQueryableSObjects: [String] { objects.map(\.name) }
}

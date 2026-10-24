import Foundation

// Replays SoqlXplorer's SoqlTokenizerTests golden files against the Swift SOQL parser and analyzer.
// The golden files and describes.xml are from SoqlXplorer (MIT license). Run with run.sh.
let testsDir = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

func jsonObject(from element: XMLElement) -> JSONObject {
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

let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: "\(testsDir)/describes.xml"))
let describes = (try xml.nodes(forXPath: "/describes/describe")).compactMap { $0 as? XMLElement }
    .map { SoqlSchemaObject(SObjectDescribe(json: jsonObject(from: $0))) }
let describer = TestDescriber(describes)

var failures = 0
for file in ["funcs.txt", "select_exprs.txt", "using_scope.txt", "order_by.txt", "where.txt", "literals.txt", "group_by.txt", "with.txt", "limit_offset.txt", "sosl.txt"] {
    var golden = try String(contentsOfFile: "\(testsDir)/\(file)", encoding: .utf8)
    // Known difference: SoqlXplorer compares path steps by pointer, and short strings are tagged
    // pointers, so it misses that the first "name" in account.name.name is a field. We report it.
    golden = golden.replacingOccurrences(
        of: "      15-4   : Field           name                           completions 31 \n      20-4   : Field           name                           completions 5 \n",
        with: "      19-1   : Error           .                              completions 0 name is a field not a relationship, it should be the last item in the field path\n")
    var queries: [String] = []
    var atStart = true
    for line in golden.split(separator: "\n", omittingEmptySubsequences: false) {
        if atStart && !line.isEmpty { queries.append(String(line)) }
        atStart = line.isEmpty
    }
    let analyzer = SoqlAnalyzer()
    analyzer.describer = describer
    var out = ""
    for q in queries {
        out += q + "\n"
        out += analyzer.parseAndResolve(q).description
        out += "\n"
    }
    try out.write(toFile: "\(outDir)/\(file)", atomically: true, encoding: .utf8)
    if out != golden { print("  diff \(testsDir)/\(file) \(outDir)/\(file)") }
    let ok = out == golden
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(file) (\(queries.count) queries)")
}
exit(failures == 0 ? 0 : 1)

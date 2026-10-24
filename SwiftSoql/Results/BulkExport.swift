import Foundation

/// Which queries the Bulk API can run. Bulk API 2.0 query jobs don't support subqueries, GROUP BY,
/// aggregate functions, TYPEOF, OFFSET or FOR clauses; queries with those are exported by paging
/// through the results instead.
nonisolated enum BulkExport {
    static func canRun(_ soql: String) -> Bool {
        guard let lexemes = SoqlFormatter.lex(soql), let nodes = SoqlFormatter.tree(lexemes),
              case .lexeme(.word(let first))? = nodes.first, first.lowercased() == "select" else { return false }
        return supported(nodes)
    }

    private static let aggregates: Set<String> = ["count", "count_distinct", "sum", "avg", "min", "max"]

    private static func supported(_ nodes: [SoqlFormatter.Node]) -> Bool {
        for (i, node) in nodes.enumerated() {
            switch node {
            case .group(let children):
                if case .lexeme(.word(let w))? = children.first, w.lowercased() == "select" { return false }
                if !supported(children) { return false }
            case .lexeme(.word(let w)):
                let word = w.lowercased()
                if ["typeof", "offset", "for"].contains(word) { return false }
                let next: String? = if i + 1 < nodes.count, case .lexeme(.word(let n)) = nodes[i + 1] { n.lowercased() } else { nil }
                if word == "group", next == "by" { return false }
                if aggregates.contains(word), i + 1 < nodes.count, case .group = nodes[i + 1] { return false }
            default:
                break
            }
        }
        return true
    }
}

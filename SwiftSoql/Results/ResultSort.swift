import Foundation

/// Sorts result rows by one column: numbers as numbers, text in natural order ("Item 2" before
/// "Item 10"), subqueries by their row count, and empty values last either way. Rows that tie stay
/// in the order they were loaded. An empty column name sorts by that original order.
nonisolated struct ResultSortComparator: SortComparator, Hashable, Sendable {
    let column: String
    var order: SortOrder = .forward

    init(column: String, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    func compare(_ lhs: ResultRow, _ rhs: ResultRow) -> ComparisonResult {
        let path = column.split(separator: ".")
        return compare(Self.sortValue(lhs.record.value(atPath: path)), lhs.id, Self.sortValue(rhs.record.value(atPath: path)), rhs.id)
    }

    /// Sorts rows by the first comparator, reading each row's value once rather than on every
    /// comparison, which matters for related fields in tens of thousands of rows.
    static func sorted(_ rows: [ResultRow], by order: [ResultSortComparator]) -> [ResultRow] {
        let comparator = order.first ?? ResultSortComparator(column: "")
        let path = comparator.column.split(separator: ".")
        let keyed = rows.map { row in (row, comparator.column.isEmpty ? nil : sortValue(row.record.value(atPath: path))) }
        return keyed.sorted { a, b in
            comparator.compare(a.1, a.0.id, b.1, b.0.id) == .orderedAscending
        }.map(\.0)
    }

    private func compare(_ a: SortValue?, _ lhsID: Int, _ b: SortValue?, _ rhsID: Int) -> ComparisonResult {
        if !column.isEmpty {
            switch (a, b) {
            case (nil, nil): break
            case (nil, _): return .orderedDescending
            case (_, nil): return .orderedAscending
            case let (a?, b?):
                let result = a.compare(b)
                if result != .orderedSame {
                    return order == .forward ? result : result.reversed
                }
            }
        }
        let byLoadOrder: ComparisonResult = lhsID < rhsID ? .orderedAscending : lhsID > rhsID ? .orderedDescending : .orderedSame
        return column.isEmpty && order == .reverse ? byLoadOrder.reversed : byLoadOrder
    }

    private enum SortValue {
        case number(Double)
        case text(String)

        func compare(_ other: SortValue) -> ComparisonResult {
            switch (self, other) {
            case let (.number(a), .number(b)):
                a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case let (.text(a), .text(b)):
                a.localizedStandardCompare(b)
            // Numbers before text, if a column somehow has both.
            case (.number, .text): .orderedAscending
            case (.text, .number): .orderedDescending
            }
        }
    }

    private static func sortValue(_ value: JSONValue?) -> SortValue? {
        guard let value else { return nil }
        if let child = QueryResult(nested: value) {
            return .number(Double(child.totalSize))
        }
        switch value {
        case .number(let n): return Double(n).map(SortValue.number) ?? .text(n)
        case .bool(let b): return .number(b ? 1 : 0)
        case .string(let s): return s.isEmpty ? nil : .text(s)
        case .null, .array, .object: return nil
        }
    }
}

nonisolated extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}

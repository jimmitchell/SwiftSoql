import Foundation

/// Works out the table columns for a set of query results.
///
/// Related records become dotted columns (`Account.Owner.Name`), compound fields are split
/// into their parts (`BillingAddress.city`), and subquery results get a single column. Ported
/// from SoqlXplorer's QueryColumns: a relationship can be null in some rows, or (with TYPEOF)
/// a different SObject type in others, so rows are scanned until each column is resolved.
nonisolated enum QueryColumns {
    static func names(for records: [JSONObject], isSearchResult: Bool) -> [String] {
        let root = Column(name: "")
        var processedTypes = Set<String>()
        var path: [String] = []
        for record in records {
            // SOSL results mix types, so collect columns for the first row of each type.
            let type = record.sobjectType ?? ""
            if processedTypes.contains(type) { continue }
            path.removeAll()
            addColumns(from: record, prefix: "", path: &path, to: root, startingAt: 0, records: records)
            if !isSearchResult { break }
            processedTypes.insert(type)
        }
        return root.allNames()
    }

    private final class Column {
        let name: String
        var children: [Column] = []
        var childrenByName: [String: Column] = [:]
        var hasSeenValue = false

        init(name: String) {
            self.name = name
        }

        func child(named name: String) -> Column {
            if let existing = childrenByName[name] { return existing }
            let c = Column(name: name)
            children.append(c)
            childrenByName[name] = c
            return c
        }

        func allNames() -> [String] {
            var names: [String] = []
            collectNames(into: &names)
            return names
        }

        private func collectNames(into names: inout [String]) {
            if !name.isEmpty && children.isEmpty {
                names.append(name)
            }
            for c in children {
                c.collectNames(into: &names)
            }
        }
    }

    private static func addColumns(from record: JSONObject, prefix: String, path: inout [String], to parent: Column, startingAt startRow: Int, records: [JSONObject]) {
        for field in record.fieldNames {
            let fullName = prefix.isEmpty ? field : "\(prefix).\(field)"
            let column = parent.child(named: fullName)
            if column.children.isEmpty && column.hasSeenValue { continue }

            path.append(field)
            defer { path.removeLast() }
            // Check the rows for this column until one tells us what it holds.
            for rowIndex in startRow..<records.count {
                guard let value = records[rowIndex].value(atPath: path), !value.isNull else { continue }
                if QueryResult(nested: value) != nil {
                    column.hasSeenValue = true
                } else if let related = value.object, related.sobjectType != nil {
                    // Look at all remaining rows: with TYPEOF, related records can be of different types.
                    var types = Set<String>()
                    for nestedIndex in rowIndex..<records.count {
                        if let nested = records[nestedIndex].value(atPath: path)?.object,
                           let type = nested.sobjectType, types.insert(type).inserted {
                            addColumns(from: nested, prefix: fullName, path: &path, to: column, startingAt: nestedIndex, records: records)
                        }
                    }
                } else if let compound = value.object {
                    // An address or geolocation value.
                    if column.children.isEmpty {
                        for key in compound.keys {
                            column.child(named: "\(fullName).\(key)").hasSeenValue = true
                        }
                    }
                    column.hasSeenValue = true
                } else {
                    column.hasSeenValue = true
                }
                break
            }
        }
    }
}

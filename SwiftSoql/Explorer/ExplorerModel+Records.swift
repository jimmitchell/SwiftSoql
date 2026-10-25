import Foundation

/// Opening, editing, deleting and restoring the records in query results.
extension ExplorerModel {
    /// The record's page in Salesforce. The browser's own Salesforce login is used.
    func recordURL(_ id: String) -> URL? {
        session?.instanceURL.appending(path: id)
    }

    /// The related records a result row refers to, as (column, record Id, SObject type).
    func relatedRecords(in row: ResultRow, columns: [String]) -> [(column: String, id: String, type: String)] {
        columns.compactMap { column in
            guard column != "Id", let id = row.record.value(atPath: column)?.string, id != row.recordID,
                  let type = sobjectType(ofRecordID: id) else { return nil }
            return (column, id, type)
        }
    }

    /// The field a results cell shows, if it can be edited: a top-level field the user may
    /// update, once the row's SObject type has been described.
    func editableField(_ column: String, of row: ResultRow) -> FieldDescribe? {
        guard column != "Id", row.recordID != nil, let type = row.record.sobjectType,
              let field = dataSchema.cachedDescribe(type)?.field(exactly: column), field.updateable else { return nil }
        return field
    }

    /// Saves text typed into a results cell to the record, and updates the results to show the
    /// value Salesforce saved. Returns whether the change was saved.
    @discardableResult
    func saveEdit(_ text: String, field: String, row: ResultRow) async -> Bool {
        guard let client, let id = row.recordID, let type = row.record.sobjectType else { return false }
        if (row.record[field]?.displayText ?? "") == text { return true }
        let tab = currentTab
        isSaving = true
        defer { isSaving = false }
        tab.statusText = "Updating \(field) on \(id)…"
        do {
            guard let fieldDescribe = try await dataSchema.describe(type).field(named: field) else {
                throw InvalidFieldValue(errorDescription: "\(type) has no field named \(field).")
            }
            let value = try fieldDescribe.value(fromText: text)
            var fields = JSONObject()
            fields[fieldDescribe.name] = value
            try await client.update(type, id: id, fields: fields)
            // Salesforce can store something else, e.g. a trigger can change the value or turn
            // a Task's reminder back off, so show what it kept.
            let saved = (try? await client.query("SELECT \(fieldDescribe.name) FROM \(type) WHERE Id = '\(id)'"))?
                .records.first?[fieldDescribe.name] ?? value
            // The record can be in other tabs' results too.
            for tab in tabs {
                tab.results?.applyUpdate(recordID: id, field: field, value: saved)
                tab.childResults?.applyUpdate(recordID: id, field: field, value: saved)
            }
            tab.statusText = saved == value ? "Updated \(field) on \(id)" : "Updated \(field) on \(id); Salesforce saved \(saved.displayText ?? "an empty value")"
            await refreshAPIUsage()
            return true
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Unable to update \(field)", error)
            await refreshAPIUsage()
            return false
        }
    }

    /// Restores the checked records from the Recycle Bin. Restored rows are unchecked and show
    /// IsDeleted as false if it was queried; rows that fail stay checked and show why.
    func restoreCheckedRows() async {
        guard let client else { return }
        await saveCheckedRows(doing: "Restoring", done: "Restored", with: { try await client.undelete(ids: $0) }) { tab, restored in
            for row in restored {
                tab.results?.checkedRows.remove(row.id)
                if let id = row.recordID {
                    tab.results?.applyUpdate(recordID: id, field: "IsDeleted", value: .bool(false))
                }
            }
        }
    }

    /// Deletes the records checked in the results. Rows that fail stay checked and show why.
    func deleteCheckedRows() async {
        guard let client else { return }
        await saveCheckedRows(doing: "Deleting", done: "Deleted", with: { try await client.delete(ids: $0) }) { tab, deleted in
            let ids = Set(deleted.map(\.id))
            tab.results?.removeRows(ids)
            if let parent = tab.childResults?.parentRowID, ids.contains(parent) {
                tab.childResults = nil
            }
        }
    }

    /// Sends the current tab's checked records to `save` in batches of 200, the most Salesforce
    /// takes at once, then passes the rows that succeeded to `apply`. Rows that fail show why.
    private func saveCheckedRows(doing verb: String, done pastTense: String,
                                 with save: ([String]) async throws -> [SaveResult],
                                 apply: (QueryTab, [ResultRow]) -> Void) async {
        let tab = currentTab
        guard let checked = tab.results?.checkedRows, !checked.isEmpty, !isSaving else { return }
        let rows = (tab.results?.rows ?? []).filter { checked.contains($0.id) && $0.recordID != nil }
        isSaving = true
        defer { isSaving = false }
        var succeeded: [ResultRow] = []
        var errors: [ResultRow.ID: String] = [:]
        for start in stride(from: 0, to: rows.count, by: 200) {
            let batch = rows[start..<min(start + 200, rows.count)]
            tab.statusText = "\(verb) \(start + batch.count) of \(rows.count) rows…"
            do {
                let saveResults = try await save(batch.compactMap(\.recordID))
                for (row, saveResult) in zip(batch, saveResults) {
                    if saveResult.success {
                        succeeded.append(row)
                    } else {
                        errors[row.id] = saveResult.message
                    }
                }
            } catch {
                for row in rows[start...] {
                    errors[row.id] = error.localizedDescription
                }
                break
            }
        }
        tab.results?.rowErrors = errors
        apply(tab, succeeded)
        tab.statusText = "\(pastTense) \(succeeded.count) \(succeeded.count == 1 ? "row" : "rows")" + (errors.isEmpty ? "" : ", \(errors.count) failed")
        await refreshAPIUsage()
    }
}

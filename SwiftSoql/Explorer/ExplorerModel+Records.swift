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

    /// The fields of results that can be edited, by SObject type and then column: top-level
    /// fields the user may update, once their SObject type has been described. Worked out once
    /// per table rather than per cell, so cells don't each watch the schema.
    func editableFields(in results: ResultSet) -> [String: [String: FieldDescribe]] {
        guard !isLocked, results.isEditable else { return [:] }
        var fields: [String: [String: FieldDescribe]] = [:]
        for type in results.sobjectTypes {
            guard let describe = dataSchema.cachedDescribe(type) else { continue }
            for column in results.columns where column != "Id" {
                if let field = describe.field(exactly: column), field.updateable {
                    fields[type, default: [:]][column] = field
                }
            }
        }
        return fields
    }

    /// Saves text typed into a results cell to the record, and updates the results to show the
    /// value Salesforce saved. Returns whether the change was saved.
    @discardableResult
    func saveEdit(_ text: String, field: String, row: ResultRow) async -> Bool {
        guard let id = row.recordID, let type = row.record.sobjectType else { return false }
        if (row.record[field]?.displayText ?? "") == text { return true }
        return await saveField(text, field: field, sobject: type, id: id) != nil
    }

    /// Saves text for one field of a record, and updates every tab's results to show the value
    /// Salesforce saved. Returns that value, or nil if the change couldn't be saved.
    func saveField(_ text: String, field: String, sobject type: String, id: String) async -> JSONValue? {
        guard let client, canChangeData else { return nil }
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
            return saved
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Unable to update \(field)", error)
            await refreshAPIUsage()
            return nil
        }
    }

    // MARK: Record inspector

    /// Shows a results row's record in the inspector's Record tab, replacing any records
    /// followed there.
    func inspectRecord(in row: ResultRow, api: SalesforceAPI) {
        guard let id = row.recordID, let type = row.record.sobjectType else { return }
        let record = RecordReference(sobject: type, id: id, api: api)
        if inspectedRecords != [record] {
            inspectedRecords = [record]
        }
    }

    /// Every field of a record, and its SObject's describe.
    func fetchRecord(_ record: RecordReference) async throws -> (describe: SObjectDescribe, fields: JSONObject) {
        guard let client else { throw CancellationError() }
        let schema = record.api == .tooling ? toolingSchema : dataSchema
        if record.api == .tooling, !schema.isLoaded {
            try await schema.load(using: client)
        }
        let describe = try await schema.describe(record.sobject)
        let fields = try await client.record(describe.name, id: record.id, api: record.api)
        await refreshAPIUsage()
        return (describe, fields)
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
        guard canChangeData, let checked = tab.results?.checkedRows, !checked.isEmpty, !isSaving else { return }
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

// MARK: - Creating records

extension ExplorerModel {
    /// Data API SObjects the user can create, for the new record form.
    var createableSObjects: [String] {
        dataSchema.sobjects.filter(\.createable).map(\.name)
    }

    /// Opens the form for a new record of the results' SObject, or the query's, if there is one.
    func newRecord() {
        guard canChangeData else { return }
        let tab = currentTab
        var sobject = ""
        if let results = tab.results, results.api == .data, results.sobjectTypes.count == 1, let type = results.sobjectTypes.first {
            sobject = type
        } else if tab.api == .data, let type = dataSchema.sobjects.first(where: { $0.name.caseInsensitiveCompare(tab.title) == .orderedSame }) {
            sobject = type.name
        }
        recordDraft = RecordDraft(sobject: createableSObjects.contains(sobject) ? sobject : "")
    }

    /// Opens the form for a copy of a row's record, with every field a new record can set.
    func cloneRecord(_ row: ResultRow) async {
        guard let client, canChangeData, let id = row.recordID, let type = row.record.sobjectType else { return }
        currentTab.statusText = "Reading \(id)…"
        do {
            let describe = try await dataSchema.describe(type)
            let record = try await client.record(type, id: id)
            currentTab.statusText = ""
            recordDraft = RecordDraft(cloning: record, id: id, describe: describe)
        } catch {
            currentTab.statusText = ""
            self.error = DisplayedError("Unable to clone \(id)", error)
        }
        await refreshAPIUsage()
    }

    /// Creates the draft's record and, when the current tab's results are of the same SObject,
    /// adds it as their first row. Throws if it can't be created, so the form can show why.
    func createRecord(_ draft: RecordDraft) async throws {
        guard let client, canChangeData else { return }
        let tab = currentTab
        isSaving = true
        defer { isSaving = false }
        defer { Task { await refreshAPIUsage() } }
        let describe = try await dataSchema.describe(draft.sobject)
        let id = try await client.create(describe.name, fields: draft.fieldValues(describe))
        tab.statusText = "Created \(describe.name) \(id)"
        guard let results = tab.results, results.api == .data, !results.isSearchResult,
              results.sobjectTypes == [describe.name] else { return }
        // Read it back with the results' columns, leaving out subqueries.
        let subqueries = Set(describe.childRelationships.compactMap { $0.relationshipName?.lowercased() })
        let columns = results.columns.filter { !subqueries.contains($0.lowercased()) }
        guard !columns.isEmpty,
              let record = try? await client.query("SELECT \(columns.joined(separator: ", ")) FROM \(describe.name) WHERE Id = '\(id)'").records.first else {
            tab.statusText += "; run the query again to see it"
            return
        }
        tab.results?.insertFirst(record)
    }
}

// MARK: - Importing

extension ExplorerModel {
    /// Data API SObjects whose records can be created or updated, for imports.
    var importableSObjects: [String] {
        dataSchema.sobjects.filter { $0.createable || $0.updateable }.map(\.name)
    }

    /// Reads a CSV file and opens the import sheet for it. The SObject starts as the one the
    /// file is named after, if any, or the current results'.
    func beginImport(of url: URL) async {
        guard let client, canChangeData else { return }
        do {
            let file = try await Task.detached {
                try ImportFile(name: url.lastPathComponent, text: String(contentsOf: url, encoding: .utf8))
            }.value
            let names = importableSObjects
            // "Account.csv" or "accounts.csv".
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let candidates = [stem, stem.hasSuffix("s") ? String(stem.dropLast()) : stem]
            var sobject = names.first { candidates.contains($0.lowercased()) }
            if sobject == nil, let results, results.api == .data, results.sobjectTypes.count == 1 {
                sobject = results.sobjectTypes.first.flatMap { type in names.first { $0 == type } }
            }
            let csvImport = CSVImport(file: file, sobject: sobject ?? "", client: client, schema: dataSchema)
            csvImport.didCallAPI = { [weak self] in await self?.refreshAPIUsage() }
            self.csvImport = csvImport
        } catch {
            self.error = DisplayedError("Unable to read \(url.lastPathComponent)", error)
        }
    }
}

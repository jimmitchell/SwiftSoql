import Foundation
import Observation

/// An error to show in an alert.
struct DisplayedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(_ title: String, _ error: Error) {
        self.title = title
        message = error.localizedDescription
    }
}

/// Something selected in the schema sidebar.
enum SchemaItem: Hashable {
    case sobject(String)
    case field(sobject: String, field: String)

    var sobjectName: String {
        switch self {
        case .sobject(let name), .field(let name, _): name
        }
    }
}

/// What the main area of an explorer window shows.
enum Workspace: String, CaseIterable, Identifiable {
    case query = "Query"
    case apex = "Apex"
    case schema = "Schema"

    var id: String { rawValue }
}

/// The state of one explorer window, which is connected to at most one org.
@Observable
final class ExplorerModel {
    private(set) var client: SalesforceClient?
    private(set) var session: OrgSession?
    private(set) var sobjects: [GlobalSObject] = []
    private(set) var isConnecting = false
    var statusText = ""
    var apiUsage: String?
    var error: DisplayedError?

    // Schema browser
    var schemaFilter = ""
    var schemaSelection: SchemaItem?
    var expandedSObjects: Set<String> = []
    private var describes: [String: SObjectDescribe] = [:]
    private var describesInFlight: [String: Task<SObjectDescribe, Error>] = [:]
    /// How far describing every SObject in the background has got, while it runs.
    private(set) var backgroundDescribeProgress: (done: Int, total: Int)?
    @ObservationIgnored private var backgroundDescribes: Task<Void, Never>?

    // Query
    var soql = UserDefaults.standard.string(forKey: "soql") ?? "SELECT Id, Name FROM Account"
    private(set) var isQuerying = false
    /// True while an edit or delete is being saved.
    private(set) var isSaving = false
    /// Set to ask the user to confirm deleting the checked rows.
    var isConfirmingDelete = false
    var results: ResultSet?
    /// A subquery result opened from a cell of `results`.
    var childResults: ResultSet?
    /// Queries run in this org, newest first.
    private(set) var recentQueries: [String] = []
    /// The fields picked by double-clicking in the schema sidebar, for building a query.
    private var pickedFields: (sobject: String, fields: [String])?

    // SOQL editor
    /// Changes when a describe the SOQL editor asked for arrives, so it can recheck the query.
    private(set) var schemaGeneration = 0
    @ObservationIgnored private var schemaObjects: [String: SoqlSchemaObject] = [:]
    @ObservationIgnored private var pendingSchemaObjects: Set<String> = []
    @ObservationIgnored private var sobjectNames: Set<String> = []

    // Files
    /// Set by the File menu to show the open or save panel.
    var isOpeningFile = false
    var isSavingFile = false

    // Anonymous Apex
    var workspace = Workspace.query
    let apex = ApexModel()

    var isConnected: Bool { client != nil }

    /// Whether the Run command can run what the current workspace shows.
    var canRun: Bool {
        switch workspace {
        case .query: isConnected && !isQuerying
        case .apex: isConnected && !apex.isRunning
        case .schema: false
        }
    }

    /// Runs the query or the anonymous Apex, depending on the workspace.
    func run(includeDeleted: Bool = false) async {
        switch workspace {
        case .query: await runQuery(includeDeleted: includeDeleted)
        case .apex: await executeApex()
        case .schema: break
        }
    }

    func executeApex() async {
        guard let client else { return }
        do {
            try await apex.execute(using: client)
        } catch {
            self.error = DisplayedError("Unable to run Apex", error)
        }
        await refreshAPIUsage()
    }

    /// Connects to an org the Salesforce CLI knows by username, e.g. when a window is restored.
    func connect(username: String) async {
        await connect(to: SFOrg(username: username, alias: nil, instanceURL: "", connectedStatus: "", kind: "", isDefault: false))
    }

    func connect(to org: SFOrg) async {
        isConnecting = true
        defer { isConnecting = false }
        statusText = "Connecting to \(org.alias ?? org.username)…"
        do {
            let username = org.username
            let session = try await SFCLI.session(for: username)
            let client = SalesforceClient(session: session) {
                try await SFCLI.session(for: username)
            }
            // The global describe doubles as a check that the session works.
            let types = try await client.describeGlobal()
            self.session = session
            self.client = client
            sobjects = types.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            sobjectNames = Set(sobjects.map { $0.name.lowercased() })
            statusText = "Connected, \(sobjects.count) SObject types"
            recentQueries = UserDefaults.standard.stringArray(forKey: recentQueriesKey) ?? []
            startBackgroundDescribes()
            await refreshAPIUsage()
            UserDefaults.standard.set(username, forKey: "lastOrgUsername")
        } catch {
            statusText = ""
            self.error = DisplayedError("Unable to connect to \(org.alias ?? org.username)", error)
        }
    }

    func disconnect() {
        backgroundDescribes?.cancel()
        backgroundDescribes = nil
        backgroundDescribeProgress = nil
        client = nil
        session = nil
        sobjects = []
        describes = [:]
        describesInFlight = [:]
        schemaSelection = nil
        expandedSObjects = []
        results = nil
        childResults = nil
        pickedFields = nil
        recentQueries = []
        schemaObjects = [:]
        pendingSchemaObjects = []
        sobjectNames = []
        statusText = ""
        apiUsage = nil
        apex.clearRuns()
    }

    func refreshAPIUsage() async {
        apiUsage = await client?.apiUsage
    }

    // MARK: - Schema

    func cachedDescribe(_ sobject: String) -> SObjectDescribe? {
        describes[sobject.lowercased()]
    }

    /// Describes an SObject, using the cache when possible. Concurrent requests for the same type share one call.
    @discardableResult
    func describe(_ sobject: String) async throws -> SObjectDescribe {
        let key = sobject.lowercased()
        if let cached = describes[key] { return cached }
        if let pending = describesInFlight[key] { return try await pending.value }
        guard let client else { throw CancellationError() }
        let task = Task { try await client.describe(sobject) }
        describesInFlight[key] = task
        defer { describesInFlight[key] = nil }
        let result = try await task.value
        describes[key] = result
        await refreshAPIUsage()
        return result
    }

    /// Describes an SObject for the UI, reporting failures in an alert.
    func ensureDescribed(_ sobject: String) async {
        do {
            try await describe(sobject)
        } catch is CancellationError {
        } catch {
            self.error = DisplayedError("Unable to describe \(sobject)", error)
        }
    }

    /// Describes every SObject, a few batches at a time, so the sidebar filter can find fields in
    /// all of them. SoqlXplorer does the same. Describes the UI asks for go ahead separately.
    private func startBackgroundDescribes() {
        backgroundDescribes?.cancel()
        guard UserDefaults.standard.bool(forKey: "describeAllInBackground"), let client else { return }
        backgroundDescribes = Task { await describeAll(using: client) }
    }

    private func describeAll(using client: SalesforceClient) async {
        let names = sobjects.map(\.name)
        var failures: [String: Int] = [:]
        var batchSize = SalesforceClient.describeBatchLimit
        func remaining() -> [String] {
            names.filter { name in
                let key = name.lowercased()
                return describes[key] == nil && describesInFlight[key] == nil && failures[name, default: 0] < 3
            }
        }
        var todo = remaining()
        while !todo.isEmpty, !Task.isCancelled {
            backgroundDescribeProgress = (names.count - todo.count, names.count)
            let batches = stride(from: 0, to: min(todo.count, batchSize * 3), by: batchSize).map {
                Array(todo[$0..<min($0 + batchSize, todo.count)])
            }
            await withTaskGroup(of: (batch: [String], result: Result<(describes: [SObjectDescribe], failed: [String]), Error>).self) { group in
                for batch in batches {
                    group.addTask {
                        do {
                            return (batch, .success(try await client.describe(batch: batch)))
                        } catch {
                            return (batch, .failure(error))
                        }
                    }
                }
                for await (batch, result) in group {
                    switch result {
                    case .success(let r):
                        for describe in r.describes where describes[describe.name.lowercased()] == nil {
                            describes[describe.name.lowercased()] = describe
                        }
                        for name in r.failed {
                            failures[name] = 3
                        }
                    case .failure:
                        // Try again in smaller batches, giving up on an SObject after a few failures.
                        for name in batch {
                            failures[name, default: 0] += 1
                        }
                        batchSize = max(1, batchSize / 2)
                    }
                }
            }
            await refreshAPIUsage()
            todo = remaining()
        }
        backgroundDescribeProgress = nil
    }

    /// SObjects whose name, label, or (already described) field names match the filter.
    var filteredSObjects: [GlobalSObject] {
        let filter = schemaFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return sobjects }
        return sobjects.filter { sobject in
            sobject.name.localizedCaseInsensitiveContains(filter)
                || sobject.label.localizedCaseInsensitiveContains(filter)
                || (cachedDescribe(sobject.name)?.fields.contains { $0.name.localizedCaseInsensitiveContains(filter) } ?? false)
        }
    }

    func fieldMatchesFilter(_ field: FieldDescribe) -> Bool {
        let filter = schemaFilter.trimmingCharacters(in: .whitespaces)
        return !filter.isEmpty && field.name.localizedCaseInsensitiveContains(filter)
    }

    // MARK: - Query

    var canLoadMore: Bool { results?.nextRecordsURL != nil }

    /// Runs the query in the editor. `includeDeleted` uses queryAll, which also returns deleted and archived rows.
    func runQuery(includeDeleted: Bool = false) async {
        let text = soql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, !isQuerying else { return }
        isQuerying = true
        defer { isQuerying = false }
        UserDefaults.standard.set(soql, forKey: "soql")
        statusText = "Running query…"
        let started = ContinuousClock.now
        do {
            let result = try await client.query(text, includeDeleted: includeDeleted)
            let time = Self.elapsed(since: started)
            addRecentQuery(text)
            childResults = nil
            if result.records.isEmpty {
                results = nil
                statusText = result.totalSize > 0
                    ? "Count query result is \(result.totalSize) rows \(time)"
                    : "Query returned 0 rows \(time)"
            } else {
                results = ResultSet(result: result)
                statusText = rowsLoadedStatus(time: time)
                describeResultTypes()
            }
        } catch {
            statusText = ""
            self.error = DisplayedError("Query failed", error)
        }
        await refreshAPIUsage()
    }

    // MARK: - Recent queries

    private var recentQueriesKey: String { "recentQueries-\(session?.username ?? "")" }

    private func addRecentQuery(_ text: String) {
        recentQueries.removeAll { $0 == text }
        recentQueries.insert(text, at: 0)
        let limit = max(1, UserDefaults.standard.integer(forKey: "maxRecentQueries"))
        if recentQueries.count > limit {
            recentQueries.removeLast(recentQueries.count - limit)
        }
        UserDefaults.standard.set(recentQueries, forKey: recentQueriesKey)
    }

    func removeRecentQueries(_ queries: Set<String>) {
        recentQueries.removeAll { queries.contains($0) }
        UserDefaults.standard.set(recentQueries, forKey: recentQueriesKey)
    }

    /// Puts a recent query in the editor, optionally running it.
    func useRecentQuery(_ text: String, run: Bool) async {
        soql = text
        workspace = .query
        if run {
            await runQuery()
        }
    }

    /// Fetches the next batch of rows for the current results.
    func loadMore() async {
        guard let client, let next = results?.nextRecordsURL, !isQuerying else { return }
        isQuerying = true
        defer { isQuerying = false }
        let started = ContinuousClock.now
        do {
            let batch = try await client.queryMore(next)
            results?.append(batch)
            statusText = rowsLoadedStatus(time: Self.elapsed(since: started))
            describeResultTypes()
        } catch {
            self.error = DisplayedError("Unable to load more rows", error)
        }
        await refreshAPIUsage()
    }

    /// Fetches every remaining batch, e.g. before exporting.
    func loadAll() async {
        while canLoadMore, error == nil {
            await loadMore()
        }
    }

    func showChildResults(_ result: QueryResult, column: String, parentRowID: ResultRow.ID) {
        childResults = ResultSet(result: result, title: column, parentRowID: parentRowID)
        describeResultTypes()
    }

    private func rowsLoadedStatus(time: String) -> String {
        guard let results else { return "" }
        return "Loaded \(results.rows.count) of \(results.totalSize) total rows \(time)"
    }

    /// Describes the SObject types in the results in the background, so the table knows which
    /// fields can be edited.
    private func describeResultTypes() {
        let types = (results?.sobjectTypes ?? []).union(childResults?.sobjectTypes ?? [])
        for type in types where knownSObject(type) && cachedDescribe(type) == nil {
            Task { try? await describe(type) }
        }
    }

    // MARK: - Editing

    /// The fields of a result row's SObject type that can be edited, once it has been described.
    func editableFields(of row: ResultRow) -> Set<String> {
        guard row.recordID != nil, let type = row.record.sobjectType else { return [] }
        return cachedDescribe(type)?.updateableFields ?? []
    }

    /// Saves text typed into a results cell to the record, and updates the results to match.
    /// Returns whether the change was saved.
    @discardableResult
    func saveEdit(_ text: String, field: String, row: ResultRow) async -> Bool {
        guard let client, let id = row.recordID, let type = row.record.sobjectType else { return false }
        if (row.record[field]?.displayText ?? "") == text { return true }
        isSaving = true
        defer { isSaving = false }
        statusText = "Updating \(field) on \(id)…"
        do {
            guard let fieldDescribe = try await describe(type).field(named: field) else {
                throw InvalidFieldValue(errorDescription: "\(type) has no field named \(field).")
            }
            let value = try fieldDescribe.value(fromText: text)
            var fields = JSONObject()
            fields[fieldDescribe.name] = value
            try await client.update(type, id: id, fields: fields)
            results?.applyUpdate(recordID: id, field: field, value: value)
            childResults?.applyUpdate(recordID: id, field: field, value: value)
            statusText = "Updated \(field) on \(id)"
            await refreshAPIUsage()
            return true
        } catch {
            statusText = ""
            self.error = DisplayedError("Unable to update \(field)", error)
            await refreshAPIUsage()
            return false
        }
    }

    /// Deletes the records checked in the results, in batches of 200. Rows that fail stay checked
    /// and show why.
    func deleteCheckedRows() async {
        guard let client, let checked = results?.checkedRows, !checked.isEmpty, !isSaving else { return }
        let rows = (results?.rows ?? []).filter { checked.contains($0.id) && $0.recordID != nil }
        isSaving = true
        defer { isSaving = false }
        var deleted = Set<ResultRow.ID>()
        var errors: [ResultRow.ID: String] = [:]
        for start in stride(from: 0, to: rows.count, by: 200) {
            let batch = rows[start..<min(start + 200, rows.count)]
            statusText = "Deleting \(start + batch.count) of \(rows.count) rows…"
            do {
                let saveResults = try await client.delete(ids: batch.compactMap(\.recordID))
                for (row, saveResult) in zip(batch, saveResults) {
                    if saveResult.success {
                        deleted.insert(row.id)
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
        results?.rowErrors = errors
        results?.removeRows(deleted)
        if let parent = childResults?.parentRowID, deleted.contains(parent) {
            childResults = nil
        }
        statusText = "Deleted \(deleted.count) \(deleted.count == 1 ? "row" : "rows")" + (errors.isEmpty ? "" : ", \(errors.count) failed")
        await refreshAPIUsage()
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> String {
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        return "(in \(Int(ms.rounded())) ms)"
    }

    /// Builds a query from a double-clicked schema item, as SoqlXplorer does: an SObject selects all
    /// of its fields, and each field toggles that field in the query.
    func buildQuery(for item: SchemaItem) async {
        guard let describe = try? await describe(item.sobjectName) else { return }
        var fields: [String]
        switch item {
        case .sobject:
            fields = describe.fields.map(\.name)
        case .field(_, let field):
            fields = pickedFields?.sobject == describe.name ? pickedFields?.fields ?? [] : []
            if let i = fields.firstIndex(where: { $0.caseInsensitiveCompare(field) == .orderedSame }) {
                fields.remove(at: i)
            } else {
                fields.append(describe.field(named: field)?.name ?? field)
            }
        }
        pickedFields = (describe.name, fields)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "sortFieldsInGeneratedQueries") {
            fields.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        // Selecting a compound address or location field and its parts is redundant, so drop one or the other.
        let compound = Set(describe.fields.filter(\.isCompound).map(\.name))
        if defaults.bool(forKey: "skipCompoundFieldsInGeneratedQueries") {
            fields.removeAll { compound.contains($0) }
        } else {
            let parts = Set(describe.fields.filter { $0.json["compoundFieldName"]?.string.map(compound.contains) ?? false }.map(\.name))
            fields.removeAll { parts.contains($0) }
        }
        soql = fields.isEmpty ? "SELECT FROM \(describe.name)" : "SELECT \(fields.joined(separator: ", ")) FROM \(describe.name)"
    }
}

extension ExplorerModel: SoqlDescriber {
    func schemaObject(_ sobject: String) -> SoqlSchemaObject? {
        let key = sobject.lowercased()
        if let obj = schemaObjects[key] { return obj }
        if let describe = cachedDescribe(sobject) {
            let obj = SoqlSchemaObject(describe)
            schemaObjects[key] = obj
            return obj
        }
        // Fetch it in the background; the editor rechecks the query when it arrives.
        if knownSObject(sobject), pendingSchemaObjects.insert(key).inserted {
            Task {
                if (try? await describe(sobject)) != nil {
                    schemaGeneration += 1
                }
                pendingSchemaObjects.remove(key)
            }
        }
        return nil
    }

    func knownSObject(_ sobject: String) -> Bool {
        sobjectNames.contains(sobject.lowercased())
    }

    var allQueryableSObjects: [String] {
        sobjects.filter(\.queryable).map(\.name)
    }
}

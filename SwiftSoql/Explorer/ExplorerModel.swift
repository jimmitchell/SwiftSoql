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

    // Query tabs
    private(set) var tabs: [QueryTab]
    var selectedTabID: QueryTab.ID

    /// The tab showing in the query workspace.
    var currentTab: QueryTab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }

    // The current tab's query and results.
    var soql: String {
        get { currentTab.soql }
        set { currentTab.soql = newValue }
    }
    var results: ResultSet? {
        get { currentTab.results }
        set { currentTab.results = newValue }
    }
    /// A subquery result opened from a cell of `results`.
    var childResults: ResultSet? {
        get { currentTab.childResults }
        set { currentTab.childResults = newValue }
    }
    var isQuerying: Bool { currentTab.isQuerying }

    /// The plans for the current tab's query, while they're shown.
    var queryPlan: QueryPlanResult?

    /// True while an edit or delete is being saved.
    private(set) var isSaving = false
    /// Set to ask the user to confirm deleting the checked rows.
    var isConfirmingDelete = false
    /// Queries run in this org, newest first. Pinned queries aren't included.
    private(set) var recentQueries: [String] = []
    /// Queries pinned in this org, which are kept however many queries are run.
    private(set) var pinnedQueries: [String] = []
    /// The fields picked by double-clicking in the schema sidebar, for building a query.
    private var pickedFields: (sobject: String, fields: [String])?

    // SOQL editor
    /// Changes when a describe the SOQL editor asked for arrives, so it can recheck the query.
    private(set) var schemaGeneration = 0
    @ObservationIgnored private var schemaObjects: [String: SoqlSchemaObject] = [:]
    @ObservationIgnored private var pendingSchemaObjects: Set<String> = []
    @ObservationIgnored private var sobjectNames: Set<String> = []
    @ObservationIgnored private var sobjectsByKeyPrefix: [String: String] = [:]

    // Files
    /// Set by the File menu to show the open or save panel.
    var isOpeningFile = false
    var isSavingFile = false

    // Anonymous Apex
    var workspace = Workspace.query
    let apex = ApexModel()

    var isConnected: Bool { client != nil }

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "queryTabs") ?? [defaults.string(forKey: "soql") ?? "SELECT Id, Name FROM Account"]
        let restored = (saved.isEmpty ? [""] : saved).map { QueryTab(soql: $0) }
        let selected = min(max(0, defaults.integer(forKey: "selectedQueryTab")), restored.count - 1)
        tabs = restored
        selectedTabID = restored[selected].id
    }

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
            sobjectsByKeyPrefix = Dictionary(sobjects.compactMap { s in s.keyPrefix.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
            statusText = "Connected, \(sobjects.count) SObject types"
            currentTab.statusText = statusText
            recentQueries = UserDefaults.standard.stringArray(forKey: recentQueriesKey) ?? []
            pinnedQueries = UserDefaults.standard.stringArray(forKey: pinnedQueriesKey) ?? []
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
        for tab in tabs {
            tab.results = nil
            tab.childResults = nil
            tab.statusText = ""
        }
        pickedFields = nil
        recentQueries = []
        pinnedQueries = []
        schemaObjects = [:]
        pendingSchemaObjects = []
        sobjectNames = []
        sobjectsByKeyPrefix = [:]
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
        // The task caches the describe itself, so it's cached before any caller sees it.
        let task = Task {
            defer { describesInFlight[key] = nil }
            let result = try await client.describe(sobject)
            describes[key] = result
            return result
        }
        describesInFlight[key] = task
        let result = try await task.value
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
        // The results go to the tab the query was run in, even if another is showing by then.
        let tab = currentTab
        let text = tab.soql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, !tab.isQuerying else { return }
        tab.isQuerying = true
        defer { tab.isQuerying = false }
        saveTabs()
        tab.statusText = "Running query…"
        let started = ContinuousClock.now
        do {
            let result = try await client.query(text, includeDeleted: includeDeleted)
            let time = Self.elapsed(since: started)
            addRecentQuery(text)
            tab.childResults = nil
            if result.records.isEmpty {
                tab.results = nil
                tab.statusText = result.totalSize > 0
                    ? "Count query result is \(result.totalSize) rows \(time)"
                    : "Query returned 0 rows \(time)"
            } else {
                tab.results = ResultSet(result: result)
                tab.results?.includesDeleted = includeDeleted
                tab.statusText = rowsLoadedStatus(tab, time: time)
                describeResultTypes(tab)
            }
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Query failed", error)
        }
        await refreshAPIUsage()
    }

    /// Shows how Salesforce would run the current tab's query, without running it.
    func explainQuery() async {
        let tab = currentTab
        let text = tab.soql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, !tab.isQuerying else { return }
        guard !text.lowercased().hasPrefix("find") else {
            error = DisplayedError("Can't show a query plan", InvalidFieldValue(errorDescription: "Query plans are only available for SOQL queries, not SOSL searches."))
            return
        }
        tab.isQuerying = true
        defer { tab.isQuerying = false }
        tab.statusText = "Getting the query plan…"
        do {
            let plans = try await client.explain(text)
            tab.statusText = ""
            queryPlan = QueryPlanResult(query: text, plans: plans)
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Unable to get the query plan", error)
        }
        await refreshAPIUsage()
    }

    // MARK: - Tabs

    /// Opens a new query tab after the current one and shows it.
    func newTab(soql: String = "") {
        let tab = QueryTab(soql: soql)
        let index = (tabs.firstIndex { $0.id == selectedTabID } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: index)
        selectedTabID = tab.id
        workspace = .query
        saveTabs()
    }

    /// Closes a tab, showing its neighbor. Closing the last tab leaves an empty one.
    func closeTab(_ id: QueryTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            tabs = [QueryTab(soql: "")]
        }
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        saveTabs()
    }

    func closeOtherTabs(than id: QueryTab.ID) {
        tabs.removeAll { $0.id != id }
        selectedTabID = id
        saveTabs()
    }

    /// Shows the next tab (or the previous one with `offset: -1`), wrapping around.
    func selectTab(offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + offset + tabs.count) % tabs.count].id
        saveTabs()
    }

    /// Remembers the tabs' queries for the next window.
    private func saveTabs() {
        UserDefaults.standard.set(tabs.map(\.soql), forKey: "queryTabs")
        UserDefaults.standard.set(tabs.firstIndex { $0.id == selectedTabID } ?? 0, forKey: "selectedQueryTab")
    }

    // MARK: - Recent queries

    private var recentQueriesKey: String { "recentQueries-\(session?.username ?? "")" }
    private var pinnedQueriesKey: String { "pinnedQueries-\(session?.username ?? "")" }

    private func addRecentQuery(_ text: String) {
        // A pinned query stays where it was pinned.
        guard !pinnedQueries.contains(text) else { return }
        recentQueries.removeAll { $0 == text }
        recentQueries.insert(text, at: 0)
        saveQueries()
    }

    /// Saves the recent and pinned queries, keeping only as many recent ones as Settings allows.
    private func saveQueries() {
        let limit = max(1, UserDefaults.standard.integer(forKey: "maxRecentQueries"))
        if recentQueries.count > limit {
            recentQueries.removeLast(recentQueries.count - limit)
        }
        UserDefaults.standard.set(recentQueries, forKey: recentQueriesKey)
        UserDefaults.standard.set(pinnedQueries, forKey: pinnedQueriesKey)
    }

    /// Removes recent or pinned queries.
    func removeQueries(_ queries: Set<String>) {
        recentQueries.removeAll { queries.contains($0) }
        pinnedQueries.removeAll { queries.contains($0) }
        saveQueries()
    }

    func clearRecentQueries() {
        recentQueries = []
        saveQueries()
    }

    /// Moves recent queries to the end of the pinned ones, in the order they're listed.
    func pinQueries(_ queries: Set<String>) {
        pinnedQueries += recentQueries.filter(queries.contains)
        recentQueries.removeAll { queries.contains($0) }
        saveQueries()
    }

    /// Moves pinned queries back to the top of the recent ones.
    func unpinQueries(_ queries: Set<String>) {
        recentQueries.insert(contentsOf: pinnedQueries.filter(queries.contains), at: 0)
        pinnedQueries.removeAll { queries.contains($0) }
        saveQueries()
    }

    func movePinnedQueries(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { pinnedQueries[$0] }
        for i in source.reversed() {
            pinnedQueries.remove(at: i)
        }
        pinnedQueries.insert(contentsOf: moving, at: destination - source.count { $0 < destination })
        saveQueries()
    }

    /// Puts a recent query in the editor, optionally running it.
    func useRecentQuery(_ text: String, run: Bool) async {
        soql = text
        workspace = .query
        if run {
            await runQuery()
        }
    }

    /// Fetches the next batch of rows for a tab's results (the current tab's by default).
    func loadMore(in tab: QueryTab? = nil) async {
        let tab = tab ?? currentTab
        guard let client, let next = tab.results?.nextRecordsURL, !tab.isQuerying else { return }
        tab.isQuerying = true
        defer { tab.isQuerying = false }
        let started = ContinuousClock.now
        do {
            let batch = try await client.queryMore(next)
            tab.results?.append(batch)
            tab.statusText = rowsLoadedStatus(tab, time: Self.elapsed(since: started))
            describeResultTypes(tab)
        } catch {
            self.error = DisplayedError("Unable to load more rows", error)
        }
        await refreshAPIUsage()
    }

    /// Fetches every remaining batch of the current tab's results, e.g. before exporting.
    func loadAll() async {
        let tab = currentTab
        while tab.results?.nextRecordsURL != nil, error == nil {
            await loadMore(in: tab)
        }
    }

    func showChildResults(_ result: QueryResult, column: String, parentRowID: ResultRow.ID) {
        childResults = ResultSet(result: result, title: column, parentRowID: parentRowID)
        describeResultTypes(currentTab)
    }

    private func rowsLoadedStatus(_ tab: QueryTab, time: String) -> String {
        guard let results = tab.results else { return "" }
        return "Loaded \(results.rows.count) of \(results.totalSize) total rows \(time)"
    }

    /// Describes the SObject types in the results in the background, so the table knows which
    /// fields can be edited.
    private func describeResultTypes(_ tab: QueryTab) {
        let types = (tab.results?.sobjectTypes ?? []).union(tab.childResults?.sobjectTypes ?? [])
        for type in types where knownSObject(type) && cachedDescribe(type) == nil {
            Task { try? await describe(type) }
        }
    }

    // MARK: - Records in Salesforce

    /// The SObject type of a record Id, if the text is an Id with a key prefix this org knows.
    func sobjectType(ofRecordID text: String) -> String? {
        guard text.count == 15 || text.count == 18, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return sobjectsByKeyPrefix[String(text.prefix(3))]
    }

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

    // MARK: - Editing

    /// The field a results cell shows, if it can be edited: a top-level field the user may
    /// update, once the row's SObject type has been described.
    func editableField(_ column: String, of row: ResultRow) -> FieldDescribe? {
        guard column != "Id", row.recordID != nil, let type = row.record.sobjectType,
              let field = cachedDescribe(type)?.field(exactly: column), field.updateable else { return nil }
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
            guard let fieldDescribe = try await describe(type).field(named: field) else {
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

    /// Restores the checked records from the Recycle Bin, in batches of 200. Restored rows are
    /// unchecked and show IsDeleted as false if it was queried; rows that fail stay checked and
    /// show why.
    func restoreCheckedRows() async {
        let tab = currentTab
        guard let client, let checked = tab.results?.checkedRows, !checked.isEmpty, !isSaving else { return }
        let rows = (tab.results?.rows ?? []).filter { checked.contains($0.id) && $0.recordID != nil }
        isSaving = true
        defer { isSaving = false }
        var restored = 0
        var errors: [ResultRow.ID: String] = [:]
        for start in stride(from: 0, to: rows.count, by: 200) {
            let batch = rows[start..<min(start + 200, rows.count)]
            tab.statusText = "Restoring \(start + batch.count) of \(rows.count) rows…"
            do {
                let saveResults = try await client.undelete(ids: batch.compactMap(\.recordID))
                for (row, saveResult) in zip(batch, saveResults) {
                    if saveResult.success, let id = row.recordID {
                        restored += 1
                        tab.results?.checkedRows.remove(row.id)
                        tab.results?.applyUpdate(recordID: id, field: "IsDeleted", value: .bool(false))
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
        tab.statusText = "Restored \(restored) \(restored == 1 ? "row" : "rows")" + (errors.isEmpty ? "" : ", \(errors.count) failed")
        await refreshAPIUsage()
    }

    /// Deletes the records checked in the results, in batches of 200. Rows that fail stay checked
    /// and show why.
    func deleteCheckedRows() async {
        let tab = currentTab
        guard let client, let checked = tab.results?.checkedRows, !checked.isEmpty, !isSaving else { return }
        let rows = (tab.results?.rows ?? []).filter { checked.contains($0.id) && $0.recordID != nil }
        isSaving = true
        defer { isSaving = false }
        var deleted = Set<ResultRow.ID>()
        var errors: [ResultRow.ID: String] = [:]
        for start in stride(from: 0, to: rows.count, by: 200) {
            let batch = rows[start..<min(start + 200, rows.count)]
            tab.statusText = "Deleting \(start + batch.count) of \(rows.count) rows…"
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
        tab.results?.rowErrors = errors
        tab.results?.removeRows(deleted)
        if let parent = tab.childResults?.parentRowID, deleted.contains(parent) {
            tab.childResults = nil
        }
        tab.statusText = "Deleted \(deleted.count) \(deleted.count == 1 ? "row" : "rows")" + (errors.isEmpty ? "" : ", \(errors.count) failed")
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

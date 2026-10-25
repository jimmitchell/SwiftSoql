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

    /// True while an edit or delete is being saved. Set only by the record changes in
    /// ExplorerModel+Records.swift.
    var isSaving = false
    /// Set to ask the user to confirm deleting the checked rows.
    var isConfirmingDelete = false
    /// The queries run and pinned in this org.
    let history = QueryHistory()
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

    /// SObject icons from the org's theme.
    let icons = SObjectIcons()

    // Anonymous Apex
    var workspace = Workspace.query
    let apex = ApexModel()

    var isConnected: Bool { client != nil }

    init() {
        let defaults = AppDefaults.store
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
        await connect(to: SFOrg(username: username, alias: nil, instanceURL: "", connectedStatus: "", kind: "", isDefault: false,
                                isBrowserLogin: BrowserLogin.isSaved(username)))
    }

    func connect(to org: SFOrg) async {
        isConnecting = true
        defer { isConnecting = false }
        statusText = "Connecting to \(org.alias ?? org.username)…"
        do {
            let username = org.username
            let newSession: @Sendable () async throws -> OrgSession = org.isBrowserLogin
                ? { @Sendable in try await BrowserLogin.session(for: username) }
                : { @Sendable in try await SFCLI.session(for: username) }
            let session = try await newSession()
            let client = SalesforceClient(session: session, reauthenticate: newSession)
            // The global describe doubles as a check that the session works.
            let types = try await client.describeGlobal()
            self.session = session
            self.client = client
            sobjects = types.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            sobjectNames = Set(sobjects.map { $0.name.lowercased() })
            sobjectsByKeyPrefix = Dictionary(sobjects.compactMap { s in s.keyPrefix.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
            statusText = "Connected, \(sobjects.count) SObject types"
            currentTab.statusText = statusText
            history.load(username: session.username)
            let batchSize = AppDefaults.store.integer(forKey: "queryBatchSize")
            await client.setQueryBatchSize(batchSize > 0 ? batchSize : nil)
            startBackgroundDescribes()
            Task { [icons] in
                if let theme = try? await client.theme() { icons.load(theme: theme) }
            }
            await refreshAPIUsage()
            AppDefaults.store.set(username, forKey: "lastOrgUsername")
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
        history.load(username: nil)
        schemaObjects = [:]
        pendingSchemaObjects = []
        sobjectNames = []
        sobjectsByKeyPrefix = [:]
        statusText = ""
        apiUsage = nil
        apex.clearRuns()
        icons.reset()
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
        guard AppDefaults.store.bool(forKey: "describeAllInBackground"), let client else { return }
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

    /// The most rows a results table loads; exporting all rows writes the rest straight to the file.
    static var tableRowLimit: Int { max(1, AppDefaults.store.integer(forKey: "tableRowLimit")) }
    /// Exports of more rows than this use the Bulk API, when the query allows it.
    static var bulkExportThreshold: Int { AppDefaults.store.integer(forKey: "bulkExportThreshold") }

    /// Whether more rows can be loaded into the current tab's table.
    var canLoadMore: Bool {
        guard let results else { return false }
        return results.nextRecordsURL != nil && results.rows.count < Self.tableRowLimit
    }

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
            history.add(text)
            tab.childResults = nil
            if result.records.isEmpty {
                tab.results = nil
                tab.statusText = result.totalSize > 0
                    ? "Count query result is \(result.totalSize) rows \(time)"
                    : "Query returned 0 rows \(time)"
            } else {
                tab.results = ResultSet(result: result)
                tab.results?.includesDeleted = includeDeleted
                tab.results?.query = text
                tab.statusText = rowsLoadedStatus(tab, time: time)
                describeResultTypes(tab)
            }
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Query failed", error)
        }
        await refreshAPIUsage()
    }

    /// Puts a recent query in the editor, optionally running it.
    func useRecentQuery(_ text: String, run: Bool) async {
        soql = text
        workspace = .query
        if run {
            await runQuery()
        }
    }

    /// Lays the current tab's query out on several lines. Only whitespace changes, and Undo
    /// puts it back.
    func formatQuery() {
        if let formatted = SoqlFormatter.format(soql) {
            soql = formatted
        } else {
            currentTab.statusText = "Only SOQL queries can be formatted, and this one couldn't be read."
        }
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
        AppDefaults.store.set(tabs.map(\.soql), forKey: "queryTabs")
        AppDefaults.store.set(tabs.firstIndex { $0.id == selectedTabID } ?? 0, forKey: "selectedQueryTab")
    }

    // MARK: - Loading more rows

    /// Fetches the next batch of rows for a tab's results (the current tab's by default).
    func loadMore(in tab: QueryTab? = nil) async {
        let tab = tab ?? currentTab
        guard let client, let next = tab.results?.nextRecordsURL, !tab.isQuerying,
              (tab.results?.rows.count ?? 0) < Self.tableRowLimit else { return }
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
        while tab.results?.nextRecordsURL != nil, (tab.results?.rows.count ?? 0) < Self.tableRowLimit, error == nil {
            await loadMore(in: tab)
        }
    }

    func showChildResults(_ result: QueryResult, column: String, parentRowID: ResultRow.ID) {
        childResults = ResultSet(result: result, title: column, parentRowID: parentRowID)
        describeResultTypes(currentTab)
    }

    private func rowsLoadedStatus(_ tab: QueryTab, time: String) -> String {
        guard let results = tab.results else { return "" }
        let status = "Loaded \(results.rows.count) of \(results.totalSize) total rows \(time)"
        if results.nextRecordsURL != nil, results.rows.count >= Self.tableRowLimit {
            return status + ". The table stops at \(Self.tableRowLimit.formatted()) rows; Export CSV gets them all."
        }
        return status
    }

    // MARK: - Exporting

    /// Writes every row of the current tab's query to a CSV file: the rows already loaded, then
    /// the rest straight from Salesforce, without loading them into the table. Large exports use
    /// a Bulk API job when the query allows it, and fall back to paging if the job can't run.
    func exportAll(to url: URL) async {
        let tab = currentTab
        guard let client, let results = tab.results, !tab.isQuerying else { return }
        tab.isQuerying = true
        defer { tab.isQuerying = false }
        let started = ContinuousClock.now
        do {
            let exporter = CSVExporter(client: client) { tab.statusText = $0 }
            var rows: Int?
            if results.totalSize > Self.bulkExportThreshold, let query = results.query, BulkExport.canRun(query) {
                do {
                    rows = try await exporter.bulk(query, includeDeleted: results.includesDeleted, to: url)
                } catch let error as CSVExporter.BulkJobUnavailable {
                    // The job couldn't start or run; page through the results instead.
                    tab.statusText = "Bulk API unavailable (\(error.message)); exporting page by page…"
                }
            }
            if rows == nil {
                rows = try await exporter.paged(results, to: url)
            }
            tab.statusText = "Exported \((rows ?? 0).formatted()) rows to \(url.lastPathComponent) \(Self.elapsed(since: started))"
        } catch {
            tab.statusText = ""
            self.error = DisplayedError("Unable to export", error)
        }
        await refreshAPIUsage()
    }

    /// Describes the SObject types in the results in the background, so the table knows which
    /// fields can be edited.
    private func describeResultTypes(_ tab: QueryTab) {
        let types = (tab.results?.sobjectTypes ?? []).union(tab.childResults?.sobjectTypes ?? [])
        for type in types where knownSObject(type) && cachedDescribe(type) == nil {
            Task { try? await describe(type) }
        }
    }

    // MARK: - Records

    /// The SObject type of a record Id, if the text is an Id with a key prefix this org knows.
    func sobjectType(ofRecordID text: String) -> String? {
        guard text.count == 15 || text.count == 18, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return sobjectsByKeyPrefix[String(text.prefix(3))]
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

        let defaults = AppDefaults.store
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

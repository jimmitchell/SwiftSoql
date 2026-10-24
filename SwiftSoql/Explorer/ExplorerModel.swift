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

    // Query
    var soql = UserDefaults.standard.string(forKey: "soql") ?? "SELECT Id, Name FROM Account"
    private(set) var isQuerying = false
    var results: ResultSet?
    /// A subquery result opened from a cell of `results`.
    var childResults: ResultSet?
    /// The fields picked by double-clicking in the schema sidebar, for building a query.
    private var pickedFields: (sobject: String, fields: [String])?

    var isConnected: Bool { client != nil }

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
            statusText = "Connected, \(sobjects.count) SObject types"
            await refreshAPIUsage()
            UserDefaults.standard.set(username, forKey: "lastOrgUsername")
        } catch {
            statusText = ""
            self.error = DisplayedError("Unable to connect to \(org.alias ?? org.username)", error)
        }
    }

    func disconnect() {
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
        statusText = ""
        apiUsage = nil
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

    var canLoadMore: Bool { results?.result.nextRecordsURL != nil }

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
            childResults = nil
            if result.records.isEmpty {
                results = nil
                statusText = result.totalSize > 0
                    ? "Count query result is \(result.totalSize) rows \(time)"
                    : "Query returned 0 rows \(time)"
            } else {
                results = ResultSet(result: result)
                statusText = rowsLoadedStatus(time: time)
            }
        } catch {
            statusText = ""
            self.error = DisplayedError("Query failed", error)
        }
        await refreshAPIUsage()
    }

    /// Fetches the next batch of rows for the current results.
    func loadMore() async {
        guard let client, let next = results?.result.nextRecordsURL, !isQuerying else { return }
        isQuerying = true
        defer { isQuerying = false }
        let started = ContinuousClock.now
        do {
            let batch = try await client.queryMore(next)
            results?.append(batch)
            statusText = rowsLoadedStatus(time: Self.elapsed(since: started))
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

    func showChildResults(_ result: QueryResult, column: String) {
        childResults = ResultSet(result: result, title: column)
    }

    private func rowsLoadedStatus(time: String) -> String {
        guard let results else { return "" }
        return "Loaded \(results.rows.count) of \(results.result.totalSize) total rows \(time)"
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

/// Loaded query results, with the columns to display them.
struct ResultSet: Identifiable {
    let id = UUID()
    private(set) var result: QueryResult
    private(set) var columns: [String]
    private(set) var rows: [ResultRow]
    /// For subquery results, the column they came from.
    var title: String?

    init(result: QueryResult, title: String? = nil) {
        self.result = result
        self.title = title
        columns = QueryColumns.names(for: result.records, isSearchResult: result.isSearchResult)
        rows = result.records.enumerated().map { ResultRow(id: $0.offset, record: $0.element) }
    }

    /// A starting width for a column that fits its name and the values in the first rows.
    func idealWidth(for column: String) -> CGFloat {
        let path = column.split(separator: ".")
        let longest = rows.prefix(100).reduce(column.count) { longest, row in
            max(longest, row.record.value(atPath: path)?.displayText?.count ?? 0)
        }
        return min(max(CGFloat(longest) * 7 + 16, 50), 320)
    }

    mutating func append(_ batch: QueryResult) {
        let start = rows.count
        result.append(batch)
        rows += batch.records.enumerated().map { ResultRow(id: start + $0.offset, record: $0.element) }
        // A later batch can resolve columns that were null in every earlier row.
        columns = QueryColumns.names(for: result.records, isSearchResult: result.isSearchResult)
    }
}

struct ResultRow: Identifiable {
    let id: Int
    let record: JSONObject
}

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
}

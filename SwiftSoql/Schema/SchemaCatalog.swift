import Foundation
import Observation

/// The SObjects one Salesforce API offers in the connected org, their describes as they arrive,
/// and what the sidebar has selected and expanded among them. A window has one for the data API
/// and one for the Tooling API.
@Observable
final class SchemaCatalog {
    let api: SalesforceAPI
    private(set) var sobjects: [GlobalSObject] = []
    /// Whether the global describe has loaded.
    private(set) var isLoaded = false
    private(set) var isLoading = false

    var selection: SchemaItem?
    var expanded: Set<String> = []

    private var describes: [String: SObjectDescribe] = [:]
    private var describesInFlight: [String: Task<SObjectDescribe, Error>] = [:]
    /// How far describing every SObject in the background has got, while it runs.
    private(set) var backgroundDescribeProgress: (done: Int, total: Int)?
    @ObservationIgnored private var backgroundDescribes: Task<Void, Never>?

    /// Changes when a describe the SOQL editor asked for arrives, so it can recheck the query.
    private(set) var schemaGeneration = 0
    @ObservationIgnored private var schemaObjects: [String: SoqlSchemaObject] = [:]
    @ObservationIgnored private var pendingSchemaObjects: Set<String> = []
    @ObservationIgnored private var sobjectNames: Set<String> = []
    @ObservationIgnored private var sobjectsByKeyPrefix: [String: String] = [:]

    @ObservationIgnored private var client: SalesforceClient?
    /// Called after describes, so the window can show the org's API usage.
    @ObservationIgnored var didCallAPI: () async -> Void = {}

    init(api: SalesforceAPI) {
        self.api = api
    }

    /// Loads the global describe, replacing anything from an earlier connection, then starts
    /// describing every SObject in the background if Settings asks for it.
    func load(using client: SalesforceClient) async throws {
        reset()
        isLoading = true
        defer { isLoading = false }
        let types = try await client.describeGlobal(api: api)
        self.client = client
        sobjects = types.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        sobjectNames = Set(sobjects.map { $0.name.lowercased() })
        sobjectsByKeyPrefix = Dictionary(sobjects.compactMap { s in s.keyPrefix.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
        isLoaded = true
        // Editors checked against an empty list until now.
        schemaGeneration += 1
        if AppDefaults.store.bool(forKey: "describeAllInBackground") {
            backgroundDescribes = Task { await describeAll(using: client) }
        }
    }

    /// Forgets the org's SObjects, e.g. on disconnecting.
    func reset() {
        backgroundDescribes?.cancel()
        backgroundDescribes = nil
        backgroundDescribeProgress = nil
        client = nil
        sobjects = []
        isLoaded = false
        selection = nil
        expanded = []
        describes = [:]
        describesInFlight = [:]
        schemaObjects = [:]
        pendingSchemaObjects = []
        sobjectNames = []
        sobjectsByKeyPrefix = [:]
    }

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
        let api = api
        let task = Task {
            defer { describesInFlight[key] = nil }
            let result = try await client.describe(sobject, api: api)
            describes[key] = result
            return result
        }
        describesInFlight[key] = task
        let result = try await task.value
        await didCallAPI()
        return result
    }

    /// Describes every SObject, a few batches at a time, so the sidebar filter can find fields in
    /// all of them. SoqlXplorer does the same. Describes the UI asks for go ahead separately.
    private func describeAll(using client: SalesforceClient) async {
        let names = sobjects.map(\.name)
        let api = api
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
                            return (batch, .success(try await client.describe(batch: batch, api: api)))
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
            await didCallAPI()
            todo = remaining()
        }
        backgroundDescribeProgress = nil
    }

    /// The SObject type of a record Id, if the text is an Id with a key prefix this API knows.
    func sobjectType(ofRecordID text: String) -> String? {
        guard text.count == 15 || text.count == 18, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return sobjectsByKeyPrefix[String(text.prefix(3))]
    }
}

extension SchemaCatalog: SoqlDescriber {
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

import Foundation

/// Where to connect and with which token.
nonisolated struct OrgSession: Sendable {
    var username: String
    var alias: String?
    var instanceURL: URL
    var apiVersion: String
    var accessToken: String

    var displayName: String { alias ?? username }
}

/// An error returned by the Salesforce REST API.
nonisolated struct SalesforceError: LocalizedError {
    let statusCode: Int
    let errorCode: String
    let message: String

    var errorDescription: String? {
        errorCode.isEmpty || message.contains(errorCode) ? message : "\(errorCode): \(message)"
    }

    var isInvalidSession: Bool {
        statusCode == 401 || errorCode == "INVALID_SESSION_ID"
    }
}

/// Which Salesforce API queries and describes go to: the regular data API, or the Tooling API
/// with its metadata objects, such as ApexClass and CustomField.
nonisolated enum SalesforceAPI: String, Sendable {
    case data
    case tooling
}

/// The outcome for one record of a save, delete or undelete.
nonisolated struct SaveResult: Sendable {
    let success: Bool
    /// The errors, if it failed.
    let message: String
    /// The record's Id, when Salesforce reports it.
    var id: String?
    /// Whether an insert or upsert created the record.
    var created = false

    init(success: Bool, message: String) {
        self.success = success
        self.message = message
    }

    init(json: JSONValue) {
        id = json["id"]?.string
        created = json["created"]?.bool ?? false
        success = json["success"]?.bool ?? false
        message = (json["errors"]?.array ?? []).map { e in
            let message = e["message"]?.string ?? ""
            guard let code = e["statusCode"]?.string, !code.isEmpty else { return message }
            return "\(code): \(message)"
        }.joined(separator: "\n")
    }
}

/// A minimal async client for the Salesforce REST API.
///
/// When the access token expires it asks `reauthenticate` for a fresh session once,
/// then retries the request.
actor SalesforceClient {
    private(set) var session: OrgSession
    private let reauthenticate: @Sendable () async throws -> OrgSession
    private let urlSession: URLSession

    /// The latest "used/limit" daily API request count, from the Sforce-Limit-Info header.
    private(set) var apiUsage: String?

    init(session: OrgSession, reauthenticate: @escaping @Sendable () async throws -> OrgSession) {
        self.session = session
        self.reauthenticate = reauthenticate
        self.urlSession = URLSession(configuration: .ephemeral)
    }

    private var dataPath: String { "/services/data/v\(session.apiVersion)" }

    private func path(_ api: SalesforceAPI) -> String {
        api == .tooling ? "\(dataPath)/tooling" : dataPath
    }

    func describeGlobal(api: SalesforceAPI = .data) async throws -> [GlobalSObject] {
        let json = try await get("\(path(api))/sobjects")
        return (json["sobjects"]?.array ?? []).compactMap { $0.object.map(GlobalSObject.init) }
    }

    func describe(_ sobject: String, api: SalesforceAPI = .data) async throws -> SObjectDescribe {
        let json = try await get("\(path(api))/sobjects/\(Self.pathEncoded(sobject))/describe")
        guard let obj = json.object else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Unexpected describe response for \(sobject)")
        }
        return SObjectDescribe(json: obj)
    }

    /// The most SObjects `describe(batch:)` takes at once: the composite API's limit on subrequests.
    static let describeBatchLimit = 25

    /// Describes several SObjects in one request with the composite API, which counts as a single
    /// API call. (The composite batch API counts each subrequest as a call.) Returns the
    /// describes, and the names that Salesforce couldn't describe.
    func describe(batch sobjects: [String], api: SalesforceAPI = .data) async throws -> (describes: [SObjectDescribe], failed: [String]) {
        let requests = sobjects.enumerated().map { i, name -> JSONValue in
            var request = JSONObject()
            request["method"] = .string("GET")
            request["url"] = .string("\(path(api))/sobjects/\(Self.pathEncoded(name))/describe")
            request["referenceId"] = .string("describe\(i)")
            return .object(request)
        }
        var body = JSONObject()
        body["allOrNone"] = .bool(false)
        body["compositeRequest"] = .array(requests)
        let json = try await send("POST", "\(path(api))/composite", body: .object(body))
        var describes: [SObjectDescribe] = []
        var failed: [String] = []
        let results = json["compositeResponse"]?.array ?? []
        for (i, name) in sobjects.enumerated() {
            if i < results.count, results[i]["httpStatusCode"]?.int == 200, let obj = results[i]["body"]?.object {
                describes.append(SObjectDescribe(json: obj))
            } else {
                failed.append(name)
            }
        }
        return (describes, failed)
    }

    /// Runs a SOQL query, or a SOSL search if the text starts with FIND. The Tooling API has no
    /// queryAll, so `includeDeleted` only works with the data API.
    func query(_ soql: String, includeDeleted: Bool = false, api: SalesforceAPI = .data) async throws -> QueryResult {
        let q = [URLQueryItem(name: "q", value: soql)]
        if soql.lowercased().hasPrefix("find ") {
            return QueryResult(searchResponse: try await get("\(path(api))/search", query: q))
        }
        return QueryResult(json: try await send("GET", "\(path(api))/\(includeDeleted ? "queryAll" : "query")", query: q, headers: queryHeaders))
    }

    /// Rows per batch for queries, from 200 to 2,000; nil for Salesforce's default (2,000).
    private(set) var queryBatchSize: Int?

    func setQueryBatchSize(_ size: Int?) {
        queryBatchSize = size
    }

    private var queryHeaders: [String: String] {
        queryBatchSize.map { ["Sforce-Query-Options": "batchSize=\($0)"] } ?? [:]
    }

    /// The org's limits, such as daily API requests and data storage.
    func limits() async throws -> [OrgLimit] {
        OrgLimit.limits(from: try await get("\(dataPath)/limits"))
    }

    /// The org's theme: SObject colors and icon URLs.
    func theme() async throws -> JSONValue {
        try await get("\(dataPath)/theme")
    }

    /// Asks Salesforce how it would run a query, without running it.
    func explain(_ soql: String, api: SalesforceAPI = .data) async throws -> [QueryPlan] {
        let json = try await get("\(path(api))/query", query: [URLQueryItem(name: "explain", value: soql)])
        return (json["plans"]?.array ?? []).enumerated()
            .map { QueryPlan(id: $0.offset, json: $0.element) }
            .sorted { $0.relativeCost < $1.relativeCost }
    }

    /// Fetches the next batch of a query, given the `nextRecordsUrl` of the previous batch.
    func queryMore(_ nextRecordsURL: String) async throws -> QueryResult {
        QueryResult(json: try await send("GET", nextRecordsURL, headers: queryHeaders))
    }

    // MARK: Bulk API 2.0

    /// Starts a Bulk API 2.0 query job and returns its Id.
    func startBulkQuery(_ soql: String, includeDeleted: Bool) async throws -> String {
        var body = JSONObject()
        body["operation"] = .string(includeDeleted ? "queryAll" : "query")
        body["query"] = .string(soql)
        body["contentType"] = .string("CSV")
        body["columnDelimiter"] = .string("COMMA")
        body["lineEnding"] = .string("LF")
        let json = try await send("POST", "\(dataPath)/jobs/query", body: .object(body))
        guard let id = json["id"]?.string else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Salesforce didn't return a Bulk API job Id.")
        }
        return id
    }

    /// A Bulk API 2.0 query job's state (UploadComplete, InProgress, JobComplete, Failed or
    /// Aborted), how many records it has processed, and its error message if it failed.
    func bulkQueryStatus(_ jobID: String) async throws -> (state: String, processed: Int, error: String?) {
        let json = try await send("GET", "\(dataPath)/jobs/query/\(Self.pathEncoded(jobID))")
        return (json["state"]?.string ?? "", json["numberRecordsProcessed"]?.int ?? 0, json["errorMessage"]?.string)
    }

    /// One page of a finished job's results as CSV, with its header row, and the locator for the
    /// next page (nil after the last).
    func bulkQueryResults(_ jobID: String, locator: String?, maxRecords: Int = 50_000) async throws -> (csv: Data, nextLocator: String?) {
        var query = [URLQueryItem(name: "maxRecords", value: String(maxRecords))]
        if let locator {
            query.append(URLQueryItem(name: "locator", value: locator))
        }
        let (data, response) = try await sendRaw("GET", "\(dataPath)/jobs/query/\(Self.pathEncoded(jobID))/results", query: query, accept: "text/csv")
        let next = response.value(forHTTPHeaderField: "Sforce-Locator")
        return (data, next == nil || next == "null" || next?.isEmpty == true ? nil : next)
    }

    /// Stops a Bulk API 2.0 query job, e.g. when an export fails partway.
    func abortBulkQuery(_ jobID: String) async {
        var body = JSONObject()
        body["state"] = .string("Aborted")
        _ = try? await send("PATCH", "\(dataPath)/jobs/query/\(Self.pathEncoded(jobID))", body: .object(body))
    }

    /// Creates a record and returns its Id.
    func create(_ sobject: String, fields: JSONObject, api: SalesforceAPI = .data) async throws -> String {
        let json = try await send("POST", "\(path(api))/sobjects/\(Self.pathEncoded(sobject))", body: .object(fields))
        guard let id = json["id"]?.string else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Salesforce didn't return the new record's Id.")
        }
        return id
    }

    /// Every field of one record.
    func record(_ sobject: String, id: String, api: SalesforceAPI = .data) async throws -> JSONObject {
        let json = try await get("\(path(api))/sobjects/\(Self.pathEncoded(sobject))/\(Self.pathEncoded(id))")
        guard let object = json.object else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Unexpected response for record \(id)")
        }
        return object
    }

    /// Changes fields on a record. A null value clears the field.
    func update(_ sobject: String, id: String, fields: JSONObject, api: SalesforceAPI = .data) async throws {
        _ = try await send("PATCH", "\(path(api))/sobjects/\(Self.pathEncoded(sobject))/\(Self.pathEncoded(id))", body: .object(fields))
    }

    /// Deletes up to 200 records. Each record succeeds or fails on its own, and the results are in
    /// the same order as `ids`.
    func delete(ids: [String]) async throws -> [SaveResult] {
        let json = try await send("DELETE", "\(dataPath)/composite/sobjects", query: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "allOrNone", value: "false"),
        ])
        return (json.array ?? []).map(SaveResult.init)
    }

    /// The most records one sObject Collections request takes.
    static let saveBatchLimit = 200

    /// Inserts, updates or upserts up to 200 records with sObject Collections. Each record
    /// succeeds or fails on its own, and the results are in the same order as `records`. Upserts
    /// find existing records by `matchField`.
    func save(_ records: [JSONObject], sobject: String, operation: ImportOperation, matchField: String = "Id") async throws -> [SaveResult] {
        var attributes = JSONObject()
        attributes["type"] = .string(sobject)
        var object = JSONObject()
        object["allOrNone"] = .bool(false)
        object["records"] = .array(records.map { record in
            var typed = JSONObject()
            typed["attributes"] = .object(attributes)
            for key in record.keys { typed[key] = record[key] }
            return .object(typed)
        })
        let body = JSONValue.object(object)
        let json: JSONValue
        switch operation {
        case .insert:
            json = try await send("POST", "\(dataPath)/composite/sobjects", body: body)
        case .update:
            json = try await send("PATCH", "\(dataPath)/composite/sobjects", body: body)
        case .upsert:
            json = try await send("PATCH", "\(dataPath)/composite/sobjects/\(Self.pathEncoded(sobject))/\(Self.pathEncoded(matchField))", body: body)
        case .delete, .hardDelete:
            // Collections can't hard delete; imports send those to the Bulk API.
            return try await delete(ids: records.compactMap { $0["Id"]?.string })
        }
        return (json.array ?? []).map { json in
            var result = SaveResult(json: json)
            if operation == .insert { result.created = result.success }
            return result
        }
    }

    // MARK: Bulk API 2.0 ingest

    /// Opens a Bulk API 2.0 ingest job for CSV with LF line endings and returns its Id.
    func startIngestJob(sobject: String, operation: ImportOperation, matchField: String) async throws -> String {
        var body = JSONObject()
        body["object"] = .string(sobject)
        body["operation"] = .string(operation.rawValue)
        if operation == .upsert {
            body["externalIdFieldName"] = .string(matchField)
        }
        body["contentType"] = .string("CSV")
        body["columnDelimiter"] = .string("COMMA")
        body["lineEnding"] = .string("LF")
        let json = try await send("POST", "\(dataPath)/jobs/ingest", body: .object(body))
        guard let id = json["id"]?.string else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Salesforce didn't return a Bulk API job Id.")
        }
        return id
    }

    /// Uploads a job's CSV, then tells Salesforce to start processing it.
    func uploadIngestData(_ jobID: String, csv: Data) async throws {
        _ = try await sendRaw("PUT", "\(dataPath)/jobs/ingest/\(Self.pathEncoded(jobID))/batches", body: .csv(csv))
        try await setIngestState(jobID, "UploadComplete")
    }

    func abortIngestJob(_ jobID: String) async {
        try? await setIngestState(jobID, "Aborted")
    }

    private func setIngestState(_ jobID: String, _ state: String) async throws {
        var body = JSONObject()
        body["state"] = .string(state)
        _ = try await send("PATCH", "\(dataPath)/jobs/ingest/\(Self.pathEncoded(jobID))", body: .object(body))
    }

    /// An ingest job's state (Open, UploadComplete, InProgress, JobComplete, Failed or Aborted),
    /// the records processed and failed so far, and its error message if it failed.
    func ingestStatus(_ jobID: String) async throws -> (state: String, processed: Int, failed: Int, error: String?) {
        let json = try await send("GET", "\(dataPath)/jobs/ingest/\(Self.pathEncoded(jobID))")
        return (json["state"]?.string ?? "", json["numberRecordsProcessed"]?.int ?? 0, json["numberRecordsFailed"]?.int ?? 0, json["errorMessage"]?.string)
    }

    enum IngestResults: String {
        /// Rows that worked, with sf__Id and sf__Created columns first.
        case successful = "successfulResults"
        /// Rows that failed, with sf__Id and sf__Error columns first.
        case failed = "failedResults"
        /// Rows that weren't processed, e.g. because the job was aborted.
        case unprocessed = "unprocessedrecords"
    }

    /// One kind of a finished ingest job's results, as CSV.
    func ingestResults(_ jobID: String, _ kind: IngestResults) async throws -> Data {
        try await sendRaw("GET", "\(dataPath)/jobs/ingest/\(Self.pathEncoded(jobID))/\(kind.rawValue)", accept: "text/csv").0
    }

    // MARK: Debug logs

    /// The Id of the user this session is for.
    func currentUserID() async throws -> String {
        let username = session.username.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        guard let id = try await query("SELECT Id FROM User WHERE Username = '\(username)'").records.first?["Id"]?.string else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Couldn't find the user \(session.username).")
        }
        return id
    }

    /// The newest debug logs, of one user or of everyone.
    func apexLogs(userID: String?, limit: Int = 200) async throws -> [ApexLogEntry] {
        let filter = userID.map { " WHERE LogUserId = '\($0)'" } ?? ""
        return try await query("SELECT \(ApexLogEntry.fields) FROM ApexLog\(filter) ORDER BY StartTime DESC LIMIT \(limit)")
            .records.compactMap(ApexLogEntry.init)
    }

    /// The users who have debug logs, by name.
    func apexLogUsers() async throws -> [(id: String, name: String)] {
        try await query("SELECT LogUserId, LogUser.Name name FROM ApexLog GROUP BY LogUserId, LogUser.Name").records
            .compactMap { r in r["LogUserId"]?.string.map { ($0, r["name"]?.string ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A debug log's text.
    func apexLogBody(_ id: String) async throws -> String {
        let (data, _) = try await sendRaw("GET", "\(dataPath)/sobjects/ApexLog/\(Self.pathEncoded(id))/Body", accept: "text/plain")
        return String(decoding: data, as: UTF8.self)
    }

    /// Active users whose name or username contains some text, for choosing whom to log.
    func users(matching text: String) async throws -> [(id: String, name: String, username: String)] {
        let like = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try await query("SELECT Id, Name, Username FROM User WHERE IsActive = true AND (Name LIKE '%\(like)%' OR Username LIKE '%\(like)%') ORDER BY Name LIMIT 50")
            .records.compactMap { r in r["Id"]?.string.map { ($0, r["Name"]?.string ?? "", r["Username"]?.string ?? "") } }
    }

    /// The user's trace flag for debug logs, if there is one, active or not.
    func traceFlag(for userID: String) async throws -> TraceFlagInfo? {
        let records = try await query("SELECT Id, ExpirationDate FROM TraceFlag WHERE TracedEntityId = '\(userID)' AND LogType = 'USER_DEBUG' ORDER BY ExpirationDate DESC LIMIT 1", api: .tooling).records
        return records.first.flatMap { r in
            r["Id"]?.string.map { TraceFlagInfo(id: $0, userID: userID, expiration: r["ExpirationDate"]?.string.flatMap(SalesforceDateTime.parse)) }
        }
    }

    /// Records debug logs for a user until `until` (at most 24 hours away), at the given levels,
    /// with a debug level named SwiftSoql that this creates or updates.
    func startTraceFlag(for userID: String, until expiration: Date, levels: [ApexLogCategory: ApexLogLevel]) async throws -> TraceFlagInfo {
        var level = JSONObject()
        for category in ApexLogCategory.allCases {
            level[category.debugLevelField] = .string((levels[category] ?? category.defaultLevel).rawValue.uppercased())
        }
        for field in ["System", "Visualforce", "Wave", "Nba"] {
            level[field] = .string("INFO")
        }
        let levelID: String
        if let existing = try await query("SELECT Id FROM DebugLevel WHERE DeveloperName = 'SwiftSoql'", api: .tooling).records.first?["Id"]?.string {
            levelID = existing
            try await update("DebugLevel", id: existing, fields: level, api: .tooling)
        } else {
            level["DeveloperName"] = .string("SwiftSoql")
            level["MasterLabel"] = .string("SwiftSoql")
            levelID = try await create("DebugLevel", fields: level, api: .tooling)
        }
        var flag = JSONObject()
        flag["DebugLevelId"] = .string(levelID)
        flag["StartDate"] = .string(SalesforceDateTime.format(Date()))
        flag["ExpirationDate"] = .string(SalesforceDateTime.format(expiration))
        if let existing = try await traceFlag(for: userID) {
            try await update("TraceFlag", id: existing.id, fields: flag, api: .tooling)
            return TraceFlagInfo(id: existing.id, userID: userID, expiration: expiration)
        }
        flag["TracedEntityId"] = .string(userID)
        flag["LogType"] = .string("USER_DEBUG")
        let id = try await create("TraceFlag", fields: flag, api: .tooling)
        return TraceFlagInfo(id: id, userID: userID, expiration: expiration)
    }

    /// Stops recording debug logs by deleting the trace flag.
    func stopTraceFlag(_ id: String) async throws {
        _ = try await send("DELETE", "\(path(.tooling))/sobjects/TraceFlag/\(Self.pathEncoded(id))")
    }

    // MARK: Apex tests

    /// Every row of a query, following its later batches.
    private func allRecords(_ soql: String, api: SalesforceAPI = .data) async throws -> [JSONObject] {
        var result = try await query(soql, api: api)
        var records = result.records
        while let next = result.nextRecordsURL {
            result = try await queryMore(next)
            records += result.records
        }
        return records
    }

    /// The org's own Apex classes that have tests, leaving out managed packages' classes.
    func apexTestClasses() async throws -> [ApexTestClass] {
        try await allRecords("SELECT Id, Name, Body FROM ApexClass WHERE NamespacePrefix = null ORDER BY Name")
            .compactMap { r in
                guard let id = r["Id"]?.string, let name = r["Name"]?.string, ApexTestClass.hasTests(r["Body"]?.string ?? "") else { return nil }
                return ApexTestClass(id: id, name: name)
            }
    }

    /// Starts running the tests in some classes, or with no classes, all local tests (every
    /// test outside managed packages). Returns the run's job Id.
    func runTests(classIDs: [String]) async throws -> String {
        var body = JSONObject()
        if classIDs.isEmpty {
            body["testLevel"] = .string("RunLocalTests")
        } else {
            body["classids"] = .string(classIDs.joined(separator: ","))
        }
        guard let jobID = try await send("POST", "\(path(.tooling))/runTestsAsynchronous", body: .object(body)).string else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Salesforce didn't return the test run's job Id.")
        }
        return jobID
    }

    /// The classes of a test run and how far each has got.
    func testQueue(jobID: String) async throws -> [TestQueueItem] {
        try await allRecords("SELECT \(TestQueueItem.fields) FROM ApexTestQueueItem WHERE ParentJobId = '\(jobID)' ORDER BY ApexClass.Name")
            .compactMap(TestQueueItem.init)
    }

    /// The results of a test run's methods so far.
    func testResults(jobID: String) async throws -> [ApexTestMethodResult] {
        try await allRecords("SELECT \(ApexTestMethodResult.fields) FROM ApexTestResult WHERE AsyncApexJobId = '\(jobID)' ORDER BY ApexClass.Name, MethodName")
            .compactMap(ApexTestMethodResult.init)
    }

    /// Stops a test run's classes that haven't finished.
    func abortTests(_ items: [TestQueueItem]) async throws {
        let records = items.filter { !$0.isFinished }.map { item in
            var record = JSONObject()
            record["Id"] = .string(item.id)
            record["Status"] = .string("Aborted")
            return record
        }
        for start in stride(from: 0, to: records.count, by: Self.saveBatchLimit) {
            _ = try await save(Array(records[start..<min(start + Self.saveBatchLimit, records.count)]), sobject: "ApexTestQueueItem", operation: .update)
        }
    }

    /// The org-wide code coverage of every class and trigger, from the latest test runs.
    func codeCoverage() async throws -> [ClassCoverage] {
        try await allRecords("SELECT ApexClassOrTriggerId, ApexClassOrTrigger.Name, NumLinesCovered, NumLinesUncovered FROM ApexCodeCoverageAggregate", api: .tooling)
            .compactMap(ClassCoverage.init)
    }

    /// One class's covered and uncovered line numbers. Salesforce only returns them for a
    /// single class at a time.
    func coveredLines(classID: String) async throws -> (covered: Set<Int>, uncovered: Set<Int>) {
        let record = try await query("SELECT Coverage FROM ApexCodeCoverageAggregate WHERE ApexClassOrTriggerId = '\(classID)'", api: .tooling).records.first
        let lines = { (key: String) in Set((record?["Coverage"]?[key]?.array ?? []).compactMap(\.int)) }
        return (lines("coveredLines"), lines("uncoveredLines"))
    }

    /// A class's or trigger's Apex source.
    func apexSource(id: String) async throws -> (name: String, body: String) {
        let sobject = id.hasPrefix("01q") ? "ApexTrigger" : "ApexClass"
        guard let record = try await query("SELECT Name, Body FROM \(sobject) WHERE Id = '\(id)'").records.first else {
            throw SalesforceError(statusCode: 200, errorCode: "", message: "Couldn't find the Apex \(sobject == "ApexTrigger" ? "trigger" : "class") \(id).")
        }
        return (record["Name"]?.string ?? id, record["Body"]?.string ?? "")
    }

    /// Runs anonymous Apex and returns the outcome with its debug log.
    func executeAnonymous(_ code: String, logLevels: [ApexLogCategory: ApexLogLevel]) async throws -> ApexExecution {
        let root = try await soap("services/Soap/s/\(session.apiVersion)") { sessionID in
            AnonymousApex.request(code: code, sessionID: sessionID, logLevels: logLevels)
        }
        return try AnonymousApex.execution(from: root, code: code)
    }

    /// Restores deleted records from the Recycle Bin, up to 200 at a time, with the partner SOAP
    /// API; REST has no undelete. The results are in the same order as `ids`.
    func undelete(ids: [String]) async throws -> [SaveResult] {
        let root = try await soap("services/Soap/u/\(session.apiVersion)") { sessionID in
            SOAP.undeleteRequest(ids: ids, sessionID: sessionID)
        }
        return SOAP.undeleteResults(from: root)
    }

    /// Sends a SOAP request, built with the current session Id, trying once more with a fresh
    /// session if it has expired.
    private func soap(_ path: String, envelope: (String) -> String) async throws -> XMLElement {
        do {
            return try await soapOnce(path, envelope(session.accessToken))
        } catch let error as SalesforceError where error.isInvalidSession {
            session = try await reauthenticate()
            return try await soapOnce(path, envelope(session.accessToken))
        }
    }

    private func soapOnce(_ path: String, _ envelope: String) async throws -> XMLElement {
        var request = URLRequest(url: session.instanceURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope.utf8)
        let (data, response) = try await urlSession.data(for: request)
        return try SOAP.root(of: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        try await send("GET", path, query: query)
    }

    /// A request's body: JSON, or CSV for a Bulk API upload.
    private enum RequestBody {
        case json(JSONValue)
        case csv(Data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: JSONValue? = nil, headers: [String: String] = [:]) async throws -> JSONValue {
        let (data, response) = try await sendRaw(method, path, query: query, body: body.map(RequestBody.json), headers: headers)
        if data.isEmpty { return .null }
        guard let json = try? JSONValue.parse(data) else {
            throw SalesforceError(statusCode: response.statusCode, errorCode: "", message: "Salesforce returned a response that isn't valid JSON.")
        }
        return json
    }

    /// Sends a request and returns the body as it came, trying once more with a fresh session if
    /// the old one has expired. Throws for responses other than 2xx.
    private func sendRaw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: RequestBody? = nil, headers: [String: String] = [:], accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        do {
            return try await sendOnce(method, path, query: query, body: body, headers: headers, accept: accept)
        } catch let error as SalesforceError where error.isInvalidSession {
            session = try await reauthenticate()
            return try await sendOnce(method, path, query: query, body: body, headers: headers, accept: accept)
        }
    }

    private static func pathEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    private func sendOnce(_ method: String, _ path: String, query: [URLQueryItem], body: RequestBody?, headers: [String: String], accept: String) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: session.instanceURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        // SOQL can contain '+', which URLComponents leaves alone but servers decode as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        switch body {
        case .json(let json)?:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(json.serialized.utf8)
        case .csv(let data)?:
            request.setValue("text/csv", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        case nil:
            break
        }

        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        if let limitInfo = http?.value(forHTTPHeaderField: "Sforce-Limit-Info"),
           let usage = limitInfo.split(separator: ",").first(where: { $0.hasPrefix("api-usage=") }) {
            apiUsage = String(usage.dropFirst("api-usage=".count))
        }
        guard let http else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(from: try? JSONValue.parse(data), status: http.statusCode, data: data)
        }
        return (data, http)
    }

    private static func error(from json: JSONValue?, status: Int, data: Data) -> SalesforceError {
        // Errors are usually [{"message": "...", "errorCode": "..."}].
        let first = json?.array?.first ?? json
        if let message = first?["message"]?.string {
            return SalesforceError(statusCode: status, errorCode: first?["errorCode"]?.string ?? "", message: message)
        }
        let body = String(decoding: data.prefix(500), as: UTF8.self)
        return SalesforceError(statusCode: status, errorCode: "HTTP \(status)", message: body.isEmpty ? "HTTP \(status)" : body)
    }
}

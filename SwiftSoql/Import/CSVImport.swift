import Foundation
import Observation

/// One CSV import: the file, how its columns map onto an SObject's fields, and its progress and
/// outcome. Up to the Bulk API threshold, rows go to Salesforce in batches of up to 200 with
/// sObject Collections; larger files are one Bulk API 2.0 ingest job, unless a smaller batch size
/// is chosen, which only Collections can honor.
@Observable
final class CSVImport: Identifiable {
    let id = UUID()
    let file: ImportFile
    @ObservationIgnored private let client: SalesforceClient
    @ObservationIgnored private let schema: SchemaCatalog
    /// Called after API calls, so the window can show the org's API usage.
    @ObservationIgnored var didCallAPI: () async -> Void = {}

    var sobject: String
    var operation: ImportOperation
    var matchField = "Id"
    var mapping: ImportMapping
    var clearEmpty = false
    /// Rows per Collections request, from 1 to 200; remembered as the default for later imports.
    var batchSize = min(max(AppDefaults.store.integer(forKey: "importBatchSize"), 1), SalesforceClient.saveBatchLimit) {
        didSet { AppDefaults.store.set(batchSize, forKey: "importBatchSize") }
    }
    /// The SObject's describe, once it has loaded.
    private(set) var describe: SObjectDescribe?
    private(set) var describeError: String?

    enum Phase {
        case editing
        case running(status: String, fraction: Double?)
        case finished(ImportOutcome, stopped: Bool)
        case failed(String)
    }
    private(set) var phase = Phase.editing
    @ObservationIgnored private var task: Task<Void, Never>?

    init(file: ImportFile, sobject: String, client: SalesforceClient, schema: SchemaCatalog) {
        self.file = file
        self.sobject = sobject
        self.client = client
        self.schema = schema
        operation = file.header.contains { $0.caseInsensitiveCompare("Id") == .orderedSame } ? .update : .insert
        mapping = ImportMapping(fields: file.header.map { _ in nil })
    }

    /// Whether the import runs as a Bulk API job: always for Hard Delete, and for large files
    /// unless a batch size under 200 asks for smaller transactions than Bulk API jobs use.
    var usesBulkAPI: Bool {
        operation == .hardDelete || (file.rows.count > ExplorerModel.bulkExportThreshold && batchSize >= SalesforceClient.saveBatchLimit)
    }

    /// The requests a Collections import makes.
    var requestCount: Int { (file.rows.count + batchSize - 1) / max(batchSize, 1) }

    var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    /// The plan for the current choices, once the SObject is described.
    var plan: ImportPlan? {
        describe.map { ImportPlan(describe: $0, operation: operation, matchField: matchField, mapping: mapping, clearEmpty: clearEmpty) }
    }

    /// Describes the chosen SObject and maps the columns: as last time for files with the same
    /// columns, or by matching names.
    func prepare() async {
        describe = nil
        describeError = nil
        guard !sobject.isEmpty else { return }
        do {
            let describe = try await schema.describe(sobject)
            let allowed = Set(ImportPlan.mappableFields(describe, operation: operation).map(\.name))
            mapping = ImportMapping.remembered(sobject: describe.name, header: file.header, allowed: allowed, store: AppDefaults.store)
                ?? ImportMapping.automatic(header: file.header, fields: ImportPlan.mappableFields(describe, operation: operation))
            if !ImportPlan.matchFields(describe).contains(matchField) {
                matchField = "Id"
            }
            self.describe = describe
        } catch {
            describeError = error.localizedDescription
        }
    }

    /// After the operation changes, drops mappings to fields it can't set and maps columns that
    /// now match a field.
    func operationChanged() {
        guard let describe else { return }
        let fields = ImportPlan.mappableFields(describe, operation: operation)
        let allowed = Set(fields.map(\.name))
        let automatic = ImportMapping.automatic(header: file.header, fields: fields)
        mapping.fields = zip(mapping.fields, automatic.fields).map { current, suggested in
            current.flatMap { allowed.contains($0) ? $0 : nil } ?? suggested
        }
    }

    func start() {
        guard let plan, plan.problem == nil, case .editing = phase else { return }
        plan.mapping.remember(sobject: plan.describe.name, header: file.header, store: AppDefaults.store)
        phase = .running(status: "Starting…", fraction: 0)
        task = Task {
            do {
                if usesBulkAPI {
                    let (outcome, stopped) = try await bulkImport(plan)
                    phase = .finished(outcome, stopped: stopped)
                } else {
                    let (outcome, stopped) = await collectionsImport(plan)
                    phase = .finished(outcome, stopped: stopped)
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
            await didCallAPI()
        }
    }

    /// Stops the import after the rows already sent.
    func stop() {
        task?.cancel()
    }

    private func collectionsImport(_ plan: ImportPlan) async -> (ImportOutcome, stopped: Bool) {
        var outcome = ImportOutcome(header: file.header)
        let rows = file.rows
        var start = 0
        while start < rows.count, !Task.isCancelled {
            let end = min(start + batchSize, rows.count)
            phase = .running(status: "Importing rows \((start + 1).formatted())–\(end.formatted()) of \(rows.count.formatted())…", fraction: Double(start) / Double(rows.count))
            var results: [Int: (id: String?, created: Bool, error: String?)] = [:]
            var records: [JSONObject] = []
            var sent: [Int] = []
            for i in start..<end {
                do {
                    records.append(try plan.record(rows[i]))
                    sent.append(i)
                } catch {
                    results[i] = (nil, false, error.localizedDescription)
                }
            }
            if !records.isEmpty {
                do {
                    let saved = try await client.save(records, sobject: plan.describe.name, operation: plan.operation, matchField: plan.matchField)
                    for (i, result) in zip(sent, saved) {
                        results[i] = (result.id, result.created, result.success ? nil : result.message)
                    }
                } catch {
                    for i in sent { results[i] = (nil, false, error.localizedDescription) }
                }
            }
            for i in start..<end {
                let result = results[i] ?? (nil, false, "Salesforce didn't report on this row.")
                outcome.add(rows[i], row: i + 1, id: result.id, created: result.created, error: result.error)
            }
            start = end
        }
        for i in start..<rows.count {
            outcome.add(rows[i], row: i + 1, id: nil, created: false, error: "Not imported: the import was stopped.")
        }
        return (outcome, start < rows.count)
    }

    struct TooLarge: LocalizedError {
        var errorDescription: String? { "The upload would be over the Bulk API's 100 MB limit. Split the file and import each part." }
    }

    private func bulkImport(_ plan: ImportPlan) async throws -> (ImportOutcome, stopped: Bool) {
        // Rows that can't be converted are reported without being sent.
        var outcome = ImportOutcome(header: plan.uploadHeader)
        var csv = CSV.line(plan.uploadHeader, lineEnding: "\n")
        var invalid: [(row: Int, error: String)] = []
        for (i, row) in file.rows.enumerated() {
            do {
                csv += CSV.line(try plan.uploadValues(row), lineEnding: "\n")
            } catch {
                invalid.append((i, error.localizedDescription))
            }
        }
        let data = Data(csv.utf8)
        guard data.count < 100_000_000 else { throw TooLarge() }

        phase = .running(status: "Starting a Bulk API job…", fraction: nil)
        let job = try await client.startIngestJob(sobject: plan.describe.name, operation: plan.operation, matchField: plan.matchField)
        var stopped = false
        do {
            phase = .running(status: "Uploading \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))…", fraction: nil)
            try await client.uploadIngestData(job, csv: data)
            let total = file.rows.count - invalid.count
            while true {
                let status = try await client.ingestStatus(job)
                if status.state == "JobComplete" { break }
                if status.state == "Failed" || status.state == "Aborted" {
                    throw SalesforceError(statusCode: 200, errorCode: "", message: "The Bulk API job \(status.state.lowercased()): \(status.error ?? "no reason given").")
                }
                phase = .running(status: "Salesforce has processed \(status.processed.formatted()) of \(total.formatted()) rows…", fraction: Double(status.processed) / Double(max(total, 1)))
                try await Task.sleep(for: .seconds(2))
            }
        } catch where Task.isCancelled {
            await client.abortIngestJob(job)
            stopped = true
        } catch {
            await client.abortIngestJob(job)
            throw error
        }

        phase = .running(status: "Downloading the results…", fraction: nil)
        let header = plan.uploadHeader
        func values(_ row: [String], _ columns: [String]) -> [String] {
            header.map { name in columns.firstIndex(of: name).map { $0 < row.count ? row[$0] : "" } ?? "" }
        }
        for kind in [SalesforceClient.IngestResults.successful, .failed, .unprocessed] {
            let rows = CSV.rows(String(decoding: try await client.ingestResults(job, kind), as: UTF8.self))
            guard let columns = rows.first else { continue }
            let idIndex = columns.firstIndex(of: "sf__Id")
            let createdIndex = columns.firstIndex(of: "sf__Created")
            let errorIndex = columns.firstIndex(of: "sf__Error")
            for row in rows.dropFirst() {
                let field = { (index: Int?) in index.flatMap { $0 < row.count ? row[$0] : nil } }
                let error: String? = switch kind {
                case .successful: nil
                case .failed: field(errorIndex) ?? "Failed"
                case .unprocessed: "Not imported: the import was stopped."
                }
                outcome.add(values(row, columns), row: nil, id: field(idIndex).flatMap { $0.isEmpty ? nil : $0 },
                            created: field(createdIndex) == "true", error: error)
            }
        }
        for (i, error) in invalid {
            let mapped = plan.mapping.fields.enumerated().compactMap { index, field in field == nil ? nil : file.rows[i][index] }
            outcome.add(mapped, row: i + 1, id: nil, created: false, error: error)
        }
        return (outcome, stopped)
    }
}

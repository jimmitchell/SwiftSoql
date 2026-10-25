import Foundation

/// Writes every row of a query to a CSV file, without loading them into a results table: page by
/// page through the query's remaining batches, or as a Bulk API job.
struct CSVExporter {
    let client: SalesforceClient
    /// Called with a description of how far the export has got.
    let progress: (String) -> Void

    /// The Bulk API job couldn't start or run, so the export should page through the results instead.
    struct BulkJobUnavailable: Error {
        let message: String
    }

    /// Writes the rows already loaded, then fetches and writes the rest. Returns the rows written.
    func paged(_ results: ResultSet, to url: URL) async throws -> Int {
        let file = try Self.createFile(at: url)
        defer { try? file.close() }
        let columns = results.columns
        try file.write(contentsOf: Data((ResultsExport.csvHeader(columns) + results.rows.map { ResultsExport.csvLine($0.record, columns: columns) }.joined()).utf8))
        var rows = results.rows.count
        var next = results.nextRecordsURL
        while let url = next {
            progress("Exporting \(rows.formatted()) of \(results.totalSize.formatted()) rows…")
            let batch = try await client.queryMore(url)
            try file.write(contentsOf: Data(batch.records.map { ResultsExport.csvLine($0, columns: columns) }.joined().utf8))
            rows += batch.records.count
            next = batch.nextRecordsURL
        }
        return rows
    }

    /// Runs the query as a Bulk API job and writes its results. Throws `BulkJobUnavailable` if the
    /// job can't start or fails, before anything is written.
    func bulk(_ query: String, includeDeleted: Bool, to url: URL) async throws -> Int {
        progress("Starting a Bulk API job…")
        let jobID: String
        do {
            jobID = try await client.startBulkQuery(query, includeDeleted: includeDeleted)
        } catch {
            throw BulkJobUnavailable(message: error.localizedDescription)
        }
        while true {
            let status = try await client.bulkQueryStatus(jobID)
            switch status.state {
            case "JobComplete":
                break
            case "Failed", "Aborted":
                throw BulkJobUnavailable(message: status.error ?? "the job \(status.state.lowercased())")
            default:
                progress("Salesforce is preparing the export (\(status.processed.formatted()) rows so far)…")
                try await Task.sleep(for: .seconds(2))
                continue
            }
            break
        }
        let file = try Self.createFile(at: url)
        defer { try? file.close() }
        var rows = 0
        var locator: String?
        var first = true
        repeat {
            progress("Downloading \(rows.formatted()) rows…")
            let page = try await client.bulkQueryResults(jobID, locator: locator)
            let converted = ResultsExport.bulkCSV(page.csv, includeHeader: first)
            try file.write(contentsOf: Data(converted.text.utf8))
            rows += converted.records
            locator = page.nextLocator
            first = false
        } while locator != nil
        return rows
    }

    private static func createFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return try FileHandle(forWritingTo: url)
    }
}

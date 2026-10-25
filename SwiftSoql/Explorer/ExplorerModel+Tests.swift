import Foundation

/// The Tests workspace's actions, reporting failures in an alert. Test data rolls back, so
/// tests run in locked windows too.
extension ExplorerModel {
    func loadTestClasses() async {
        guard let client else { return }
        do {
            try await tests.loadClasses(using: client)
            try await tests.loadCoverage(using: client)
        } catch {
            self.error = DisplayedError("Unable to list the test classes", error)
        }
        await refreshAPIUsage()
    }

    /// Runs the checked test classes, or every local test.
    func runTests(allLocal: Bool) async {
        guard let client else { return }
        do {
            try await tests.run(allLocal: allLocal, using: client) { [weak self] in await self?.refreshAPIUsage() }
        } catch is CancellationError {
        } catch {
            self.error = DisplayedError("Unable to run the tests", error)
        }
        await refreshAPIUsage()
    }

    func stopTests() async {
        guard let client else { return }
        do {
            try await tests.stop(using: client)
        } catch {
            self.error = DisplayedError("Unable to stop the tests", error)
        }
    }

    func openApexSource(classID: String, line: Int? = nil) async {
        guard let client else { return }
        do {
            try await tests.openSource(classID: classID, line: line, using: client)
        } catch {
            self.error = DisplayedError("Unable to open the class", error)
        }
        await refreshAPIUsage()
    }
}

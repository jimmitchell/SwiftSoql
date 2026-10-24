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
        statusText = ""
        apiUsage = nil
    }

    func refreshAPIUsage() async {
        apiUsage = await client?.apiUsage
    }
}

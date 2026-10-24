import SwiftUI

/// Lists the orgs the Salesforce CLI is logged in to, and connects to the chosen one.
struct LoginView: View {
    let model: ExplorerModel

    @State private var orgs: [SFOrg] = []
    @State private var selection: SFOrg.ID?
    @State private var isLoading = false
    @State private var loadError: String?
    @AppStorage("lastOrgUsername") private var lastOrgUsername = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Salesforce")
                    .font(.title2.weight(.semibold))
                Text("Choose an org you've logged in to with the Salesforce CLI.")
                    .foregroundStyle(.secondary)
            }

            Table(orgs, selection: $selection) {
                TableColumn("Alias") { org in
                    Text(org.alias ?? "")
                        .fontWeight(org.isDefault ? .semibold : .regular)
                }
                .width(min: 80, ideal: 140)
                TableColumn("Username", value: \.username)
                    .width(min: 160, ideal: 240)
                TableColumn("Instance") { org in
                    Text(URL(string: org.instanceURL)?.host() ?? org.instanceURL)
                }
                .width(min: 120, ideal: 220)
                TableColumn("Type", value: \.kind)
                    .width(min: 50, ideal: 70)
                TableColumn("Status") { org in
                    Label(org.connectedStatus, systemImage: org.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(org.isConnected ? Color.green : Color.orange)
                }
                .width(min: 80, ideal: 110)
            }
            .contextMenu(forSelectionType: SFOrg.ID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first { connect(id) }
            }
            .overlay {
                if isLoading && orgs.isEmpty {
                    ProgressView("Asking the Salesforce CLI for your orgs…")
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't list orgs", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError).textSelection(.enabled)
                    }
                } else if orgs.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("No orgs", systemImage: "cloud")
                    } description: {
                        Text("Log in to an org with `sf org login web --alias my-org`, then refresh.")
                    }
                }
            }

            HStack {
                Button {
                    Task { await loadOrgs() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || model.isConnecting)

                if model.isConnecting {
                    ProgressView().controlSize(.small)
                    Text(model.statusText).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect") {
                    if let selection { connect(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || model.isConnecting)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 360)
        .task {
            await loadOrgs()
            connectFromLaunchArgument()
        }
    }

    /// `-connect <alias or username>` on the command line connects the first window straight away,
    /// and `-query <soql>` then runs a query, `-executeApex <code>` runs anonymous Apex, `-explainQuery <soql>` shows a query plan, `-formatQuery YES`
    /// formats the query, and
    /// `-showSchema <sobject>` shows its schema diagram.
    private static var launchArgumentHandled = false

    private func connectFromLaunchArgument() {
        let defaults = AppDefaults.store
        guard !Self.launchArgumentHandled, let target = defaults.string(forKey: "connect") else { return }
        Self.launchArgumentHandled = true
        guard let org = orgs.first(where: { $0.alias == target || $0.username == target }) else { return }
        selection = org.id
        Task {
            await model.connect(to: org)
            if model.isConnected, let query = defaults.string(forKey: "query") {
                model.soql = query
                await model.runQuery()
            }
            if model.isConnected, defaults.bool(forKey: "formatQuery") {
                model.formatQuery()
            }
            if model.isConnected, let query = defaults.string(forKey: "explainQuery") {
                model.soql = query
                await model.explainQuery()
            }
            if model.isConnected, let sobject = defaults.string(forKey: "showSchema") {
                model.workspace = .schema
                model.schemaSelection = .sobject(sobject)
            }
            if model.isConnected, let apex = defaults.string(forKey: "executeApex") {
                model.workspace = .apex
                model.apex.code = apex
                await model.executeApex()
            }
        }
    }

    private func loadOrgs() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            orgs = try await SFCLI.listOrgs()
            if selection == nil || !orgs.contains(where: { $0.id == selection }) {
                selection = orgs.first(where: { $0.username == lastOrgUsername })?.id
                    ?? orgs.first(where: \.isDefault)?.id
                    ?? orgs.first?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func connect(_ id: SFOrg.ID) {
        guard let org = orgs.first(where: { $0.id == id }), !model.isConnecting else { return }
        Task { await model.connect(to: org) }
    }
}

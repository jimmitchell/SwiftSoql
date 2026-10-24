import SwiftUI

/// Lists the orgs the Salesforce CLI is logged in to, and connects to the chosen one.
struct LoginView: View {
    let model: ExplorerModel

    @State private var orgs: [SFOrg] = []
    @State private var selection: SFOrg.ID?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isLoggingIn = false
    @AppStorage("lastOrgUsername") private var lastOrgUsername = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to Salesforce")
                    .font(.title2.weight(.semibold))
                Text("Choose an org you've logged in to with the Salesforce CLI or in the browser, or log in to another.")
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
            .contextMenu(forSelectionType: SFOrg.ID.self) { ids in
                if let org = orgs.first(where: { ids.contains($0.id) }), org.isBrowserLogin {
                    Button("Remove Saved Login") {
                        BrowserLogin.remove(org.username)
                        Task { await loadOrgs() }
                    }
                }
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
                Button("Log In with Browser…") { isLoggingIn = true }
                    .disabled(model.isConnecting)
                Button("Connect") {
                    if let selection { connect(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || model.isConnecting)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 360)
        .sheet(isPresented: $isLoggingIn) {
            BrowserLoginSheet { login in
                Task {
                    await loadOrgs()
                    selection = login.username
                    connect(login.username)
                }
            }
        }
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
            let browserOrgs = BrowserLogin.savedLogins.map { login in
                SFOrg(username: login.username, alias: nil, instanceURL: login.instanceURL, connectedStatus: "Saved login",
                      kind: login.loginHost == "test.salesforce.com" ? "Sandbox" : "Browser", isDefault: false, isBrowserLogin: true)
            }
            // The CLI might not be installed if all the orgs are browser logins.
            let cliOrgs: [SFOrg]
            do {
                cliOrgs = try await SFCLI.listOrgs()
            } catch where !browserOrgs.isEmpty {
                cliOrgs = []
            }
            let cliNames = Set(cliOrgs.map(\.username))
            orgs = cliOrgs + browserOrgs.filter { !cliNames.contains($0.username) }
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

/// Asks which Salesforce login page and which org's consumer key to use, then logs in there in
/// the browser. A new key can be entered here and is remembered for next time.
private struct BrowserLoginSheet: View {
    let onLogin: (BrowserLogin.SavedLogin) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "production"
    @State private var domain = ""
    @State private var keys = BrowserLogin.consumerKeys
    /// The chosen key's id, or nil to enter a new one.
    @State private var keyID: UUID?
    @State private var newLabel = ""
    @State private var newKey = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var host: String {
        switch kind {
        case "sandbox": "test.salesforce.com"
        case "domain": BrowserLogin.normalizedHost(domain)
        default: "login.salesforce.com"
        }
    }

    private var chosenKey: BrowserLogin.ConsumerKey? {
        if let keyID { return keys.first { $0.id == keyID } }
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        return BrowserLogin.ConsumerKey(label: label.isEmpty ? host : label, key: key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log In with Browser").font(.headline)
            Picker("Log in to", selection: $kind) {
                Text("Production or Developer Edition").tag("production")
                Text("Sandbox").tag("sandbox")
                Text("My Domain").tag("domain")
            }
            .pickerStyle(.radioGroup)
            if kind == "domain" {
                TextField("mycompany.my.salesforce.com", text: $domain)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()
            if !keys.isEmpty {
                Picker("Consumer key", selection: $keyID) {
                    ForEach(keys) { key in
                        Text(key.label).tag(Optional(key.id))
                    }
                    Divider()
                    Text("New Key…").tag(UUID?.none)
                }
            }
            if keyID == nil {
                TextField("Label, such as the org's name", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                TextField("Consumer key", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Link("How to create the External Client App and find its key",
                     destination: URL(string: "https://github.com/jimmitchell/SwiftSoql#logging-in-with-the-browser")!)
                    .font(.callout)
            }
            Text("Use the key of the External Client App in the org you're logging in to. Salesforce's login page opens in a browser window, and SwiftSoql keeps the login in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Log In") { logIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || chosenKey == nil || (kind == "domain" && host.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: suggestKey)
        .onChange(of: host) { suggestKey() }
    }

    /// Picks the key last used with this login page, or else the first one.
    private func suggestKey() {
        keyID = (BrowserLogin.lastKey(for: host) ?? keys.first)?.id
    }

    private func logIn() {
        guard let key = chosenKey else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let login = try await BrowserLogin.logIn(host: host, key: key)
                dismiss()
                onLogin(login)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

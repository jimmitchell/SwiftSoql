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

/// Asks which Salesforce login page to use, then logs in there in the browser.
private struct BrowserLoginSheet: View {
    let onLogin: (BrowserLogin.SavedLogin) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "production"
    @State private var domain = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var host: String {
        switch kind {
        case "sandbox": "test.salesforce.com"
        case "domain": BrowserLogin.normalizedHost(domain)
        default: "login.salesforce.com"
        }
    }

    var body: some View {
        if BrowserLogin.consumerKey == nil {
            needsKey
        } else {
            form
        }
    }

    /// Browser login needs the consumer key of an External Client App in the user's org.
    private var needsKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log In with Browser").font(.headline)
            Text("To log in without the Salesforce CLI, SwiftSoql needs the consumer key of an External Client App in your org. An admin creates one in Setup, then you add its key in SwiftSoql's Settings.")
                .fixedSize(horizontal: false, vertical: true)
            Link("How to create the External Client App", destination: URL(string: "https://github.com/jimmitchell/SwiftSoql#logging-in-with-the-browser")!)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                SettingsLink {
                    Text("Open Settings…")
                }
                .keyboardShortcut(.defaultAction)
                .simultaneousGesture(TapGesture().onEnded { dismiss() })
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var form: some View {
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
            Text("Salesforce's login page opens in a browser window. SwiftSoql keeps the login in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Log In") {
                    isWorking = true
                    errorMessage = nil
                    Task {
                        defer { isWorking = false }
                        do {
                            let login = try await BrowserLogin.logIn(host: host)
                            dismiss()
                            onLogin(login)
                        } catch is CancellationError {
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || (kind == "domain" && host.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

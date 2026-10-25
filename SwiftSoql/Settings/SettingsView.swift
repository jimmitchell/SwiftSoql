import SwiftUI

/// The Settings window: General, Editor, Data and Login tabs, remembering the last one shown.
struct SettingsView: View {
    enum Tab: String {
        case general, editor, data, login
    }

    @AppStorage("settingsTab") private var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            EditorSettings()
                .tabItem { Label("Editor", systemImage: "pencil") }
                .tag(Tab.editor)
            DataSettings()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
                .tag(Tab.data)
            LoginSettings()
                .tabItem { Label("Login", systemImage: "key") }
                .tag(Tab.login)
        }
        .frame(width: 500)
    }
}

/// An explanation under a setting.
private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage("lockDeveloperEditionOrgs") private var lockDeveloperEditionOrgs = false
    @AppStorage("describeAllInBackground") private var describeAllInBackground = true
    @AppStorage("maxRecentQueries") private var maxRecentQueries = 25

    var body: some View {
        Form {
            Section("Production Orgs") {
                Toggle("Open Developer Edition orgs read-only too", isOn: $lockDeveloperEditionOrgs)
                Note("Windows connected to production orgs open read-only: no edits, new records, deletes, imports or anonymous Apex until you click the padlock in the toolbar. Takes effect the next time you connect.")
            }
            Section("Schema") {
                Toggle("Describe every SObject after connecting", isOn: $describeAllInBackground)
                Note("Lets the sidebar filter find fields in every SObject, at the cost of about one API request per 25 SObjects. Takes effect the next time you connect.")
            }
            Section("Recent Queries") {
                Stepper("Remember the last \(maxRecentQueries) queries for each org", value: $maxRecentQueries, in: 5...200, step: 5)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

private struct EditorSettings: View {
    @AppStorage("soqlSyntaxHighlighting") private var syntaxHighlighting = true
    @AppStorage("soqlPopupCompletions") private var popupCompletions = true
    @AppStorage("soqlUppercaseKeywords") private var uppercaseKeywords = true
    @AppStorage("sortFieldsInGeneratedQueries") private var sortGeneratedFields = true
    @AppStorage("skipCompoundFieldsInGeneratedQueries") private var skipCompoundFields = false

    var body: some View {
        Form {
            Section("Query Editor") {
                Toggle("Highlight syntax and check queries", isOn: $syntaxHighlighting)
                Toggle("Show completions while typing", isOn: $popupCompletions)
                    .disabled(!syntaxHighlighting)
                Toggle("Make keywords uppercase", isOn: $uppercaseKeywords)
                    .disabled(!syntaxHighlighting)
            }
            Section("Generated Queries") {
                Toggle("Sort fields alphabetically", isOn: $sortGeneratedFields)
                Toggle("Use address parts instead of compound address fields", isOn: $skipCompoundFields)
                Note("Applies to queries built by double-clicking an SObject or field in the sidebar.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

private struct DataSettings: View {
    /// 0 means Salesforce's default of 2,000 rows.
    @AppStorage("queryBatchSize") private var queryBatchSize = 0
    @AppStorage("tableRowLimit") private var tableRowLimit = 50_000
    @AppStorage("bulkExportThreshold") private var bulkThreshold = 10_000
    @AppStorage("importBatchSize") private var importBatchSize = 200

    var body: some View {
        Form {
            Section("Queries") {
                Picker("Rows per batch", selection: $queryBatchSize) {
                    Text("Salesforce default (2,000)").tag(0)
                    ForEach([200, 500, 1_000], id: \.self) { Text($0.formatted()).tag($0) }
                }
                Note("How many rows each request fetches, for the first rows and each Load More. Smaller batches arrive sooner, which helps with wide queries. Takes effect the next time you connect.")
                Picker("Rows in the results table", selection: $tableRowLimit) {
                    ForEach([10_000, 25_000, 50_000, 100_000, 200_000], id: \.self) { Text("Up to \($0.formatted())").tag($0) }
                }
                Note("The table stops loading at this many rows; Export writes every row. More rows take more memory.")
            }
            Section("Bulk API") {
                Picker("Use the Bulk API above", selection: $bulkThreshold) {
                    ForEach([2_000, 5_000, 10_000, 25_000, 50_000], id: \.self) { Text("\($0.formatted()) rows").tag($0) }
                }
                Note("Larger exports and imports run as Bulk API jobs, which take far fewer API requests.")
            }
            Section("Imports") {
                Stepper(value: $importBatchSize, in: 1...200) {
                    LabeledContent("Rows per request", value: importBatchSize.formatted())
                }
                Note("Each request is one transaction, so triggers and flows run on these rows together. If an import fails with errors like \"Apex CPU time limit exceeded\" or \"Too many SOQL queries\", try a smaller batch. Imports with a batch under 200 don't use the Bulk API (except Hard Delete, which needs it), so they take more requests. The import sheet changes this too.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

private struct LoginSettings: View {
    @State private var consumerKeys = BrowserLogin.consumerKeys

    var body: some View {
        Form {
            Section("Browser Login") {
                Note("Logging in with the browser needs an External Client App in each org, with the callback URL swiftsoql://oauth/callback. Keep a key for each org you work in; keys added when logging in appear here too. The Salesforce CLI's orgs work without any of this.")
                ForEach($consumerKeys) { $key in
                    HStack {
                        TextField("Label", text: $key.label)
                            .frame(width: 130)
                        TextField("Consumer key", text: $key.key)
                            .font(.system(.body, design: .monospaced))
                        Button {
                            consumerKeys.removeAll { $0.id == key.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this key")
                        .accessibilityLabel("Remove \(key.label)")
                    }
                    .labelsHidden()
                }
                HStack {
                    Button("Add Key") {
                        consumerKeys.append(BrowserLogin.ConsumerKey(label: "", key: ""))
                    }
                    Spacer()
                    Link("How to create the External Client App", destination: URL(string: "https://github.com/jimmitchell/SwiftSoql#logging-in-with-the-browser")!)
                        .font(.caption)
                }
            }
            .onChange(of: consumerKeys) { BrowserLogin.consumerKeys = consumerKeys }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
    }
}

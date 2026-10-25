# SwiftSoql

A Mac app for exploring Salesforce orgs, written in SwiftUI. It's a port of Simon Fell's
[SoqlXplorer](https://github.com/superfell/SoqlX), with some additions.

- **Queries:** SOQL and SOSL with syntax coloring, error checking against your org's schema, and
  completions; tabs, each on the data API or the Tooling API (⌃⌘T); query plans; formatting; recent and pinned queries.
- **Results:** filter the loaded rows as you type, hide and reorder columns, sort, edit in place (checkboxes, picklist menus, date pickers), create and clone
  records (⌃⌘N, or right-click a row), delete and restore
  records, open them in Salesforce, view them as JSON, and export to CSV or JSON (large CSV
  exports use the Bulk API).
- **Record inspector:** the inspector's Record tab shows every field of the selected row's
  record, with labels; edit fields there, and follow lookups to related records.
- **Production guard:** each window shows what kind of org it's connected to (production,
  sandbox, Developer Edition, scratch or trial). Production windows open read-only, with no edits,
  deletes, imports or anonymous Apex until you click the padlock in the toolbar.
- **Import:** insert, update, upsert, delete or hard delete records from a CSV file (File ▸ Import CSV…, ⇧⌘I).
  Columns are matched to fields by name or label, and the mapping is remembered. Files of up to
  10,000 rows go 200 at a time; larger ones use a Bulk API job. Save Results writes each row
  with its Id and any error, so failed rows can be fixed and imported again.
- **Schema:** browse every SObject and field, see their details, explore relationships in a
  diagram, and export a data dictionary of chosen SObjects as CSV or Markdown (File ▸ Export
  Data Dictionary…).
- **Org limits:** Query ▸ Org Limits… (⇧⌘L), or click the API counter, to see every limit, most
  used first.
- **Debug logs:** the Logs workspace (⌘4) lists your logs, everyone's or one user's, shows a
  log with filters, starts and stops logging for you or another user, follows new logs, and
  deletes them.
- **Apex tests:** the Tests workspace (⌘5) lists the org's own test classes; run the checked ones
  or all local tests, see each method's result with links from stack traces into the class, and
  see code coverage per class, with a class's covered and uncovered lines highlighted.
- **Anonymous Apex:** run all of it or just the selected lines and read the debug log, with SOQL
  checking and completions in the editor, and a library of saved snippets.

## Getting started

Download the latest release from the [Releases](https://github.com/jimmitchell/SwiftSoql/releases)
page. The app updates itself.

To connect, log in to an org with the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
(`sf org login web --alias my-org`) and pick it from the list. That's the easiest way, and works
with any org.

If you'd rather not install the CLI, you can log in with the browser instead, once your org has an
External Client App for SwiftSoql (see below).

Requires macOS 27.

## Logging in with the browser

**Log In with Browser…** signs in on Salesforce's own login page and keeps the login in your
Keychain. It needs the consumer key of an External Client App in your org, because an app created
in one org only works for logins to that org. Creating one takes a few minutes and needs
permission to customize the org (an admin can do it for you).

1. In Salesforce, go to **Setup → External Client App Manager** and click **New External Client
   App**.
2. Give it a name such as *SwiftSoql*, your email as the contact, and leave **Distribution State**
   as **Local**.
3. Under **API (Enable OAuth Settings)**, check **Enable OAuth** and set:
   - **Callback URL:** `swiftsoql://oauth/callback`
   - **OAuth Scopes:** *Manage user data via APIs (api)* and *Perform requests at any time
     (refresh_token, offline_access)*
   - **Require Proof Key for Code Exchange (PKCE)** checked
   - **Require secret for Web Server Flow** and **Require secret for Refresh Token Flow**
     unchecked, since SwiftSoql uses PKCE and has no secret
4. Click **Create**. On the app's **Policies** tab, make sure the people who'll use SwiftSoql are
   allowed to use it (for example, **Permitted Users: All users may self-authorize**).
5. On the **Settings** tab, open **OAuth Settings → Consumer Key and Secret** and copy the
   **Consumer Key**.
6. In SwiftSoql, choose **Log In with Browser…** on the connect screen, pick Production, Sandbox
   or your My Domain, and paste the key with a label for the org. (You can also add keys in
   **Settings → Browser Login**.)

A new app can take a few minutes before Salesforce accepts logins with it. The key isn't a
secret: with PKCE, it only identifies the app.

**Working in several orgs?** Each org needs its own External Client App and key. Add each key with
a label (such as the org's name) in **Settings → Browser Login**, or enter it in the login window
the first time you log in to that org. The login window suggests the key you last used with each
login page, and every saved login keeps the key it was made with, so reconnecting always uses the
right one. (Packaging the External Client App in a managed package and installing it in each org
lets one key work everywhere, but needs a Dev Hub.)

## Building

Open `SwiftSoql.xcodeproj` in Xcode 27 and run the SwiftSoql scheme.

- **Tests:** `xcodebuild test -scheme SwiftSoql` runs the unit tests and UI tests. UI tests that need
  an org use the Salesforce CLI alias in `SWIFTSOQL_TEST_ORG` and are skipped without it; the one
  that creates and deletes a record also needs `SWIFTSOQL_TEST_WRITES=YES`.
- **Browser login:** users enter their own External Client App's consumer key in Settings. To build
  one into the app instead (for an External Client App packaged for every org), set
  `SalesforceConsumerKey` in `SwiftSoql-Info.plist`.
- **Releases:** `Scripts/release.sh <version> <build>` signs, notarizes and publishes a release and
  its Sparkle appcast; see the script for the one-time setup.

## Credits

SwiftSoql is based on SoqlXplorer and ZKParser by Simon Fell, and uses Sparkle. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

# SwiftSoql

A Mac app for exploring Salesforce orgs, written in SwiftUI. It's a port of Simon Fell's
[SoqlXplorer](https://github.com/superfell/SoqlX), with some additions.

- **Queries:** SOQL and SOSL with syntax coloring, error checking against your org's schema, and
  completions; tabs; query plans; formatting; recent and pinned queries.
- **Results:** sort, edit in place (checkboxes, picklist menus, date pickers), delete and restore
  records, open them in Salesforce, and export to CSV (large exports use the Bulk API).
- **Schema:** browse every SObject and field, see their details, and explore relationships in a
  diagram.
- **Anonymous Apex:** run it and read the debug log, with SOQL checking and completions in the
  editor.

## Getting started

Download the latest release from the [Releases](https://github.com/jimmitchell/SwiftSoql/releases)
page. The app updates itself.

To connect, log in to an org with the [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli)
(`sf org login web --alias my-org`) and pick it from the list, or use **Log In with Browser…**.

Requires macOS 27.

## Building

Open `SwiftSoql.xcodeproj` in Xcode 27 and run the SwiftSoql scheme.

- **Tests:** `xcodebuild test -scheme SwiftSoql` runs the unit tests and UI tests. UI tests that need
  an org use the Salesforce CLI alias in `SWIFTSOQL_TEST_ORG` and are skipped without it; the one
  that creates and deletes a record also needs `SWIFTSOQL_TEST_WRITES=YES`.
- **Browser login:** set `SalesforceConsumerKey` in `SwiftSoql-Info.plist` to the consumer key of a
  Salesforce External Client App with the callback URL `swiftsoql://oauth/callback`, PKCE, and the
  `api` and `refresh_token` scopes.
- **Releases:** `Scripts/release.sh <version> <build>` signs, notarizes and publishes a release and
  its Sparkle appcast; see the script for the one-time setup.

## Credits

SwiftSoql is based on SoqlXplorer and ZKParser by Simon Fell, and uses Sparkle. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

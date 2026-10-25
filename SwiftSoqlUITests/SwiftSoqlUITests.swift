import XCTest

/// Drives the app the way a person does: clicking, typing and using the menus.
///
/// Tests that need an org use the Salesforce CLI alias or username in the SWIFTSOQL_TEST_ORG
/// environment variable (set it in the scheme's Test action, or pass TEST_RUNNER_SWIFTSOQL_TEST_ORG
/// to xcodebuild) and are skipped without it. The one that creates, edits and deletes a record also
/// needs SWIFTSOQL_TEST_WRITES=YES. The app runs with -Testing, so it uses its own settings
/// store and leaves the user's settings alone.
final class SwiftSoqlUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run { app?.terminate() }
    }

    // MARK: Helpers

    private var testOrg: String? {
        ProcessInfo.processInfo.environment["SWIFTSOQL_TEST_ORG"].flatMap { $0.isEmpty ? nil : $0 }
    }

    @MainActor
    private func launch(connected: Bool = true, extraArguments: [String] = []) throws {
        var arguments = ["-Testing", "YES", "-ApplePersistenceIgnoreState", "YES", "-describeAllInBackground", "NO"]
        if connected {
            let org = try XCTUnwrap(testOrg, "Set SWIFTSOQL_TEST_ORG to run this test")
            arguments += ["-connect", org]
        }
        app = XCUIApplication()
        app.launchArguments = arguments + extraArguments
        app.launch()
        if connected {
            XCTAssertTrue(app.outlines["schemaSidebar"].waitForExistence(timeout: 60), "The app should connect and show its SObjects")
        }
    }

    @MainActor private var editor: XCUIElement { app.textViews["soqlEditor"] }
    /// SwiftUI tables appear to UI tests as outlines.
    @MainActor private var results: XCUIElement { app.outlines.matching(identifier: "results").firstMatch }

    /// Cell text is exposed as the element's value.
    @MainActor
    private func text(_ value: String, in element: XCUIElement) -> XCUIElement {
        element.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// Replaces the query editor's text.
    @MainActor
    private func setQuery(_ soql: String) {
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(soql)
    }

    @MainActor
    private func runQuery() {
        app.typeKey(.return, modifierFlags: .command)
    }

    @MainActor
    private func waitForStatus(_ prefix: String, timeout: TimeInterval = 60) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: timeout)
    }

    // MARK: Tests

    @MainActor
    func testLoginScreenListsOrgs() throws {
        try launch(connected: false)
        XCTAssertTrue(app.staticTexts["Connect to Salesforce"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Connect"].exists)
    }

    @MainActor
    func testRunQueryAndSortByColumn() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id, Name FROM User ORDER BY Name")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded"), "The query should load rows")
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        let rows = results.outlineRows
        try XCTSkipIf(rows.count < 2, "Needs at least two users to check sorting")
        let firstName = rows.element(boundBy: 0).staticTexts.element(boundBy: 1).value as? String

        // Clicking the header sorts ascending (the query's own order), again for descending.
        let header = results.buttons.matching(NSPredicate(format: "title == 'Name'")).firstMatch
        XCTAssertTrue(header.exists, "The Name column header should be clickable")
        // The column can be wider than the window, so click near the header's left end.
        let headerSpot = header.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 30, dy: 0))
        headerSpot.click()
        headerSpot.click()
        let sortedFirst = rows.element(boundBy: 0).staticTexts.element(boundBy: 1).value as? String
        XCTAssertNotEqual(firstName, sortedFirst, "Sorting descending should change the first row")
    }

    @MainActor
    func testCompletionPopupOffersSObjects() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id FROM Use")
        let completion = text("User", in: app.popovers.firstMatch)
        XCTAssertTrue(completion.waitForExistence(timeout: 5), "Pausing after a partial SObject name should offer completions")
        editor.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "SELECT Id FROM User")
    }

    @MainActor
    func testQueryTabs() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        let tabs = app.descendants(matching: .any).matching(identifier: "queryTab")
        let before = tabs.count
        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(tabs.count, before + 1, "⌘T should open a tab")
        XCTAssertEqual(editor.value as? String, "", "A new tab starts empty")
        setQuery("SELECT Id FROM Contact")
        XCTAssertTrue(tabs.matching(NSPredicate(format: "label == 'Contact'")).firstMatch.waitForExistence(timeout: 5), "The tab is named after its SObject")
        app.buttons["Close Contact"].click()
        XCTAssertEqual(tabs.count, before, "The close button closes the tab")
    }

    @MainActor
    func testToolingAPITab() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        app.typeKey("t", modifierFlags: .command)
        app.descendants(matching: .any)["toolingAPIToggle"].firstMatch.click()
        // The sidebar switches to the Tooling API's SObjects, which include ApexClass but not Account.
        let sidebar = app.outlines["schemaSidebar"]
        XCTAssertTrue(text("ApexClass", in: sidebar).waitForExistence(timeout: 30), "The sidebar should list Tooling API SObjects")
        XCTAssertFalse(text("Account", in: sidebar).exists)
        setQuery("SELECT Id, Name FROM ApexClass ORDER BY Name LIMIT 5")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded"), "The Tooling API query should load rows")
        XCTAssertFalse(results.checkBoxes.firstMatch.exists, "Tooling API results are read-only")
        // Back on the data API, the sidebar lists Account again.
        app.descendants(matching: .any)["toolingAPIToggle"].firstMatch.click()
        XCTAssertTrue(text("Account", in: sidebar).waitForExistence(timeout: 10))
    }

    @MainActor
    func testResultsAsJSON() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id, Name, (SELECT Id FROM Contacts) FROM Account ORDER BY Name LIMIT 3")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded"))
        // In windows, not the Touch Bar's copy of the control.
        app.windows.radioButtons["JSON"].click()
        let json = app.textViews["resultsJSON"]
        XCTAssertTrue(json.waitForExistence(timeout: 10))
        let text = json.value as? String ?? ""
        XCTAssertTrue(text.hasPrefix("[\n  {\n    \"attributes\": {\n      \"type\": \"Account\""), "The rows show as indented JSON")
        XCTAssertTrue(text.contains("\"Contacts\""), "Subqueries are included")
        app.windows.radioButtons["Table"].click()
        XCTAssertTrue(results.waitForExistence(timeout: 10))
    }

    /// With Developer Edition orgs set to open read-only, the test org's window starts locked:
    /// no checkboxes or New Record until the padlock is clicked.
    @MainActor
    func testGuardedOrgStartsReadOnly() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch(extraArguments: ["-lockDeveloperEditionOrgs", "YES"])
        XCTAssertTrue(app.staticTexts["orgKind"].waitForExistence(timeout: 10), "The toolbar shows the org's kind")
        let lock = app.descendants(matching: .any)["changesLock"].firstMatch
        XCTAssertTrue(lock.exists, "A guarded org's window has a padlock")
        setQuery("SELECT Id, Name FROM Account ORDER BY Name LIMIT 3")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded"))
        XCTAssertFalse(results.checkBoxes.firstMatch.exists, "Rows can't be checked for deletion while locked")
        XCTAssertFalse(app.buttons["New Record"].exists)
        XCTAssertEqual(results.textFields.count, 0, "Cells aren't editable while locked")

        lock.click()
        let banner = app.descendants(matching: .any)["unlockedBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "Unlocking shows a warning banner")
        XCTAssertTrue(results.checkBoxes.firstMatch.waitForExistence(timeout: 10), "Unlocked, rows can be checked")
        XCTAssertTrue(app.buttons["New Record"].exists)

        banner.buttons["Lock"].click()
        XCTAssertFalse(results.checkBoxes.firstMatch.waitForExistence(timeout: 2), "Locking again removes the checkboxes")
    }

    /// Filters the loaded rows, then shows a row's record in the inspector and follows its owner.
    @MainActor
    func testFilterRowsAndInspectRecord() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch(extraArguments: ["-inspectorTab", "Record"])
        setQuery("SELECT Id, Name, OwnerId FROM Account ORDER BY Name LIMIT 3")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded 3"))

        let filter = app.textFields["resultsFilter"]
        filter.click()
        filter.typeText("no account has this text")
        XCTAssertEqual(app.staticTexts["filterCount"].value as? String, "0 of 3")
        XCTAssertEqual(results.outlineRows.count, 0)
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(results.outlineRows.count, 3, "Clearing the filter shows every row")

        results.outlineRows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        XCTAssertTrue(text("Account Name", in: app.windows.firstMatch).waitForExistence(timeout: 30), "The Record tab lists the record's fields by label")
        XCTAssertTrue(text("Created Date", in: app.windows.firstMatch).exists, "Fields the query didn't select are shown too")

        // Link-style buttons appear to UI tests as links.
        let owner = app.descendants(matching: .any).matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND (title BEGINSWITH '005' OR label BEGINSWITH '005')", XCUIElement.ElementType.link.rawValue, XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 10), "The owner is a link")
        owner.click()
        XCTAssertTrue(text("Username", in: app.windows.firstMatch).waitForExistence(timeout: 30), "Following the owner shows the User's fields")
        app.buttons["Back"].click()
        XCTAssertTrue(text("Account Name", in: app.windows.firstMatch).waitForExistence(timeout: 30), "Back returns to the Account")
    }

    @MainActor
    func testOrgLimits() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id FROM User LIMIT 1")
        runQuery()
        let usage = app.buttons["apiUsage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 60))
        usage.click()
        let daily = app.windows.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Daily Api Requests' OR value CONTAINS 'Daily Api Requests'")).firstMatch
        XCTAssertTrue(daily.waitForExistence(timeout: 30), "The limits sheet lists the org's limits")
        app.buttons["Done"].click()
    }

    @MainActor
    func testExportDataDictionary() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        let url = FileManager.default.temporaryDirectory.appending(path: "dictionary-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try launch(extraArguments: ["-exportDataDictionary", url.path, "-dictionarySObjects", "Account,Contact"])
        let exists = NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) }
        wait(for: [XCTNSPredicateExpectation(predicate: exists, object: nil)], timeout: 60)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("## Account (`Account`)"), "Account comes first")
        XCTAssertTrue(text.contains("## Contact (`Contact`)"))
        XCTAssertTrue(text.contains("| `LastName` | Last Name | string(80) | Yes |"), "Contact's required LastName is listed with its size")
    }

    /// Runs the first line of some Apex, then the broken second line, whose error is reported
    /// on the editor's line 2.
    @MainActor
    func testExecuteSelectedApex() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        app.typeKey("2", modifierFlags: .command)
        let apexEditor = app.textViews["apexEditor"]
        XCTAssertTrue(apexEditor.waitForExistence(timeout: 10))
        apexEditor.click()
        apexEditor.typeKey("a", modifierFlags: .command)
        apexEditor.typeText("System.debug('one');\nInteger broken = ;")
        let runs = app.outlines.matching(identifier: "apexRuns").firstMatch

        apexEditor.typeKey(.upArrow, modifierFlags: .command)
        apexEditor.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(text("Success", in: runs).waitForExistence(timeout: 60), "The selected first line runs on its own")

        apexEditor.typeKey(.downArrow, modifierFlags: .command)
        apexEditor.typeKey(.leftArrow, modifierFlags: [.command, .shift])
        app.typeKey(.return, modifierFlags: .command)
        let error = runs.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Line 2:'")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 60), "The selection's error is on the editor's line 2")
    }

    @MainActor
    func testApexSnippets() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        app.typeKey("2", modifierFlags: .command)
        let apexEditor = app.textViews["apexEditor"]
        XCTAssertTrue(apexEditor.waitForExistence(timeout: 10))
        apexEditor.click()
        apexEditor.typeKey("a", modifierFlags: .command)
        apexEditor.typeText("System.debug('snippet');")
        apexEditor.typeKey("a", modifierFlags: .command)

        let menu = app.descendants(matching: .any)["apexSnippets"].firstMatch
        menu.click()
        app.menuItems["Save Selection as Snippet"].click()

        apexEditor.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(apexEditor.value as? String, "")
        menu.click()
        app.menuItems["System.debug('snippet');"].click()
        XCTAssertEqual(apexEditor.value as? String, "System.debug('snippet');", "Choosing the snippet inserts it")
    }

    /// Starts logging, runs Apex to make a log, reads it in the Logs workspace, deletes it and
    /// stops logging.
    @MainActor
    func testDebugLogs() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTSOQL_TEST_WRITES"] == "YES", "Set SWIFTSOQL_TEST_WRITES=YES to let this test start logging and delete logs")
        try launch()
        let marker = "SwiftSoql log test \(UUID().uuidString.prefix(8))"
        app.typeKey("4", modifierFlags: .command)
        let start = app.descendants(matching: .any)["startLogging"].firstMatch
        let status = app.descendants(matching: .any)["loggingStatus"].firstMatch
        // An earlier run may have left logging on.
        let ready = NSPredicate { _, _ in start.exists || status.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30)
        if !status.exists {
            start.click()
            app.menuItems["For 30 Minutes"].click()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 30), "Logging should start")

        app.typeKey("2", modifierFlags: .command)
        let apexEditor = app.textViews["apexEditor"]
        XCTAssertTrue(apexEditor.waitForExistence(timeout: 10))
        apexEditor.click()
        apexEditor.typeKey("a", modifierFlags: .command)
        apexEditor.typeText("System.debug('\(marker)');")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(text("Success", in: app.outlines.matching(identifier: "apexRuns").firstMatch).waitForExistence(timeout: 60))

        app.typeKey("4", modifierFlags: .command)
        let logList = app.outlines.matching(identifier: "debugLogs").firstMatch
        app.buttons["Refresh"].click()
        XCTAssertTrue(logList.outlineRows.firstMatch.waitForExistence(timeout: 30), "The run should leave a log")
        // The columns are wider than the list, so click near the row's left end.
        let firstLog = logList.outlineRows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 30, dy: 0))
        firstLog.click()
        let body = app.textViews["debugLogText"]
        let hasMarker = NSPredicate(format: "value CONTAINS %@", marker)
        wait(for: [XCTNSPredicateExpectation(predicate: hasMarker, object: body)], timeout: 30)

        let count = logList.outlineRows.count
        firstLog.rightClick()
        app.menuItems["Delete Log"].click()
        let fewer = NSPredicate(format: "count < %d", count)
        wait(for: [XCTNSPredicateExpectation(predicate: fewer, object: logList.outlineRows)], timeout: 30)

        status.buttons["Stop"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 30), "Stopping logging brings back Start Logging")
    }

    @MainActor
    func testFormatQuery() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id, Name FROM Account WHERE Name = 'x' AND Industry = 'y'")
        app.typeKey("i", modifierFlags: .control)
        XCTAssertEqual(editor.value as? String, "SELECT Id, Name\nFROM Account\nWHERE Name = 'x'\n  AND Industry = 'y'")
        editor.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(editor.value as? String, "SELECT Id, Name FROM Account WHERE Name = 'x' AND Industry = 'y'", "Undo puts the original back")
    }

    @MainActor
    func testQueryPlanSheet() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        setQuery("SELECT Id FROM User WHERE IsActive = true")
        app.typeKey(.return, modifierFlags: [.command, .option])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        XCTAssertTrue(sheet.staticTexts["Query Plan"].exists)
        XCTAssertGreaterThan(sheet.outlines.firstMatch.outlineRows.count, 0, "Salesforce should return at least one plan")
        sheet.buttons["Done"].click()
        XCTAssertFalse(sheet.exists)
    }

    @MainActor
    func testPinRecentQuery() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch(extraArguments: ["-showDetailsInspector", "YES"])
        setQuery("SELECT Id FROM Profile LIMIT 1")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded"))
        app.radioButtons["Recent Queries"].click()
        let recent = app.outlines.matching(identifier: "recentQueries").firstMatch
        let row = text("SELECT Id FROM Profile LIMIT 1", in: recent)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The query should be in the recent list")
        row.rightClick()
        app.menuItems["Pin"].click()
        XCTAssertTrue(recent.images["Pinned"].waitForExistence(timeout: 5), "The pinned query shows a pin")
    }

    /// Creates a Task with anonymous Apex, edits its Priority with the picklist menu, and deletes it.
    @MainActor
    func testApexEditAndDeleteRecord() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTSOQL_TEST_WRITES"] == "YES", "Set SWIFTSOQL_TEST_WRITES=YES to let this test create and delete a record")
        try launch()
        let subject = "SwiftSoql UI test \(UUID().uuidString.prefix(8))"

        app.typeKey("2", modifierFlags: .command)
        let apexEditor = app.textViews["apexEditor"]
        XCTAssertTrue(apexEditor.waitForExistence(timeout: 10))
        apexEditor.click()
        apexEditor.typeKey("a", modifierFlags: .command)
        apexEditor.typeText("insert new Task(Subject = '\(subject)', Priority = 'Normal');")
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(text("Success", in: app.outlines.matching(identifier: "apexRuns").firstMatch).waitForExistence(timeout: 60), "The Apex should run")

        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        setQuery("SELECT Id, Subject, Priority FROM Task WHERE Subject = '\(subject)'")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded 1 of 1"), "The new Task should be found")

        let priority = results.menuButtons.firstMatch
        XCTAssertTrue(priority.waitForExistence(timeout: 30), "Priority should be editable with a menu once Task is described")
        priority.click()
        app.menuItems["High"].click()
        XCTAssertTrue(waitForStatus("Updated Priority"), "Choosing a value should save it")
        let highMenu = results.menuButtons.matching(NSPredicate(format: "label CONTAINS 'High' OR title CONTAINS 'High' OR value CONTAINS 'High'")).firstMatch
        XCTAssertTrue(highMenu.waitForExistence(timeout: 10), "The picklist cell shows the saved value")

        results.checkBoxes.firstMatch.click()
        app.buttons["Delete Checked"].click()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting asks first")
        confirm.click()
        XCTAssertTrue(waitForStatus("Deleted 1 row"), "The Task should be deleted")
    }

    /// Creates an Account with the new record form, clones it from the results, and deletes both.
    @MainActor
    func testCreateAndCloneRecord() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTSOQL_TEST_WRITES"] == "YES", "Set SWIFTSOQL_TEST_WRITES=YES to let this test create and delete records")
        try launch()
        let name = "SwiftSoql UI test \(UUID().uuidString.prefix(8))"
        setQuery("SELECT Id, Name FROM Account WHERE Name LIKE '\(name)%' ORDER BY Name")

        // The form starts on the query's SObject and needs its required Name.
        app.typeKey("n", modifierFlags: [.control, .command])
        let nameField = app.textFields["field.Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 30), "The form should list Account's fields")
        XCTAssertFalse(app.buttons["Create"].isEnabled, "Name is required")
        nameField.click()
        nameField.typeText(name)
        app.buttons["Create"].click()
        XCTAssertTrue(waitForStatus("Created Account"), "The record should be created")

        // Close the completion popup, which can cover the results.
        editor.typeKey(.escape, modifierFlags: [])
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded 1 of 1"), "The new Account should be found")
        // Right-click the read-only Id cell; an editable cell shows its text field's menu.
        let idCell = { self.results.outlineRows.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)) }
        idCell().rightClick()
        app.menuItems["Clone Record…"].click()
        XCTAssertTrue(nameField.waitForExistence(timeout: 30), "Cloning opens the form")
        XCTAssertEqual(nameField.value as? String, name, "The copy starts with the record's values")
        nameField.click()
        nameField.typeKey(.rightArrow, modifierFlags: .command)
        nameField.typeText(" copy")
        app.buttons["Create"].click()
        XCTAssertTrue(waitForStatus("Created Account"), "The copy should be created")
        // Name is editable, so its cells are text fields.
        let copyCell = results.textFields.matching(NSPredicate(format: "value == %@", "\(name) copy")).firstMatch
        XCTAssertTrue(copyCell.waitForExistence(timeout: 10), "The copy is added to the results")
        XCTAssertEqual(results.outlineRows.count, 2)

        idCell().rightClick()
        app.menuItems["Check All Rows"].click()
        app.buttons["Delete Checked"].click()
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitForStatus("Deleted 2 rows"), "Both Accounts should be deleted")
    }

    /// Imports CSV files into Accounts: an insert with one bad row, an update by Id, and an upsert
    /// through a Bulk API job; then deletes the Accounts.
    @MainActor
    func testImportCSV() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTSOQL_TEST_WRITES"] == "YES", "Set SWIFTSOQL_TEST_WRITES=YES to let this test create and delete records")
        let tag = "SwiftSoql UI import \(UUID().uuidString.prefix(8))"
        let folder = FileManager.default.temporaryDirectory.appending(path: "SwiftSoqlImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        /// Writes accounts.csv in its own folder, so the app picks Account from the name.
        func csvFile(_ step: Int, _ text: String) throws -> String {
            let url = folder.appending(path: "\(step)/accounts.csv")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        func runImport(_ operation: String, expect summary: String, timeout: TimeInterval = 60) {
            let start = app.buttons["startImport"]
            XCTAssertTrue(start.waitForExistence(timeout: 30))
            let enabled = NSPredicate(format: "isEnabled == true")
            wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: start)], timeout: 30)
            start.click()
            // Not the Touch Bar's copy of the button.
            let confirm = app.windows.buttons.matching(NSPredicate(format: "label == %@", operation)).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Importing asks first")
            confirm.click()
            let result = app.staticTexts["importSummary"]
            XCTAssertTrue(result.waitForExistence(timeout: timeout), "The import should finish")
            XCTAssertEqual(result.value as? String, summary)
            app.buttons["Done"].click()
        }

        // Insert: the row with a bad number fails without being sent.
        try launch(extraArguments: ["-importCSV", try csvFile(1, "Name,NumberOfEmployees\n\(tag) A,1\n\(tag) B,2\n\(tag) C,3\n\(tag) X,lots\n")])
        runImport("Insert", expect: "3 created, 1 failed")

        setQuery("SELECT Id, Name FROM Account WHERE Name LIKE '\(tag)%' ORDER BY Name")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded 3 of 3"))
        let ids = (0..<3).compactMap { results.outlineRows.element(boundBy: $0).staticTexts.element(boundBy: 0).value as? String }
        XCTAssertEqual(ids.count, 3)
        app.terminate()

        // Update by Id; the empty cell leaves B's employees alone.
        try launch(extraArguments: ["-importCSV", try csvFile(2, "Id,NumberOfEmployees\n\(ids[0]),10\n\(ids[1]),\n")])
        runImport("Update", expect: "2 updated, 0 failed")
        app.terminate()

        // Upsert on Id with a Bulk API job: C is updated, D is created.
        try launch(extraArguments: ["-importCSV", try csvFile(3, "Id,Name,NumberOfEmployees\n\(ids[2]),\(tag) C2,30\n,\(tag) D,4\n"), "-bulkExportThreshold", "1"])
        let upsert = app.radioButtons["Upsert"]
        XCTAssertTrue(upsert.waitForExistence(timeout: 30))
        upsert.click()
        runImport("Upsert", expect: "1 created, 1 updated, 0 failed", timeout: 300)

        setQuery("SELECT Id, Name, NumberOfEmployees FROM Account WHERE Name LIKE '\(tag)%' ORDER BY Name")
        runQuery()
        XCTAssertTrue(waitForStatus("Loaded 4 of 4"), "A, B, C2 and D should exist")
        let employees = results.textFields.matching(NSPredicate(format: "value IN %@", ["10", "2", "30", "4"]))
        XCTAssertEqual(employees.count, 4, "The imported employee counts should be saved")
        let allIDs = (0..<4).compactMap { results.outlineRows.element(boundBy: $0).staticTexts.element(boundBy: 0).value as? String }
        XCTAssertEqual(allIDs.count, 4)
        app.terminate()

        // Delete them all from a file of Ids.
        try launch(extraArguments: ["-importCSV", try csvFile(4, "Id\n" + allIDs.joined(separator: "\n") + "\n")])
        let delete = app.radioButtons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 30))
        delete.click()
        runImport("Delete", expect: "4 deleted, 0 failed")
        setQuery("SELECT Id FROM Account WHERE Name LIKE '\(tag)%'")
        runQuery()
        XCTAssertTrue(waitForStatus("Query returned 0 rows"), "The Accounts should be gone")
    }

    @MainActor
    func testSchemaDiagramMovesToARelatedSObject() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch(extraArguments: ["-showSchema", "Contact", "-schemaHideSystemChildren", "YES"])
        let account = app.descendants(matching: .any)["schemaBox.Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 60), "Contact's diagram should show Account, which it refers to")
        account.doubleClick()
        let accountDiagram = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Schema diagram of Account'")).firstMatch
        XCTAssertTrue(accountDiagram.waitForExistence(timeout: 60), "Double-clicking Account should move it to the middle")
    }

    @MainActor
    func testBrowserLoginAsksForAKeyTheFirstTime() throws {
        try launch(connected: false)
        app.buttons["Log In with Browser…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let key = sheet.textFields["Consumer key"]
        XCTAssertTrue(key.exists, "With no keys saved, the sheet asks for one")
        XCTAssertFalse(sheet.buttons["Log In"].isEnabled, "Logging in needs a key")
        key.click()
        key.typeText("3MVGexample")
        XCTAssertTrue(sheet.buttons["Log In"].isEnabled)
        sheet.buttons["Cancel"].click()
    }

    /// The toolbar's display mode, chosen from its context menu, is still in effect after a
    /// relaunch.
    @MainActor
    func testToolbarDisplayModeSurvivesRelaunch() throws {
        try XCTSkipIf(testOrg == nil, "Set SWIFTSOQL_TEST_ORG to run this test")
        try launch()
        let iconsOnlyHeight = app.windows.firstMatch.toolbars.firstMatch.frame.height
        app.windows.firstMatch.toolbars.firstMatch.rightClick()
        app.menuItems["Icon and Text"].click()
        let withTextHeight = app.windows.firstMatch.toolbars.firstMatch.frame.height
        XCTAssertGreaterThan(withTextHeight, iconsOnlyHeight, "Showing text makes the toolbar taller")
        app.terminate()

        try launch(extraArguments: ["-KeepTestingSettings", "YES"])
        let toolbar = app.windows.firstMatch.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
        XCTAssertEqual(toolbar.frame.height, withTextHeight, "After a relaunch the toolbar should still show icons and text")
    }
}

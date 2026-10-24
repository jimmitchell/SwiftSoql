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
            XCTAssertTrue(editor.waitForExistence(timeout: 60), "The app should connect and show the query editor")
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
}

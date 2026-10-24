import Foundation
import Testing
@testable import SwiftSoql

/// The tests run with -Testing, so the model reads and writes the separate testing store.
@Suite(.serialized)
struct QueryTabTests {
    init() {
        #expect(AppDefaults.isTesting, "The scheme's test action should launch the app with -Testing YES")
    }

    @Test func titles() {
        let titles = ["SELECT Id FROM Account", "select id, (select id from Contacts) from Account where x = 1", "FIND {acme}", "", "SELECT COUNT() FROM Opportunity_c__x", "garbage"]
        #expect(titles.map { QueryTab(soql: $0).title } == ["Account", "Account", "Search", "New Query", "Opportunity_c__x", "Query"])
    }

    @Test func openingClosingAndCycling() {
        AppDefaults.store.set(["SELECT Id FROM A", "SELECT Id FROM B"], forKey: "queryTabs")
        AppDefaults.store.set(1, forKey: "selectedQueryTab")
        let m = ExplorerModel()
        #expect(m.tabs.map(\.title) == ["A", "B"] && m.currentTab.title == "B")
        #expect(m.soql == "SELECT Id FROM B")
        m.soql = "SELECT Id FROM C"
        #expect(m.tabs[1].soql == "SELECT Id FROM C")
        m.newTab(soql: "SELECT Id FROM D")
        #expect(m.tabs.map(\.title) == ["A", "C", "D"] && m.currentTab.title == "D")
        m.selectTab(offset: 1)
        #expect(m.currentTab.title == "A")
        m.selectTab(offset: -1)
        #expect(m.currentTab.title == "D")
        m.closeTab(m.selectedTabID)
        #expect(m.tabs.map(\.title) == ["A", "C"] && m.currentTab.title == "C")
        m.closeOtherTabs(than: m.tabs[0].id)
        #expect(m.tabs.map(\.title) == ["A"])
        m.closeTab(m.selectedTabID)
        #expect(m.tabs.count == 1 && m.currentTab.soql.isEmpty)
        #expect(AppDefaults.store.stringArray(forKey: "queryTabs") == [""])
    }

    @Test func formatQueryReplacesTheTabsText() {
        let m = ExplorerModel()
        m.soql = "SELECT Id, Name FROM Account WHERE Name = 'x'"
        m.formatQuery()
        #expect(m.soql == "SELECT Id, Name\nFROM Account\nWHERE Name = 'x'")
        m.soql = "FIND {x}"
        m.formatQuery()
        #expect(m.soql == "FIND {x}" && !m.currentTab.statusText.isEmpty)
    }
}

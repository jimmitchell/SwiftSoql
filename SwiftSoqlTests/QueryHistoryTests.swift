import Foundation
import Testing
@testable import SwiftSoql

struct QueryHistoryTests {
    /// A history saved in its own throwaway store.
    private func history(maxRecent: Int = 3) -> (QueryHistory, UserDefaults) {
        let suite = "QueryHistoryTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        store.set(maxRecent, forKey: "maxRecentQueries")
        let history = QueryHistory(store: store)
        history.load(username: "a@example.com")
        return (history, store)
    }

    @Test func newestFirstWithoutDuplicatesUpToTheLimit() {
        let (h, _) = history()
        for q in ["A", "B", "C", "A", "D"] { h.add(q) }
        #expect(h.recent == ["D", "A", "C"])
    }

    @Test func pinnedQueriesOutliveTheLimitAndStayPut() {
        let (h, _) = history(maxRecent: 2)
        h.add("A"); h.add("B"); h.add("C")
        h.pin(["B", "C"])
        #expect(h.pinned == ["C", "B"] && h.recent == [])
        h.add("B")
        for q in ["D", "E", "F"] { h.add(q) }
        #expect(h.pinned == ["C", "B"] && h.recent == ["F", "E"])
        h.movePinned(fromOffsets: [1], toOffset: 0)
        #expect(h.pinned == ["B", "C"])
        h.unpin(["C"])
        #expect(h.pinned == ["B"] && h.recent == ["C", "F"])
    }

    @Test func savedPerOrg() {
        let (h, store) = history()
        h.add("A"); h.pin(["A"]); h.add("B")
        h.load(username: "b@example.com")
        #expect(h.recent.isEmpty && h.pinned.isEmpty)
        h.add("C")
        let reloaded = QueryHistory(store: store)
        reloaded.load(username: "a@example.com")
        #expect(reloaded.recent == ["B"] && reloaded.pinned == ["A"])
        reloaded.remove(["A", "B"])
        reloaded.load(username: "a@example.com")
        #expect(reloaded.recent.isEmpty && reloaded.pinned.isEmpty)
        h.load(username: nil)
        h.add("D")
        #expect(store.stringArray(forKey: "recentQueries-b@example.com") == ["C"])
    }
}

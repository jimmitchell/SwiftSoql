import Foundation
import Observation

/// The queries run in one org, newest first, and the queries pinned there, which are kept however
/// many queries are run. Both are saved per username.
@Observable
final class QueryHistory {
    /// Queries run in this org, newest first. Pinned queries aren't included.
    private(set) var recent: [String] = []
    /// Queries pinned in this org, in the order the user arranged them.
    private(set) var pinned: [String] = []
    @ObservationIgnored private var username: String?
    @ObservationIgnored private let store: UserDefaults

    init(store: UserDefaults = AppDefaults.store) {
        self.store = store
    }

    /// Shows the queries saved for an org, or none if `username` is nil.
    func load(username: String?) {
        self.username = username
        recent = username.flatMap { store.stringArray(forKey: recentKey(for: $0)) } ?? []
        pinned = username.flatMap { store.stringArray(forKey: pinnedKey(for: $0)) } ?? []
    }

    private func recentKey(for username: String) -> String { "recentQueries-\(username)" }
    private func pinnedKey(for username: String) -> String { "pinnedQueries-\(username)" }

    func add(_ text: String) {
        // A pinned query stays where it was pinned.
        guard !pinned.contains(text) else { return }
        recent.removeAll { $0 == text }
        recent.insert(text, at: 0)
        save()
    }

    /// Saves the recent and pinned queries, keeping only as many recent ones as Settings allows.
    private func save() {
        let limit = max(1, store.integer(forKey: "maxRecentQueries"))
        if recent.count > limit {
            recent.removeLast(recent.count - limit)
        }
        guard let username else { return }
        store.set(recent, forKey: recentKey(for: username))
        store.set(pinned, forKey: pinnedKey(for: username))
    }

    /// Removes recent or pinned queries.
    func remove(_ queries: Set<String>) {
        recent.removeAll { queries.contains($0) }
        pinned.removeAll { queries.contains($0) }
        save()
    }

    func clearRecent() {
        recent = []
        save()
    }

    /// Moves recent queries to the end of the pinned ones, in the order they're listed.
    func pin(_ queries: Set<String>) {
        pinned += recent.filter(queries.contains)
        recent.removeAll { queries.contains($0) }
        save()
    }

    /// Moves pinned queries back to the top of the recent ones.
    func unpin(_ queries: Set<String>) {
        recent.insert(contentsOf: pinned.filter(queries.contains), at: 0)
        pinned.removeAll { queries.contains($0) }
        save()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { pinned[$0] }
        for i in source.reversed() {
            pinned.remove(at: i)
        }
        pinned.insert(contentsOf: moving, at: destination - source.count { $0 < destination })
        save()
    }
}

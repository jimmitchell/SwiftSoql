import Foundation
import Observation

/// Saved pieces of anonymous Apex, kept for every org.
@Observable
final class ApexSnippets {
    struct Snippet: Identifiable, Equatable {
        let id: UUID
        var name: String
        var code: String

        init(id: UUID = UUID(), name: String, code: String) {
            self.id = id
            self.name = name
            self.code = code
        }
    }

    /// The snippets every window shows.
    static let shared = ApexSnippets()

    var snippets: [Snippet] {
        didSet { save() }
    }
    @ObservationIgnored private let store: UserDefaults
    private static let key = "apexSnippets"

    init(store: UserDefaults = AppDefaults.store) {
        self.store = store
        snippets = (store.array(forKey: Self.key) as? [[String: String]] ?? []).compactMap { saved in
            guard let name = saved["name"], let code = saved["code"] else { return nil }
            return Snippet(id: saved["id"].flatMap(UUID.init) ?? UUID(), name: name, code: code)
        }
    }

    private func save() {
        store.set(snippets.map { ["id": $0.id.uuidString, "name": $0.name, "code": $0.code] }, forKey: Self.key)
    }

    /// Saves code as a new snippet, named after its first line.
    @discardableResult
    func add(_ code: String) -> Snippet {
        let snippet = Snippet(name: Self.name(for: code), code: code)
        snippets.append(snippet)
        return snippet
    }

    /// The first line with something on it, shortened.
    static func name(for code: String) -> String {
        let line = code.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "Snippet"
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

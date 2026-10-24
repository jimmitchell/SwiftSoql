import Foundation

/// A suggestion for the text at a position in a query.
final class Completion {
    /// The text shown in the completions popup.
    let displayText: String
    /// The text inserted while moving through the list, before one is chosen.
    var nonFinalInsertionText: String
    /// The text inserted when this completion is chosen.
    var finalInsertionText: String
    /// What to do after inserting the final text.
    var onFinalInsert: FinalInsertAction = .none
    let type: TokenType

    enum FinalInsertAction {
        case none
        /// Moves the cursor by this many characters, e.g. back inside a function's parentheses.
        case moveSelection(Int)
        /// Selects the "Id" just inserted after a relationship name, and shows completions for it.
        case selectRelationshipField
    }

    init(display: String, insert: String, finalInsertion: String, type: TokenType) {
        displayText = display
        nonFinalInsertionText = insert
        finalInsertionText = finalInsertion
        self.type = type
    }

    convenience init(_ txt: String, type: TokenType) {
        self.init(display: txt, insert: txt, finalInsertion: txt, type: type)
    }

    static func completions(_ txt: [String], type: TokenType) -> [Completion] {
        txt.map { Completion($0, type: type) }
    }
}

/// Completions for each position in the query text.
///
/// Kept separately from the text storage because storing hundreds of custom attributes
/// there gets progressively slower.
struct CompletionLocations {
    private var items: [[Completion]] = []

    mutating func clear() {
        items.removeAll(keepingCapacity: true)
    }

    mutating func add(_ completions: [Completion], at loc: NSRange) {
        let end = NSMaxRange(loc)
        if items.count < end {
            items.append(contentsOf: Array(repeating: [], count: end - items.count))
        }
        for p in loc.location..<end {
            items[p] = completions
        }
    }

    /// The completions for a range: those of the last position in the range that has any.
    func completions(in loc: NSRange) -> [Completion] {
        guard !items.isEmpty else { return [] }
        var p = min(items.count, NSMaxRange(loc)) - 1
        while p >= loc.location && p >= 0 {
            if !items[p].isEmpty {
                return items[p]
            }
            p -= 1
        }
        return []
    }
}

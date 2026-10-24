import AppKit

/// Syntax colors and completion icons, from SoqlXplorer's ColorizerStyle and Icons.
enum SOQLStyle {
    static let keyword = NSColor(named: "soql.keyword") ?? .systemRed
    static let field = NSColor(named: "soql.field") ?? .systemTeal
    static let function = NSColor(named: "soql.func") ?? .systemGreen
    static let sobject = NSColor(named: "soql.sobject") ?? .systemPink
    static let relationship = NSColor(named: "soql.rel") ?? .systemBlue
    static let alias = NSColor(named: "soql.alias") ?? .systemPurple
    static let literal = NSColor(named: "soql.literal") ?? .systemGreen
    static let error = NSColor(named: "soql.error") ?? .systemYellow

    /// The color for a token type, or nil for default text.
    static func color(for type: TokenType) -> NSColor? {
        switch type {
        case .keyword, .operator: keyword
        case .alias, .aliasDecl: alias
        case .field, .usingScope, .dataCategory, .listViewName: field
        case .relationship, .sobjectRelation: relationship
        case .sobject: sobject
        case .function: function
        case .dataCategoryValue: literal
        default: TokenType.literals.contains(type) ? literal : nil
        }
    }

    private static var icons: [UInt32: NSImage] = [:]

    /// A small badge with a letter for the kind of completion.
    static func icon(for type: TokenType) -> NSImage? {
        if let icon = icons[type.rawValue] { return icon }
        let spec: (String, NSColor)? = switch type {
        case .field: ("F", field)
        case .sobject: ("O", sobject)
        case .relationship, .sobjectRelation: ("R", relationship)
        case .operator: ("Op", keyword)
        case .keyword: ("K", keyword)
        case .typeOf: ("T", keyword)
        case .function: ("ƒ", function)
        case .literalNamedDateTime: ("D", literal)
        case .alias: ("A", alias)
        default: TokenType.literals.contains(type) ? ("V", literal) : nil
        }
        guard let (text, color) = spec else { return nil }
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 8, yRadius: 8)
            (color.blended(withFraction: 0.75, of: .black) ?? color).setFill()
            color.setStroke()
            box.lineWidth = 6
            box.fill()
            box.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.boldSystemFont(ofSize: 40)]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attrs)
            return true
        }
        icons[type.rawValue] = image
        return image
    }
}

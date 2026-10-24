import AppKit
import Observation

/// SObject icons from the org's theme: Salesforce's white glyphs on each SObject's color, as in
/// Lightning. The theme comes from one API call when connecting; each image is fetched the first
/// time it's shown (the images are public, so no token is sent) and kept in memory.
@Observable
final class SObjectIcons {
    /// Changes as images arrive, so views showing icons can redraw.
    private(set) var version = 0

    @ObservationIgnored private var themes: [String: (color: NSColor, url: URL)] = [:]
    @ObservationIgnored private var glyphs: [URL: NSImage] = [:]
    @ObservationIgnored private var badges: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<URL> = []

    /// Reads the REST API's theme: each SObject's Lightning (theme4) color and 60-point PNG.
    func load(theme: JSONValue) {
        for item in theme["themeItems"]?.array ?? [] {
            guard let name = item["name"]?.string else { continue }
            let color = (item["colors"]?.array ?? []).first { $0["theme"]?.string == "theme4" && $0["context"]?.string == "primary" }?["color"]?.string
            let icon = (item["icons"]?.array ?? []).first {
                $0["theme"]?.string == "theme4" && $0["contentType"]?.string == "image/png" && $0["width"]?.int == 60
            }
            guard let color = color.flatMap(Self.color(hex:)), let url = icon?["url"]?.string.flatMap(URL.init(string:)),
                  BrowserLogin.isSalesforceURL(url) else { continue }
            themes[name.lowercased()] = (color, url)
        }
        version += 1
    }

    func reset() {
        themes = [:]
        glyphs = [:]
        badges = [:]
        loading = []
        version += 1
    }

    /// The SObject's icon, or nil if the org has none or it's still loading.
    func icon(for sobject: String) -> NSImage? {
        let key = sobject.lowercased()
        if let badge = badges[key] { return badge }
        guard let theme = themes[key] else { return nil }
        if let glyph = glyphs[theme.url] {
            let badge = Self.badge(glyph, color: theme.color)
            badges[key] = badge
            return badge
        }
        if loading.insert(theme.url).inserted {
            Task {
                if let (data, response) = try? await URLSession.shared.data(from: theme.url),
                   (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                    glyphs[theme.url] = image
                    version += 1
                }
            }
        }
        return nil
    }

    private static func badge(_ glyph: NSImage, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            glyph.draw(in: rect.insetBy(dx: 3, dy: 3))
            return true
        }
        image.accessibilityDescription = "SObject icon"
        return image
    }

    nonisolated private static func color(hex: String) -> NSColor? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

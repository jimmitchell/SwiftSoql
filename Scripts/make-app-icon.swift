// Draws the SwiftSoql app icon and writes every size the macOS asset catalog needs.
// Usage: swift Scripts/make-app-icon.swift SwiftSoql/Assets.xcassets/AppIcon.appiconset
import AppKit

func drawIcon(in size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        // The rounded square of a macOS icon, inset from the canvas for its shadow.
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor(red: 0.04, green: 0.36, blue: 0.68, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(red: 0.19, green: 0.72, blue: 0.95, alpha: 1),
                   ending: NSColor(red: 0.03, green: 0.33, blue: 0.66, alpha: 1))?.draw(in: shape, angle: -90)

        // A cloud: overlapping circles on a rounded base.
        let cloud = NSBezierPath()
        cloud.append(NSBezierPath(roundedRect: NSRect(x: 230 * s, y: 380 * s, width: 560 * s, height: 190 * s), xRadius: 95 * s, yRadius: 95 * s))
        cloud.append(NSBezierPath(ovalIn: NSRect(x: 300 * s, y: 450 * s, width: 230 * s, height: 230 * s)))
        cloud.append(NSBezierPath(ovalIn: NSRect(x: 450 * s, y: 470 * s, width: 280 * s, height: 280 * s)))
        NSColor.white.setFill()
        cloud.fill()

        // Result rows inside the cloud.
        NSColor(red: 0.07, green: 0.45, blue: 0.80, alpha: 0.85).setFill()
        for (i, width) in [300.0, 240, 270].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 330 * s, y: CGFloat(530 - i * 52) * s, width: CGFloat(width) * s, height: 26 * s),
                         xRadius: 13 * s, yRadius: 13 * s).fill()
        }

        // A magnifying glass for querying.
        let orange = NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
        let lens = NSRect(x: 510 * s, y: 250 * s, width: 210 * s, height: 210 * s)
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 700 * s, y: 270 * s))
        handle.line(to: NSPoint(x: 780 * s, y: 190 * s))
        handle.lineCapStyle = .round
        for (color, extra) in [(NSColor.white, 22.0), (orange, 0.0)] {
            color.setStroke()
            handle.lineWidth = CGFloat(56 + extra) * s
            handle.stroke()
            let ring = NSBezierPath(ovalIn: lens)
            ring.lineWidth = CGFloat(44 + extra) * s
            ring.stroke()
        }
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: lens.insetBy(dx: 22 * s, dy: 22 * s)).fill()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(drawIcon(in: CGFloat(pixels)), pixels: pixels).write(to: dir.appendingPathComponent(name))
        images.append(#"    { "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)", "filename" : "\#(name)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n" + images.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

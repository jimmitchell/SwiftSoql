import AppKit
import SwiftUI

/// Which fields the central SObject's box lists.
enum SchemaFieldMode: String, CaseIterable, Identifiable {
    case key = "Key Fields"
    case important = "Important Fields"
    case all = "All Fields"

    var id: String { rawValue }

    func shows(_ field: FieldDescribe) -> Bool {
        switch self {
        case .key: field.importance <= 2
        case .important: field.importance <= 3 || !field.custom
        case .all: true
        }
    }
}

/// A diagram of an SObject and its relationships, as in SoqlXplorer: the SObject in the middle,
/// the SObjects it refers to on an arc to the left, and the SObjects that refer to it on an arc
/// to the right. Double-click a related SObject to put it in the middle.
struct SchemaDiagram: View {
    let describe: SObjectDescribe
    var fieldMode: SchemaFieldMode
    var hideSystemChildren: Bool
    var onOpen: (String) -> Void

    @State private var hovered: String?

    var body: some View {
        GeometryReader { geometry in
            let layout = SchemaLayout(describe: describe, fieldMode: fieldMode, hideSystemChildren: hideSystemChildren, visibleSize: geometry.size)
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    draw(layout, in: &context)
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hovered = layout.box(at: point)?.name
                    case .ended: hovered = nil
                    }
                }
                .onTapGesture(count: 2, coordinateSpace: .local) { point in
                    if let box = layout.box(at: point), box.role != .central {
                        onOpen(box.name)
                    }
                }
            }
            // Open on the central SObject, which is in the middle, and again when it changes.
            .defaultScrollAnchor(.center)
            .id(describe.name)
            .background(Color("schema.background"))
        }
    }

    private func draw(_ layout: SchemaLayout, in context: inout GraphicsContext) {
        for line in layout.lines {
            let isHighlighted = line.relatedBox == hovered || (hovered == layout.central.name)
            var path = Path()
            path.move(to: line.start)
            path.addCurve(to: line.end, control1: line.control1, control2: line.control2)
            context.stroke(path, with: .color(line.color.opacity(isHighlighted ? 1 : 0.55)), lineWidth: isHighlighted ? 2 : 1)
        }
        for box in layout.boxes {
            draw(box, highlighted: box.name == hovered, in: &context)
        }
    }

    private func draw(_ box: SchemaBox, highlighted: Bool, in context: inout GraphicsContext) {
        let shape = RoundedRectangle(cornerRadius: 6).path(in: box.frame)
        context.fill(shape, with: .color(box.color.opacity(highlighted ? 0.18 : 0.08)))
        var title = context
        title.clip(to: shape)
        title.fill(Path(CGRect(x: box.frame.minX, y: box.frame.minY, width: box.frame.width, height: SchemaBox.titleHeight)), with: .color(box.color))
        context.stroke(shape, with: .color(box.color), lineWidth: highlighted ? 3 : 1.5)
        context.draw(Text(box.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white),
                     at: CGPoint(x: box.frame.minX + SchemaBox.padding, y: box.frame.minY + SchemaBox.titleHeight / 2), anchor: .leading)
        for (i, field) in box.fields.enumerated() {
            context.draw(Text(field).font(.system(size: 11)).foregroundStyle(.primary),
                         at: CGPoint(x: box.frame.minX + SchemaBox.padding, y: box.fieldMidY(i)), anchor: .leading)
        }
    }
}

/// One SObject's box in the diagram.
struct SchemaBox {
    enum Role { case central, parent, child }

    static let titleHeight: CGFloat = 22
    static let rowHeight: CGFloat = 16
    static let padding: CGFloat = 8
    static let minWidth: CGFloat = 120

    let name: String
    let role: Role
    let fields: [String]
    var frame: CGRect

    init(name: String, role: Role, fields: [String]) {
        self.name = name
        self.role = role
        self.fields = fields
        let titleWidth = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let fieldFont = NSFont.systemFont(ofSize: 11)
        let fieldWidth = fields.map { ($0 as NSString).size(withAttributes: [.font: fieldFont]).width }.max() ?? 0
        frame = CGRect(x: 0, y: 0,
                       width: max(Self.minWidth, ceil(max(titleWidth, fieldWidth)) + Self.padding * 2),
                       height: Self.titleHeight + CGFloat(fields.count) * Self.rowHeight + 6)
    }

    var color: Color {
        switch role {
        case .central: Color("schema.primary")
        case .parent: Color("schema.parent")
        case .child: Color("schema.child")
        }
    }

    func fieldMidY(_ index: Int) -> CGFloat {
        frame.minY + Self.titleHeight + 3 + Self.rowHeight * (CGFloat(index) + 0.5)
    }

    /// Where a relationship line meets this box: beside the field's row, or the title if the field isn't listed.
    func anchorY(for field: String) -> CGFloat {
        if let i = fields.firstIndex(where: { $0.caseInsensitiveCompare(field) == .orderedSame }) {
            return fieldMidY(i)
        }
        return frame.minY + Self.titleHeight / 2
    }
}

/// Positions the boxes and relationship lines. Ported from SoqlXplorer's SchemaView.
struct SchemaLayout {
    struct Line {
        let relatedBox: String
        let color: Color
        let start: CGPoint
        let end: CGPoint
        let control1: CGPoint
        let control2: CGPoint
    }

    private(set) var central: SchemaBox
    private(set) var parents: [SchemaBox] = []
    private(set) var children: [SchemaBox] = []
    private(set) var lines: [Line] = []
    private(set) var size: CGSize

    var boxes: [SchemaBox] { [central] + parents + children }

    private static let spacer: CGFloat = 5

    init(describe: SObjectDescribe, fieldMode: SchemaFieldMode, hideSystemChildren: Bool, visibleSize: CGSize) {
        let shownFields = describe.fields
            .filter(fieldMode.shows)
            .sorted { ($0.importance, $0.name) < ($1.importance, $1.name) }
        central = SchemaBox(name: describe.name, role: .central, fields: shownFields.map(\.name))

        // Parents, in the order the listed fields refer to them, then any other fields' references.
        var parentNames: [String] = []
        for field in shownFields + describe.fields {
            for ref in field.referenceTo where ref != describe.name && !parentNames.contains(ref) {
                parentNames.append(ref)
            }
        }
        var childFields: [String: [String]] = [:]
        var childNames: [String] = []
        for rel in describe.childRelationships where rel.childSObject != describe.name && !parentNames.contains(rel.childSObject) {
            if hideSystemChildren, Self.isSystemSObject(rel.childSObject) { continue }
            if childFields[rel.childSObject] == nil {
                childNames.append(rel.childSObject)
            }
            if !(childFields[rel.childSObject]?.contains(rel.field) ?? false) {
                childFields[rel.childSObject, default: []].append(rel.field)
            }
        }
        parents = parentNames.map { SchemaBox(name: $0, role: .parent, fields: ["Id"]) }
        children = childNames.map { SchemaBox(name: $0, role: .child, fields: ["Id"] + (childFields[$0] ?? [])) }

        // Lay out the arcs first, as they can make the diagram taller than the window.
        let width = max(visibleSize.width, central.frame.width + 2 * (([parents, children].flatMap { $0 }.map(\.frame.width).max() ?? 0) + 60))
        var height = max(visibleSize.height, central.frame.height + Self.spacer * 2)
        height = max(height, Self.arcHeight(parents), Self.arcHeight(children))
        size = CGSize(width: width, height: height)
        Self.layOut(&parents, onLeft: true, in: size)
        Self.layOut(&children, onLeft: false, in: size)
        central.frame.origin = CGPoint(x: (width - central.frame.width) / 2, y: (height - central.frame.height) / 2)
        fitToContents()

        // Lines from each listed reference field to its parents, and from Id to each child's reference fields.
        for field in shownFields {
            for ref in field.referenceTo {
                if ref == describe.name {
                    lines.append(Self.selfLine(central, from: field.name))
                } else if let parent = parents.first(where: { $0.name == ref }) {
                    lines.append(Self.line(from: central, field: field.name, to: parent, field: "Id", color: Color("schema.parent")))
                }
            }
        }
        for child in children {
            for field in child.fields.dropFirst() {
                lines.append(Self.line(from: central, field: "Id", to: child, field: field, color: Color("schema.child")))
            }
        }
    }

    /// Boxes on the outer part of an arc can stick out past the edges, so widen the diagram to fit them.
    private mutating func fitToContents() {
        let margin: CGFloat = 20
        let all = boxes.map(\.frame)
        let minX = all.map(\.minX).min() ?? 0
        let maxX = all.map(\.maxX).max() ?? 0
        let shift = max(0, margin - minX)
        size.width = max(size.width, maxX + shift + margin)
        guard shift > 0 else { return }
        central.frame.origin.x += shift
        for i in parents.indices { parents[i].frame.origin.x += shift }
        for i in children.indices { children[i].frame.origin.x += shift }
    }

    func box(at point: CGPoint) -> SchemaBox? {
        boxes.last { $0.frame.contains(point) }
    }

    /// SObjects that most SObjects have, which crowd the diagram: history, sharing, feeds and change events.
    static func isSystemSObject(_ name: String) -> Bool {
        ["History", "Share", "Feed", "ChangeEvent"].contains { name.hasSuffix($0) }
    }

    private static func arcHeight(_ boxes: [SchemaBox]) -> CGFloat {
        boxes.reduce(0) { $0 + $1.frame.height } + spacer * CGFloat(boxes.count + 2) + 75
    }

    /// Spreads the boxes along a curve that bows out towards the edge of the diagram.
    private static func layOut(_ boxes: inout [SchemaBox], onLeft: Bool, in size: CGSize) {
        guard !boxes.isEmpty else { return }
        let midX = size.width / 2
        let startX = onLeft ? midX / 2 : midX * 3 / 2
        let outerX = onLeft ? midX / 6 : midX * 11 / 6
        let total = boxes.reduce(0) { $0 + $1.frame.height }
        let spacer = max(Self.spacer, (size.height - total) / CGFloat(boxes.count + 1))
        let p0 = CGPoint(x: startX, y: spacer)
        let p3 = CGPoint(x: startX, y: size.height - spacer)
        let control = CGPoint(x: outerX, y: size.height / 2)
        // Sample the curve so the x for any y can be looked up.
        let samples = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200, u = 1 - t
            let a = u * u * u, b = 3 * u * u * t + 3 * u * t * t, c = t * t * t
            return CGPoint(x: a * p0.x + b * control.x + c * p3.x, y: a * p0.y + b * control.y + c * p3.y)
        }
        func curveX(atY y: CGFloat) -> CGFloat {
            guard let i = samples.firstIndex(where: { $0.y >= y }), i > 0 else { return samples.last?.x ?? startX }
            let p = samples[i - 1], q = samples[i]
            return q.y == p.y ? p.x : p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x)
        }
        var y = spacer
        var x = startX
        for i in boxes.indices {
            let size = boxes[i].frame.size
            boxes[i].frame.origin = CGPoint(x: x - size.width / 2, y: y)
            y += size.height + spacer
            x = curveX(atY: y + size.height / 2)
        }
    }

    private static func line(from a: SchemaBox, field aField: String, to b: SchemaBox, field bField: String, color: Color) -> Line {
        let aY = a.anchorY(for: aField), bY = b.anchorY(for: bField)
        let start: CGPoint, end: CGPoint, offset: CGFloat
        if a.frame.maxX < b.frame.minX {
            start = CGPoint(x: a.frame.maxX, y: aY)
            end = CGPoint(x: b.frame.minX, y: bY)
            offset = 50
        } else {
            start = CGPoint(x: a.frame.minX, y: aY)
            end = CGPoint(x: b.frame.maxX, y: bY)
            offset = -50
        }
        return Line(relatedBox: b.name, color: color, start: start, end: end,
                    control1: CGPoint(x: start.x + offset, y: start.y), control2: CGPoint(x: end.x - offset, y: end.y))
    }

    /// A loop from a field back to the same box's Id, for self references such as Account.ParentId.
    private static func selfLine(_ box: SchemaBox, from field: String) -> Line {
        let start = CGPoint(x: box.frame.minX, y: box.anchorY(for: field))
        let end = CGPoint(x: box.frame.minX, y: box.anchorY(for: "Id"))
        return Line(relatedBox: box.name, color: Color("schema.primary"), start: start, end: end,
                    control1: CGPoint(x: start.x - 75, y: start.y), control2: CGPoint(x: end.x - 75, y: end.y))
    }
}

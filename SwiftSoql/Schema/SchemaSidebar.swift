import AppKit
import SwiftUI

/// The list of SObject types in the org. Expanding a type describes it and lists its fields.
struct SchemaSidebar: View {
    @Bindable var model: ExplorerModel
    /// Called when an item is double-clicked.
    var onOpen: (SchemaItem) -> Void = { _ in }
    @AppStorage("sortFieldsAlphabetically") private var sortFields = false

    var body: some View {
        let sobjects = model.filteredSObjects
        SchemaOutline(
            sobjects: sobjects,
            describedNames: Set(sobjects.lazy.map(\.name).filter { model.cachedDescribe($0) != nil }),
            expanded: model.expandedSObjects,
            selection: model.schemaSelection,
            filter: model.schemaFilter,
            sortFields: sortFields,
            describe: { model.cachedDescribe($0) },
            isHighlighted: { model.fieldMatchesFilter($0) },
            onSelect: { model.schemaSelection = $0 },
            onExpand: { name, isExpanded in
                if isExpanded {
                    model.expandedSObjects.insert(name)
                    Task { await model.ensureDescribed(name) }
                } else {
                    model.expandedSObjects.remove(name)
                }
            },
            onOpen: onOpen,
            onToggleSort: { sortFields.toggle() }
        )
        .searchable(text: $model.schemaFilter, placement: .sidebar, prompt: "Filter")
        .onChange(of: model.schemaSelection) { _, item in
            if let item {
                Task { await model.ensureDescribed(item.sobjectName) }
            }
        }
        .overlay {
            if sobjects.isEmpty && !model.schemaFilter.isEmpty {
                ContentUnavailableView.search(text: model.schemaFilter)
            }
        }
    }
}

/// An NSOutlineView of SObjects and their fields.
///
/// A SwiftUI List of an org's 1,000-plus SObjects made AppKit warn about a reentrant operation in
/// its table delegate while estimating row heights. Fixed-height rows avoid that estimation.
private struct SchemaOutline: NSViewRepresentable {
    let sobjects: [GlobalSObject]
    let describedNames: Set<String>
    let expanded: Set<String>
    let selection: SchemaItem?
    let filter: String
    let sortFields: Bool
    let describe: (String) -> SObjectDescribe?
    let isHighlighted: (FieldDescribe) -> Bool
    let onSelect: (SchemaItem?) -> Void
    let onExpand: (String, Bool) -> Void
    let onOpen: (SchemaItem) -> Void
    let onToggleSort: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.usesAutomaticRowHeights = false
        outline.rowSizeStyle = .default
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        context.coordinator.parent = self
        context.coordinator.update(outline)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let outline = scrollView.documentView as? NSOutlineView {
            context.coordinator.update(outline)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Node: NSObject {
        enum Kind {
            case sobject(GlobalSObject)
            case field(sobject: String, FieldDescribe)
            case loading
        }

        let kind: Kind
        var children: [Node] = []

        init(_ kind: Kind) {
            self.kind = kind
        }

        var item: SchemaItem? {
            switch kind {
            case .sobject(let sobject): .sobject(sobject.name)
            case .field(let sobject, let field): .field(sobject: sobject, field: field.name)
            case .loading: nil
            }
        }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: SchemaOutline
        private var nodes: [Node] = []
        private var nodesByName: [String: Node] = [:]
        private var shownNames: [String] = []
        private var shownDescribed: Set<String> = []
        private var shownSort = false
        private var shownFilter = ""
        /// True while the outline is changed to match the model, so its delegate calls aren't echoed back.
        private var isSyncing = false
        private weak var outline: NSOutlineView?

        init(parent: SchemaOutline) {
            self.parent = parent
        }

        // MARK: Keeping the outline in step with the model

        func update(_ outline: NSOutlineView) {
            self.outline = outline
            isSyncing = true
            defer { isSyncing = false }
            let names = parent.sobjects.map(\.name)
            if names != shownNames || parent.sortFields != shownSort || parent.filter != shownFilter {
                nodes = parent.sobjects.map { sobject in
                    let node = Node(.sobject(sobject))
                    node.children = children(of: sobject.name)
                    return node
                }
                nodesByName = Dictionary(nodes.map { (($0.item?.sobjectName ?? ""), $0) }, uniquingKeysWith: { a, _ in a })
                outline.reloadData()
            } else {
                // Only the SObjects described since the last update change.
                for name in parent.describedNames.symmetricDifference(shownDescribed) {
                    guard let node = nodesByName[name] else { continue }
                    node.children = children(of: name)
                    outline.reloadItem(node, reloadChildren: true)
                }
            }
            shownNames = names
            shownDescribed = parent.describedNames
            shownSort = parent.sortFields
            shownFilter = parent.filter

            for node in nodes {
                guard let name = node.item?.sobjectName else { continue }
                let shouldExpand = parent.expanded.contains(name)
                if shouldExpand != outline.isItemExpanded(node) {
                    if shouldExpand {
                        outline.expandItem(node)
                    } else {
                        outline.collapseItem(node)
                    }
                }
            }
            syncSelection(outline)
        }

        private func children(of sobject: String) -> [Node] {
            guard let describe = parent.describe(sobject) else { return [Node(.loading)] }
            let fields = parent.sortFields
                ? describe.fields.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                : describe.fields
            return fields.map { Node(.field(sobject: sobject, $0)) }
        }

        private func syncSelection(_ outline: NSOutlineView) {
            let current = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.item : nil
            guard current != parent.selection else { return }
            guard let selection = parent.selection, let row = row(of: selection, in: outline) else {
                outline.deselectAll(nil)
                return
            }
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }

        private func row(of item: SchemaItem, in outline: NSOutlineView) -> Int? {
            guard let sobjectNode = nodesByName[item.sobjectName] else { return nil }
            let node: Node? = switch item {
            case .sobject: sobjectNode
            case .field: sobjectNode.children.first { $0.item == item }
            }
            guard let node else { return nil }
            let row = outline.row(forItem: node)
            return row >= 0 ? row : nil
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return nodes.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return nodes[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            if case .sobject = (item as? Node)?.kind { return true }
            return false
        }

        // MARK: NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            switch node.kind {
            case .sobject(let sobject):
                let cell = outlineView.makeView(withIdentifier: SObjectCell.identifier, owner: nil) as? SObjectCell ?? SObjectCell()
                cell.configure(sobject, isDescribed: parent.describedNames.contains(sobject.name))
                return cell
            case .field(_, let field):
                let cell = outlineView.makeView(withIdentifier: FieldCell.identifier, owner: nil) as? FieldCell ?? FieldCell()
                cell.configure(field, isHighlighted: parent.isHighlighted(field))
                return cell
            case .loading:
                return LoadingCell()
            }
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.item != nil
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline = notification.object as? NSOutlineView else { return }
            let item = outline.selectedRow >= 0 ? (outline.item(atRow: outline.selectedRow) as? Node)?.item : nil
            parent.onSelect(item)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            expansionChanged(notification, isExpanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            expansionChanged(notification, isExpanded: false)
        }

        private func expansionChanged(_ notification: Notification, isExpanded: Bool) {
            guard !isSyncing, let node = notification.userInfo?["NSObject"] as? Node, let name = node.item?.sobjectName else { return }
            parent.onExpand(name, isExpanded)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let item = (sender.item(atRow: sender.clickedRow) as? Node)?.item else { return }
            parent.onOpen(item)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            if outline.clickedRow >= 0, let item = (outline.item(atRow: outline.clickedRow) as? Node)?.item {
                let copy = NSMenuItem(title: "Copy Name", action: #selector(copyName(_:)), keyEquivalent: "")
                copy.target = self
                copy.representedObject = item.name
                menu.addItem(copy)
            }
            let sort = NSMenuItem(title: "Sort Fields Alphabetically", action: #selector(toggleSort(_:)), keyEquivalent: "")
            sort.target = self
            sort.state = parent.sortFields ? .on : .off
            menu.addItem(sort)
        }

        @objc private func copyName(_ sender: NSMenuItem) {
            guard let name = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }

        @objc private func toggleSort(_ sender: NSMenuItem) {
            parent.onToggleSort()
        }
    }
}

private extension SchemaItem {
    /// The SObject or field name, for copying.
    var name: String {
        switch self {
        case .sobject(let name): name
        case .field(_, let field): field
        }
    }
}

private final class SObjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SObjectCell")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for v in [image, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ sobject: GlobalSObject, isDescribed: Bool) {
        textField?.stringValue = sobject.name
        textField?.textColor = isDescribed ? .labelColor : .secondaryLabelColor
        imageView?.image = NSImage(systemSymbolName: sobject.custom ? "tablecells.badge.ellipsis" : "tablecells", accessibilityDescription: nil)
        imageView?.contentTintColor = sobject.custom ? .systemOrange : .controlAccentColor
        toolTip = sobject.label
    }
}

private final class FieldCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FieldCell")
    private let type = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        type.lineBreakMode = .byTruncatingTail
        type.font = .preferredFont(forTextStyle: .caption1)
        type.textColor = .secondaryLabelColor
        type.alignment = .right
        type.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for v in [name, type] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            type.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            type.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            type.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        textField = name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ field: FieldDescribe, isHighlighted: Bool) {
        textField?.stringValue = field.name
        textField?.font = isHighlighted ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        textField?.textColor = isHighlighted ? .controlAccentColor : .labelColor
        type.stringValue = field.typeDescription
        toolTip = field.label
    }
}

private final class LoadingCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

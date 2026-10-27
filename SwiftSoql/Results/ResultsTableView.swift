import AppKit
import SwiftUI

/// The NSTableView behind `ResultsTable`. Cells are made only for the rows and columns on screen
/// and reused as the table scrolls.
struct ResultsTableView: NSViewRepresentable {
    let resultSet: ResultSet
    let model: ExplorerModel
    /// The fields that can be edited, by SObject type and then column.
    let editableFields: [String: [String: FieldDescribe]]
    let isSaving: Bool
    let canChangeData: Bool
    let checkedRows: Binding<Set<ResultRow.ID>>?
    let sortOrder: Binding<[ResultSortComparator]>
    let accessibilityID: String
    let onOpenChild: (QueryResult, String, ResultRow.ID) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = ResultsNSTableView()
        table.setAccessibilityIdentifier(accessibilityID)
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .default
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        // Type-select reads every row's text, which is slow with tens of thousands of rows.
        table.allowsTypeSelect = false
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.onCopy = { [weak coordinator] in coordinator?.copySelection() }
        table.menu = coordinator.rowMenu
        table.headerView?.menu = coordinator.headerMenu

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Scrolling and resizing change which columns have cells.
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.visibleAreaChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.visibleAreaChanged), name: NSView.frameDidChangeNotification, object: clip)

        coordinator.parent = self
        coordinator.update(table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let table = scrollView.documentView as? NSTableView {
            context.coordinator.update(table)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    enum Column: Equatable {
        case check
        case error
        case field(String)

        var identifier: NSUserInterfaceItemIdentifier {
            switch self {
            case .check: NSUserInterfaceItemIdentifier("✓")
            case .error: NSUserInterfaceItemIdentifier("⚠")
            case .field(let name): NSUserInterfaceItemIdentifier("field." + name)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: ResultsTableView
        let rowMenu = NSMenu()
        let headerMenu = NSMenu()
        private weak var table: NSTableView?

        /// The rows the table shows. Replaced only when the table reloads, so it always matches
        /// what's on screen, even while a reload waits for an edit to finish.
        private var rows: [ResultRow] = []
        private var columns: [Column] = []
        private var columnsByID: [NSUserInterfaceItemIdentifier: Column] = [:]
        private var paths: [String: [Substring]] = [:]
        private var shownRevision = -1
        private var shownEditable: Set<String> = []
        private var shownSaving = false
        private var shownChecked: Set<ResultRow.ID> = []
        private var shownErrors: [ResultRow.ID: String] = [:]
        private var shownHighlight: ResultRow.ID?
        /// True while the table is changed to match the model, so its delegate calls aren't echoed back.
        private var isSyncing = false
        private var datePopover: NSPopover?
        /// The columns that get cells: those on screen and a screen's width either side. AppKit
        /// makes a cell for every column of each row it shows, which with hundreds of columns
        /// made scrolling slow, so the rest get none until they come near.
        private var loadedColumns: Range<Int> = 0..<0
        private var loadedIDs: Set<NSUserInterfaceItemIdentifier> = []

        /// More than this many records at once would flood the browser with tabs.
        private static let maxRecordsToOpen = 20

        init(parent: ResultsTableView) {
            self.parent = parent
            super.init()
            rowMenu.delegate = self
            rowMenu.autoenablesItems = false
            headerMenu.delegate = self
            headerMenu.autoenablesItems = false
        }

        // MARK: Keeping the table in step with the model

        func update(_ table: NSTableView) {
            self.table = table
            isSyncing = true
            defer { isSyncing = false }
            let results = parent.resultSet

            var wanted: [Column] = []
            if parent.checkedRows != nil { wanted.append(.check) }
            if !results.rowErrors.isEmpty { wanted.append(.error) }
            wanted += results.columns.map(Column.field)

            let editable = Set(parent.editableFields.flatMap { type, fields in fields.keys.map { "\(type)\u{1}\($0)" } })
            let checked = parent.checkedRows?.wrappedValue ?? []
            let needsReload = wanted != columns || results.revision != shownRevision
            let needsRefresh = editable != shownEditable || parent.isSaving != shownSaving || checked != shownChecked || results.rowErrors != shownErrors

            // Changing the table now would end the edit in progress; finishing it updates again.
            if (needsReload || needsRefresh) && !isEditing(table) {
                if wanted != columns {
                    setColumns(wanted, in: table)
                }
                shownEditable = editable
                shownSaving = parent.isSaving
                shownChecked = checked
                shownErrors = results.rowErrors
                if needsReload {
                    shownRevision = results.revision
                    reloadKeepingSelection(table)
                } else {
                    reloadCells(inRows: availableRows(table), of: table)
                }
            }

            let sortDescriptors = parent.sortOrder.wrappedValue.prefix(1).map {
                NSSortDescriptor(key: $0.column, ascending: $0.order == .forward)
            }
            if table.sortDescriptors != sortDescriptors {
                table.sortDescriptors = sortDescriptors
            }

            if results.highlightedRowID != shownHighlight {
                shownHighlight = results.highlightedRowID
                if let id = shownHighlight, let index = rows.firstIndex(where: { $0.id == id }) {
                    // Not syncing, so the inspector follows, as it does for a click.
                    DispatchQueue.main.async {
                        table.selectRowIndexes([index], byExtendingSelection: false)
                        table.scrollRowToVisible(index)
                    }
                }
            }
        }

        /// Whether a cell's text is being edited.
        private func isEditing(_ table: NSTableView) -> Bool {
            guard let editor = table.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField else { return false }
            return field.isDescendant(of: table)
        }

        // MARK: Cells only for columns near the screen

        /// The columns on screen, with a screen's width either side.
        private func columnsToLoad(in table: NSTableView) -> Range<Int> {
            let visible = table.visibleRect
            guard visible.width > 0 else { return 0..<0 }
            let indexes = table.columnIndexes(in: visible.insetBy(dx: -visible.width, dy: 0))
            guard let first = indexes.first, let last = indexes.last else { return 0..<0 }
            return first..<last + 1
        }

        /// The rows that have row views, on screen or prepared just off it.
        private func availableRows(_ table: NSTableView) -> IndexSet {
            var rows = IndexSet()
            table.enumerateAvailableRowViews { _, row in rows.insert(row) }
            return rows
        }

        /// Reloads rows' cells in the loaded columns only: naming every column would make cells
        /// for hundreds of columns out of sight.
        private func reloadCells(inRows rows: IndexSet, of table: NSTableView) {
            let columns = IndexSet(loadedColumns.clamped(to: 0..<table.numberOfColumns))
            if !rows.isEmpty, !columns.isEmpty {
                table.reloadData(forRowIndexes: rows, columnIndexes: columns)
            }
        }

        private func ids(of range: Range<Int>, in table: NSTableView) -> Set<NSUserInterfaceItemIdentifier> {
            Set(range.clamped(to: 0..<table.numberOfColumns).map { table.tableColumns[$0].identifier })
        }

        @objc func visibleAreaChanged() {
            guard let table else { return }
            // Scrolling within the loaded columns needs nothing.
            let onScreen = table.columnIndexes(in: table.visibleRect)
            if let first = onScreen.first, let last = onScreen.last, loadedColumns.contains(first), loadedColumns.contains(last) { return }
            loadNearbyColumns(table)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            if let table { loadNearbyColumns(table) }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            visibleAreaChanged()
        }

        /// Gives cells to the columns that came near the screen, in every row that has a row
        /// view, and takes them from the columns that left.
        private func loadNearbyColumns(_ table: NSTableView) {
            let range = columnsToLoad(in: table)
            let ids = ids(of: range, in: table)
            guard ids != loadedIDs else {
                loadedColumns = range
                return
            }
            let changed = ids.symmetricDifference(loadedIDs)
            loadedColumns = range
            loadedIDs = ids
            let rowIndexes = availableRows(table)
            let columnIndexes = IndexSet(table.tableColumns.indices.filter { changed.contains(table.tableColumns[$0].identifier) })
            if !rowIndexes.isEmpty, !columnIndexes.isEmpty {
                table.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
            }
        }

        private func setColumns(_ wanted: [Column], in table: NSTableView) {
            let results = parent.resultSet
            // Keep the columns that stay, with their widths and whether they're hidden.
            var existing: [NSUserInterfaceItemIdentifier: NSTableColumn] = [:]
            for column in table.tableColumns {
                existing[column.identifier] = column
                table.removeTableColumn(column)
            }
            for column in wanted {
                let tableColumn = existing[column.identifier] ?? makeColumn(column, results: results)
                table.addTableColumn(tableColumn)
            }
            columns = wanted
            loadedColumns = columnsToLoad(in: table)
            loadedIDs = ids(of: loadedColumns, in: table)
            columnsByID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.identifier, $0) })
            paths = Dictionary(uniqueKeysWithValues: results.columns.map { ($0, $0.split(separator: ".")) })
        }

        private func makeColumn(_ column: Column, results: ResultSet) -> NSTableColumn {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.minWidth = 40
            // Every column sorts; the checkbox and error columns sort by the order rows were loaded in.
            switch column {
            case .check:
                tableColumn.title = ""
                tableColumn.minWidth = 22
                tableColumn.width = 22
                tableColumn.resizingMask = []
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "", ascending: true)
            case .error:
                tableColumn.title = "Error"
                tableColumn.width = 240
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: "", ascending: true)
            case .field(let name):
                tableColumn.title = name
                tableColumn.width = results.idealWidth(for: name)
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
            }
            return tableColumn
        }

        /// Reloads the rows, keeping the same records selected.
        private func reloadKeepingSelection(_ table: NSTableView) {
            let selected = Set(table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
            rows = parent.resultSet.visibleRows
            table.reloadData()
            if !selected.isEmpty {
                table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
            }
        }

        private func reloadRow(_ id: ResultRow.ID) {
            guard let table, let index = rows.firstIndex(where: { $0.id == id }) else { return }
            reloadCells(inRows: [index], of: table)
        }

        /// Catches up with changes that waited for an edit to finish.
        private func editingEnded() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.update(table)
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard let tableColumn, index < rows.count, loadedIDs.contains(tableColumn.identifier),
                  let column = columnsByID[tableColumn.identifier] else { return nil }
            let row = rows[index]
            switch column {
            case .check:
                let deleted = parent.resultSet.includesDeleted
                let cell = tableView.reusedCell(CheckboxCell.self)
                cell.configure(isOn: shownChecked.contains(row.id), label: deleted ? "Check row" : "Check row for deletion", isEnabled: true) { [weak self] isOn in
                    if isOn {
                        self?.parent.checkedRows?.wrappedValue.insert(row.id)
                    } else {
                        self?.parent.checkedRows?.wrappedValue.remove(row.id)
                    }
                }
                return cell
            case .error:
                let cell = tableView.reusedCell(TextCell.self)
                cell.configure(shownErrors[row.id] ?? "", color: .systemRed)
                return cell
            case .field(let name):
                return fieldCell(tableView, row: row, column: name)
            }
        }

        private func fieldCell(_ tableView: NSTableView, row: ResultRow, column: String) -> NSView {
            let value = row.record.value(atPath: paths[column] ?? [])
            if let value, let child = QueryResult(nested: value) {
                let cell = tableView.reusedCell(LinkCell.self)
                cell.configure("\(child.totalSize) \(child.totalSize == 1 ? "row" : "rows")") { [weak self] in
                    self?.parent.onOpenChild(child, column, row.id)
                }
                return cell
            }
            guard row.recordID != nil, let type = row.record.sobjectType, let field = parent.editableFields[type]?[column] else {
                let cell = tableView.reusedCell(TextCell.self)
                cell.configure(value?.displayText ?? "")
                return cell
            }
            let isEnabled = !parent.isSaving
            let save: (String) -> Void = { [weak self] text in self?.save(text, column: column, rowID: row.id) }
            switch field.type {
            case "boolean":
                let cell = tableView.reusedCell(CheckboxCell.self)
                cell.configure(isOn: value?.bool ?? false, label: field.name, isEnabled: isEnabled) { save($0 ? "true" : "false") }
                return cell
            case "picklist":
                let cell = tableView.reusedCell(PicklistCell.self)
                cell.configure(field: field, value: value?.string, isEnabled: isEnabled, choose: save)
                return cell
            case "date", "datetime":
                let cell = tableView.reusedCell(DateCell.self)
                cell.configure(value?.string ?? "", label: field.name, isEditable: isEnabled, delegate: self, rowID: row.id, column: column)
                cell.onChooseDate = { [weak self, weak cell] in
                    guard let self, let cell else { return }
                    self.showDatePicker(for: field, value: value?.string, from: cell.calendarButton, save: save)
                }
                return cell
            default:
                let cell = tableView.reusedCell(EditableTextCell.self)
                cell.configure(value?.displayText ?? "", label: field.name, isEditable: isEnabled, delegate: self, rowID: row.id, column: column)
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let table else { return }
            // The inspector's Record tab follows the selected row.
            if table.selectedRowIndexes.count == 1, let index = table.selectedRowIndexes.first, index < rows.count {
                parent.model.inspectRecord(in: rows[index], api: parent.resultSet.api)
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isSyncing else { return }
            parent.sortOrder.wrappedValue = tableView.sortDescriptors.prefix(1).map {
                ResultSortComparator(column: $0.key ?? "", order: $0.ascending ? .forward : .reverse)
            }
        }

        /// Double-clicking an editable text cell edits it.
        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow, column = sender.clickedColumn
            guard row >= 0, column >= 0, let cell = sender.view(atColumn: column, row: row, makeIfNecessary: false) as? EditableTextCell,
                  cell.field.isEditable else { return }
            sender.editColumn(column, row: row, with: nil, select: true)
        }

        // MARK: Editing

        private func save(_ text: String, column: String, rowID: ResultRow.ID) {
            guard let row = rows.first(where: { $0.id == rowID }) else { return }
            Task {
                // On success the results change and the table reloads; otherwise put the old value back.
                if !(await parent.model.saveEdit(text, field: column, row: row)) {
                    reloadRow(rowID)
                }
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let cell = field.superview as? EditableTextCell else { return }
            if field.stringValue != cell.original, let rowID = cell.rowID, let column = cell.column {
                save(field.stringValue, column: column, rowID: rowID)
            }
            editingEnded()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Escape puts the value back.
            guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField,
                  let cell = field.superview as? EditableTextCell else { return false }
            field.stringValue = cell.original
            field.abortEditing()
            table?.window?.makeFirstResponder(table)
            editingEnded()
            return true
        }

        private func showDatePicker(for field: FieldDescribe, value: String?, from button: NSView, save: @escaping (String) -> Void) {
            datePopover?.close()
            let includesTime = field.type == "datetime"
            let popover = NSPopover()
            popover.behavior = .transient
            let start = value.flatMap { SalesforceDates.parse($0, includesTime: includesTime) } ?? Date()
            popover.contentViewController = NSHostingController(rootView: DatePickerPopover(field: field, start: start, includesTime: includesTime) { [weak popover] text in
                popover?.close()
                if let text, text != (value ?? "") { save(text) }
            })
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            datePopover = popover
        }

        // MARK: Copying

        private var selectedIDs: Set<ResultRow.ID> {
            Set(table?.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil } ?? [])
        }

        func copySelection() {
            copy(selectedIDs, includeHeader: false)
        }

        private func copy(_ ids: Set<ResultRow.ID>, includeHeader: Bool) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ResultsExport.tabSeparated(parent.resultSet, rowIDs: ids, includeHeader: includeHeader), forType: .string)
        }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu {
                updateHeaderMenu(menu)
            } else {
                updateRowMenu(menu)
            }
        }

        /// Shows or hides each column.
        private func updateHeaderMenu(_ menu: NSMenu) {
            guard let table else { return }
            for tableColumn in table.tableColumns {
                guard case .field(let name) = columnsByID[tableColumn.identifier] else { continue }
                let item = ClosureMenuItem(name) { [weak self] in
                    tableColumn.isHidden.toggle()
                    self?.visibleAreaChanged()
                }
                item.state = tableColumn.isHidden ? .off : .on
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(showAllColumnsItem())
        }

        private func showAllColumnsItem() -> NSMenuItem {
            let hidden = table?.tableColumns.filter(\.isHidden) ?? []
            return ClosureMenuItem("Show All Columns", isEnabled: !hidden.isEmpty) { [weak self] in
                hidden.forEach { $0.isHidden = false }
                self?.visibleAreaChanged()
            }
        }

        private func updateRowMenu(_ menu: NSMenu) {
            guard let table else { return }
            let results = parent.resultSet
            let model = parent.model
            // The clicked row, or the selection if the clicked row is part of it.
            let clicked = table.clickedRow
            let ids: Set<ResultRow.ID> = if clicked >= 0, clicked < rows.count, !table.selectedRowIndexes.contains(clicked) {
                [rows[clicked].id]
            } else {
                selectedIDs
            }
            let chosen = results.rows.filter { ids.contains($0.id) }

            menu.addItem(ClosureMenuItem("Copy", isEnabled: !ids.isEmpty) { [weak self] in self?.copy(ids, includeHeader: false) })
            menu.addItem(ClosureMenuItem("Copy with Column Names", isEnabled: !ids.isEmpty) { [weak self] in self?.copy(ids, includeHeader: true) })
            menu.addItem(ClosureMenuItem("Copy as JSON", isEnabled: !ids.isEmpty) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ResultsExport.json(chosen.map(\.record)), forType: .string)
            })
            menu.addItem(ClosureMenuItem("Show in Loaded Order", isEnabled: !parent.sortOrder.wrappedValue.isEmpty) { [weak self] in
                self?.parent.sortOrder.wrappedValue = []
            })
            menu.addItem(showAllColumnsItem())
            menu.addItem(.separator())

            let single = chosen.count == 1 ? chosen.first : nil
            if let row = single, row.recordID != nil, row.record.sobjectType != nil {
                menu.addItem(ClosureMenuItem("Show All Fields") {
                    model.inspectRecord(in: row, api: results.api)
                    AppDefaults.store.set(InspectorPanel.Tab.record.rawValue, forKey: "inspectorTab")
                    AppDefaults.store.set(true, forKey: "showDetailsInspector")
                })
            }
            let recordIDs = chosen.compactMap(\.recordID)
            menu.addItem(ClosureMenuItem(recordIDs.count > 1 ? "Open \(recordIDs.count) Records in Salesforce" : "Open in Salesforce",
                                         isEnabled: !recordIDs.isEmpty && recordIDs.count <= Self.maxRecordsToOpen) {
                for id in recordIDs {
                    if let url = model.recordURL(id) { NSWorkspace.shared.open(url) }
                }
            })
            if let row = single {
                let related = model.relatedRecords(in: row, columns: results.columns)
                if !related.isEmpty {
                    let submenu = NSMenu()
                    submenu.autoenablesItems = false
                    for record in related {
                        submenu.addItem(ClosureMenuItem("\(record.column) (\(record.type))") {
                            if let url = model.recordURL(record.id) { NSWorkspace.shared.open(url) }
                        })
                    }
                    let item = NSMenuItem(title: "Open Related Record", action: nil, keyEquivalent: "")
                    item.submenu = submenu
                    menu.addItem(item)
                }
            }
            if results.isEditable, parent.canChangeData, let row = single, row.recordID != nil {
                menu.addItem(ClosureMenuItem("Clone Record…", isEnabled: !parent.isSaving) {
                    Task { await model.cloneRecord(row) }
                })
            }
            if let checkedRows = parent.checkedRows {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(results.includesDeleted ? "Check Rows" : "Check Rows for Deletion", isEnabled: !ids.isEmpty) {
                    checkedRows.wrappedValue.formUnion(ids)
                })
                menu.addItem(ClosureMenuItem("Uncheck Rows", isEnabled: !ids.isEmpty) {
                    checkedRows.wrappedValue.subtract(ids)
                })
                menu.addItem(.separator())
                let shown = rows.map(\.id)
                menu.addItem(ClosureMenuItem(results.filter.isEmpty ? "Check All Rows" : "Check All Shown Rows") {
                    checkedRows.wrappedValue.formUnion(shown)
                })
                menu.addItem(ClosureMenuItem("Uncheck All Rows", isEnabled: !checkedRows.wrappedValue.isEmpty) {
                    checkedRows.wrappedValue = []
                })
            }
        }
    }
}

/// The results table, which copies its selected rows.
final class ResultsNSTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Cells

private extension NSTableView {
    /// A cell of the given kind from the table's reuse queue, or a new one.
    func reusedCell<Cell: NSTableCellView>(_ kind: Cell.Type) -> Cell {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: kind))
        if let cell = makeView(withIdentifier: identifier, owner: nil) as? Cell { return cell }
        let cell = Cell()
        cell.identifier = identifier
        return cell
    }
}

private extension NSView {
    /// Pins a control to the cell's leading and trailing edges, centered vertically.
    func pin(_ view: NSView, leading: CGFloat = 2, trailing: CGFloat = 2) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -trailing),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}

/// Read-only text, on one line. A truncated value shows in full when the pointer rests on it.
private final class TextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ text: String, color: NSColor = .labelColor) {
        label.stringValue = text
        label.textColor = color
    }
}

/// Text that can be edited: double-click it, or click it in a selected row. Return or moving
/// elsewhere saves it, and Escape puts the value back.
private class EditableTextCell: NSTableCellView {
    let field = NSTextField()
    /// The value before editing.
    private(set) var original = ""
    private(set) var rowID: ResultRow.ID?
    private(set) var column: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.allowsExpansionToolTips = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        layoutField()
        textField = field
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func layoutField() {
        pin(field)
        field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2).isActive = true
    }

    func configure(_ text: String, label: String, isEditable: Bool, delegate: NSTextFieldDelegate, rowID: ResultRow.ID, column: String) {
        original = text
        field.stringValue = text
        field.isEditable = isEditable
        field.isSelectable = isEditable
        field.delegate = delegate
        field.setAccessibilityLabel(label)
        self.rowID = rowID
        self.column = column
    }
}

/// A date or date-time: typed like other text, or picked from a calendar with the button that the
/// selected row shows.
private final class DateCell: EditableTextCell {
    let calendarButton = NSButton()
    var onChooseDate: (() -> Void)?

    override func layoutField() {
        calendarButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Choose a date")
        calendarButton.isBordered = false
        calendarButton.target = self
        calendarButton.action = #selector(chooseDate)
        calendarButton.toolTip = "Choose a date"
        calendarButton.isHidden = true
        calendarButton.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(calendarButton)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            calendarButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 2),
            calendarButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            calendarButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// The row draws its selection behind its cells as emphasized, which is when the button shows.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { calendarButton.isHidden = backgroundStyle != .emphasized || !field.isEditable }
    }

    override func configure(_ text: String, label: String, isEditable: Bool, delegate: NSTextFieldDelegate, rowID: ResultRow.ID, column: String) {
        super.configure(text, label: label, isEditable: isEditable, delegate: delegate, rowID: rowID, column: column)
        calendarButton.isHidden = backgroundStyle != .emphasized || !isEditable
        calendarButton.setAccessibilityLabel("Choose \(label)")
    }

    @objc private func chooseDate() {
        onChooseDate?()
    }
}

/// A checkbox: a true/false field, or a row checked for deletion.
private final class CheckboxCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var onChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.target = self
        checkbox.action = #selector(changed)
        pin(checkbox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(isOn: Bool, label: String, isEnabled: Bool, onChange: @escaping (Bool) -> Void) {
        checkbox.state = isOn ? .on : .off
        checkbox.isEnabled = isEnabled
        checkbox.setAccessibilityLabel(label)
        self.onChange = onChange
    }

    @objc private func changed() {
        onChange?(checkbox.state == .on)
    }
}

/// A picklist value, with a menu of the field's active values to change it. The menu is filled
/// when it opens, since a picklist can have hundreds of values.
private final class PicklistCell: NSTableCellView, NSMenuDelegate {
    private let button = NSPopUpButton(frame: .zero, pullsDown: true)
    private var field: FieldDescribe?
    private var value: String?
    private var choose: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.target = self
        button.action = #selector(chosen)
        button.menu?.delegate = self
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pin(button, leading: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(field: FieldDescribe, value: String?, isEnabled: Bool, choose: @escaping (String) -> Void) {
        self.field = field
        self.value = value
        self.choose = choose
        button.removeAllItems()
        // A pull-down button shows its first item as its title.
        button.addItem(withTitle: value ?? "")
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(field.name)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let field else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        func add(_ title: String, _ itemValue: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = itemValue
            item.state = itemValue == (value ?? "") ? .on : .off
            menu.addItem(item)
        }
        if field.nillable {
            add("None", "")
            menu.addItem(.separator())
        }
        for item in field.picklistValues where item.active {
            add(item.label == item.value ? item.value : "\(item.label) (\(item.value))", item.value)
        }
    }

    @objc private func chosen() {
        guard let chosen = button.selectedItem?.representedObject as? String, chosen != (value ?? "") else { return }
        choose?(chosen)
    }
}

/// A subquery's rows, as a link that shows them below.
private final class LinkCell: NSTableCellView {
    private let button = NSButton(title: "", target: nil, action: nil)
    private var open: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityHelp("Shows these rows below")
        pin(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ title: String, open: @escaping () -> Void) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        self.open = open
    }

    @objc private func clicked() {
        open?()
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, isEnabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.isEnabled = isEnabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() {
        handler()
    }
}

/// A calendar for choosing a date cell's value. Finishes with the value as Salesforce writes it,
/// empty to clear it, or nil to leave it alone.
private struct DatePickerPopover: View {
    let field: FieldDescribe
    let includesTime: Bool
    let finish: (String?) -> Void
    @State private var picked: Date

    init(field: FieldDescribe, start: Date, includesTime: Bool, finish: @escaping (String?) -> Void) {
        self.field = field
        self.includesTime = includesTime
        self.finish = finish
        _picked = State(initialValue: start)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            DatePicker(field.name, selection: $picked, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                if field.nillable {
                    Button("Clear") { finish("") }
                }
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { finish(SalesforceDates.format(picked, includesTime: includesTime)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }
}

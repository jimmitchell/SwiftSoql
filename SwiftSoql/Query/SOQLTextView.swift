import AppKit

/// A text view that shows a completions popup when typing pauses at the end of a word, and
/// explains errors when an underlined error is clicked. Ported from SoqlXplorer's ZKTextView.
final class SOQLTextView: NSTextView {
    /// Supplies the completions for a range of text.
    var completionsProvider: (NSRange) -> [Completion] = { _ in [] }

    private var popupCompletions: [Completion] = []
    private var lastEvent = ProcessInfo.processInfo.systemUptime
    private var hasTyped = false
    private var idleTimer: Timer?

    private lazy var completionsTable: NSTableView = {
        let table = NSTableView()
        // One column that fills the popover, so long names aren't cut off.
        let column = NSTableColumn(identifier: .init("completion"))
        column.width = 300
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(completionDoubleClicked)
        return table
    }()

    private lazy var completionsPopover: NSPopover = {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        scroll.documentView = completionsTable
        scroll.hasVerticalScroller = true
        let vc = NSViewController()
        vc.view = scroll
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .semitransient
        popover.animates = false
        return popover
    }()

    private lazy var errorLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.preferredMaxLayoutWidth = 360
        return label
    }()

    private lazy var errorPopover: NSPopover = {
        let vc = NSViewController()
        let container = NSView()
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            errorLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            errorLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        vc.view = container
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        return popover
    }()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        idleTimer?.invalidate()
        idleTimer = nil
        if window != nil {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkIdle() }
            }
        }
    }

    // We control the formatting, so pasted rich text is treated as plain text.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        if let storage = textStorage, charIndex >= 0, charIndex < storage.length {
            var attrRange = NSRange()
            if let message = storage.attribute(.toolTip, at: charIndex, effectiveRange: &attrRange) as? String {
                errorLabel.stringValue = message
                errorPopover.show(relativeTo: rect(forCharacterRange: attrRange), of: self, preferredEdge: .maxY)
            }
        }
        hasTyped = true
        lastEvent = ProcessInfo.processInfo.systemUptime
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        lastEvent = ProcessInfo.processInfo.systemUptime
        super.mouseMoved(with: event)
    }

    override func keyDown(with event: NSEvent) {
        lastEvent = ProcessInfo.processInfo.systemUptime
        let key = event.charactersIgnoringModifiers ?? ""
        if completionsPopover.isShown, let keyChar = key.utf16.first, key.utf16.count == 1 {
            var isFinal = false
            var movement = NSTextMovement.other
            switch Int(keyChar) {
            case NSPageUpFunctionKey, NSPageDownFunctionKey:
                let amount = Int(keyChar) == NSPageUpFunctionKey ? -8 : 8
                let row = min(max(0, completionsTable.selectedRow + amount), completionsTable.numberOfRows - 1)
                completionsTable.selectRowIndexes([row], byExtendingSelection: false)
                completionsTable.scrollRowToVisible(row)
            case NSUpArrowFunctionKey, NSDownArrowFunctionKey:
                completionsTable.keyDown(with: event)
                movement = .up
            case 0x09: // tab
                isFinal = true
                movement = .tab
            case 0x0D: // return
                isFinal = true
                movement = .return
            case 0x1B, NSLeftArrowFunctionKey, NSRightArrowFunctionKey: // escape
                completionsPopover.performClose(self)
                return
            case 0x20, 0x2E, NSDeleteFunctionKey: // space, period
                completionsPopover.performClose(self)
                hasTyped = true
                super.keyDown(with: event)
                return
            default:
                hasTyped = true
                super.keyDown(with: event)
                return
            }
            let row = completionsTable.selectedRow
            if row >= 0 && row < popupCompletions.count {
                let c = popupCompletions[row]
                insertCompletion(isFinal ? c.finalInsertionText : c.nonFinalInsertionText,
                                 forPartialWordRange: rangeForUserCompletion, movement: movement.rawValue, isFinal: isFinal)
                if isFinal {
                    completionsPopover.performClose(self)
                    hasTyped = perform(c.onFinalInsert)
                }
            }
            return
        }
        if errorPopover.isShown {
            errorPopover.performClose(self)
        }
        hasTyped = true
        if let keyChar = key.utf16.first, key.utf16.count == 1,
           Int(keyChar) == NSUpArrowFunctionKey || Int(keyChar) == NSDownArrowFunctionKey {
            hasTyped = false
        }
        super.keyDown(with: event)
    }

    /// Does a completion's final insert action, returning whether to treat it as typing.
    private func perform(_ action: Completion.FinalInsertAction) -> Bool {
        switch action {
        case .none:
            return false
        case .moveSelection(let amount):
            var sel = selectedRange()
            sel.location += amount
            setSelectedRange(sel)
            return true
        case .selectRelationshipField:
            // Select the "Id" just inserted, so typing replaces it.
            var sel = selectedRange()
            sel.location -= 2
            sel.length += 2
            setSelectedRange(sel)
            showPopup()
            return true
        }
    }

    func showPopup() {
        let partialWordRange = rangeForUserCompletion
        popupCompletions = completionsProvider(partialWordRange)
            .sorted { $0.displayText.caseInsensitiveCompare($1.displayText) == .orderedAscending }
        guard !popupCompletions.isEmpty else { return }
        let typed = (string as NSString).substring(with: partialWordRange)
        let selIdx = popupCompletions.firstIndex { $0.displayText.caseInsensitiveCompare(typed) != .orderedAscending }
        completionsTable.reloadData()
        let height = min(CGFloat(popupCompletions.count), 10) * (completionsTable.rowHeight + completionsTable.intercellSpacing.height) + 4
        completionsPopover.contentSize = NSSize(width: 320, height: height)
        if let selIdx {
            completionsTable.selectRowIndexes([selIdx], byExtendingSelection: false)
            completionsTable.scrollRowToVisible(selIdx)
        } else {
            completionsTable.deselectAll(nil)
        }
        completionsPopover.show(relativeTo: rect(forCharacterRange: selectedRange()), of: self, preferredEdge: .maxY)
    }

    private func isWordBreak(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == unichar(ascii: ",") || c == unichar(ascii: "(") || c == unichar(ascii: ")") || c == 0x0D || c == 0x0A
    }

    private var isAtEndOfWord: Bool {
        let r = selectedRange()
        let txt = string as NSString
        if r.location == 0 { return false }
        if r.location == txt.length { return true }
        let prev = txt.character(at: r.location - 1)
        let next = txt.character(at: r.location)
        return isWordBreak(next) && prev != 0x20 && prev != 0x09
    }

    private func checkIdle() {
        let now = ProcessInfo.processInfo.systemUptime
        if hasTyped && now - lastEvent > 0.4 {
            lastEvent = now
            hasTyped = false
            if isAtEndOfWord && window?.firstResponder === self {
                showPopup()
            }
        }
    }

    /// The partial word before the insertion point.
    override var rangeForUserCompletion: NSRange {
        var sel = selectedRange()
        let txt = string as NSString
        while sel.location > 0 {
            let c = txt.character(at: sel.location - 1)
            if isWordBreak(c) || c == unichar(ascii: ".") { break }
            sel.location -= 1
            sel.length += 1
        }
        return sel
    }

    @objc private func completionDoubleClicked() {
        let row = completionsTable.clickedRow
        guard row >= 0 && row < popupCompletions.count else { return }
        let c = popupCompletions[row]
        insertCompletion(c.finalInsertionText, forPartialWordRange: rangeForUserCompletion, movement: NSTextMovement.other.rawValue, isFinal: true)
        completionsPopover.performClose(self)
        hasTyped = perform(c.onFinalInsert)
    }

    private func rect(forCharacterRange range: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        r.origin.x += textContainerOrigin.x
        r.origin.y += textContainerOrigin.y
        r.size.width += 2
        return r
    }
}

extension SOQLTextView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        popupCompletions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("CompletionCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            for v in [image, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = text
            return cell
        }()
        let c = popupCompletions[row]
        cell.textField?.stringValue = c.displayText
        cell.imageView?.image = SOQLStyle.icon(for: c.type)
        return cell
    }
}

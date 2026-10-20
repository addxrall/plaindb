import AppKit

private let rowHeight: CGFloat = 22, listWidth: CGFloat = 340
private let visibleRows = 9

// Selection that stays drawn although the text view, not the list, has the focus.
private final class CompletionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Theme.sel.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// Completion list for the SQL editor: becomes the text view's delegate, shows sqlSuggestions under the cursor while
// typing (or on ⌃Space / Esc), ↑↓ to choose, Tab or Enter to insert, Esc to close.
@MainActor final class SQLCompleter: NSObject, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var schema: SchemaGraph?
    var isShown: Bool { panel?.isVisible ?? false }

    private weak var textView: NSTextView?
    private var panel: NSPanel?
    private let list = NSTableView()
    private var items: [SQLSuggestion] = []
    private var chosen = 0 // kept here: a table in a window that isn't on screen yet drops its selection
    private var replace = NSRange() // the word being completed
    private var inserting = false
    private var monitor: Any?

    init(textView: NSTextView) {
        self.textView = textView
        super.init()
        textView.delegate = self
        // ⌃Space opens the list, as in most editors
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let ctrlSpace = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control && event.keyCode == 49
            guard ctrlSpace, let self, let view = self.textView, view.window?.firstResponder === view else { return event }
            self.show()
            return nil
        }
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        panel?.close()
    }

    // For the current word, also with nothing typed yet.
    func show() { update(showingEmpty: true) }

    func hide() {
        guard let panel else { return }
        if panel.isVisible { textView?.window?.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    // MARK: List window

    private func buildPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: listWidth, height: rowHeight * CGFloat(visibleRows)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        pin(Panel(fill: Theme.modal, border: Theme.boxB, radius: 10), background)

        list.headerView = nil
        list.rowHeight = rowHeight
        list.intercellSpacing = .zero
        list.backgroundColor = .clear
        list.style = .plain
        list.refusesFirstResponder = true
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")))
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(accept)
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        pin(scroll, background, NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0))
        panel.contentView = background
        return panel
    }

    // Recomputes the list for the cursor; `force` also shows it with no word typed (⌃Space).
    private func update(showingEmpty force: Bool) {
        guard let view = textView, view.selectedRange().length == 0 else { return hide() }
        let (suggestions, replace) = sqlSuggestions(view.string, cursor: view.selectedRange().location, schema: schema, evenWithoutWord: force)
        guard !suggestions.isEmpty else { return hide() }
        (items, chosen, self.replace) = (suggestions, 0, replace)
        let panel = self.panel ?? buildPanel()
        self.panel = panel
        list.reloadData()
        list.scrollRowToVisible(0)
        // under the line, names lined up with the word's start (badge first); above it near the bottom of the screen
        let word = view.firstRect(forCharacterRange: NSRange(location: replace.location, length: 0), actualRange: nil)
        let height = rowHeight * CGFloat(min(suggestions.count, visibleRows)) + 12
        var frame = NSRect(x: word.minX - 28, y: word.minY - height - 3, width: listWidth, height: height)
        if let screen = view.window?.screen?.visibleFrame, frame.minY < screen.minY { frame.origin.y = word.maxY + 3 }
        panel.setFrame(frame, display: true)
        if !panel.isVisible { view.window?.addChildWindow(panel, ordered: .above) }
    }

    @objc private func accept() {
        guard let view = textView, chosen >= 0, chosen < items.count else { return hide() }
        let text = items[chosen].text
        let call = text.hasSuffix("(")
        inserting = true
        view.insertText(call ? text + ")" : text, replacementRange: replace)
        if call { view.setSelectedRange(NSRange(location: view.selectedRange().location - 1, length: 0)) } // between the parentheses
        inserting = false
        hide()
    }

    // MARK: Text view delegate

    func textDidChange(_ notification: Notification) {
        guard !inserting, let view = textView else { return }
        let text = view.string as NSString
        let cursor = view.selectedRange().location
        let typed: unichar = cursor > 0 && cursor <= text.length ? text.character(at: cursor - 1) : 0
        let word = typed == 46 || typed == 95 || (Unicode.Scalar(typed).map { CharacterSet.alphanumerics.contains($0) } ?? false) // . _
        if word || isShown { update(showingEmpty: false) }
    }

    // Moving the cursor away from the word closes the list.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard isShown, !inserting, let sel = textView?.selectedRange() else { return }
        if sel.length > 0 || sel.location < replace.location || sel.location > NSMaxRange(replace) + 1 { hide() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isShown else {
            if selector == #selector(NSResponder.complete(_:)) { show(); return true } // Esc / ⌥Esc
            return false
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            choose(max(0, min(items.count - 1, chosen + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1))))
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            accept()
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)):
            hide() // and the cursor moves
            return false
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private func choose(_ row: Int) {
        let previous = chosen
        chosen = row
        var rows = IndexSet(integer: row)
        if previous >= 0 && previous < items.count { rows.insert(previous) }
        list.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        list.scrollRowToVisible(row)
    }

    // A click picks a row; a double-click inserts it.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        choose(row)
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CompletionRowView()
        view.isSelected = row == chosen
        return view
    }

    // kind badge · name · detail (type and table)
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = items[row]
        tableView.rowView(atRow: row, makeIfNecessary: false)?.isSelected = row == chosen
        let (letter, color): (String, NSColor) = switch s.kind {
        case .column: ("C", Theme.acc)
        case .table: ("T", Theme.green)
        case .function: ("ƒ", Theme.fn)
        case .keyword: ("K", Theme.kw)
        }
        let badge = label(letter, 10, .bold, color)
        badge.alignment = .center
        let name = label(s.text, 12, .regular, Theme.t1, mono: true)
        let detail = label(s.detail, 11, .regular, Theme.t3)
        detail.alignment = .right
        let cell = NSView()
        for v in [badge, name, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        detail.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1), for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

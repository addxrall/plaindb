import AppKit
import QuartzCore

// A value as the popovers show it: NULL, newlines as ⏎, at most 300 characters.
func referenceShownValue(_ value: DBValue) -> String {
    guard let s = value.string else { return "NULL" }
    let line = s.replacingOccurrences(of: "\n", with: " ⏎ ")
    return line.count > 300 ? String(line.prefix(300)) + "…" : line
}

// The × in a popover header.
private final class CloseGlyph: NSButton {
    private var hovering = false { didSet { restyle() } }

    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        (self.target, self.action) = (target, action)
        isBordered = false
        toolTip = L("Close")
        setButtonType(.momentaryChange)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        restyle()
    }

    private func restyle() {
        attributedTitle = NSAttributedString(string: "×", attributes: [.font: Theme.font(15), .foregroundColor: hovering ? Theme.t1 : Theme.t3])
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// MARK: - Preview

// Popover content showing the row a foreign key points to, field by field, with Open Table. Six rows show at once;
// more scroll. Its background is transparent: it is meant for a CardPopover, and also reads well inside an NSPopover.
final class ReferencePreview: NSViewController {
    var onOpenTable: (() -> Void)?
    private let titleText, subtitle: String
    private let result: DBResult

    static let width: CGFloat = 320
    static let visibleRows = 6
    private static let rowHeight: CGFloat = 23

    // `result` holds the referenced row (or no rows when it doesn't exist).
    init(title: String, subtitle: String, result: DBResult) {
        (titleText, self.subtitle, self.result) = (title, subtitle, result)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // The fields shown: column, value as shown, whether it is NULL; nil when the row doesn't exist.
    static func fields(_ result: DBResult) -> [(column: String, value: String, isNull: Bool)]? {
        guard let row = result.rows.first else { return nil }
        return zip(result.columns, row).map { ($0, referenceShownValue($1), $1.isNull) }
    }

    override func loadView() {
        let title = label(titleText, 13, .semibold)
        let sub = label(subtitle, 11, .regular, Theme.t2)
        let titles = NSStackView(views: [title, sub])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let close = CloseGlyph(target: self, action: #selector(closeClicked))
        let header = NSView()
        for v in [titles, close] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titles.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            titles.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
            close.leadingAnchor.constraint(equalTo: titles.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            close.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)

        let body: NSView
        if let fields = Self.fields(result) {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = 0
            rows.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            for (i, f) in fields.enumerated() {
                let name = label(f.column, 12, .regular, Theme.t2)
                name.toolTip = f.column
                name.widthAnchor.constraint(equalToConstant: 90).isActive = true
                let value = label(f.value, 12, .regular, f.isNull ? Theme.t3 : Theme.t1, mono: true)
                value.isSelectable = true
                value.toolTip = result.rows[0][i].string
                let line = NSStackView(views: [name, value])
                line.spacing = 12
                line.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
                line.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                rows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            let document = FlippedView()
            pin(rows, document)
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            document.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = document
            NSLayoutConstraint.activate([
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: CGFloat(min(fields.count, Self.visibleRows)) * Self.rowHeight + 12),
            ])
            body = scroll
        } else {
            let missing = wrappingLabel(L("The referenced row doesn't exist."), 12, Theme.t2)
            let box = NSView()
            pin(missing, box, NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
            body = box
        }

        let open = PillButton(L("Open Table"), target: self, action: #selector(openTable))
        let footer = bar([], [open], height: 42, left: 12, right: 12)
        let view = column([header, separator(), body, separator(), footer])
        view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        self.view = view
    }

    @objc private func openTable(_ sender: Any?) {
        onOpenTable?()
    }

    // Closes whatever shows it: a CardPopover or an NSPopover (both answer performClose: in the responder chain).
    @objc private func closeClicked(_ sender: Any?) {
        _ = view.tryToPerform(#selector(NSPopover.performClose(_:)), with: sender)
    }
}

// MARK: - Picker

// Popover content for choosing the row a foreign key should point to: search the referenced table, pick a row,
// and its key value goes into the cell. Transparent background, like ReferencePreview.
final class ReferencePicker: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onSearch: ((String) -> Void)? // "" = first rows; answer with showResult
    var onPick: ((DBValue) -> Void)?  // the key value as the database returned it, or .null
    private let columnName, table, keyColumn: String
    private var result: DBResult?
    private let search = NSSearchField()
    private let list = NSTableView()
    private let status = label("", 11, .regular, Theme.t2)

    // Titled "column → table".
    init(column: String, table: String, keyColumn: String) {
        (columnName, self.table, self.keyColumn) = (column, table, keyColumn)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // The status line under the results: the error, the number of rows or "Nothing found".
    static func statusText(_ result: DBResult?, error: Error?) -> String {
        if let error { return error.localizedDescription }
        let n = result?.rows.count ?? 0
        return n > 0 ? LN("%lu rows", n) : L("Nothing found")
    }

    // A result row as the list shows it: the key value, then up to four other non-empty values to recognise the
    // row by (newlines flattened, each at most 40 characters).
    static func rowText(_ row: [DBValue], keyIndex: Int?) -> (key: String, rest: String) {
        var others: [String] = []
        for (i, v) in row.enumerated() where i != keyIndex {
            guard let s = v.string, !s.isEmpty else { continue }
            let flat = s.replacingOccurrences(of: "\n", with: " ")
            others.append(flat.count > 40 ? String(flat.prefix(40)) + "…" : flat)
            if others.count == 4 { break }
        }
        return (keyIndex.map { referenceShownValue(row[$0]) } ?? "", others.joined(separator: " · "))
    }

    private var keyIndex: Int? { result?.columns.firstIndex(of: keyColumn) }

    override func loadView() {
        let heading = NSMutableAttributedString(string: columnName, attributes: [.font: Theme.font(13, .semibold), .foregroundColor: Theme.t1])
        heading.append(NSAttributedString(string: " → ", attributes: [.font: Theme.font(13), .foregroundColor: Theme.t3]))
        heading.append(NSAttributedString(string: table, attributes: [.font: Theme.font(13, .semibold), .foregroundColor: Theme.t1]))
        let title = label("")
        title.attributedStringValue = heading
        search.placeholderString = L("Search in any column")
        search.font = Theme.font(12.5)
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self

        list.headerView = nil
        list.style = .plain
        list.rowHeight = 36
        list.intercellSpacing = NSSize(width: 0, height: 1)
        list.backgroundColor = .clear
        list.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(pick)
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let null = PillButton(L("Set NULL"), target: self, action: #selector(pickNull))
        let choose = PillButton(L("Choose"), style: .accent, target: self, action: #selector(pick))
        choose.keyEquivalent = "\r" // Enter in the search field also picks (see below)

        let top = column([title, search], insets: NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14), spacing: 8)
        let view = column([top, separator(), scroll, separator(), bar([status], [null, choose], height: 42, left: 14, right: 12)], grow: scroll)
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: 440), view.heightAnchor.constraint(equalToConstant: 330)])
        self.view = view
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
        setStatus(L("Loading…"), error: false)
        onSearch?("")
    }

    @objc private func searchChanged(_ sender: Any?) {
        setStatus(L("Searching…"), error: false)
        onSearch?(search.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func showResult(_ result: DBResult?, error: Error?) {
        self.result = result
        list.reloadData()
        if let result, !result.rows.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        setStatus(Self.statusText(result, error: error), error: error != nil)
    }

    private func setStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? Theme.red : Theme.t2
    }

    // ↑ ↓ move through the results while typing, Enter picks.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let count = list.numberOfRows
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard count > 0 else { return true }
            let row = max(0, min(count - 1, list.selectedRow + (selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1)))
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            pick(nil)
            return true
        }
        return false
    }

    @objc private func pick(_ sender: Any?) {
        let row = list.selectedRow
        guard let result, row >= 0, row < result.rows.count, let key = keyIndex else { return }
        onPick?(result.rows[row][key])
    }

    @objc private func pickNull(_ sender: Any?) {
        onPick?(.null)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { result?.rows.count ?? 0 }

    // The selection stays visible while typing in the search field: RowView draws it whatever has the focus.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = RowView()
        v.inset = 6
        v.baseColor = row % 2 == 1 ? Theme.zebra : nil
        return v
    }

    // Two lines: the key value, then a few other values.
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let key = label("", 12, .semibold, Theme.t1, mono: true)
            let rest = label("", 11.5, .regular, Theme.t2)
            rest.tag = 1
            for v in [key, rest] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                key.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
                key.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
                key.bottomAnchor.constraint(equalTo: cell.centerYAnchor, constant: 1),
                rest.leadingAnchor.constraint(equalTo: key.leadingAnchor),
                rest.trailingAnchor.constraint(equalTo: key.trailingAnchor),
                rest.topAnchor.constraint(equalTo: key.bottomAnchor),
            ])
            cell.textField = key
        }
        guard let result else { return cell }
        let text = Self.rowText(result.rows[row], keyIndex: keyIndex)
        cell.textField?.stringValue = text.key
        (cell.viewWithTag(1) as? NSTextField)?.stringValue = text.rest
        return cell
    }
}

// MARK: - Card popover

// The window a CardPopover shows its card in: borderless, clear, becomes key (for typing into the picker's search
// field) without making its parent look inactive.
private final class CardWindow: NSPanel {
    weak var owner: CardPopover?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { owner?.close() }        // Esc
    override func performClose(_ sender: Any?) { owner?.close() }           // the ×, ⌘W
}

// Replaces NSPopover: a card without an arrow, below the rect (above when there is no room), its corner 20 pt left of
// the rect's middle. It pops in, growing out of the rect; with Reduce Motion it only fades in. Transient like
// NSPopover's .transient: a click outside, Esc, the app going to the background or the parent window resizing or
// closing closes it.
@MainActor final class CardPopover: NSObject {
    var contentViewController: NSViewController?
    var onClose: (() -> Void)?
    private(set) var isShown = false
    private var window: CardWindow?
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    static let radius: CGFloat = 16
    // room around the card for its shadow
    private static let margin = NSEdgeInsets(top: 24, left: 32, bottom: 56, right: 32)

    func show(relativeTo rect: NSRect, of view: NSView) {
        close()
        guard let content = contentViewController, let parent = view.window else { return }
        let screenRect = parent.convertToScreen(view.convert(rect, to: nil))

        // card: blur, fill and border, the content; a shadow behind it
        let host = NSViewController()
        let stage = NSView()
        stage.wantsLayer = true
        host.view = stage
        let shadow = CardShadow()
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.radius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        let card = Panel(fill: Theme.modal, border: Theme.boxB, radius: Self.radius)
        card.layer?.masksToBounds = true
        host.addChild(content)
        pin(content.view, card)
        for v in [shadow, blur, card] { pin(v, stage, Self.margin) }

        let size = card.fittingSize
        let m = Self.margin
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? screenRect.insetBy(dx: -10_000, dy: -10_000)
        var x = screenRect.midX - 20
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        let below = screenRect.minY - 4 - size.height >= visible.minY
        let y = below ? screenRect.minY - 4 - size.height : screenRect.maxY + 4
        let frame = NSRect(x: x - m.left, y: y - m.bottom, width: size.width + m.left + m.right, height: size.height + m.top + m.bottom)

        let w = CardWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.owner = self
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.appearance = parent.effectiveAppearance // follows the window, which may differ from the app (light / dark button)
        w.contentViewController = host
        w.setFrame(frame, display: false)
        parent.addChildWindow(w, ordered: .above)
        w.makeKeyAndOrderFront(nil)
        (window, self.parent, isShown) = (w, parent, true)
        popIn(stage, originX: m.left + 20, originY: below ? frame.height - m.top : m.bottom)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.window { self.close() }
            }
            return event // the click still reaches what it was meant for
        }
        let center = NotificationCenter.default
        for (name, object) in [(NSApplication.didResignActiveNotification, nil), (NSWindow.didResizeNotification, parent),
                               (NSWindow.willCloseNotification, parent)] as [(Notification.Name, AnyObject?)] {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }

    // Fades in and springs to identity around (originX, originY) of the stage (AppKit layers: y up).
    private func popIn(_ stage: NSView, originX: CGFloat, originY: CGFloat) {
        guard let layer = stage.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        (fade.fromValue, fade.toValue, fade.duration, fade.timingFunction) = (0, 1, Motion.reduced ? 0.15 : 0.2, Motion.ease)
        layer.add(fade, forKey: "fade")
        guard !Motion.reduced else { return }
        let from = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(originX, originY - 6, 0), 0.94, 0.94, 1), -originX, -originY, 0)
        layer.add(Motion.spring("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.32),
                  forKey: "pop")
    }

    func close() {
        guard let w = window else { return }
        window = nil
        isShown = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        let wasKey = w.isKeyWindow
        parent?.removeChildWindow(w)
        if wasKey { parent?.makeKey() }
        Motion.animate(0.12, Motion.ease, { w.animator().alphaValue = 0 }, completion: { w.orderOut(nil) })
        onClose?()
    }
}

// The card's shadow: a layer shadow along the card's outline, nothing else drawn.
private final class CardShadow: LayerView {
    override func updateColors() {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 25 // a CSS blur of 50
        layer.shadowOffset = CGSize(width: 0, height: -18)
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: CardPopover.radius, cornerHeight: CardPopover.radius, transform: nil)
    }
}

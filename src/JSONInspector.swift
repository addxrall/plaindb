import AppKit

// A parsed JSON value that keeps the original key order (JSONSerialization doesn't).
final class JSONNode {
    enum Kind: String { case object, array, string, number, bool, null }
    var key: String?       // nil for array items and the root
    var index = 0          // position in the parent array
    var kind: Kind
    var text = ""          // scalar value, strings unescaped
    var children: [JSONNode] = []

    init(kind: Kind) { self.kind = kind }
}

// MARK: - Parsing and formatting

private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 }

// True for a string holding a JSON object or array (what the inspector opens).
func jsonIsValid(_ value: String?) -> Bool {
    guard let s = value?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("{") || s.hasPrefix("[") else { return false }
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
}

// A cell value: NULL is never JSON.
func jsonIsValid(_ value: DBValue) -> Bool { jsonIsValid(value.string) }

private struct Cursor {
    let s: [UInt16]
    var i = 0

    mutating func skipSpace() {
        while i < s.count && isSpace(s[i]) { i += 1 }
    }

    // At an opening quote. Unescaping is left to JSONSerialization, which knows all the escapes.
    mutating func parseString() -> String? {
        let start = i
        i += 1
        while i < s.count {
            let ch = s[i]
            if ch == 92 { i += 2 } // backslash
            else if ch == 34 {
                i += 1
                let raw = String(decoding: s[start..<i], as: UTF16.self)
                return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
            } else { i += 1 }
        }
        return nil
    }

    mutating func parseValue(_ depth: Int) -> JSONNode? {
        skipSpace()
        guard i < s.count, depth <= 256 else { return nil }
        let ch = s[i]
        if ch == 123 || ch == 91 { // { [
            let object = ch == 123
            let close: UInt16 = object ? 125 : 93
            let node = JSONNode(kind: object ? .object : .array)
            i += 1
            skipSpace()
            if i < s.count && s[i] == close {
                i += 1
                return node
            }
            while true {
                var key: String?
                if object {
                    skipSpace()
                    guard i < s.count, s[i] == 34, let k = parseString() else { return nil }
                    key = k
                    skipSpace()
                    guard i < s.count, s[i] == 58 else { return nil } // :
                    i += 1
                }
                guard let child = parseValue(depth + 1) else { return nil }
                child.key = key
                child.index = node.children.count
                node.children.append(child)
                skipSpace()
                guard i < s.count else { return nil }
                let next = s[i]
                i += 1
                if next == close { return node }
                if next != 44 { return nil } // ,
            }
        }
        if ch == 34 {
            guard let text = parseString() else { return nil }
            let node = JSONNode(kind: .string)
            node.text = text
            return node
        }
        let start = i
        func wordChar(_ c: UInt16) -> Bool { c < 128 && (isalnum(Int32(c)) != 0 || c == 43 || c == 45 || c == 46) } // + - .
        while i < s.count && wordChar(s[i]) { i += 1 }
        let word = String(decoding: s[start..<i], as: UTF16.self)
        let kind: JSONNode.Kind
        if word == "true" || word == "false" { kind = .bool }
        else if word == "null" { kind = .null }
        else if !word.isEmpty && Scanner(string: word).scanDouble() != nil { kind = .number }
        else { return nil }
        let node = JSONNode(kind: kind)
        node.text = word
        return node
    }
}

// nil when the text isn't valid JSON.
func jsonParse(_ text: String) -> JSONNode? {
    var c = Cursor(s: Array(text.utf16))
    let root = c.parseValue(0)
    c.skipSpace()
    return c.i == c.s.count ? root : nil
}

// Copies every character outside whitespace, with string contents passed through; `pretty` re-indents by 2.
private func reformat(_ text: String, pretty: Bool) -> String {
    let s = Array(text.utf16)
    var out: [UInt16] = []
    out.reserveCapacity(s.count * (pretty ? 2 : 1))
    var indent = 0
    var inString = false, escape = false
    func newline(_ level: Int) {
        out.append(10)
        out.append(contentsOf: repeatElement(32, count: max(0, level) * 2))
    }
    var i = 0
    while i < s.count {
        defer { i += 1 }
        let ch = s[i]
        if inString {
            out.append(ch)
            if escape { escape = false }
            else if ch == 92 { escape = true }
            else if ch == 34 { inString = false }
            continue
        }
        if isSpace(ch) { continue }
        if ch == 34 { inString = true }
        if !pretty {
            out.append(ch)
            continue
        }
        switch ch {
        case 123, 91: // { [
            out.append(ch)
            var j = i + 1
            while j < s.count && isSpace(s[j]) { j += 1 }
            if j < s.count && (s[j] == 125 || s[j] == 93) { // empty container stays on one line
                out.append(s[j])
                i = j
            } else {
                indent += 1
                newline(indent)
            }
        case 125, 93: // } ]
            indent -= 1
            newline(indent)
            out.append(ch)
        case 44: // ,
            out.append(ch)
            newline(indent)
        case 58: // :
            out.append(58)
            out.append(32)
        default:
            out.append(ch)
        }
    }
    return String(utf16CodeUnits: out, count: out.count)
}

// Re-indent / strip whitespace outside strings. Key order and string contents stay as they are.
func jsonPretty(_ text: String) -> String { reformat(text, pretty: true) }
func jsonMinify(_ text: String) -> String { reformat(text, pretty: false) }

// MARK: - Highlighting

private let jsonTokens = try! NSRegularExpression(
    pattern: "(\"(?:[^\"\\\\]|\\\\.)*\")(\\s*:)?|(-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b)|\\b(true|false|null)\\b")

@MainActor func jsonHighlight(_ storage: NSTextStorage) {
    let all = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.addAttribute(.foregroundColor, value: Theme.t1, range: all)
    for m in jsonTokens.matches(in: storage.string, range: all) {
        if m.range(at: 1).location != NSNotFound {
            let key = m.range(at: 2).location != NSNotFound
            storage.addAttribute(.foregroundColor, value: key ? Theme.fn : Theme.str, range: m.range(at: 1))
        } else if m.range(at: 3).location != NSNotFound {
            storage.addAttribute(.foregroundColor, value: Theme.num, range: m.range)
        } else {
            storage.addAttribute(.foregroundColor, value: Theme.kw, range: m.range)
        }
    }
    storage.endEditing()
}

// MARK: - Tree pieces

// The disclosure caret ›; points down when open.
private final class CaretView: LayerView {
    private let shape = CAShapeLayer()
    private(set) var open = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        shape.fillColor = nil
        shape.lineWidth = 1.2
        shape.lineCap = .round
        shape.lineJoin = .round
        layer?.addSublayer(shape)
        widthAnchor.constraint(equalToConstant: 12).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateColors() { shape.strokeColor = Theme.t3.cgColor }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4.5, y: 9))
        p.addLine(to: CGPoint(x: 7.5, y: 6))
        p.addLine(to: CGPoint(x: 4.5, y: 3))
        shape.path = p
        CATransaction.commit()
    }

    private func angle(_ open: Bool) -> CGFloat { open ? -.pi / 2 : 0 } // clockwise: y points up in the layer

    func setOpen(_ open: Bool, animated: Bool) {
        let from = shape.presentation()?.value(forKeyPath: "transform.rotation.z") ?? angle(self.open)
        self.open = open
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.setValue(angle(open), forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        if animated { shape.add(Motion.spring("transform.rotation.z", from: from, to: angle(open), duration: 0.3), forKey: "turn") }
        else { shape.removeAnimation(forKey: "turn") }
    }
}

// One tree row: caret, then "key: value", indented by depth.
private final class TreeCell: NSTableCellView {
    let caret = CaretView()
    let text = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("node")
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [caret, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = text
        indent = caret.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        NSLayoutConstraint.activate([
            indent,
            caret.topAnchor.constraint(equalTo: topAnchor),
            caret.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: caret.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ node: JSONNode, depth: Int, open: Bool) {
        indent.constant = 10 + 16 * CGFloat(depth)
        caret.isHidden = node.children.isEmpty
        caret.setOpen(open, animated: false)
        let line = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor, _ weight: NSFont.Weight = .regular) {
            line.append(NSAttributedString(string: s, attributes: [.font: Theme.mono(12, weight), .foregroundColor: color]))
        }
        add(node.key ?? "[\(node.index)]", Theme.t1, .semibold)
        add(": ", Theme.t3)
        switch node.kind {
        case .object: add("{\(node.children.count)}", Theme.t3)
        case .array: add("[\(node.children.count)]", Theme.t3)
        case .string: add("\"\(node.text.replacingOccurrences(of: "\n", with: "⏎"))\"", Theme.str)
        case .number: add(node.text, Theme.num)
        case .bool, .null: add(node.text, Theme.kw)
        }
        text.attributedStringValue = line
        text.toolTip = node.kind == .string ? node.text : nil
    }
}

// Rows use the full width: no disclosure triangle (the cell draws its own caret) and no indentation (the cell
// indents itself).
private final class TreeOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let r = rect(ofRow: row)
        return NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
    }
}

private final class CloseButton: NSButton {
    private var hovering = false { didSet { restyle() } }

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        (self.target, self.action) = (target, action)
        isBordered = false
        wantsLayer = true
        toolTip = L("Close")
        setAccessibilityLabel(L("Close"))
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 22)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        restyle()
    }

    private func restyle() {
        attributedTitle = NSAttributedString(string: "×", attributes: [.font: Theme.font(16), .foregroundColor: hovering ? Theme.t1 : Theme.t2])
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = hovering ? Theme.fill.cgColor : nil
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

// Takes no clicks while disabled, and dims its content (the Tree / Text control has no enabled state).
private final class EnablingView: NSView {
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }
    override func hitTest(_ point: NSPoint) -> NSView? { isEnabled ? super.hitTest(point) : nil }
}

// MARK: - Inspector

// Side panel showing one JSON cell as a tree or as editable, highlighted text. Its view is transparent: the main
// window puts it in a Panel and animates its width, so it has no minimum width of its own.
final class JSONInspector: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextViewDelegate {
    var onApply: ((String) -> Void)? // minified
    var onClose: (() -> Void)?

    private var root: JSONNode?
    private var original = "" // minified, to tell whether the text changed
    private var editable = false
    private var initialized = Set<ObjectIdentifier>() // containers whose children got their default expansion
    private var reloading = false

    // Internal rather than private so the tests can drive the panel.
    private(set) var titleLabel = label("", 13, .semibold, mono: true)
    private(set) var subtitleLabel = label("", 11, .regular, Theme.t2)
    private(set) var statusLabel = label("", 11, .regular, Theme.t2)
    private(set) var mode = SlidingSegments([L("Tree"), L("Text")], segmentWidth: 52, height: 24, radius: 8, fontSize: 12, inset: 2)
    private let modeHost = EnablingView()
    private(set) var pages: Switcher!
    private(set) var outline: NSOutlineView = TreeOutlineView()
    private(set) var textView: SQLTextView!
    private(set) var formatButton: PillButton!
    private(set) var applyButton: PillButton!

    override func loadView() {
        for l in [titleLabel, subtitleLabel] { // full text unless the panel really is too narrow
            l.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue - 1), for: .horizontal)
        }
        let titles = column([titleLabel, subtitleLabel], spacing: 2)
        let header = bar([titles], [CloseButton(target: self, action: #selector(close))], height: 48, left: 14, right: 12)

        pin(mode, modeHost)
        mode.onChange = { [weak self] _ in self?.modeChanged() }
        let modeBar = bar([modeHost], [], height: 34, left: 14, right: 14)

        let nodeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        nodeColumn.resizingMask = .autoresizingMask
        outline.addTableColumn(nodeColumn)
        outline.outlineTableColumn = nodeColumn
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 22
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        let outlineScroll = NSScrollView()
        outlineScroll.documentView = outline
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.automaticallyAdjustsContentInsets = false
        outlineScroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        let (textScroll, text) = sqlTextScrollView(editable: true, lineNumbers: false)
        textScroll.drawsBackground = false
        textView = text
        text.highlighter = jsonHighlight // JSON colours instead of SQL ones
        text.font = Theme.mono(12)
        text.lineHeight = 19
        text.textContainerInset = NSSize(width: 14, height: 10)
        text.padding = (14, 14)
        text.delegate = self

        let icon = NSImageView(image: NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = Theme.t3
        let hint = label(L("Double-click a cell with JSON to see it here."), 12, .regular, Theme.t2)
        hint.alignment = .center
        let placeholder = centeredState([icon, hint])
        pages = Switcher([outlineScroll, textScroll, placeholder])

        let body = Panel(fill: Theme.edBg, radius: 0)
        let content = NSView()
        pin(pages, content)
        pin(column([separator(), content], grow: content), body)

        formatButton = PillButton(L("Format"), target: self, action: #selector(format))
        applyButton = PillButton(L("Apply"), target: self, action: #selector(apply))
        let footer = bar([statusLabel], [formatButton, applyButton], height: 46, left: 14, right: 12)
        let footerColumn = column([separator(), footer])

        let view = NSView()
        pin(column([header, modeBar, body, footerColumn], grow: body), view)
        self.view = view
        showPlaceholder()
    }

    func showPlaceholder() {
        loadViewIfNeeded()
        root = nil
        outline.reloadData()
        titleLabel.stringValue = L("JSON")
        subtitleLabel.stringValue = ""
        statusLabel.stringValue = ""
        modeHost.isEnabled = false
        formatButton.isEnabled = false
        applyButton.isEnabled = false
        pages.selectedIndex = 2
    }

    func showJSON(_ json: String, title: String, subtitle: String, editable: Bool) {
        loadViewIfNeeded()
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        self.editable = editable
        original = jsonMinify(json)
        textView.string = jsonPretty(json)
        textView.rehighlight()
        textView.isEditable = editable
        modeHost.isEnabled = true
        applyButton.isHidden = !editable
        formatButton.isHidden = !editable
        formatButton.isEnabled = true
        modeChanged()
        validate()
    }

    // MARK: Actions

    private func modeChanged() {
        if mode.selectedIndex == 0 && !jsonIsValid(textView.string) { mode.select(1, animated: true) } // no tree for broken JSON
        if mode.selectedIndex == 0 { reloadTree() }
        pages.selectedIndex = mode.selectedIndex
    }

    func textDidChange(_ notification: Notification) { validate() }

    private func validate() {
        let text = textView.string
        var valid = false, detail: String?
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8))
            valid = jsonIsValid(text)
        } catch {
            detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
        }
        statusLabel.stringValue = valid ? "✓ " + L("Valid JSON") : "✕ " + String(format: L("Invalid JSON: %@"), detail ?? "")
        statusLabel.textColor = valid ? Theme.green : Theme.red
        statusLabel.toolTip = valid ? nil : detail
        // literal comparison (as NSString's isEqual): a change to another Unicode normalisation is still a change
        applyButton.isEnabled = editable && valid && !jsonMinify(text).utf16.elementsEqual(original.utf16)
        formatButton.isEnabled = valid
    }

    @objc private func format() {
        textView.string = jsonPretty(textView.string)
        textView.rehighlight()
        validate()
    }

    @objc private func apply() {
        guard applyButton.isEnabled else { return }
        original = jsonMinify(textView.string)
        onApply?(original)
        validate()
    }

    @objc private func close() { onClose?() }

    // MARK: Tree

    private func reloadTree() {
        root = jsonParse(textView.string)
        initialized = []
        reloading = true
        outline.reloadData()
        expandDefaults(root?.children ?? [])
        reloading = false
    }

    // Containers start open, except array items (objects inside arrays start collapsed).
    private func expandDefaults(_ nodes: [JSONNode]) {
        for node in nodes where !node.children.isEmpty && node.key != nil { outline.expandItem(node) }
    }

    // A click on a row opens or closes it.
    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? JSONNode, !node.children.isEmpty else { return }
        if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
    }

    private func caret(of node: JSONNode, open: Bool) {
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TreeCell else { return }
        cell.caret.setOpen(open, animated: !reloading)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? JSONNode else { return }
        caret(of: node, open: true)
        // the children's own default, the first time this container opens
        if initialized.insert(ObjectIdentifier(node)).inserted { expandDefaults(node.children) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? JSONNode else { return }
        caret(of: node, open: false)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? JSONNode) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? JSONNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? JSONNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = RowView()
        (row.inset, row.radius) = (6, 6)
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? JSONNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("node"), owner: nil) as? TreeCell ?? TreeCell()
        cell.show(node, depth: outlineView.level(forItem: node), open: outlineView.isItemExpanded(node))
        return cell
    }
}

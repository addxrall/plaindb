import AppKit
import UniformTypeIdentifiers

private let pageSize = 200
private let s3PreviewLimit = 50 << 20, storagePreviewLimit = 20 << 20
private let pinsKey = "pinnedTables" // { "<connection id>/<database>": ["schema.table", …] }
private let diagramPositionsKey = "diagramPositions" // {identity: {"schema.table": "{x, y}"}}
private let appearanceKey = "appearance" // "light" / "dark" from the toolbar's toggle; missing: the system's

enum Tab: Int { case data, structure, sql, diagram, empty } // segments, then the empty page
private enum DataState: Int { case grid, loading, failed }
private enum SQLState: Int { case idle, running, done, failed, result }

// 950, 12.3K, 4.5M (localized: 12,3 tys., 4,5 mln)
private func compactCount(_ n: Int64) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 1
    func format(_ v: Double) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
    if n < 1000 { return format(Double(n)) }
    if n < 1_000_000 { return String(format: L("%@K"), format(Double(n) / 1e3)) }
    if n < 1_000_000_000 { return String(format: L("%@M"), format(Double(n) / 1e6)) }
    return String(format: L("%@B"), format(Double(n) / 1e9))
}

private func fullCount(_ n: Int64) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
}

// Postgres "public" and SQLite "main" are left out of names shown to the user.
private func isDefaultSchema(_ schema: String) -> Bool { schema == "public" || schema == "main" }

private func shownName(_ schema: String, _ table: String) -> String {
    isDefaultSchema(schema) ? table : "\(schema).\(table)"
}

@MainActor private func dot(_ color: NSColor, _ size: CGFloat) -> Panel {
    let d = Panel(fill: color, radius: size / 2)
    NSLayoutConstraint.activate([d.widthAnchor.constraint(equalToConstant: size), d.heightAnchor.constraint(equalToConstant: size)])
    return d
}

// Colour dot with a thin light ring, for menus.
@MainActor private func colorDot(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
        NSColor(white: 1, alpha: 0.6).setFill()
        NSBezierPath(ovalIn: rect).fill()
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
}

// "Name\taddress" with the address dimmed and right-aligned at `at`, for menus.
@MainActor private func menuTitle(_ name: String, _ detail: String, at: CGFloat) -> NSAttributedString {
    let tabs = NSMutableParagraphStyle()
    tabs.tabStops = [NSTextTab(textAlignment: .right, location: at)]
    let title = NSMutableAttributedString(string: name + "\t", attributes: [.font: NSFont.menuFont(ofSize: 0)])
    title.append(NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]))
    title.addAttribute(.paragraphStyle, value: tabs, range: NSRange(location: 0, length: title.length))
    return title
}

// One table of the sidebar list.
private struct TableItem: Equatable {
    var schema, name, kind: String
    var estimate: String? // planner's row estimate, nil when unknown
    var isView: Bool { kind == "view" }
    var pinName: String { "\(schema).\(name)" }
}

private enum SideRow {
    case section(String)
    case table(TableItem)
}

// The sidebar table: the selection is one pill that slides to the selected row, hidden while SQL or Diagram shows.
private final class SidebarTable: NSTableView {
    let pill = Panel(fill: Theme.sideSel, radius: 8)
    var pillVisible = true { didSet { Motion.animate(0.2) { pill.animator().alphaValue = pillVisible ? 1 : 0 } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(pill, positioned: .below, relativeTo: nil)
        pill.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func movePill(animated: Bool) {
        guard selectedRow >= 0 else { pill.alphaValue = 0; return }
        let frame = rect(ofRow: selectedRow).insetBy(dx: 8, dy: 0)
        let first = pill.alphaValue == 0 || pill.frame.isEmpty
        if animated && !first {
            Motion.animate(0.42, Motion.springCurve) { pill.animator().frame = frame }
        } else {
            pill.frame = frame
        }
        if pillVisible { pill.alphaValue = 1 }
    }

    override func layout() {
        super.layout()
        if selectedRow >= 0 && pill.layer?.animationKeys()?.isEmpty ?? true { pill.frame = rect(ofRow: selectedRow).insetBy(dx: 8, dy: 0) }
    }
}

private final class SidebarCell: NSTableCellView {
    let icon = TableIcon()
    let count = label("", 11, .regular, Theme.t3, mono: true)
}

// The window's content view: the background, and a hook to place the traffic lights after every layout pass.
private final class RootView: WindowBackground {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }
}

private final class PlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// Table icon: an outline with a line under its header; dashed for views.
private final class TableIcon: NSView {
    var color: NSColor = Theme.sideIcon { didSet { needsDisplay = true } }
    var dashed = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 13, height: 10) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.65, dy: 0.65)
        let box = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
        box.lineWidth = 1.3
        if dashed { box.setLineDash([2, 1.5], count: 2, phase: 0) }
        color.setStroke()
        box.stroke()
        if !dashed { NSRect(x: r.minX, y: r.maxY - 3.2, width: r.width, height: 1.3).fill(using: .sourceOver) }
    }
}

// The connection's name and address at the left of the top row; a click opens the switcher.
private final class ConnectionPill: Panel {
    var onClick: ((NSView) -> Void)?
    private var hovering = false

    convenience init(name: String, target: String) {
        self.init(fill: Theme.pill, border: Theme.pillB, radius: 10)
        let title = label(name, 12.5, .semibold), sub = label(target, 10.5, .regular, Theme.t2)
        // full text up to the 320 pt cap, but below the window's own size (500), so a long path doesn't widen the window
        for l in [title, sub] { l.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(490), for: .horizontal) }
        let texts = column([title, sub], spacing: 1)
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!)
        chevron.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        chevron.contentTintColor = Theme.t2
        let row = NSStackView(views: [texts, chevron])
        row.spacing = 10
        row.alignment = .centerY
        pin(row, self, NSEdgeInsets(top: 5, left: 11, bottom: 5, right: 10))
        widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        toolTip = L("Switch database or connection")
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(L("Switch database or connection"))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; fillColor = Theme.ctlH }
    override func mouseExited(with event: NSEvent) { hovering = false; fillColor = Theme.pill }
    override func mouseDown(with event: NSEvent) { onClick?(self) }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class AppearanceButton: Panel {
    var onClick: (() -> Void)?
    private let glyph = CAShapeLayer(), half = CAShapeLayer()
    private var turns: CGFloat = 0

    convenience init() {
        self.init(fill: Theme.ctl, border: Theme.ctlB, radius: 8)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 28), heightAnchor.constraint(equalToConstant: 28)])
        layer?.addSublayer(glyph)
        glyph.addSublayer(half)
        toolTip = L("Light / Dark")
    }

    override func updateColors() {
        super.updateColors()
        glyph.strokeColor = Theme.t1.cgColor
        glyph.fillColor = nil
        glyph.lineWidth = 1.4
        half.fillColor = Theme.t1.cgColor
    }

    override func layout() {
        super.layout()
        let r = CGRect(x: 0, y: 0, width: 12, height: 12)
        glyph.bounds = r
        glyph.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glyph.path = CGPath(ellipseIn: r.insetBy(dx: 0.7, dy: 0.7), transform: nil)
        let p = CGMutablePath()
        p.addArc(center: CGPoint(x: 6, y: 6), radius: 5.3, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        p.closeSubpath()
        half.path = p
    }

    override func mouseDown(with event: NSEvent) {
        let from = turns
        turns += .pi
        glyph.setValue(turns, forKeyPath: "transform.rotation.z")
        glyph.add(Motion.spring("transform.rotation.z", from: from, to: turns, duration: 0.6), forKey: "turn")
        onClick?()
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

// Confirmation for writes on production, drawn over the window. Enter cancels: running takes a click.
private final class ProductionConfirm: NSView {
    var onRun: (() -> Void)?
    var onCancel: (() -> Void)?
    private let card = Panel(fill: Theme.modal, border: Theme.boxB, radius: 16)
    private let runButton: PillButton
    private let runSpinner = spinner(.small)

    init(connection: String, color: NSColor, sql: String) {
        runButton = PillButton(L("Run in Transaction"), style: .custom(color, .white), height: 28, target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        runButton.target = self
        runButton.action = #selector(run)
        let cancel = PillButton(L("Cancel"), height: 28, target: self, action: #selector(cancel))

        let titleRow = NSStackView(views: [badge(L("PRODUCTION"), .white, color), label(String(format: L("Write to %@?"), connection), 14, .bold)])
        titleRow.spacing = 10
        let text = wrappingLabel(L("The changes run in one transaction that is allowed to write. The session goes back to read-only right after."), 12.5)
        text.isSelectable = false
        text.preferredMaxLayoutWidth = 460
        let (scroll, preview) = sqlTextScrollView(editable: false, lineNumbers: false)
        preview.string = sql
        preview.rehighlight()
        scroll.backgroundColor = Theme.edBg2
        let box = Panel(fill: Theme.edBg2, border: Theme.line, radius: 10)
        box.layer?.masksToBounds = true
        pin(scroll, box, NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        let lines = CGFloat(sql.components(separatedBy: "\n").count)
        box.heightAnchor.constraint(equalToConstant: min(180, lines * 20 + 22)).isActive = true
        let buttons = NSStackView(views: [runSpinner, cancel, runButton])
        buttons.spacing = 8
        let buttonRow = NSStackView()
        buttonRow.addView(buttons, in: .trailing)

        let content = column([titleRow, text, label(L("This SQL will run:"), 11, .semibold, Theme.t2), box, buttonRow], spacing: 12)
        content.setCustomSpacing(16, after: box)
        pin(content, card, NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))
        card.shadowed = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 500),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { self.layer?.backgroundColor = Theme.scrim.cgColor } }

    func present() {
        Motion.enter(layer, duration: 0.25)
        guard let l = card.layer, !Motion.reduced else { return }
        let (cx, cy) = (l.bounds.midX, l.bounds.midY)
        let small = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(cx, cy, 0), 0.94, 0.94, 1), -cx, -cy - 6, 0)
        l.add(Motion.spring("transform", from: NSValue(caTransform3D: small), to: NSValue(caTransform3D: CATransform3DIdentity), duration: 0.42), forKey: "pop")
    }

    var running = false {
        didSet {
            running ? runSpinner.startAnimation(nil) : runSpinner.stopAnimation(nil)
            runButton.title = running ? L("Running…") : L("Run in Transaction")
            runButton.isEnabled = !running
        }
    }

    @objc private func run() { if !running { onRun?() } }
    @objc private func cancel() { if !running { onCancel?() } }

    override func mouseDown(with event: NSEvent) { // a click on the scrim cancels; the card keeps its clicks
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { cancel() }
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76 { cancel() } // Esc, Return, Enter
    }
    override func cancelOperation(_ sender: Any?) { cancel() }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor private func showToast(_ text: String, in view: NSView) {
    let pill = Panel(fill: Theme.t1, radius: 999)
    let tick = label("✓", 12.5, .medium, Theme.green), words = label(text, 12.5, .medium, Theme.panelSolid)
    let row = NSStackView(views: [tick, words])
    row.spacing = 8
    pin(row, pill, NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([pill.centerXAnchor.constraint(equalTo: view.centerXAnchor), pill.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -56)])
    view.layoutSubtreeIfNeeded()
    Motion.enter(pill.layer, dy: -12, duration: 0.3)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
        Motion.animate(0.3, Motion.ease, { pill.animator().alphaValue = 0 }, completion: { pill.removeFromSuperview() })
    }
}

// Window for one connection: table list on the left, Data / Structure / SQL / Diagram on the right, as floating
// panels on the window background.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate, NSSearchFieldDelegate {
    var onClose: ((MainWindowController) -> Void)?
    // The user switched to another database or connection from the toolbar: the new connection is open,
    // and the owner should show it in place of `controller` (whose unsaved changes were already confirmed).
    var onReplace: ((MainWindowController, DBConnection, SSHTunnel?, Connection) -> Void)?
    // "Open in New Tab" (sidebar menu, ⌘-click): the owner makes a tab of the same connection showing that table.
    // nil table: an empty tab (the tab bar's "+" or ⌘T with no table open).
    var onOpenInNewTab: ((MainWindowController, String?, String?) -> Void)?
    // The window's table or tab changed (the owner saves the open tabs).
    var onTabsChanged: ((MainWindowController) -> Void)?

    // Tabs: windows of one connection share it. The owner closes the connection with its last window.
    let connection: DBConnection
    let tunnel: SSHTunnel?
    let info: Connection
    private var conn: DBConnection { connection }
    private let production: Bool
    private var tunnelConnected: Bool

    private let jsonInspector = JSONInspector()
    private var inspectorWidth: NSLayoutConstraint!
    private var inspectorPanel: Panel!
    private var inspectorOpen = false
    private weak var inspectorGrid: GridView?
    private var inspectorRow = 0, inspectorColumn = 0

    private var tables: [TableItem]?
    private var sideRows: [SideRow] = []
    private var pendingTable: SavedTab? // to show once the table list has loaded
    private var pendingReloaded = false // the list was reloaded once for it already
    private var pinned: [String]        // "schema.table", in the order they were pinned
    private var databases: [String] = [] // other databases on this server, for the switcher
    private let switchMenu = NSMenu()
    private var foreignKeys: [String: (schema: String, table: String, column: String)] = [:]
    private var pocketBaseFiles: PocketBaseFiles? // the open table's file fields
    private var searchReferences: [String: SearchReference] = [:] // the same plus the referenced table's columns, for ⌘F
    private var columnKinds: [String: ValueKind] = [:]
    private var columnTypes: [String: String] = [:] // column → type as Postgres names it, e.g. jsonb
    private var estimate: String?                   // planner's row estimate for the open table
    private var popover: NSPopover?
    private var card: CardPopover?
    private var truncateField: NSTextField?         // while the "Empty table" sheet is open
    private var truncateButton: PillButton?, truncateCopy: PillButton?
    private var truncateName = ""
    private var schema: String?, table: String?, sortColumn: String?
    private var sortAscending = true, isView = false
    private var offset = 0
    private var pkColumns: [String] = [], columnNames: [String] = []
    private var defaultColumns: Set<String> = []
    private var searchTerm: String? // active ⌘F filter of the Data tab, nil when off
    private var tablesStatus = "", dataStatus = "", structureStatus = "", sqlStatus = "", diagramStatus = ""
    private var confirm: ProductionConfirm?
    private var schemaSheet: SchemaSheet?

    private var root: WindowBackground!
    private var contentTop: NSLayoutConstraint!
    private let filter = NSTextField()
    private let sidebar = SidebarTable()
    private let tabSwitch = SlidingSegments([L("Data"), L("Structure"), "SQL", L("Diagram")], segmentWidth: 86, height: 32, radius: 999)
    private var tabs: Switcher!
    private var currentTab = Tab.data

    private let tableLabel = label("", 13, .semibold)
    private let readOnlyBadge = badge(L("read-only"), Theme.t2, Theme.fill, kern: 0)
    private let pageLabel = label("", 12, .regular, Theme.t2, mono: true)
    private let readOnlyText = label("", 11.5, .regular, Theme.t2)
    private let loadingLabel = label("", 12, .regular, Theme.t2)
    private let errorTitle = label("", 14, .semibold)
    private let errorMessage = wrappingLabel("", 12, Theme.red)
    private var rowButtons: NSView!, addButton: ToolButton!, deleteButton: ToolButton!
    private var prevButton: ToolButton!, nextButton: ToolButton!, refreshButton: ToolButton!, findButton: ToolButton!
    private var readOnlyStrip: NSView!
    private var dataState: Switcher!
    private let dataSpinner = spinner(.regular)
    private let dataGrid = GridView()
    private let emptyLabel = label("", 12, .regular, Theme.t3)

    private var searchBar: NSView!
    private let searchField = NSSearchField()
    private let searchHint = label("", 11.5, .regular, Theme.t3)
    private let searchStatus = label("", 11.5, .regular, Theme.t2, mono: true)

    private let structureTitle = label("", 13, .semibold)
    private let structureMeta = label("", 12, .regular, Theme.t3)
    private let columnsCard = column([], spacing: 0)
    private let indexesCard = column([], spacing: 0)
    private var structureColumns: DBResult?

    private var sqlText: SQLTextView!
    private var completer: SQLCompleter!
    private var sqlState: Switcher!
    private let sqlSpinner = spinner(.small)
    private let sqlDoneLabel = label("", 12, .regular, Theme.t2, mono: true)
    private let sqlErrorText = wrappingLabel("", 12, Theme.t1)
    private let sqlGrid = GridView()

    private var schemaGraph: SchemaGraph? // the whole database, nil until loaded (diagram and SQL completion)
    private var diagramFocus: String?     // "schema.table" in neighbours mode, nil for the whole database
    private var diagramReselect: String?  // "schema.table" to select once the diagram is read again (after a sheet ran)
    private var diagramLoading = false
    private let diagramView = DiagramView()
    private let diagramScroll = NSScrollView()
    private var diagramState: Switcher!
    private let diagramSpinner = spinner(.regular)
    private let diagramTitle = label("", 13, .semibold)
    private var diagramBack: PillButton!, diagramOpen: PillButton!

    private var pendingBar: NSView!
    private let pendingLabel = label("", 13, .semibold)
    private let pendingDetail = label("", 12, .regular, Theme.t3)
    private let statusLabel = label("", 11, .regular, Theme.t2)
    private let tunnelLabel = label("", 11, .regular, Theme.t2)
    private let tunnelDot = dot(Theme.t3, 7)
    private let tunnelSpinner = spinner(.mini)

    init(connection: DBConnection, tunnel: SSHTunnel?, info: Connection) {
        self.connection = connection
        self.tunnel = tunnel
        self.info = info
        production = info.production
        tunnelConnected = tunnel?.connected ?? false // a tab opened while the tunnel reconnects starts with the real state
        pinned = (UserDefaults.standard.dictionary(forKey: pinsKey)?["\(info.id)/\(info.database)"] as? [String]) ?? []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = info.name // the open table's name once there is one: the tab shows it
        window.tabbingIdentifier = info.identity // only this connection's windows share a tab bar
        window.subtitle = target
        window.titleVisibility = .hidden // shown by the connection pill instead; still used by the Window menu
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar as tall as the 52 pt top row, so the traffic lights
        // sit in the sidebar's first row; the toolbar row itself is part of the content.
        let toolbar = NSToolbar(identifier: "main")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 760, height: 460)
        if let saved = UserDefaults.standard.string(forKey: appearanceKey) { NSApp.appearance = NSAppearance(named: saved == "dark" ? .darkAqua : .aqua) }

        buildUI()
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        // Production always has a frame; other connections when the user picked a colour.
        if !info.frameColor.isEmpty { applyProductionFrame() }

        if let tunnel { // every tab of the connection follows the shared tunnel
            NotificationCenter.default.addObserver(self, selector: #selector(tunnelStatusChanged), name: SSHTunnel.statusNotification, object: tunnel)
        }
        setTunnelConnected(tunnelConnected)
        showTab(.data)
        loadTables()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var target: String {
        let t = info.kind == "sqlite" ? (info.path as NSString).abbreviatingWithTildeInPath
            : info.kind == "sqlite-ssh" ? info.path // a path on the server: ~ would mean the wrong home
            : "\(info.user)@\(info.host.isEmpty ? "localhost" : info.host)/\(info.database)"
        return info.sshHost.isEmpty ? t : String(format: L("%@ via %@"), t, info.sshHost)
    }

    // MARK: - UI

    private func buildUI() {
        let root = RootView()
        root.onLayout = { [weak self] in self?.updateContentTop() }
        self.root = root
        window!.contentView = root

        let sidePanel = Panel(fill: Theme.side, border: Theme.pb, radius: 16, shadow: true)
        sidePanel.highlighted = true
        pin(buildSidebar(), sidePanel)
        sidePanel.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let contentPanel = Panel(fill: Theme.panel, border: Theme.pb, radius: 16, shadow: true)
        contentPanel.highlighted = true
        let inner = NSView()
        inner.wantsLayer = true
        inner.layer?.cornerRadius = 16
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true // the bars and grid follow the panel's corners
        pin(buildContent(), inner)
        pin(inner, contentPanel)

        jsonInspector.onApply = { [weak self] json in self?.applyJSON(json) }
        jsonInspector.onClose = { [weak self] in self?.hideInspector() }
        inspectorPanel = Panel(fill: Theme.inspBg, border: Theme.pb, radius: 16, shadow: true)
        let inspectorInner = NSView()
        inspectorInner.wantsLayer = true
        inspectorInner.layer?.cornerRadius = 16
        inspectorInner.layer?.masksToBounds = true
        pin(jsonInspector.view, inspectorInner)
        pin(inspectorInner, inspectorPanel)
        let inspectorWrapper = NSView()
        inspectorPanel.translatesAutoresizingMaskIntoConstraints = false
        inspectorWrapper.addSubview(inspectorPanel)
        NSLayoutConstraint.activate([
            inspectorPanel.topAnchor.constraint(equalTo: inspectorWrapper.topAnchor),
            inspectorPanel.bottomAnchor.constraint(equalTo: inspectorWrapper.bottomAnchor),
            inspectorPanel.leadingAnchor.constraint(equalTo: inspectorWrapper.leadingAnchor, constant: 12),
            inspectorPanel.widthAnchor.constraint(equalToConstant: 330),
        ])
        inspectorWidth = inspectorWrapper.widthAnchor.constraint(equalToConstant: 0)
        inspectorWidth.isActive = true
        inspectorPanel.alphaValue = 0

        let body = NSStackView(views: [contentPanel, inspectorWrapper])
        body.spacing = 0
        body.alignment = .height
        body.distribution = .fill
        contentPanel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let right = column([buildToolbar(), body], grow: body, spacing: 12)
        let main = NSStackView(views: [sidePanel, right])
        main.spacing = 12
        main.alignment = .height
        main.distribution = .fill
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        contentTop = main.topAnchor.constraint(equalTo: root.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            contentTop,
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        for grid in [dataGrid, sqlGrid] {
            grid.onOpenImage = { [weak self, weak grid] row, column, rect in if let grid { self?.openImage(in: grid, row: row, column: column, rect: rect) } }
            grid.onOpenFile = { [weak self, weak grid] row, column, rect in if let grid { self?.openFile(in: grid, row: row, column: column, rect: rect) } }
            grid.detectsFileKeys = !info.s3Bucket.isEmpty // keys of files in the connection's S3 bucket
            grid.onOpenJSON = { [weak self, weak grid] row, column in if let grid { self?.showJSON(in: grid, row: row, column: column, open: true) } }
            grid.onSelectCell = { [weak self, weak grid] row, column in if let grid { self?.showJSON(in: grid, row: row, column: column, open: false) } }
            grid.booleanTrue = conn.booleanTrue // what a toggled checkbox writes: t / f, or 1 / 0 for SQLite
            grid.booleanFalse = conn.booleanFalse
        }
    }

    // The window's top row: connection pill, the tabs centred, PRODUCTION and the light / dark toggle on the right.
    private func buildToolbar() -> NSView {
        let pill = ConnectionPill(name: info.name, target: target)
        pill.onClick = { [weak self] view in self?.openSwitcher(view) }
        switchMenu.delegate = self
        tabSwitch.onChange = { [weak self] i in self?.showTab(Tab(rawValue: i) ?? .data) }
        let toggle = AppearanceButton()
        toggle.onClick = { [weak self] in self?.toggleAppearance() }

        var trailing: [NSView] = []
        if production {
            let note = label(L("read-only, writes need confirmation"), 11, .regular, Theme.t2)
            note.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(495), for: .horizontal) // before the pill's path
            trailing += [badge(L("PRODUCTION"), .white, productionColor), note]
            note.toolTip = L("Writes need confirmation")
        }
        trailing.append(toggle)
        let left = NSStackView(), right = NSStackView(views: trailing)
        left.addView(pill, in: .leading)
        right.spacing = 8
        for side in [left, right] { side.setContentHuggingPriority(.defaultLow, for: .horizontal) }
        let rightWrap = NSStackView()
        rightWrap.addView(right, in: .trailing)
        let row = NSStackView(views: [left, tabSwitch, rightWrap])
        row.spacing = 12
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 12)
        let centred = left.widthAnchor.constraint(equalTo: rightWrap.widthAnchor) // the tabs in the middle when there's room
        centred.priority = .defaultLow
        centred.isActive = true
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return row
    }

    private func toggleAppearance() {
        let dark = !Theme.isDark(window!.effectiveAppearance)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        UserDefaults.standard.set(dark ? "dark" : "light", forKey: appearanceKey)
    }

    private func buildSidebar() -> NSView {
        let lightsRow = NSView() // the traffic lights sit here (the title bar is as tall as this row)
        lightsRow.heightAnchor.constraint(equalToConstant: 52).isActive = true

        filter.placeholderAttributedString = NSAttributedString(string: L("Filter"), attributes: [.font: Theme.font(12.5), .foregroundColor: Theme.t3])
        filter.delegate = self // filters as you type (controlTextDidChange)
        filter.font = Theme.font(12.5)
        filter.textColor = Theme.t1
        filter.focusRingType = .none
        filter.isBordered = false
        filter.drawsBackground = false
        filter.cell?.isScrollable = true
        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        glass.contentTintColor = Theme.t2
        let fieldRow0 = NSStackView(views: [glass, filter])
        fieldRow0.spacing = 6
        let field = Panel(fill: Theme.fill, border: Theme.fieldB, radius: 8)
        pin(fieldRow0, field, NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let fieldRow = NSView()
        pin(field, fieldRow, NSEdgeInsets(top: 0, left: 10, bottom: 12, right: 10))

        sidebar.headerView = nil
        sidebar.floatsGroupRows = false
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.intercellSpacing = .zero
        sidebar.selectionHighlightStyle = .regular
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.menu = NSMenu()
        sidebar.menu?.delegate = self // Open in New Tab, Pin / Unpin, … titled for the clicked table
        sidebar.target = self
        sidebar.action = #selector(sidebarClicked) // ⌘-click: new tab
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        return column([lightsRow, fieldRow, scroll], grow: scroll)
    }

    private func buildContent() -> NSView {
        let empty = centeredState([
            label(L("No table selected"), 15, .semibold, Theme.t2),
            label(L("Choose a table or view from the list on the left."), 12, .regular, Theme.t3),
        ])
        tabs = Switcher([buildDataTab(), buildStructureTab(), buildSQLTab(), buildDiagramTab(), empty])

        let pendingRow = bar([dot(Theme.chgDot, 8), pendingLabel, pendingDetail],
                             [PillButton(L("Discard"), height: 26, target: self, action: #selector(discardChanges)),
                              PillButton(L("Save"), style: .accent, shortcut: "⌘S", height: 26, target: self, action: #selector(saveChanges))],
                             height: 45, spacing: 10)
        let pending = Panel(fill: Theme.pendBg, radius: 0)
        pin(column([separator(), pendingRow], grow: pendingRow), pending)
        pending.isHidden = true
        pendingBar = pending

        tunnelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusRow = bar([statusLabel], [tunnelSpinner, tunnelDot, tunnelLabel], height: 31, spacing: 7)
        let status = column([separator(), statusRow], grow: statusRow)
        return column([tabs, pending, status], grow: tabs)
    }

    private func tabBar(_ leading: [NSView], _ trailing: [NSView], spacing: CGFloat = 8) -> NSView {
        let b = bar(leading, trailing, height: 51, spacing: spacing)
        return column([b, separator()], grow: b)
    }

    // A ring in the connection's colour around the whole window, above everything, following its rounded corners.
    // The window's root view layer draws it, because a layer border is composited above all sublayers. AppKit
    // doesn't publish the corner radius, so it comes from the private _cornerRadius, with a fallback.
    // ponytail: in full screen the ring keeps its rounded corners; fix in windowDidEnterFullScreen if it bothers.
    private func applyProductionFrame() {
        guard let frameView = window?.contentView?.superview else { return }
        let selector = NSSelectorFromString("_cornerRadius")
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = window!.responds(to: selector) ? (window!.value(forKey: "_cornerRadius") as? CGFloat ?? 16) : 16
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.borderWidth = 2
        frameView.layer?.borderColor = productionColor.cgColor
    }

    private var productionColor: NSColor { Theme.color(hex: info.frameColor, fallback: Theme.prod) }

    private func buildDataTab() -> NSView {
        readOnlyBadge.isHidden = true
        addButton = ToolButton(symbol: "plus", tip: L("New row"), target: self, action: #selector(addRow))
        deleteButton = ToolButton(symbol: "minus", tip: L("Delete or restore the selected rows (⌫)"), target: self, action: #selector(deleteRows))
        rowButtons = toolGroup([addButton, deleteButton])
        prevButton = ToolButton(symbol: "chevron.left", tip: L("Previous page"), size: NSSize(width: 22, height: 22), target: self, action: #selector(previousPage))
        nextButton = ToolButton(symbol: "chevron.right", tip: L("Next page"), size: NSSize(width: 22, height: 22), target: self, action: #selector(nextPage))
        for b in [prevButton!, nextButton!] { b.grouped = true } // bare chevrons
        pageLabel.alignment = .center
        pageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        refreshButton = ToolButton(symbol: "arrow.clockwise", tip: L("Refresh (⌘R)"), target: self, action: #selector(refresh))
        findButton = ToolButton(symbol: "magnifyingglass", tip: L("Find (⌘F)"), target: self, action: #selector(toggleFind))
        let header = tabBar([tableLabel, readOnlyBadge], [rowButtons, prevButton, pageLabel, nextButton, refreshButton, findButton])

        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        lock.contentTintColor = Theme.t3
        lock.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let stripRow = bar([lock, readOnlyText], [], height: 28)
        readOnlyStrip = column([stripRow, separator()], grow: stripRow)
        readOnlyStrip.isHidden = true

        dataGrid.onSort = { [weak self] column, ascending in self?.sort(by: column, ascending: ascending) }
        dataGrid.onChange = { [weak self] in self?.updateChanges() }
        dataGrid.onOpenReference = { [weak self] row, column, rect in self?.openReference(row: row, column: column, rect: rect) }
        dataGrid.onPickReference = { [weak self] row, column, rect in self?.pickReference(row: row, column: column, rect: rect) }
        dataGrid.onPickDate = { [weak self] row, column, rect, kind in self?.pickDate(row: row, column: column, rect: rect, kind: kind) }

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        dataGrid.addSubview(emptyLabel)
        NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo: dataGrid.centerXAnchor),
                                     emptyLabel.topAnchor.constraint(equalTo: dataGrid.topAnchor, constant: 41 + 40)])

        errorMessage.font = Theme.mono(12)
        errorMessage.alignment = .center
        dataState = Switcher([
            dataGrid,
            centeredState([dataSpinner, loadingLabel]),
            centeredState([errorTitle, errorMessage, PillButton(L("Try again"), target: self, action: #selector(refresh))]),
        ])

        searchField.placeholderString = L("Search Table")
        searchField.sendsWholeSearchString = true // one query per Enter, not per keystroke: it scans the whole table
        searchField.target = self
        searchField.action = #selector(search)
        searchField.delegate = self
        searchField.controlSize = .small
        searchField.font = Theme.font(12)
        searchField.widthAnchor.constraint(equalToConstant: 250).isActive = true
        searchStatus.setContentCompressionResistancePriority(.required, for: .horizontal)
        let searchRow = bar([searchField, searchHint], [searchStatus, PillButton(L("Done"), height: 22, target: self, action: #selector(closeFind))],
                            height: 45, spacing: 10)
        searchBar = column([searchRow, separator()], grow: searchRow)
        searchBar.isHidden = true

        return column([header, searchBar, readOnlyStrip, dataState], grow: dataState)
    }

    // MARK: - JSON inspector

    // The primary key value of a Data tab row (single-column keys only), to name the row in panel titles.
    private func keyOfRow(_ row: Int) -> String? {
        guard pkColumns.count == 1, let index = dataGrid.result?.columns.firstIndex(of: pkColumns[0]) else { return nil }
        return dataGrid.value(row: row, column: index)?.string
    }

    // open: from double-click / Enter. Otherwise (a click) the panel only follows the selection while it is open.
    private func showJSON(in grid: GridView, row: Int, column: Int, open: Bool) {
        if !open && !inspectorOpen { return }
        guard let result = grid.result, let value = grid.value(row: row, column: column), jsonIsValid(value), let json = value.string else {
            return jsonInspector.showPlaceholder()
        }
        inspectorGrid = grid
        (inspectorRow, inspectorColumn) = (row, column)
        var subtitle = String(format: L("Query result · row %ld"), row + 1)
        if grid === dataGrid { // "orders · id 10231 · jsonb"
            var parts = [displayName]
            if let key = keyOfRow(row) { parts.append("\(pkColumns[0]) \(key)") }
            else { parts.append(String(format: L("row %ld"), grid.rowNumberOffset + row + 1)) }
            if let type = columnTypes[result.columns[column]] { parts.append(type) }
            subtitle = parts.joined(separator: " · ")
        }
        jsonInspector.showJSON(json, title: result.columns[column], subtitle: subtitle, editable: grid.editable && !grid.isRowDeleted(row))
        setInspectorOpen(true)
    }

    private func setInspectorOpen(_ open: Bool) {
        guard open != inspectorOpen else { return }
        inspectorOpen = open
        Motion.animate(0.5) {
            inspectorWidth.animator().constant = open ? 342 : 0
            inspectorPanel.animator().alphaValue = open ? 1 : 0
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        if open { Motion.enter(inspectorPanel.layer, dx: 24, duration: 0.5) }
    }

    private func applyJSON(_ json: String) {
        inspectorGrid?.updateValue(.text(json), row: inspectorRow, column: inspectorColumn)
    }

    private func hideInspector() {
        setInspectorOpen(false)
        inspectorGrid = nil
    }

    // The grid's rows changed (new table, page, query): the inspector no longer points at a valid cell.
    private func resetInspector(for grid: GridView) {
        guard inspectorGrid === grid else { return }
        inspectorGrid = nil
        jsonInspector.showPlaceholder()
    }

    // MARK: - Find

    // ⌘F: the SQL editor gets the system find bar, the Data tab searches the whole table.
    @objc func showFind(_ sender: Any?) {
        if currentTab == .sql {
            sqlText.usesFindBar = true
            sqlText.isIncrementalSearchingEnabled = true
            let show = NSMenuItem()
            show.tag = NSTextFinder.Action.showFindInterface.rawValue
            window?.makeFirstResponder(sqlText)
            return sqlText.performTextFinderAction(show)
        }
        guard table != nil else { return }
        if currentTab != .data { showTab(.data) }
        if searchBar.isHidden {
            searchBar.isHidden = false
            searchBar.wantsLayer = true
            Motion.enter(searchBar.layer, dy: 8, duration: 0.32) // slides down
        }
        findButton.on = true
        updateSearchHint()
        window?.makeFirstResponder(searchField)
    }

    @objc private func toggleFind(_ sender: Any?) {
        searchBar.isHidden ? showFind(sender) : closeFind(sender)
    }

    @objc private func search(_ sender: NSSearchField) {
        let term = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let active = term.isEmpty ? nil : term
        guard active != searchTerm, confirmDiscard() else { return }
        searchTerm = active
        offset = 0
        updateSearchHint()
        loadData(showingSpinner: true)
    }

    private func updateSearchHint() {
        var linked: [String] = []
        for column in searchReferences.keys.sorted() {
            let ref = searchReferences[column]!
            let name = ref.schema == schema ? ref.table : shownName(ref.schema, ref.table)
            if !linked.contains(name) { linked.append(name) }
        }
        let tables = linked.joined(separator: ", ")
        if let searchTerm {
            searchHint.stringValue = linked.isEmpty ? String(format: L("All columns, whole table · “%@”"), searchTerm)
                : String(format: L("All columns and linked tables · “%@”"), searchTerm)
        } else {
            searchHint.stringValue = linked.isEmpty ? L("All columns of the whole table, ignoring case · Enter")
                : String(format: L("All columns and linked tables (%@), ignoring case · Enter"), tables)
        }
        searchHint.toolTip = linked.isEmpty ? nil : String(format: L("Also finds rows whose foreign key points to a matching row in: %@"), tables)
        if searchTerm == nil { searchStatus.stringValue = "" }
    }

    @objc private func closeFind(_ sender: Any?) {
        searchBar.isHidden = true
        findButton.on = false
        searchField.stringValue = ""
        if searchTerm != nil { search(searchField) }
        window?.makeFirstResponder(dataGrid.table)
    }

    // Esc in the search field closes the bar; Enter or Esc in the "Empty table" name field cancels.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === truncateField && (selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))) {
            if let sheet = control.window { window?.endSheet(sheet, returnCode: .cancel) }
            return true
        }
        guard control === searchField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        closeFind(nil)
        return true
    }

    // Esc closes, in this order: the confirmation, a popover, the find row, the inspector.
    @objc override func cancelOperation(_ sender: Any?) {
        if let confirm { return confirm.cancelOperation(sender) }
        if let card, card.isShown { return card.close() }
        if let popover, popover.isShown { return popover.close() }
        if !searchBar.isHidden { return closeFind(nil) }
        if inspectorOpen { return hideInspector() }
    }

    // MARK: - Structure

    private func buildStructureTab() -> NSView {
        let header = tabBar([structureTitle, structureMeta], [], spacing: 10)
        func cardBox(_ content: NSView) -> NSView {
            let box = Panel(fill: Theme.box, border: Theme.line, radius: 10)
            box.layer?.masksToBounds = true
            pin(content, box)
            return box
        }
        let body = column([label(L("Columns"), 11, .semibold, Theme.t2), cardBox(columnsCard),
                           label(L("Indexes"), 11, .semibold, Theme.t2), cardBox(indexesCard)],
                          insets: NSEdgeInsets(top: 18, left: 18, bottom: 24, right: 18), spacing: 10)
        body.setCustomSpacing(24, after: body.arrangedSubviews[1])
        let document = FlippedView()
        pin(body, document)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return column([header, scroll], grow: scroll)
    }

    // A row of a structure card; each cell has a weight (≤ 10) or a fixed width.
    private func structureRow(_ cells: [(NSView, CGFloat)], height: CGFloat, line: Bool) -> NSView {
        let row = NSView()
        // flexible cells share, by weight, what the fixed cells and the 14 pt padding on each side leave
        let fixed = cells.map(\.1).filter { $0 > 10 }.reduce(0, +)
        let weights = cells.map(\.1).filter { $0 <= 10 }.reduce(0, +)
        var previous = row.leadingAnchor
        for (i, (view, size)) in cells.enumerated() {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
            view.leadingAnchor.constraint(equalTo: previous, constant: i == 0 ? 14 : 0).isActive = true
            view.centerYAnchor.constraint(equalTo: row.centerYAnchor).isActive = true
            if size > 10 {
                view.widthAnchor.constraint(equalToConstant: size).isActive = true
            } else {
                let share = size / weights
                view.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: share, constant: -(28 + fixed) * share).isActive = true
            }
            previous = view.trailingAnchor
        }
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        guard line else { return row }
        return column([row, separator()], grow: row)
    }

    // Rows added to a card later stretch to its width like the ones column() was made with.
    private func add(to card: NSStackView, _ row: NSView) {
        card.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: card.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: card.trailingAnchor).isActive = true
    }

    private func showStructureColumns() {
        guard let r = structureColumns else { return }
        columnsCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let headers = [L("Name"), L("Type"), L("Nullable"), L("Default")].map { label($0, 11, .semibold, Theme.t3) }
        add(to: columnsCard, structureRow([(headers[0], 1.3), (headers[1], 1), (headers[2], 100), (headers[3], 1.5)], height: 30, line: true))
        for (i, c) in r.rows.enumerated() { // [column, type, null, default, pk]
            let name = c[0].string ?? ""
            let nameCell = NSStackView(views: [label(name, 12, .regular, Theme.t1, mono: true)])
            nameCell.spacing = 8
            if c[4].string == "PK" { nameCell.addArrangedSubview(badge("PK", Theme.orange, nil, border: Theme.orange, size: 9.5, weight: .bold, kern: 0)) }
            if let fk = foreignKeys[name] {
                nameCell.addArrangedSubview(label("→ \(shownName(fk.schema, fk.table)).\(fk.column)", 11, .regular, Theme.fkT, mono: true))
            }
            let notNull = !(c[2].string ?? "").isEmpty
            let cells: [(NSView, CGFloat)] = [
                (nameCell, 1.3), (label(c[1].string ?? "", 12, .regular, Theme.t2, mono: true), 1),
                (label(notNull ? "NOT NULL" : "NULL", 12, .regular, notNull ? Theme.t1 : Theme.t3, mono: true), 100),
                (label(c[3].string ?? "", 12, .regular, Theme.t3, mono: true), 1.5),
            ]
            let row = structureRow(cells, height: 34, line: i < r.rows.count - 1)
            add(to: columnsCard, row)
            row.wantsLayer = true
            Motion.enter(row.layer, dy: -6, duration: 0.4, delay: 0.035 * Double(i))
        }
    }

    // MARK: - Diagram

    // Bar (mode, back to the whole database, Open Table, Reset Layout, Export…) above the diagram, loading and empty pages.
    private func buildDiagramTab() -> NSView {
        diagramBack = PillButton("‹ " + L("Whole Database"), target: self, action: #selector(showWholeDiagram))
        diagramOpen = PillButton(L("Open Table"), target: self, action: #selector(openDiagramSelection))
        let reset = PillButton(L("Reset Layout"), target: self, action: #selector(resetDiagramLayout))
        let export = PillButton(L("Export…"), target: self, action: #selector(exportDiagram))
        let header = tabBar([diagramTitle, diagramBack], [diagramOpen, reset, export])

        diagramScroll.documentView = diagramView
        diagramScroll.hasVerticalScroller = true
        diagramScroll.hasHorizontalScroller = true
        diagramScroll.autohidesScrollers = true
        diagramScroll.allowsMagnification = true
        diagramScroll.minMagnification = 0.2
        diagramScroll.maxMagnification = 2
        diagramScroll.drawsBackground = false // the canvas draws its dot grid on the panel
        diagramView.onSelect = { [weak self] table in self?.diagramOpen.isEnabled = table != nil }
        diagramView.onShowNeighbours = { [weak self] table in self?.showDiagram(focus: table.qualifiedName) }
        diagramView.onOpen = { [weak self] table in self?.openTable(schema: table.schema, name: table.name, tab: .data) }
        diagramView.onOpenInNewTab = { [weak self] table in
            guard let self else { return }
            onOpenInNewTab?(self, table.schema, table.name)
        }
        diagramView.onMoved = { [weak self] table in self?.saveDiagramPosition(table) }
        diagramView.onAddColumn = { [weak self] table in
            guard let self else { return }
            present(SchemaSheet.addColumn(for: table, types: conn.commonTypes, production: production))
        }
        diagramView.onAddForeignKey = { [weak self] table, column in
            guard let self else { return }
            present(SchemaSheet.addForeignKey(for: table, column: column, tables: schemaGraph?.tables ?? [], production: production))
        }
        if conn.managesOwnSchema { // PocketBase: its schema lives in _collections too, ALTER TABLE would leave that behind
            let reason = L("This database's schema is managed by its application (PocketBase). Change it there.")
            diagramView.addColumnBlockedReason = reason
            diagramView.addForeignKeyBlockedReason = reason
        } else if !conn.canAddForeignKeys {
            diagramView.addForeignKeyBlockedReason = L("SQLite can't add a foreign key to an existing table without rebuilding it.")
        }

        diagramState = Switcher([
            diagramScroll,
            centeredState([diagramSpinner, label(L("Reading the schema…"), 12, .regular, Theme.t2)]),
            centeredState([label(L("No tables"), 15, .semibold, Theme.t2)]),
        ])
        return column([header, diagramState], grow: diagramState)
    }

    // Runs the sheet's SQL in a write transaction (the sheet is the confirmation, also on production) and, on success,
    // reads the schema again for the diagram, the sidebar and an open Structure tab.
    private func present(_ sheet: SchemaSheet) {
        sheet.productionColor = productionColor
        schemaSheet = sheet // alive while it is shown
        let edited = diagramView.selected?.qualifiedName // the box whose menu opened the sheet
        sheet.onRun = { [weak self] sql, done in
            self?.run({ conn in try conn.inWriteTransaction { try conn.execute(sql) } }, done: { [weak self] _, _ in
                done(nil)
                guard let self else { return }
                schemaSheet = nil
                diagramReselect = edited // stays selected, with its new column or arrow
                loadDiagram()
                loadTables()
                if openTable != nil { loadStructure() }
            }, failed: { error, _ in done(error) })
        }
        sheet.beginSheet(on: window!)
    }

    private func loadDiagram() {
        diagramLoading = true
        diagramState.selectedIndex = 1
        diagramSpinner.startAnimation(nil)
        run({ conn in (try conn.allColumns(), try conn.allForeignKeys()) }, done: { [weak self] r, _ in
            guard let self else { return }
            diagramLoading = false
            diagramSpinner.stopAnimation(nil)
            schemaGraph = SchemaGraph(columns: r.0, foreignKeys: r.1)
            completer.schema = schemaGraph
            if let focus = diagramFocus, schemaGraph?.table(named: focus) == nil { diagramFocus = nil } // dropped since
            showDiagram()
        }, failed: { [weak self] error, _ in
            guard let self else { return }
            diagramLoading = false
            diagramSpinner.stopAnimation(nil)
            diagramState.selectedIndex = 2
            if currentTab == .diagram { showError(error) } // for the SQL editor's completion it just stays without names
        })
    }

    // Lays out the whole database (with the saved positions) or the focus's neighbours, and shows it.
    private func showDiagram() {
        guard var graph = schemaGraph else { return }
        var focus = diagramFocus.flatMap { graph.table(named: $0) }
        if focus == nil { diagramFocus = nil } // gone: the whole database, really (positions save again)
        if let f = focus {
            graph = graph.neighbours(of: f)
            focus = graph.table(named: f.qualifiedName)
            schemaLayout(graph, focus: focus, saved: [:])
        } else {
            schemaLayout(graph, focus: nil, saved: savedDiagramPositions())
        }
        diagramView.graph = graph
        diagramState.selectedIndex = graph.tables.isEmpty ? 2 : 0
        diagramTitle.stringValue = focus.map { String(format: L("Neighbours of %@"), shownName($0.schema, $0.name)) } ?? L("Whole database")
        diagramBack.isHidden = focus == nil
        diagramStatus = "\(LN("%lu tables", graph.tables.count)) · \(LN("%lu foreign keys", graph.edges.count))"
        updateStatus()
        // the table open in this window (or the focus) starts selected and in view
        let selected = diagramReselect.flatMap { graph.table(named: $0) } ?? focus
            ?? table.flatMap { graph.table(named: "\(schema!).\($0)") }
        diagramReselect = nil
        diagramView.selected = selected
        diagramOpen.isEnabled = selected != nil
        if let selected { diagramView.scrollToVisible(selected.frame.insetBy(dx: -40, dy: -40)) }
    }

    private func showDiagram(focus qualifiedName: String?) {
        diagramFocus = qualifiedName
        showDiagram()
    }

    @objc private func showWholeDiagram(_ sender: Any?) { showDiagram(focus: nil) }

    // Sidebar: right-click → Show on Diagram (neighbours of that table).
    @objc private func showOnDiagram(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? [String] else { return }
        diagramFocus = "\(t[0]).\(t[1])"
        showTab(.diagram) // loads the schema the first time
        // a table created after the schema was read (e.g. in the SQL tab): read it again
        if let graph = schemaGraph, graph.table(named: diagramFocus!) == nil { return loadDiagram() }
        showDiagram()
    }

    @objc private func openDiagramSelection(_ sender: Any?) {
        if let t = diagramView.selected { openTable(schema: t.schema, name: t.name, tab: .data) }
    }

    private func savedDiagramPositions() -> [String: CGPoint] {
        let saved = UserDefaults.standard.dictionary(forKey: diagramPositionsKey)?[info.identity] as? [String: String] ?? [:]
        return saved.mapValues { NSPointFromString($0) }
    }

    // Only the whole-database layout is remembered; neighbours are always laid out fresh.
    private func saveDiagramPosition(_ table: SchemaTable) {
        guard diagramFocus == nil else { return }
        var all = UserDefaults.standard.dictionary(forKey: diagramPositionsKey) ?? [:]
        var mine = all[info.identity] as? [String: String] ?? [:]
        mine[table.qualifiedName] = NSStringFromPoint(table.frame.origin)
        all[info.identity] = mine
        UserDefaults.standard.set(all, forKey: diagramPositionsKey)
    }

    @objc private func resetDiagramLayout(_ sender: Any?) {
        let old = diagramView.frames
        if diagramFocus == nil { // neighbours aren't remembered: laying them out again is enough
            var all = UserDefaults.standard.dictionary(forKey: diagramPositionsKey) ?? [:]
            all[info.identity] = nil
            UserDefaults.standard.set(all, forKey: diagramPositionsKey)
        }
        showDiagram()
        diagramView.animateLayout(from: old)
    }

    // The whole diagram, not just the visible part: PNG at 2× or PDF.
    @objc private func exportDiagram(_ sender: Any?) {
        guard !diagramView.contentRect.isEmpty, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(info.name.isEmpty ? "diagram" : info.name).png"
        panel.allowedContentTypes = [.png, .pdf]
        panel.allowsOtherFileTypes = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                guard let data = diagramView.exportData(pdf: url.pathExtension.lowercased() == "pdf") else { return }
                try data.write(to: url, options: .atomic)
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - SQL tab

    private func buildSQLTab() -> NSView {
        let run = PillButton(L("Run"), style: .accent, shortcut: "⌘R", target: self, action: #selector(runQuery))
        let header = tabBar([label(L("Query"), 12, .regular, Theme.t2)], [label(L("⌃Space: suggestions"), 11, .regular, Theme.t3), run], spacing: 10)
        let (editor, text) = sqlTextScrollView(editable: true, lineNumbers: true)
        sqlText = text
        completer = SQLCompleter(textView: text) // tables, columns, keywords while typing
        editor.heightAnchor.constraint(equalToConstant: 210).isActive = true

        sqlErrorText.font = Theme.mono(12)
        let errorBox = Panel(fill: Theme.errorFill, border: Theme.errorBorder, radius: 10)
        pin(column([label(L("Query error"), 12, .semibold, Theme.red), sqlErrorText], insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), spacing: 8), errorBox)
        let errorState = NSView()
        errorBox.translatesAutoresizingMaskIntoConstraints = false
        errorState.addSubview(errorBox)
        NSLayoutConstraint.activate([
            errorBox.topAnchor.constraint(equalTo: errorState.topAnchor, constant: 16),
            errorBox.leadingAnchor.constraint(equalTo: errorState.leadingAnchor, constant: 16),
            errorBox.trailingAnchor.constraint(equalTo: errorState.trailingAnchor, constant: -16),
            errorBox.bottomAnchor.constraint(lessThanOrEqualTo: errorState.bottomAnchor, constant: -16),
        ])
        let running = NSStackView(views: [sqlSpinner, label(L("Running…"), 12, .regular, Theme.t2)])
        running.spacing = 10
        sqlState = Switcher([
            centeredState([label(L("Results will appear here. Run a query: ⌘R"), 12, .regular, Theme.t3)]),
            centeredState([running]),
            centeredState([sqlDoneLabel]),
            errorState,
            sqlGrid,
        ])
        return column([header, editor, separator(), sqlState], grow: sqlState)
    }

    // MARK: - Tabs and status

    private func showTab(_ tab: Tab) {
        if tab.rawValue < 4 && tabSwitch.selectedIndex != tab.rawValue { tabSwitch.select(tab.rawValue, animated: true) }
        currentTab = tab
        tabs.selectedIndex = tab != .sql && tab != .diagram && table == nil ? Tab.empty.rawValue : tab.rawValue // SQL and Diagram need no table
        sidebar.pillVisible = tab != .sql && tab != .diagram
        // the diagram and the SQL editor's completion both need the schema
        if (tab == .diagram || tab == .sql) && schemaGraph == nil && !diagramLoading { loadDiagram() }
        updateChanges()
        updateStatus()
        onTabsChanged?(self)
    }

    private func updateStatus() {
        var text = table == nil ? tablesStatus : dataStatus
        if currentTab == .structure && table != nil { text = structureStatus }
        if currentTab == .sql { text = sqlStatus }
        if currentTab == .diagram { text = diagramStatus }
        statusLabel.stringValue = text
    }

    private func setTunnelConnected(_ connected: Bool) {
        tunnelConnected = connected
        let reconnecting = tunnel != nil && !connected
        reconnecting ? tunnelSpinner.startAnimation(nil) : tunnelSpinner.stopAnimation(nil)
        tunnelDot.isHidden = reconnecting
        tunnelDot.fillColor = tunnel != nil ? Theme.green : Theme.t3
        tunnelLabel.stringValue = tunnel == nil
            ? (info.kind == "sqlite" ? L("SQLite file") : info.kind == "sqlite-ssh" ? L("SQLite over SSH") : L("Direct connection"))
            : connected ? L("SSH tunnel: connected") : L("SSH tunnel: dropped, reconnecting…")
        tunnelLabel.textColor = reconnecting ? Theme.orange : Theme.t2
    }

    private var displayName: String { shownName(schema ?? "", table ?? "") }

    // MARK: - Running queries

    // Work runs on the connection's queue; `done` gets the result and the time it took on the main thread.
    // Without `failed`, errors are shown as a sheet.
    private func run<T: Sendable>(_ work: @escaping @Sendable (DBConnection) throws -> T, done: @escaping @MainActor (T, Double) -> Void,
                                  failed: (@MainActor (Error, Double) -> Void)? = nil) {
        let conn = conn
        let start = CFAbsoluteTimeGetCurrent()
        conn.queue.async {
            let result = Result { try work(conn) }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let r): done(r, ms)
                    case .failure(let e): if let failed { failed(e, ms) } else { self.showError(e) }
                    }
                }
            }
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Error")
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: - Tables and data

    private func loadTables() {
        run({ conn in try conn.tables() }, done: { [weak self] r, _ in
            guard let self else { return }
            tables = r.rows.map { TableItem(schema: $0[0].string ?? "", name: $0[1].string ?? "", kind: $0[2].string ?? "table", estimate: $0[3].string) }
            let views = tables!.filter(\.isView).count
            tablesStatus = "\(LN("%lu tables", tables!.count - views)) · \(LN("%lu views", views))"
            filterChanged(nil)
            updateStatus()
        })
        // no list (e.g. no access to pg_database): the switcher shows saved connections only
        run({ conn in try conn.databases() }, done: { [weak self] r, _ in self?.databases = r.rows.compactMap { $0[0].string } },
            failed: { _, _ in })
    }

    @objc private func filterChanged(_ sender: Any?) {
        let f = filter.stringValue
        var pinnedTables: [TableItem] = [], plain: [TableItem] = [], views: [TableItem] = []
        for t in tables ?? [] {
            if !f.isEmpty && !t.name.localizedCaseInsensitiveContains(f) { continue }
            if pinned.contains(t.pinName) { pinnedTables.append(t) } else if t.isView { views.append(t) } else { plain.append(t) }
        }
        pinnedTables.sort { (pinned.firstIndex(of: $0.pinName) ?? 0) < (pinned.firstIndex(of: $1.pinName) ?? 0) }
        sideRows = []
        for (title, items) in [(L("Pinned"), pinnedTables), (L("Tables"), plain), (L("Views"), views)] where !items.isEmpty {
            sideRows.append(.section(title))
            sideRows += items.map { .table($0) }
        }
        sidebar.reloadData()
        reselectCurrentTable()
        applyPendingTable()
    }

    // MARK: - Popovers

    // NSPopover for the calendar and the image preview; a card for foreign keys.
    private func showPopover(_ content: NSViewController, rect: NSRect, in view: NSView? = nil, card useCard: Bool = false) {
        popover?.close()
        card?.close()
        let view = view ?? dataGrid.table
        if useCard {
            let c = CardPopover()
            c.contentViewController = content
            c.show(relativeTo: rect, of: view)
            card = c
            return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = content
        p.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        popover = p
    }

    private func closePopovers() {
        popover?.close()
        card?.close()
    }

    // Editing a date/time cell: calendar and clock instead of typing the format.
    private func pickDate(row: Int, column: Int, rect: NSRect, kind: ValueKind) {
        guard let result = dataGrid.result else { return }
        let original = dataGrid.value(row: row, column: column) ?? .null
        let picker = DatePickerPopover(title: result.columns[column], value: original, kind: kind)
        picker.onPick = { [weak self] value in
            guard let self else { return }
            // same moment written differently (+02 vs +02:00) is not a change
            let same = value.string.flatMap { kind.date(from: $0) } != nil
                && value.string.flatMap { kind.date(from: $0) } == original.string.flatMap { kind.date(from: $0) }
            if !same { dataGrid.updateValue(value, row: row, column: column) }
            closePopovers()
        }
        showPopover(picker, rect: rect)
    }

    // 🖼 on an image value (bytea, data URI, base64, URL): the picture in a popover.
    private func openImage(in grid: GridView, row: Int, column: Int, rect: NSRect) {
        guard let result = grid.result, let value = grid.value(row: row, column: column)?.string else { return }
        let key = grid === dataGrid ? keyOfRow(row) : nil
        let title = key.map { "\(result.columns[column]) · \($0)" } ?? result.columns[column]
        showPopover(ImagePreview(title: title, value: value), rect: rect, in: grid.table)
    }

    // 🖼 on a file kept elsewhere: a PocketBase file field (its S3 bucket or pb_data/storage), or keys of files in the
    // connection's S3 bucket. Several files: a menu of their names first.
    private func openFile(in grid: GridView, row: Int, column: Int, rect: NSRect) {
        guard let result = grid.result else { return }
        let value = grid.value(row: row, column: column) ?? .null
        let columnName = result.columns[column]
        let pb = grid === dataGrid && pocketBaseFiles?.columns[columnName] != nil ? pocketBaseFiles : nil
        let record = pb != nil ? result.columns.firstIndex(of: "id").flatMap { grid.value(row: row, column: $0)?.string } : nil
        if pb != nil && record == nil { return } // a new row: nothing uploaded yet
        let files = pb != nil ? pocketBaseFileNames(value) : fileKeys(in: value)
        let open: (String) -> Void = { [weak self, weak grid] file in
            guard let self, let grid else { return }
            let name = (file as NSString).lastPathComponent
            let preview = ImagePreview(title: "\(columnName) · \(name)", name: name) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await loadFile(file, pocketBase: pb, record: record)
            }
            preview.confirmsSave = production
            showPopover(preview, rect: rect, in: grid.table)
        }
        if files.count == 1 { return open(files[0]) }
        let menu = NSMenu()
        for file in files {
            let item = menu.addItem(withTitle: (file as NSString).lastPathComponent, action: #selector(openFileMenuItem), keyEquivalent: "")
            item.target = self
            item.representedObject = FileAction { open(file) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: grid.table)
    }

    private final class FileAction: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    @objc private func openFileMenuItem(_ sender: NSMenuItem) { (sender.representedObject as? FileAction)?.run() }

    // The bytes of a file: from S3 with the user's aws CLI (the connection's bucket, or the one PocketBase uses), or
    // from PocketBase's own storage through the connection.
    private func loadFile(_ file: String, pocketBase pb: PocketBaseFiles?, record: String?) async throws -> Data {
        var bucket = info.s3Bucket, region = info.s3Region, endpoint = ""
        let profile = info.awsProfile
        if let s3 = pb?.s3, bucket.isEmpty { (bucket, region, endpoint) = (s3.bucket, s3.region, s3.endpoint) }
        if let pb, bucket.isEmpty, let record {
            let conn = conn
            return try await withCheckedThrowingContinuation { done in
                conn.queue.async {
                    do {
                        done.resume(returning: try conn.pocketBaseFile(collection: pb.collection, record: record, name: file, maxBytes: storagePreviewLimit))
                    } catch {
                        // maybe the files are in S3 and the settings just don't say so
                        done.resume(throwing: pb.settingsUnreadable ? DBError(error.localizedDescription + "\n" +
                            L("PocketBase's settings are encrypted, so PlainDB can't tell whether its files are in S3. If they are, set the bucket under S3 files in the connection.")) : error)
                    }
                }
            }
        }
        if let pb, !(pocketBaseFileNameValid(pb.collection) && pocketBaseFileNameValid(record ?? "") && pocketBaseFileNameValid(file)) {
            throw DBError(L("Not a PocketBase file name."))
        }
        guard let location = s3Location(key: pb != nil ? "\(pb!.collection)/\(record ?? "")/\(file)" : file, bucket: bucket) else {
            throw DBError(L("Set the S3 bucket for files in the connection's settings."))
        }
        return try await fetchS3File(aws: awsExecutable(), bucket: location.bucket, key: location.key, region: region, profile: profile,
                                     endpoint: endpoint, maxBytes: s3PreviewLimit)
    }

    // ↗ on a foreign key value: the referenced row, field by field.
    private func openReference(row: Int, column: Int, rect: NSRect) {
        guard let result = dataGrid.result else { return }
        let name = result.columns[column]
        guard let fk = foreignKeys[name], let value = dataGrid.value(row: row, column: column), let text = value.string else { return }
        let sql = "SELECT * FROM \(quoteIdent(fk.schema)).\(quoteIdent(fk.table)) WHERE \(quoteIdent(fk.column)) = $1 LIMIT 1"
        let from = displayName
        run({ conn in try conn.execute(sql, [value]) }, done: { [weak self] r, _ in
            guard let self else { return }
            let preview = ReferencePreview(title: shownName(fk.schema, fk.table), subtitle: String(format: L("%@ = %@ · from %@.%@"), fk.column, text, from, name), result: r)
            preview.onOpenTable = { [weak self] in self?.openTable(schema: fk.schema, name: fk.table, tab: .data) }
            showPopover(preview, rect: rect, card: true)
        })
    }

    // Editing a foreign key: search the referenced table and pick a row; its key goes into the cell.
    private func pickReference(row: Int, column: Int, rect: NSRect) {
        guard let result = dataGrid.result, let fk = foreignKeys[result.columns[column]] else { return }
        let tableSQL = "\(quoteIdent(fk.schema)).\(quoteIdent(fk.table))"
        let picker = ReferencePicker(column: result.columns[column], table: shownName(fk.schema, fk.table), keyColumn: fk.column)
        var columns: [String]? // learned from the first (unfiltered) query
        let conn = conn
        picker.onSearch = { [weak self, weak picker] term in
            let condition = !term.isEmpty && columns != nil ? " WHERE " + conn.searchCondition(columns: columns!) : ""
            let sql = "SELECT * FROM \(tableSQL)\(condition) ORDER BY \(quoteIdent(fk.column)) LIMIT 20"
            let params: [DBValue] = condition.isEmpty ? [] : [.text(likePattern(term))]
            self?.run({ conn in try conn.execute(sql, params, timeout: 3) }, done: { r, _ in // the referenced table may be big
                if columns == nil { columns = r.columns }
                picker?.showResult(r, error: nil)
            }, failed: { error, _ in picker?.showResult(nil, error: error) })
        }
        picker.onPick = { [weak self] value in
            self?.dataGrid.updateValue(value, row: row, column: column)
            self?.closePopovers()
        }
        showPopover(picker, rect: rect, card: true)
    }

    // Shows that table in `tab`, now or as soon as the table list has loaded. A table that doesn't exist (any more)
    // is ignored.
    func openTable(schema: String, name: String, tab: Tab) {
        closePopovers()
        pendingTable = SavedTab(schema: schema, table: name, page: tab.rawValue)
        applyPendingTable()
    }

    // The table asked for by openTable, once the table list has loaded (filterChanged calls this again).
    private func applyPendingTable() {
        guard let pending = pendingTable, let tables else { return }
        pendingTable = nil
        let row = sideRows.firstIndex { if case .table(let t) = $0 { t.schema == pending.schema && t.name == pending.table } else { false } }
        guard let row else {
            let listed = tables.contains { $0.schema == pending.schema && $0.name == pending.table }
            if listed && !filter.stringValue.isEmpty { // hidden by the sidebar filter: clear it and try again
                filter.stringValue = ""
                pendingTable = pending
                return filterChanged(nil)
            }
            if !listed && !pendingReloaded { // created after the list was read (e.g. seen on a fresh diagram): reload once
                pendingReloaded = true
                pendingTable = pending
                return loadTables()
            }
            pendingReloaded = false
            NSSound.beep() // the table is gone
            return
        }
        pendingReloaded = false
        if !(pending.schema == schema && pending.table == table) {
            guard confirmDiscard() else { return }
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        }
        if let tab = Tab(rawValue: pending.page), tab != .empty { showTab(tab) }
    }

    // The open table and tab. While a restored table is still waiting for the table list, that one counts, so saving
    // doesn't drop it.
    var openTable: SavedTab? {
        pendingTable ?? table.map { SavedTab(schema: schema!, table: $0, page: currentTab.rawValue) }
    }

    // MARK: - Window tabs

    // ⌘-click in the sidebar opens the table in a new tab and leaves this window's table as it is.
    private var isCommandClick: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return (event.type == .leftMouseDown || event.type == .leftMouseUp) && event.modifierFlags.contains(.command)
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        tableView === sidebar && isCommandClick ? tableView.selectedRowIndexes : proposed
    }

    @objc private func sidebarClicked(_ sender: Any?) {
        let row = sidebar.clickedRow
        guard isCommandClick, row >= 0, case .table(let t) = sideRows[row] else { return }
        onOpenInNewTab?(self, t.schema, t.name)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? [String] else { return }
        onOpenInNewTab?(self, t[0], t[1])
    }

    // The tab bar's "+" and ⌘T: the open table again in a new tab, or an empty tab when none is open.
    @objc override func newWindowForTab(_ sender: Any?) {
        onOpenInNewTab?(self, schema, table)
    }

    // MARK: - Switching database or connection

    private func openSwitcher(_ view: NSView) {
        switchMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }

    private func buildSwitchMenu() {
        let menu = switchMenu
        menu.minimumWidth = 260
        if !databases.isEmpty { // none for a file
            menu.addItem(.sectionHeader(title: String(format: L("Databases on %@"), info.host.isEmpty ? "localhost" : info.host)))
        }
        for db in databases {
            let item = menu.addItem(withTitle: db, action: #selector(switchDatabase), keyEquivalent: "")
            item.target = self
            item.representedObject = db
            item.attributedTitle = NSAttributedString(string: db, attributes: [.font: Theme.mono(13)])
            item.state = db == info.database ? .on : .off
        }
        for (title, list) in [(L("Saved connections"), ConnectionStore.load()), (L("Recent files"), ConnectionStore.recentFiles())] where !list.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for c in list {
                let address = c.kind == "sqlite" ? ((c.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
                    : c.kind == "sqlite-ssh" ? String(format: L("%@ via %@"), (c.path as NSString).lastPathComponent, c.sshHost)
                    : !c.sshHost.isEmpty ? String(format: L("via %@"), c.sshHost)
                    : "\(c.host.isEmpty ? "localhost" : c.host):\(c.port.isEmpty ? "5432" : c.port)"
                let item = menu.addItem(withTitle: c.name, action: #selector(switchConnection), keyEquivalent: "")
                item.target = self
                item.representedObject = ConnectionBox(c)
                item.attributedTitle = menuTitle(c.name, address, at: 220)
                if !c.frameColor.isEmpty { item.image = colorDot(Theme.color(hex: c.frameColor, fallback: Theme.prod)) }
                item.state = c.id == info.id && c.database == info.database ? .on : .off
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Connections…"), action: NSSelectorFromString("showConnections:"), keyEquivalent: "")
    }

    private final class ConnectionBox: NSObject {
        let connection: Connection
        init(_ c: Connection) { connection = c }
    }

    // Same server, same credentials and tunnel settings, another database.
    @objc private func switchDatabase(_ sender: NSMenuItem) {
        guard let db = sender.representedObject as? String else { return }
        var c = info
        c.database = db
        if c.id == "local" { // local windows are named after the database and use its colour
            c.name = db
            c.frame = ConnectionStore.localFrameColor(for: db)
        }
        switchTo(c)
    }

    @objc private func switchConnection(_ sender: NSMenuItem) {
        if let box = sender.representedObject as? ConnectionBox { switchTo(box.connection) }
    }

    private func switchTo(_ c: Connection) {
        guard c != info, confirmDiscard() else { return }
        let file = c.isSQLite
        let password = file || c.id == "local" ? "" : ConnectionStore.password(for: c.id) ?? ""
        statusLabel.stringValue = !c.sshHost.isEmpty && !file ? String(format: L("Opening tunnel via %@…"), c.sshHost)
            : String(format: L("Connecting to %@…"), file ? c.name : c.database.isEmpty ? c.name : c.database)
        Task { @MainActor [weak self] in
            do {
                let (connection, tunnel) = try await connect(c, password: password)
                guard let self else { return }
                onReplace?(self, connection, tunnel, c)
            } catch {
                self?.updateStatus()
                self?.showError(error)
            }
        }
    }

    // MARK: - Pinned tables

    private var pinsKeyName: String { "\(info.id)/\(info.database)" }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === switchMenu { return buildSwitchMenu() }
        let row = sidebar.clickedRow
        guard row >= 0, case .table(let t) = sideRows[row] else { return }
        let represented = [t.schema, t.name]
        let tab = menu.addItem(withTitle: L("Open in New Tab"), action: #selector(openInNewTab), keyEquivalent: "")
        tab.target = self
        tab.representedObject = represented
        tab.attributedTitle = menuTitle(L("Open in New Tab"), L("⌘-click"), at: 230)
        if !t.isView { // views aren't on the diagram
            let diagram = menu.addItem(withTitle: L("Show on Diagram"), action: #selector(showOnDiagram), keyEquivalent: "")
            diagram.target = self
            diagram.representedObject = represented
        }
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: pinned.contains(t.pinName) ? L("Unpin") : L("Pin to Top"), action: #selector(togglePin), keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        if !t.isView {
            menu.addItem(.separator())
            let empty = menu.addItem(withTitle: L("Empty Table…"), action: #selector(confirmTruncate), keyEquivalent: "")
            empty.target = self
            empty.representedObject = represented
        }
    }

    // MARK: - Emptying a table

    // "Empty" stays disabled until the table name is typed; Enter and Esc cancel.
    @objc private func confirmTruncate(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? [String], let window else { return }
        let item = tables?.first { $0.schema == t[0] && $0.name == t[1] }
        truncateName = shownName(t[0], t[1])

        let palette = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
            .applying(.init(paletteColors: [.white, NSColor(srgbRed: 0xf5 / 255, green: 0xb4 / 255, blue: 0x0a / 255, alpha: 1)]))
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!.withSymbolConfiguration(palette)!)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = label(String(format: L("Empty the table %@?"), truncateName), 13, .bold)
        let body = info.isSQLite ? L("All rows will be deleted. This can't be undone.") // DELETE, and no row estimate
            : item?.estimate.flatMap { Int64($0) }.map {
                String(format: L("All rows (about %@) will be deleted with TRUNCATE. If other tables reference this table, Postgres will refuse and say why. This can't be undone."), compactCount($0))
            } ?? L("All rows will be deleted with TRUNCATE. If other tables reference this table, Postgres will refuse and say why. This can't be undone.")
        let text = wrappingLabel(body, 12)
        text.preferredMaxLayoutWidth = 376 // 470 − 2 × 20 padding − 54 for the icon
        let texts = column([title, text], insets: NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0), spacing: 4)
        texts.widthAnchor.constraint(equalToConstant: 376).isActive = true
        let top = NSStackView(views: [icon, texts])
        top.alignment = .top
        top.spacing = 14

        let name = label(truncateName, 12, .semibold, Theme.t1, mono: true)
        name.isSelectable = true
        let chip = Panel(fill: Theme.fill, radius: 6)
        pin(name, chip, NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7))
        let copy = PillButton(L("Copy"), target: self, action: #selector(copyTruncateName))
        truncateCopy = copy
        let nameRow = NSStackView(views: [chip, copy])
        nameRow.spacing = 8
        nameRow.alignment = .centerY
        let field = NSTextField()
        field.placeholderString = truncateName
        field.font = Theme.mono(12)
        field.delegate = self
        truncateField = field
        let confirm = column([label(L("To confirm, type the table name:"), 12), nameRow, field], insets: NSEdgeInsets(top: 0, left: 54, bottom: 0, right: 0), spacing: 6)

        let empty = PillButton(L("Empty"), style: .custom(Theme.red, .white), target: self, action: #selector(endTruncateSheet))
        empty.tag = NSApplication.ModalResponse.OK.rawValue
        empty.isEnabled = false
        truncateButton = empty
        let cancel = PillButton(L("Cancel"), target: self, action: #selector(endTruncateSheet))
        cancel.tag = NSApplication.ModalResponse.cancel.rawValue
        cancel.keyEquivalent = "\r"
        cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
        let buttons = bar([], [empty, cancel], height: 28, left: 0, right: 0, spacing: 10)

        let content = column([top, confirm, buttons], insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), spacing: 14)
        content.widthAnchor.constraint(equalToConstant: 470).isActive = true
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = content
        sheet.initialFirstResponder = field
        window.beginSheet(sheet) { [weak self] response in
            self?.truncateField = nil
            if response == .OK { self?.truncate(schema: t[0], table: t[1]) }
        }
    }

    @objc private func endTruncateSheet(_ sender: NSButton) {
        if sender.tag == NSApplication.ModalResponse.OK.rawValue && truncateField?.stringValue != truncateName { return }
        if let sheet = sender.window { window?.endSheet(sheet, returnCode: NSApplication.ModalResponse(sender.tag)) }
    }

    @objc private func copyTruncateName(_ sender: Any?) {
        copyLocally(.general, text: truncateName)
        truncateCopy?.title = L("Copied")
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as AnyObject? === filter { return filterChanged(nil) }
        guard let field = truncateField, notification.object as AnyObject? === field else { return }
        truncateButton?.isEnabled = field.stringValue == truncateName
    }

    private func truncate(schema: String, table: String) {
        let sql = conn.emptyTableStatement(schema: schema, table: table)
        // a write transaction: a production session is read-only by default
        run({ conn in try conn.inWriteTransaction { try conn.execute(sql) } }, done: { [weak self] _, _ in
            guard let self else { return }
            if self.schema == schema && self.table == table {
                dataGrid.discardChanges()
                loadData(showingSpinner: false)
            }
            loadTables() // row estimates
        })
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? [String] else { return }
        let name = "\(t[0]).\(t[1])"
        if let i = pinned.firstIndex(of: name) { pinned.remove(at: i) } else { pinned.append(name) }
        var all = UserDefaults.standard.dictionary(forKey: pinsKey) ?? [:]
        all[pinsKeyName] = pinned.isEmpty ? nil : pinned
        UserDefaults.standard.set(all, forKey: pinsKey)
        filterChanged(nil)
    }

    // After the list is rebuilt, keep the open table selected (without reloading it).
    private func reselectCurrentTable() {
        guard let table else { return }
        let row = sideRows.firstIndex { if case .table(let t) = $0 { t.schema == schema && t.name == table } else { false } }
        if let row { sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        sidebar.movePill(animated: false)
    }

    // MARK: - Data

    private func loadData(showingSpinner spinner: Bool) {
        guard let schema, let table else { return }
        var sql = "SELECT * FROM \(quoteIdent(schema)).\(quoteIdent(table))"
        let term = columnNames.isEmpty ? nil : searchTerm
        let condition = term != nil ? currentSearchCondition : nil
        if let condition { sql += " WHERE \(condition)" }
        if let sortColumn { sql += " ORDER BY \(quoteIdent(sortColumn)) \(sortAscending ? "ASC" : "DESC")" }
        sql += " LIMIT \(pageSize) OFFSET \(offset)"
        let query = sql
        let params: [DBValue] = term.map { [.text(likePattern($0))] } ?? []
        if spinner {
            loadingLabel.stringValue = String(format: L("Loading %@…"), displayName)
            dataSpinner.startAnimation(nil)
            dataState.selectedIndex = DataState.loading.rawValue
            dataStatus = L("Loading…")
            updateStatus()
        }
        let offset = offset, newTable = spinner
        run({ conn in
            // ponytail: a search scans every column of the whole table; capped so a big production table can't hang the window
            term == nil ? try conn.execute(query, params) : try conn.execute(query, params, timeout: 15)
        }, done: { [weak self] r, ms in
            guard let self else { return }
            dataSpinner.stopAnimation(nil)
            dataGrid.rowNumberOffset = offset
            dataGrid.result = r
            dataGrid.highlight = term
            dataGrid.highlightedValues = nil // key cells matched through their referenced row: highlightReferences
            emptyLabel.stringValue = !r.rows.isEmpty ? "" : term != nil ? L("Nothing found") : L("The table is empty")
            // the exact count follows from loadTotal
            searchStatus.stringValue = term == nil ? "" : r.rows.count < pageSize ? LN("%lu rows", offset + r.rows.count) : ""
            resetInspector(for: dataGrid)
            dataState.selectedIndex = DataState.grid.rawValue
            applyEditability()
            updateChanges()
            if newTable { dataGrid.animateRowsIn(.rise) }
            pageLabel.stringValue = r.rows.isEmpty ? L("no rows") : "\(offset + 1)–\(offset + r.rows.count)"
            prevButton.isEnabled = offset > 0
            nextButton.isEnabled = r.rows.count == pageSize
            if !r.rows.isEmpty { loadTotal(condition: condition, params: params, offset: offset, shown: r.rows.count) }
            if let term { highlightReferences(term: term, result: r) }
            dataStatus = "\(LN("%lu rows", r.rows.count)) · \(Int(ms.rounded())) ms"
            updateStatus()
        }, failed: { [weak self] error, _ in
            guard let self else { return }
            dataSpinner.stopAnimation(nil)
            let timedOut = term != nil && (error as? DBError)?.sqlstate == "57014"
            errorTitle.stringValue = timedOut ? L("The search took too long") : String(format: L("Couldn't load %@"), displayName)
            errorMessage.stringValue = timedOut ? L("It was stopped after 15 s. Try a more specific term.") : error.localizedDescription
            dataState.selectedIndex = DataState.failed.rawValue
            dataStatus = L("Loading failed")
            updateStatus()
        })
    }

    // "1–200 of 12,345": an exact count, capped at 3 s; on a huge table the planner's estimate is shown instead.
    private func loadTotal(condition: String?, params: [DBValue], offset: Int, shown: Int) {
        guard let schema, let table else { return }
        let sql = "SELECT count(*) FROM \(quoteIdent(schema)).\(quoteIdent(table))" + (condition.map { " WHERE \($0)" } ?? "")
        let term = searchTerm, estimate = estimate
        let range = "\(offset + 1)–\(offset + shown)"
        let stale = { [weak self] in self.map { $0.table != table || $0.offset != offset || $0.searchTerm != term } ?? true } // the user moved on
        run({ conn in try conn.execute(sql, params, timeout: 3) }, done: { [weak self] r, _ in
            guard let self, !stale() else { return }
            let total = Int64(r.rows.first?.first?.string ?? "") ?? 0
            if offset > 0 || total > Int64(shown) { pageLabel.stringValue = String(format: L("%@ of %@"), range, fullCount(total)) }
            nextButton.isEnabled = Int64(offset + shown) < total
            if term != nil { searchStatus.stringValue = LN("%lu rows", Int(total)) }
        }, failed: { [weak self] _, _ in
            guard let self, !stale(), term == nil, let estimate, let n = Int64(estimate) else { return }
            pageLabel.stringValue = String(format: L("%@ of ~%@"), range, compactCount(n))
        })
    }

    private func loadStructure() {
        guard let schema, let table else { return }
        structureTitle.stringValue = displayName
        let isCurrent = { [weak self] in self?.schema == schema && self?.table == table }
        // Columns arrive before the data (same serial queue), so applyEditability already knows the primary key.
        run({ conn in try conn.columns(schema: schema, table: table) }, done: { [weak self] r, _ in
            guard let self else { return }
            var pk: [String] = [], names: [String] = [], defaults = Set<String>()
            var kinds: [String: ValueKind] = [:], types: [String: String] = [:]
            for c in r.rows { // [column, type, null, default, pk]
                let name = c[0].string ?? "", type = c[1].string ?? ""
                names.append(name)
                kinds[name] = ValueKind(type: type)
                types[name] = type
                if c[4].string == "PK" { pk.append(name) }
                if !c[3].isNull { defaults.insert(name) }
            }
            (pkColumns, defaultColumns, columnNames, columnKinds, columnTypes) = (pk, defaults, names, kinds, types)
            structureColumns = r
            showStructureColumns()
            structureMeta.stringValue = LN("%lu columns", r.rows.count)
        })
        run({ conn in try conn.foreignKeys(schema: schema, table: table) }, done: { [weak self] r, _ in
            guard let self else { return }
            var keys: [String: (schema: String, table: String, column: String)] = [:]
            for fk in r.rows { keys[fk[0].string ?? ""] = (fk[1].string ?? "", fk[2].string ?? "", fk[3].string ?? "") }
            foreignKeys = keys
            showStructureColumns() // "→ table.column"
            applyEditability()
            loadSearchReferences(keys, schema: schema, table: table)
        }, failed: { _, _ in }) // without foreign keys the grid just has no ↗
        run({ conn in conn.pocketBaseFiles(table: table) }, done: { [weak self] files, _ in
            guard let self, isCurrent() else { return }
            pocketBaseFiles = files
            applyEditability()
        })
        run({ conn in try conn.indexes(schema: schema, table: table) }, done: { [weak self] r, _ in
            guard let self else { return }
            indexesCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i, ix) in r.rows.enumerated() { // [name, definition]
                let cells: [(NSView, CGFloat)] = [(label(ix[0].string ?? "", 12, .regular, Theme.t1, mono: true), 1.3),
                                                  (label(ix[1].string ?? "", 12, .regular, Theme.t2, mono: true), 2.6)]
                add(to: indexesCard, structureRow(cells, height: 34, line: i < r.rows.count - 1))
            }
            if r.rows.isEmpty { add(to: indexesCard, structureRow([(label(L("none"), 12, .regular, Theme.t3), 1)], height: 34, line: false)) }
            structureMeta.stringValue += " · " + LN("%lu indexes", r.rows.count)
            structureStatus = structureMeta.stringValue
            updateStatus()
        })
    }

    // ⌘F also searches the tables the foreign keys point to, so it needs their columns.
    private func loadSearchReferences(_ keys: [String: (schema: String, table: String, column: String)], schema: String, table: String) {
        for (column, fk) in keys {
            run({ conn in try conn.columns(schema: fk.schema, table: fk.table) }, done: { [weak self] r, _ in
                guard let self, self.schema == schema, self.table == table, !r.rows.isEmpty else { return }
                searchReferences[column] = SearchReference(schema: fk.schema, table: fk.table, column: fk.column, columns: r.rows.compactMap { $0[0].string })
                updateSearchHint()
            }, failed: { _, _ in }) // that table just isn't searched
        }
    }

    private var currentSearchCondition: String { searchCondition(conn, columns: columnNames, references: searchReferences) }

    // Rows found through a foreign key don't contain the term themselves: mark the key cells whose referenced
    // row matched. One small query per key column, only for the values on this page.
    private func highlightReferences(term: String, result: DBResult) {
        dataGrid.highlightedValues = nil
        for (column, ref) in searchReferences {
            guard let index = result.columns.firstIndex(of: column) else { continue }
            var values: [DBValue] = []
            for row in result.rows where !row[index].isNull && !values.contains(row[index]) { values.append(row[index]) }
            if values.isEmpty { continue }
            let placeholders = (0..<values.count).map { "$\($0 + 2)" }.joined(separator: ", ")
            let sql = "SELECT \(quoteIdent(ref.column)) FROM \(quoteIdent(ref.schema)).\(quoteIdent(ref.table)) WHERE \(quoteIdent(ref.column)) IN (\(placeholders))"
                + " AND \(conn.searchCondition(columns: ref.columns))"
            let params = [DBValue.text(likePattern(term))] + values
            let shownRows = result.rows.count, shownColumns = result.columns
            run({ conn in try conn.execute(sql, params) }, done: { [weak self] r, _ in
                guard let self, let now = dataGrid.result, now.columns == shownColumns, now.rows.count == shownRows, searchTerm == term else { return } // another page or search
                var marked = dataGrid.highlightedValues ?? [:]
                marked[index] = Set(r.rows.compactMap { $0[0].string })
                dataGrid.highlightedValues = marked
            }, failed: { _, _ in })
        }
    }

    // nil column: back to the table's own order (the header's third click).
    private func sort(by column: String?, ascending: Bool) {
        guard confirmDiscard() else { return }
        sortColumn = column
        sortAscending = ascending
        offset = 0
        loadData(showingSpinner: false)
    }

    @objc private func previousPage(_ sender: Any?) {
        guard confirmDiscard() else { return }
        offset = max(0, offset - pageSize)
        loadData(showingSpinner: false)
    }

    @objc private func nextPage(_ sender: Any?) {
        guard confirmDiscard() else { return }
        offset += pageSize
        loadData(showingSpinner: false)
    }

    @objc private func refresh(_ sender: Any?) {
        spin(refreshButton)
        if currentTab == .diagram { return loadDiagram() }
        if table == nil { return loadTables() }
        if confirmDiscard() { loadData(showingSpinner: false) }
    }

    private func spin(_ button: NSView) {
        guard let l = button.layer, !Motion.reduced else { return }
        // AppKit keeps the layer's anchor at its corner: rotate about the centre by translating around it
        let (cx, cy) = (l.bounds.midX, l.bounds.midY)
        let turn = CAKeyframeAnimation(keyPath: "transform")
        turn.values = stride(from: 0.0, through: 1.0, by: 0.125).map { f in
            NSValue(caTransform3D: CATransform3DTranslate(CATransform3DRotate(CATransform3DMakeTranslation(cx, cy, 0), -2 * .pi * f, 0, 0, 1), -cx, -cy, 0))
        }
        turn.duration = 0.7
        turn.timingFunction = Motion.ease
        l.add(turn, forKey: "spin")
    }

    // MARK: - Editing

    // Only tables with a primary key are editable: only then does UPDATE/DELETE hit exactly one row.
    private func applyEditability() {
        let editable = !isView && !pkColumns.isEmpty
        dataGrid.editable = editable
        addButton.isEnabled = editable
        deleteButton.isEnabled = editable
        rowButtons.alphaValue = editable ? 1 : 0.4
        readOnlyBadge.isHidden = editable || !isView
        readOnlyStrip.isHidden = editable
        readOnlyText.stringValue = isView ? L("View: data is read-only.")
            : String(format: L("Read-only: table %@ has no primary key, so a row can't be identified unambiguously."), displayName)
        var defaults = IndexSet(), references = IndexSet(), files = IndexSet()
        var kinds: [Int: ValueKind] = [:]
        for (i, name) in (dataGrid.result?.columns ?? []).enumerated() {
            if defaultColumns.contains(name) { defaults.insert(i) }
            if foreignKeys[name] != nil { references.insert(i) }
            if pocketBaseFiles?.columns[name] != nil { files.insert(i) }
            kinds[i] = columnKinds[name]
        }
        dataGrid.defaultColumns = defaults
        dataGrid.referenceColumns = references
        dataGrid.fileColumns = files
        dataGrid.columnKinds = kinds
    }

    private func updateChanges() {
        let n = dataGrid.changeCount
        let show = n > 0 && currentTab == .data
        if show && pendingBar.isHidden {
            pendingBar.isHidden = false
            pendingBar.wantsLayer = true
            Motion.enter(pendingBar.layer, dy: -46, duration: 0.4) // slides up
        } else if !show {
            pendingBar.isHidden = true
        }
        pendingLabel.stringValue = LN("%lu changes", n)
        var parts: [String] = []
        if dataGrid.editedCellCount > 0 { parts.append(LN("%lu edits", dataGrid.editedCellCount)) }
        if !dataGrid.insertedRows.isEmpty { parts.append(LN("%lu new rows", dataGrid.insertedRows.count)) }
        if !dataGrid.deletedRows.isEmpty { parts.append(LN("%lu deleted", dataGrid.deletedRows.count)) }
        pendingDetail.stringValue = parts.joined(separator: " · ")
    }

    @objc private func addRow(_ sender: Any?) { dataGrid.addRow() }
    @objc private func deleteRows(_ sender: Any?) { dataGrid.deleteSelectedRows() }
    @objc private func discardChanges(_ sender: Any?) { dataGrid.discardChanges() }

    // Asks whether to discard unsaved changes. true = OK to continue (also when there is nothing to lose).
    func confirmDiscard() -> Bool {
        let n = dataGrid.changeCount
        guard n > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = L("You have unsaved changes")
        alert.informativeText = String(format: L("%@. Discard them?"), LN("%lu changes", n))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Discard Changes")).hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        dataGrid.discardChanges()
        return true
    }

    @objc func saveChanges(_ sender: Any?) {
        guard dataGrid.changeCount > 0 else { return }
        window?.makeFirstResponder(dataGrid.table) // ends cell editing, if any
        DispatchQueue.main.async { [weak self] in // the edit is stored asynchronously
            guard let self, let schema, let table, let result = dataGrid.result else { return }
            let statements = changeStatements(schema: schema, table: table, result: result, primaryKey: pkColumns, edits: editsForSaving(),
                                              deleted: dataGrid.deletedRows, inserted: dataGrid.insertedRows)
            guard !statements.isEmpty else { return }
            if !production { return execute(statements) }
            let preview = (["BEGIN;"] + statements.map { inlineParams($0.sql, $0.params) + ";" } + ["COMMIT;"]).joined(separator: "\n")
            confirmProduction(sql: preview) { [weak self] done in self?.execute(statements, done: done) }
        }
    }

    // Edited cells as the connection wants them written: SQLite keeps the storage class of the value an edit replaces.
    private func editsForSaving() -> [Int: [Int: DBValue]] {
        let rows = dataGrid.result?.rows ?? []
        var out: [Int: [Int: DBValue]] = [:]
        for (row, cells) in dataGrid.edits {
            out[row] = cells // NULL stays NULL
            for (col, value) in cells {
                guard case .text(let text) = value else { continue }
                out[row]![col] = conn.value(forText: text, replacing: row < rows.count ? rows[row][col] : .null)
            }
        }
        return out
    }

    // Everything in one transaction. Each UPDATE/DELETE must hit exactly 1 row, otherwise ROLLBACK.
    private func execute(_ statements: [ChangeStatement], done: ((Error?) -> Void)? = nil) {
        run({ conn in
            try conn.inWriteTransaction {
                var total = 0
                for s in statements {
                    let r = try conn.execute(s.sql, s.params)
                    if s.expectsOneRow && r.affected != 1 {
                        throw DBError(L("A row changed or disappeared in the meantime, nothing was saved. Refresh the data and try again.")
                                      + "\n\n" + inlineParams(s.sql, s.params))
                    }
                    total += max(r.affected, 0)
                }
                return DBResult(affected: total)
            }
        }, done: { [weak self] r, _ in
            guard let self else { return }
            done?(nil)
            dataGrid.discardChanges()
            loadData(showingSpinner: false)
            showToast("\(L("Saved")) · \(LN("%lu rows", r.affected))", in: root)
        }, failed: { [weak self] error, _ in
            done?(error)
            self?.showError(error)
        })
    }

    // `action` runs the SQL and calls back when it ended; the modal shows Running… until then.
    private func confirmProduction(sql: String, action: @escaping (@escaping (Error?) -> Void) -> Void) {
        guard confirm == nil else { return }
        let c = ProductionConfirm(connection: info.name, color: productionColor, sql: sql)
        let close = { [weak self, weak c] in
            guard let c else { return }
            Motion.animate(0.2, Motion.ease, { c.animator().alphaValue = 0 }, completion: { c.removeFromSuperview() })
            self?.confirm = nil
            self?.window?.makeFirstResponder(self?.dataGrid.table)
        }
        c.onCancel = close
        c.onRun = { [weak c] in
            c?.running = true
            action { _ in close() }
        }
        pin(c, root)
        confirm = c
        root.layoutSubtreeIfNeeded()
        c.present()
        window?.makeFirstResponder(c)
    }

    // MARK: - SQL

    // ⌘R: runs the query in the SQL tab, refreshes elsewhere.
    @objc func runQuery(_ sender: Any?) {
        guard currentTab == .sql else { return refresh(sender) }
        let selection = sqlText.selectedRange()
        let text = sqlText.string as NSString
        let sql = (selection.length > 0 ? text.substring(with: selection) : sqlText.string).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sql.isEmpty { runSQL(sql, confirmed: false) }
    }

    // On production the session is READ ONLY, so a write fails with 25006.
    // Then we ask, and after confirmation run the same SQL in a write transaction.
    private func runSQL(_ sql: String, confirmed: Bool, done: ((Error?) -> Void)? = nil) {
        sqlSpinner.startAnimation(nil)
        sqlState.selectedIndex = SQLState.running.rawValue
        sqlStatus = L("Running…")
        updateStatus()
        run({ conn in
            confirmed ? try conn.inWriteTransaction { try conn.execute(sql) } : try conn.execute(sql)
        }, done: { [weak self] r, ms in
            guard let self else { return }
            done?(nil)
            sqlSpinner.stopAnimation(nil)
            if !r.columns.isEmpty {
                sqlGrid.result = r
                resetInspector(for: sqlGrid)
                sqlState.selectedIndex = SQLState.result.rawValue
                sqlGrid.animateRowsIn(.slide)
                sqlStatus = "\(LN("%lu rows", r.rows.count)) · \(Int(ms.rounded())) ms"
            } else {
                sqlDoneLabel.stringValue = "\(L("Query executed")) · \(LN("%lu rows", max(r.affected, 0)))"
                sqlState.selectedIndex = SQLState.done.rawValue
                sqlStatus = "\(Int(ms.rounded())) ms"
                // a statement without rows may have changed the schema (CREATE, ALTER, DROP): read it again
                if sql.range(of: "\\b(create|alter|drop|rename)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                    loadDiagram()
                    loadTables()
                }
            }
            updateStatus()
        }, failed: { [weak self] error, ms in
            guard let self else { return }
            done?(error)
            sqlSpinner.stopAnimation(nil)
            if production && !confirmed && (error as? DBError)?.sqlstate == "25006" {
                sqlState.selectedIndex = SQLState.idle.rawValue
                sqlStatus = ""
                updateStatus()
                return confirmProduction(sql: sql) { [weak self] done in self?.runSQL(sql, confirmed: true, done: done) }
            }
            sqlErrorText.stringValue = error.localizedDescription
            sqlState.selectedIndex = SQLState.failed.rawValue
            sqlStatus = "\(L("Query error")) · \(Int(ms.rounded())) ms"
            updateStatus()
        })
    }

    // MARK: - Table list

    func numberOfRows(in tableView: NSTableView) -> Int { sideRows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = sideRows[row] { true } else { false }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !self.tableView(tableView, isGroupRow: row) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard case .section = sideRows[row] else { return 30 }
        return row == 0 ? 26 : 36
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PlainRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sideRows[row] {
        case .section(let title):
            let cell = makeCell(tableView, "section", padding: 18)
            cell.textField?.stringValue = title
            cell.textField?.font = Theme.font(11, .semibold)
            cell.textField?.textColor = Theme.t3
            cell.textField?.alignment = .left
            return cell
        case .table(let t):
            let cell = sidebarCell(tableView)
            let selected = t.schema == schema && t.name == table
            cell.count.stringValue = t.estimate.flatMap { Int64($0) }.map(compactCount) ?? ""
            cell.count.toolTip = t.estimate.flatMap { Int64($0) }.map { String(format: L("About %@ rows (estimate)"), fullCount($0)) }
            let name = NSMutableAttributedString()
            let font = Theme.font(13, selected ? .semibold : .regular)
            if !isDefaultSchema(t.schema) { name.append(NSAttributedString(string: t.schema + ".", attributes: [.foregroundColor: Theme.t3, .font: font])) }
            name.append(NSAttributedString(string: t.name, attributes: [.foregroundColor: selected ? Theme.sideSelT : Theme.t1, .font: font]))
            cell.textField?.attributedStringValue = name
            cell.icon.dashed = t.isView
            cell.icon.color = selected && !t.isView ? Theme.sideSelT : t.isView ? Theme.t3 : Theme.sideIcon
            return cell
        }
    }

    private func sidebarCell(_ tableView: NSTableView) -> SidebarCell {
        let id = NSUserInterfaceItemIdentifier("table")
        if let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell { return cell }
        let cell = SidebarCell()
        cell.identifier = id
        let (icon, count) = (cell.icon, cell.count)
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, name, count] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -18),
            count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.textField = name
        return cell
    }

    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        isCommandClick || confirmDiscard() // ⌘-click doesn't change this window's table
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebar.selectedRow
        guard row >= 0, case .table(let t) = sideRows[row] else { return }
        sidebar.movePill(animated: true)
        if t.schema == schema && t.name == table { return } // same table, e.g. re-selected after pinning
        (schema, table, isView, estimate) = (t.schema, t.name, t.isView, t.estimate)
        foreignKeys = [:]; searchReferences = [:] // until this table's are loaded
        pocketBaseFiles = nil
        columnKinds = [:]; columnTypes = [:]
        pkColumns = []; columnNames = [] // read-only until the structure is loaded
        searchTerm = nil // a search belongs to one table
        searchField.stringValue = ""
        searchBar.isHidden = true
        findButton.on = false
        offset = 0
        sortColumn = nil
        dataGrid.resetSort()
        tableLabel.stringValue = displayName
        window?.title = displayName
        window?.tab.toolTip = "\(displayName) — \(info.name)"
        sidebar.reloadData(forRowIndexes: IndexSet(integersIn: 0..<sideRows.count), columnIndexes: [0]) // the bold name
        // a table picked in the sidebar opens its data, also from the SQL editor or the diagram
        showTab(currentTab == .sql || currentTab == .diagram ? .data : currentTab)
        loadStructure()
        loadData(showingSpinner: true)
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }

    // The connection may be shared with other tabs: the owner closes it (and stops the tunnel) with the last window.
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: SSHTunnel.statusNotification, object: nil)
        closePopovers()
        onClose?(self)
    }

    // A tab bar pushes the content below it; without one the top row lives in the title bar.
    func windowDidResize(_ notification: Notification) { updateContentTop() }

    private func updateContentTop() {
        guard let window, let contentTop else { return }
        let tabBar = window.tabGroup?.isTabBarVisible ?? false
        contentTop.constant = tabBar ? root.bounds.height - window.contentLayoutRect.maxY + 6 : 12
        positionTrafficLights(tabBar ? nil : 12)
    }

    // The traffic lights in the sidebar's 52 pt first row: 18 pt from the panel's edge, vertically centred in it.
    private func positionTrafficLights(_ top: CGFloat?) {
        guard let window, let close = window.standardWindowButton(.closeButton), let bar = close.superview else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = window.standardWindowButton(type) else { continue }
            var origin = b.frame.origin
            if let top {
                origin.x = 12 + 18 + CGFloat(i) * 20
                let centre = top + 26 // the row's middle, from the window's top
                origin.y = bar.isFlipped ? centre - b.frame.height / 2 : bar.bounds.height - centre - b.frame.height / 2
            }
            b.setFrameOrigin(origin)
        }
    }

    // AppKit lays the title bar out again on these (and puts the buttons back): move them once it's done.
    func windowDidBecomeKey(_ notification: Notification) { DispatchQueue.main.async { self.updateContentTop() } }
    func windowDidResignKey(_ notification: Notification) { DispatchQueue.main.async { self.updateContentTop() } }
    func windowDidExitFullScreen(_ notification: Notification) { DispatchQueue.main.async { self.updateContentTop() } }

    override func windowDidLoad() {
        super.windowDidLoad()
        updateContentTop()
    }

    @objc private func tunnelStatusChanged(_ notification: Notification) {
        setTunnelConnected(tunnel?.connected ?? false)
    }
}

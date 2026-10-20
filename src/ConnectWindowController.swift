import AppKit
import QuartzCore

private let modeKey = "connectMode" // 0 = Local, 1 = Saved, 2 = Files
private let tileColumns = 5
private let gap: CGFloat = 12 // window edge to panel and panel to panel
private let sideWidth: CGFloat = 206
private let hintWidth: CGFloat = 330 // the form's field column

// MARK: - Model

// Production frame colours offered in the form: hex, name. Any other colour comes from the custom swatch.
func frameColorChoices() -> [(hex: String, name: String)] {
    [("#e0342b", L("Red")), ("#f08c00", L("Orange")), ("#e6b800", L("Yellow")), ("#2ea043", L("Green")),
     ("#14a5b8", L("Teal")), ("#0a84ff", L("Blue")), ("#8b5cf6", L("Purple")), ("#e0418f", L("Pink"))]
}

// Every connection can have a frame colour; production always has one, so an empty choice becomes the first (red).
func formFrameColor(_ frame: String, production: Bool) -> String {
    production && frame.isEmpty ? frameColorChoices()[0].hex : frame
}

// "No colour" or one of the offered colours; anything else is shown on the custom swatch.
func isPresetFrameColor(_ hex: String) -> Bool {
    hex.isEmpty || frameColorChoices().contains { $0.hex == hex }
}

// "#rrggbb" of a colour picked in the colour panel.
func hexString(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB) ?? color
    let byte = { (v: CGFloat) in min(max(lround(Double(v) * 255), 0), 255) }
    return String(format: "#%02lx%02lx%02lx", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
}

func newSavedConnection() -> Connection {
    Connection(id: UUID().uuidString, name: L("New connection"), host: "localhost", port: "5432")
}

// A database from the Local tab: the default local server (socket in /tmp, port 5432) as the OS user.
func localConnection(database: String, frame: String) -> Connection {
    Connection(id: "local", name: database, user: NSUserName(), database: database, frame: frame)
}

// The form's text fields (in the Objective-C version's order): label, placeholder, the Connection property.
enum FormField: String, CaseIterable {
    case name, host, port, user, password, database, sshHost, path, s3Bucket, s3Region, awsProfile

    var label: String {
        switch self {
        case .name: L("Name:")
        case .host: L("Database host:")
        case .port: L("Port:")
        case .user: L("User:")
        case .password: L("Password:")
        case .database: L("Database:")
        case .sshHost: L("SSH tunnel:")
        case .path: L("File on server:")
        case .s3Bucket: L("S3 files:")
        case .s3Region: L("Region:")
        case .awsProfile: L("Profile:")
        }
    }

    var placeholder: String {
        switch self {
        case .name: L("e.g. Production – API")
        case .host: "localhost"
        case .port: "5432"
        case .user: "postgres"
        case .password: ""
        case .database: "postgres"
        case .sshHost: L("user@server or alias")
        case .path: "/home/pocketbase/pb_data/data.db"
        case .s3Bucket: L("bucket")
        case .s3Region: "eu-central-1"
        case .awsProfile: L("default profile")
        }
    }

    // nil for the password, which lives in the Keychain
    var keyPath: WritableKeyPath<Connection, String>? {
        switch self {
        case .name: \.name
        case .host: \.host
        case .port: \.port
        case .user: \.user
        case .password: nil
        case .database: \.database
        case .sshHost: \.sshHost
        case .path: \.path
        case .s3Bucket: \.s3Bucket
        case .s3Region: \.s3Region
        case .awsProfile: \.awsProfile
        }
    }
}

// The saved connection as the form describes it: values trimmed, kind and the database that goes with it, a name,
// production and the frame colour (which supersedes the old "color"). The password isn't part of it (Keychain).
// clearedDatabase: the database field held the server path standing in for it, so the form should empty it too.
func applyForm(_ values: [FormField: String], sqliteOverSSH: Bool, production: Bool, frame: String,
               to original: Connection) -> (connection: Connection, clearedDatabase: Bool) {
    var c = original, cleared = false
    for field in FormField.allCases {
        guard let keyPath = field.keyPath else { continue }
        c[keyPath: keyPath] = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if sqliteOverSSH {
        c.kind = "sqlite-ssh"
        c.database = c.path // what identifies it, like a local file's path
    } else {
        if original.kind == "sqlite-ssh" && c.database == c.path { // the path was standing in for it
            c.database = ""
            cleared = true
        }
        c.kind = ""
    }
    if c.name.isEmpty { c.name = c.host.isEmpty ? L("Untitled") : c.host }
    c.production = production
    c.frame = frame
    c.color = nil
    return (c, cleared)
}

// Why the connection can't be opened as it is, or nil.
func connectProblem(_ c: Connection) -> String? {
    c.kind == "sqlite-ssh" && (c.sshHost.isEmpty || c.path.isEmpty) ? L("Enter the SSH host and the file's path on the server.") : nil
}

// Shown while the connection opens.
func connectingStatus(_ c: Connection) -> String {
    if c.kind == "sqlite-ssh" { return String(format: L("Connecting to %@…"), c.sshHost) }
    if !c.sshHost.isEmpty { return String(format: L("Opening tunnel via %@…"), c.sshHost) }
    return String(format: L("Connecting to %@…"), c.host.isEmpty ? "localhost" : c.host)
}

// The second line of a saved connection in the list: where it goes.
func connectionSubtitle(_ c: Connection) -> String {
    if c.kind == "sqlite-ssh" { return String(format: L("%@ via %@"), (c.path as NSString).lastPathComponent, c.sshHost) }
    if !c.sshHost.isEmpty { return String(format: L("via %@"), c.sshHost) }
    return "\(c.host.isEmpty ? "localhost" : c.host):\(c.port.isEmpty ? "5432" : c.port)"
}

// The second line of a recent file: its folder and size, or that it's gone.
func fileDetail(path: String, exists: Bool, size: Int64) -> String {
    let folder = ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    return exists ? "\(folder) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))" : "\(L("File not found")) · \(folder)"
}

// What the AWS profile field completes `typed` to while it's typed, like NSComboBox's completion: the first
// profile that starts with it and is longer.
func profileCompletion(_ typed: String, in profiles: [String]) -> String? {
    typed.isEmpty ? nil : profiles.first { $0.hasPrefix(typed) && $0.count > typed.count }
}

// MARK: - Drops

// Shown while files are dragged over the window.
private final class DropOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // only a picture: the drag still goes to the window

    override func draw(_ dirtyRect: NSRect) {
        let accent = Theme.acc
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        accent.withAlphaComponent(Theme.isDark(effectiveAppearance) ? 0.1 : 0.06).setFill()
        ring.fill()
        ring.lineWidth = 3
        accent.setStroke()
        ring.stroke()
        let text = NSAttributedString(string: L("Drop to open"), attributes: [.font: Theme.font(13, .semibold), .foregroundColor: Theme.accT])
        let size = text.size()
        let pill = NSRect(x: round(bounds.midX - size.width / 2 - 14), y: round(bounds.midY - size.height / 2 - 8),
                          width: size.width + 28, height: size.height + 16)
        accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 14, y: pill.minY + 8))
    }
}

// The window's content view: accepts files dragged anywhere onto the window.
private final class FileDropView: NSView {
    var onDrop: (([String]) -> Void)?
    private var overlay: DropOverlay?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setDropHighlighted(_ on: Bool) {
        if on && overlay == nil {
            let o = DropOverlay(frame: bounds)
            o.autoresizingMask = [.width, .height]
            o.wantsLayer = true
            addSubview(o, positioned: .above, relativeTo: nil)
            Motion.enter(o.layer, duration: 0.15)
            overlay = o
        } else if !on {
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }

    private func paths(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.path)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let files = !paths(info).isEmpty
        setDropHighlighted(files)
        return files ? .copy : []
    }

    override func draggingExited(_ info: NSDraggingInfo?) { setDropHighlighted(false) }
    override func draggingEnded(_ info: NSDraggingInfo) { setDropHighlighted(false) }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        setDropHighlighted(false)
        let p = paths(info)
        if !p.isEmpty { onDrop?(p) }
        return !p.isEmpty
    }
}

// MARK: - Form controls

// Text field of the form, telling its box when editing starts and ends (the box draws the focus border).
private final class FormTextField: NSTextField {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

private final class FormSecureField: NSSecureTextField {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

// The form's field: a borderless text field in a box whose border turns accent while editing. `completions` adds a
// menu of choices and completion while typing (the AWS profiles).
private final class FieldBox: LayerView, NSTextFieldDelegate {
    let field: NSTextField
    private var focused = false { didSet { needsDisplay = true } }
    private var completions: [String] = []
    private var typedLength = 0

    init(secure: Bool = false, placeholder: String, mono: Bool = false, completions: [String]? = nil) {
        let font = mono ? Theme.mono(12) : Theme.font(12.5)
        if secure {
            let f = FormSecureField()
            field = f
            super.init(frame: .zero)
            f.onFocus = { [weak self] in self?.focused = $0 }
        } else {
            let f = FormTextField()
            field = f
            super.init(frame: .zero)
            f.onFocus = { [weak self] in self?.focused = $0 }
        }
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = Theme.t1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.usesSingleLineMode = true
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font, .foregroundColor: Theme.t3])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var trailing = trailingAnchor, inset: CGFloat = -8
        if let completions {
            self.completions = completions
            field.delegate = self
            if !completions.isEmpty { // the choices, like a combo box's list
                let more = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!, target: self, action: #selector(showChoices))
                more.isBordered = false
                more.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
                more.contentTintColor = Theme.t2
                more.translatesAutoresizingMaskIntoConstraints = false
                addSubview(more)
                NSLayoutConstraint.activate([
                    more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                    more.centerYAnchor.constraint(equalTo: centerYAnchor),
                    more.widthAnchor.constraint(equalToConstant: 18),
                ])
                (trailing, inset) = (more.leadingAnchor, -2)
            }
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailing, constant: inset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var isEnabled: Bool {
        get { field.isEnabled }
        set {
            field.isEnabled = newValue
            alphaValue = newValue ? 1 : 0.55
        }
    }

    override func updateColors() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (focused ? Theme.acc : Theme.fieldB).cgColor
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { // the padding around the text focuses it too
        if field.isEnabled { window?.makeFirstResponder(field) }
    }

    @objc private func showChoices(_ sender: NSButton) {
        let menu = NSMenu()
        for c in completions {
            let item = menu.addItem(withTitle: c, action: #selector(choose), keyEquivalent: "")
            item.target = self
            item.state = c == field.stringValue ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    @objc private func choose(_ item: NSMenuItem) {
        field.stringValue = item.title
    }

    // Completes a profile name while typing forward; deleting never completes.
    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let typed = editor.string, length = (typed as NSString).length
        defer { typedLength = length }
        let selection = editor.selectedRange()
        guard length > typedLength, selection.length == 0, selection.location == length,
              let completion = profileCompletion(typed, in: completions) else { return }
        editor.string = completion
        editor.setSelectedRange(NSRange(location: length, length: (completion as NSString).length - length))
    }
}

// The form's checkbox, drawn in the app's style.
private final class Checkbox: NSButton {
    convenience init(_ title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        setButtonType(.switch) // state toggles on click, and it is a checkbox for VoiceOver
        self.title = title
        (self.target, self.action) = (target, action)
        isBordered = false
        font = Theme.font(12.5)
    }

    private var text: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Theme.font(12.5), .foregroundColor: Theme.t1])
    }

    override var intrinsicContentSize: NSSize {
        let s = text.size()
        return NSSize(width: ceil(s.width) + 22, height: max(18, ceil(s.height)))
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0.5, y: round((bounds.height - 14) / 2), width: 14, height: 14)
        let on = state == .on
        let path = NSBezierPath(roundedRect: on ? box : box.insetBy(dx: 0.6, dy: 0.6), xRadius: 5, yRadius: 5)
        if on {
            Theme.acc.setFill()
            path.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 3.6, y: box.midY - 0.2)) // NSButton is flipped: y runs down
            tick.line(to: NSPoint(x: box.minX + 6, y: box.midY + 2.4))
            tick.line(to: NSPoint(x: box.maxX - 3.4, y: box.midY - 2.8))
            (tick.lineWidth, tick.lineCapStyle, tick.lineJoinStyle) = (1.8, .round, .round)
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            Theme.ctl.setFill()
            path.fill()
            path.lineWidth = 1.2
            Theme.cbOff.setStroke()
            path.stroke()
        }
        let t = text, size = t.size()
        t.draw(at: NSPoint(x: 22, y: round((bounds.height - size.height) / 2)))
    }
}

// Round colour swatch; the selected one gets a ring around it. The custom swatch is a colour wheel; its ring shows
// the chosen colour.
private final class SwatchButton: NSButton {
    var hex = ""
    var custom = false, none = false // none: "no colour", a crossed-out circle
    var selectedSwatch = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ rect: NSRect) {
        let color = Theme.color(hex: hex, fallback: .systemRed)
        let dot = bounds.insetBy(dx: (bounds.width - 16) / 2, dy: (bounds.height - 16) / 2)
        if selectedSwatch {
            (none ? Theme.t1 : color).setStroke()
            let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2.75, dy: -2.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let circle = NSBezierPath(ovalIn: dot)
        if none {
            (selectedSwatch ? Theme.t1 : Theme.t3).setStroke()
            let outline = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
            outline.lineWidth = 1.5
            outline.stroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: dot.minX + 4, y: dot.minY + 4))
            slash.line(to: NSPoint(x: dot.maxX - 4, y: dot.maxY - 4))
            slash.lineWidth = 1.5
            slash.stroke()
            return
        }
        if custom {
            let hues = ["#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be", "#0a84ff", "#af52de", "#ff2d55", "#ff3b30"]
            let colors = hues.map { Theme.color(hex: $0, fallback: .red).cgColor } as CFArray
            if let ctx = NSGraphicsContext.current?.cgContext,
               let wheel = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                ctx.saveGState()
                circle.addClip()
                CGContextDrawConicGradient(ctx, wheel, CGPoint(x: dot.midX, y: dot.midY), .pi / 2)
                ctx.restoreGState()
            }
        } else {
            color.setFill()
            circle.fill()
        }
        if !selectedSwatch {
            NSColor(white: 0, alpha: 0.2).setStroke()
            let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()
        }
    }
}

// Wraps a control that has no enabled state of its own (SlidingSegments): disabled, it's dimmed and takes no clicks.
private final class EnablingView: NSView {
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    init(_ content: NSView) {
        super.init(frame: .zero)
        pin(content, self)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { isEnabled ? super.hitTest(point) : nil }
}

// MARK: - Lists and tiles

// Table whose rows show a hover fill under the mouse (RowView.hovered).
private final class HoverTable: NSTableView {
    private var hoveredRow = -1
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return } // .inVisibleRect follows scrolling and resizing by itself
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    private func setHovered(_ row: Int) {
        guard row != hoveredRow else { return }
        if hoveredRow >= 0, hoveredRow < numberOfRows { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? RowView)?.hovered = false }
        hoveredRow = row
        if row >= 0 { (rowView(atRow: row, makeIfNecessary: false) as? RowView)?.hovered = true }
    }

    override func mouseMoved(with event: NSEvent) { setHovered(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(-1) }

    override func reloadData() {
        hoveredRow = -1
        super.reloadData()
    }
}

// A saved connection in the sidebar: icon in the window's frame colour, name (with the PRODUCTION badge in that
// colour) over where it connects.
private final class ConnectionCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = label("", 13, .medium)
    private let sub = label("", 11, .regular, Theme.t2)
    private let prod = badge(L("PRODUCTION"), .white, Theme.prod, size: 8.5, kern: 0.4)

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        let top = NSStackView(views: [name, prod])
        top.spacing = 6
        top.alignment = .centerY
        prod.setContentHuggingPriority(.required, for: .horizontal)
        prod.radius = 8 // a capsule at its 16 pt height; badge()'s 999 fills the whole row
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        for v in [icon, top, sub] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            top.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            top.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            top.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            sub.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            sub.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        imageView = icon
        textField = name
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ c: Connection) {
        let frame = c.frameColor
        let tint = frame.isEmpty ? Theme.t2 : Theme.color(hex: frame, fallback: Theme.red) // the window's colour
        icon.image = NSImage(systemSymbolName: c.sshHost.isEmpty ? "cylinder" : "lock.shield", accessibilityDescription: nil)
        icon.contentTintColor = tint
        name.stringValue = c.name.isEmpty ? L("Untitled") : c.name
        prod.isHidden = !c.production
        prod.fillColor = frame.isEmpty ? Theme.prod : tint
        sub.stringValue = connectionSubtitle(c)
    }
}

// A database on the local server: its icon in the frame colour over its name; hover fill, right-click for the colour.
private final class DatabaseTile: NSButton {
    var database = ""
    private var hovering = false { didSet { needsDisplay = true } }

    convenience init(_ database: String, frame: String, target: AnyObject?, action: Selector?) {
        let icon = NSImage(systemSymbolName: "cylinder.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))!
        self.init(title: database, image: icon, target: target, action: action)
        self.database = database
        imagePosition = .imageAbove
        isBordered = false
        wantsLayer = true
        contentTintColor = frame.isEmpty ? Theme.acc : Theme.color(hex: frame, fallback: Theme.acc)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.alignment = .center
        attributedTitle = NSAttributedString(string: database, attributes: [.foregroundColor: Theme.t1, .font: Theme.font(12, .medium), .paragraphStyle: style])
        lineBreakMode = .byTruncatingMiddle
        toolTip = database
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 112), heightAnchor.constraint(equalToConstant: 72)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = 10
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = (hovering ? Theme.hover : .clear).cgColor
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        pressScale(0.97)
        super.mouseDown(with: event)
        pressScale(1)
    }
}

// MARK: - Window

// Start window: local databases, saved connections and recent SQLite files. Sets up the tunnel and opens the connection.
final class ConnectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    // A connection opened from the Local or Saved tab, with its tunnel (if any) and what it was opened with.
    var onConnected: ((DBConnection, SSHTunnel?, Connection) -> Void)?
    // Files tab and files dropped on the window; the app delegate opens them.
    var onOpenFile: ((String) -> Void)?
    var onOpenPanel: (() -> Void)?

    private var connections: [Connection]
    private var selected = -1
    private var loadedPassword = "", frameColor = ""
    private var connecting = false, colorPanelAttached = false

    // The transparent title bar (traffic lights and the Local / Saved / Files switch); panels start below it.
    private var titleBar: CGFloat = 28, titleBand: CGFloat = 36
    private var tabs: Switcher!
    private let modeSwitch = SlidingSegments([L("Local"), L("Saved"), L("Files")], segmentWidth: 76, height: 26, radius: 999)
    private var modeCenter: NSLayoutConstraint!
    // saved connections
    private let list = HoverTable()
    private var fields: [FormField: FieldBox] = [:]
    private var production: Checkbox!
    private var connectButton: PillButton!
    private let kindSwitch = SlidingSegments([L("PostgreSQL"), L("SQLite over SSH")], segmentWidth: 122, height: 28, radius: 999, fontSize: 12)
    private var kindBox: EnablingView!
    private var grid: NSGridView!
    private var sshLabel: NSTextField!
    private let sshHint = wrappingLabel("", 11, Theme.t2)
    private var postgresViews: [NSView] = [], sqliteViews: [NSView] = [] // the rows each kind shows (by one of their views)
    private var swatches: [SwatchButton] = []
    private let statusSpinner = spinner()
    private let errorIcon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)!)
    private let statusLabel = wrappingLabel("", 11.5, Theme.t2)
    // recent SQLite files
    private let files = HoverTable()
    private var recent: [Connection] = []
    // local databases
    private let tilesView = FlippedView()
    private var localNames: [String] = []
    private let localSpinner = spinner()
    private let localStatus = label("", 11, .regular, Theme.t2)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        connections = ConnectionStore.load()
        if connections.isEmpty { connections.append(newSavedConnection()) }
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = L("Connections")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        titleBar = max(window.frame.height - window.contentLayoutRect.height, 28) // taller on newer macOS
        titleBand = titleBar + 8
        buildUI()
        window.center()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        tabs = Switcher([buildLocalView(), buildSavedView(), buildFilesView()])
        let mode = min(max(UserDefaults.standard.integer(forKey: modeKey), 0), 2)
        tabs.selectedIndex = mode
        modeSwitch.select(mode, animated: false)
        modeSwitch.onChange = { [weak self] in self?.switchMode($0) }

        let root = FileDropView() // a database file dropped anywhere on the window opens it
        root.onDrop = { [weak self] paths in
            for path in paths { self?.onOpenFile?(path) }
        }
        pin(WindowBackground(), root)
        pin(tabs, root)
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(modeSwitch)
        modeCenter = modeSwitch.centerXAnchor.constraint(equalTo: root.centerXAnchor)
        NSLayoutConstraint.activate([modeCenter, modeSwitch.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titleBar / 2)])
        centerModeSwitch(animated: false)
        window?.contentView = root
    }

    // Over the whole window for Local and Files, over the form (right of the sidebar) for Saved.
    private func centerModeSwitch(animated: Bool) {
        let x = tabs.selectedIndex == 1 ? (sideWidth + gap) / 2 : 0
        guard animated else { return modeCenter.constant = x }
        Motion.animate(0.45, Motion.springCurve) {
            modeCenter.animator().constant = x
            modeSwitch.superview?.layoutSubtreeIfNeeded()
        }
    }

    private func contentPanel(fill: NSColor = Theme.panel) -> Panel {
        Panel(fill: fill, border: Theme.pb, radius: 16, shadow: true)
    }

    private func scrollView(_ document: NSView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = document
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        return s
    }

    // Label of a form row, right-aligned and centred on the row's field.
    private func rowLabel(_ text: String) -> (NSView, NSTextField) {
        let l = label(text, 12.5, .regular, Theme.t2)
        l.alignment = .right
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        let box = NSView()
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 28),
            l.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            l.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor),
            l.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return (box, l)
    }

    private func hint(_ text: String) -> NSTextField {
        let h = wrappingLabel(text, 11, Theme.t2)
        h.isSelectable = false
        h.preferredMaxLayoutWidth = hintWidth
        return h
    }

    private func buildSavedView() -> NSView {
        list.headerView = nil
        list.rowHeight = 40
        list.intercellSpacing = NSSize(width: 0, height: 2)
        list.backgroundColor = .clear
        list.style = .plain
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = sideWidth // full sidebar width; the default 100 cut names short
        nameColumn.resizingMask = .autoresizingMask
        list.addTableColumn(nameColumn)
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(connectSelected)
        let listScroll = scrollView(list)
        let add = ToolButton(symbol: "plus", tip: L("New connection"), target: self, action: #selector(addConnection))
        let remove = ToolButton(symbol: "minus", tip: L("Remove"), target: self, action: #selector(removeConnection))
        let listButtons = bar([toolGroup([add, remove])], [], height: 42, left: 12, right: 12)
        let side = contentPanel(fill: Theme.side)
        pin(column([listScroll, separator(), listButtons], grow: listScroll, insets: NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)), side)

        var labels: [FormField: (NSView, NSTextField)] = [:]
        for f in FormField.allCases {
            fields[f] = FieldBox(secure: f == .password, placeholder: f.placeholder, mono: f == .path, // a path, like code
                                 completions: f == .awsProfile ? awsProfiles() : nil) // profiles set up for the aws CLI; another can be typed
            labels[f] = rowLabel(f.label)
        }
        let field = { (f: FormField) in self.fields[f]! }
        field(.port).widthAnchor.constraint(equalToConstant: 64).isActive = true
        let portLabel = label(FormField.port.label, 12.5, .regular, Theme.t2)
        portLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let hostRow = NSStackView(views: [field(.host), portLabel, field(.port)])
        hostRow.spacing = 10
        sshHint.isSelectable = false
        sshHint.preferredMaxLayoutWidth = hintWidth
        sshLabel = labels[.sshHost]!.1
        let sshColumn = column([field(.sshHost), sshHint], spacing: 5)
        let pathHint = hint(L("Needs python3 on the server. PocketBase in Docker: the volume's path on the host, e.g. /var/lib/docker/volumes/pb_data/_data/data.db."))
        let pathColumn = column([field(.path), pathHint], spacing: 5)
        // where the files that rows point to live: previews through the user's aws CLI and profile
        field(.s3Region).widthAnchor.constraint(equalToConstant: 98).isActive = true
        field(.awsProfile).widthAnchor.constraint(equalToConstant: 132).isActive = true
        let s3Fields = NSStackView(views: [field(.s3Bucket), field(.s3Region), field(.awsProfile)])
        s3Fields.spacing = 8
        field(.s3Region).toolTip = L("Region:")
        field(.awsProfile).toolTip = L("AWS profile from ~/.aws/config; empty: the default one.")
        let s3Hint = hint(L("For previews of files in S3: the bucket, its region and the AWS profile (from ~/.aws/config) that can read it; empty profile: the default one."))
        let s3Row = column([s3Fields, s3Hint], spacing: 5)
        kindSwitch.onChange = { [weak self] _ in self?.kindChanged() }
        kindBox = EnablingView(kindSwitch)
        production = Checkbox(L("Production: read-only, writes need confirmation"), target: self, action: #selector(productionToggled))

        let colors = [("", L("No color"))] + frameColorChoices().map { ($0.hex, $0.name) } + [("", L("Custom color"))]
        for (i, c) in colors.enumerated() {
            let swatch = SwatchButton(frame: .zero)
            swatch.title = ""
            swatch.hex = c.0
            swatch.none = i == 0
            swatch.custom = i == colors.count - 1
            swatch.toolTip = c.1
            swatch.setAccessibilityLabel(c.1)
            swatch.isBordered = false
            swatch.target = self
            swatch.action = swatch.custom ? #selector(customColorClicked) : #selector(swatchClicked)
            NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 23), swatch.heightAnchor.constraint(equalToConstant: 23)])
            swatches.append(swatch)
        }
        let divider = Panel(fill: Theme.line, radius: 0)
        NSLayoutConstraint.activate([divider.widthAnchor.constraint(equalToConstant: 1), divider.heightAnchor.constraint(equalToConstant: 14)])
        let swatchRow = NSStackView(views: swatches.dropLast() + [divider, swatches.last!])
        swatchRow.spacing = 0
        swatchRow.setCustomSpacing(5.5, after: swatches[swatches.count - 2]) // 7 pt gap + 2 pt margin around the divider
        swatchRow.setCustomSpacing(5.5, after: divider)

        let (typeLabel, _) = rowLabel(L("Type:")), (frameLabel, _) = rowLabel(L("Window frame:"))
        let grid = NSGridView(views: [
            [typeLabel, kindBox],
            [labels[.name]!.0, field(.name)],
            [labels[.host]!.0, hostRow],
            [labels[.user]!.0, field(.user)],
            [labels[.password]!.0, field(.password)],
            [labels[.database]!.0, field(.database)],
            [labels[.sshHost]!.0, sshColumn],
            [labels[.path]!.0, pathColumn],
            [labels[.s3Bucket]!.0, s3Row],
            [NSGridCell.emptyContentView, production],
            [frameLabel, swatchRow],
        ])
        self.grid = grid
        postgresViews = [hostRow, field(.user), field(.password), field(.database)]
        sqliteViews = [pathColumn]
        grid.rowAlignment = .none
        grid.column(at: 0).xPlacement = .fill // the label boxes align their labels to the right
        grid.column(at: 1).xPlacement = .fill // fields take the remaining width
        grid.yPlacement = .top
        grid.rowSpacing = 9
        grid.columnSpacing = 12
        for v in [kindBox!, production!, swatchRow] as [NSView] { grid.cell(for: v)?.xPlacement = .leading }
        grid.cell(for: production)?.yPlacement = .center
        grid.cell(for: production)?.row?.topPadding = 2
        grid.cell(for: swatchRow)?.yPlacement = .center

        errorIcon.contentTintColor = Theme.red
        errorIcon.isHidden = true
        statusLabel.isSelectable = true
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectButton = PillButton(L("Connect"), style: .accent, height: 28, target: self, action: #selector(connectSelected))
        connectButton.keyEquivalent = "\r"
        let save = PillButton(L("Save"), height: 28, target: self, action: #selector(save))
        let bottom = bar([statusSpinner, errorIcon, statusLabel], [save, connectButton], height: 54, left: 20, right: 14)

        let formArea = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        formArea.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: formArea.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: formArea.leadingAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: formArea.trailingAnchor, constant: -22),
        ])
        let form = contentPanel()
        pin(column([formArea, separator(), bottom], grow: formArea), form)

        // explicit constraints: sidebar on the left at full height, form fills the rest
        let saved = NSView()
        for v in [side, form] {
            v.translatesAutoresizingMaskIntoConstraints = false
            saved.addSubview(v)
        }
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: saved.topAnchor, constant: titleBand),
            side.bottomAnchor.constraint(equalTo: saved.bottomAnchor, constant: -gap),
            side.leadingAnchor.constraint(equalTo: saved.leadingAnchor, constant: gap),
            side.widthAnchor.constraint(equalToConstant: sideWidth),
            form.topAnchor.constraint(equalTo: side.topAnchor),
            form.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: gap),
            form.trailingAnchor.constraint(equalTo: saved.trailingAnchor, constant: -gap),
        ])
        return saved
    }

    // A tab's content: one panel below the title band, with a header bar on top.
    private func tabPanel(header: NSView, body: NSView, footer: NSView? = nil) -> NSView {
        let panel = contentPanel()
        pin(column([header, body] + (footer.map { [separator(), $0] } ?? []), grow: body), panel)
        let view = NSView()
        pin(panel, view, NSEdgeInsets(top: titleBand, left: gap, bottom: gap, right: gap))
        return view
    }

    private func buildLocalView() -> NSView {
        let title = label(L("Local Postgres server"), 13, .semibold)
        let refresh = ToolButton(symbol: "arrow.clockwise", tip: L("Refresh the database list"), target: self, action: #selector(reloadLocal))
        let header = bar([title, localSpinner], [localStatus, refresh], height: 52, left: 18, right: 12)

        tilesView.translatesAutoresizingMaskIntoConstraints = false
        let scroll = scrollView(tilesView)
        NSLayoutConstraint.activate([
            tilesView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            tilesView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            tilesView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let emptyHeight = tilesView.heightAnchor.constraint(equalToConstant: 0)
        emptyHeight.priority = .defaultLow // with no tiles; the tile grid's own height wins otherwise
        emptyHeight.isActive = true
        return tabPanel(header: header, body: scroll)
    }

    // MARK: Files

    // Recently opened SQLite files: click opens, right-click for colour, read-only and removal. Files can also be dropped here.
    private func buildFilesView() -> NSView {
        let title = label(L("Recent files"), 13, .semibold)
        let open = PillButton(L("Open…"), shortcut: "⌘O", target: self, action: #selector(openPanel))
        let header = bar([title], [open], height: 52, left: 18, right: 12)

        files.headerView = nil
        files.style = .plain
        files.rowHeight = 44
        files.intercellSpacing = NSSize(width: 0, height: 2)
        files.backgroundColor = .clear
        files.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        files.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        files.dataSource = self
        files.delegate = self
        files.target = self
        files.action = #selector(openFileRow)
        files.menu = NSMenu()
        files.menu?.delegate = self
        let footer = label(L("Open a database with ⌘O or drop a file on this window."), 11.5, .regular, Theme.t3)
        footer.alignment = .center
        let footerBar = NSView()
        footerBar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        pin(footer, footerBar, NSEdgeInsets(top: 9, left: 18, bottom: 9, right: 18))
        return tabPanel(header: header, body: scrollView(files), footer: footerBar)
    }

    private func reloadFiles() {
        recent = ConnectionStore.recentFiles()
        files.reloadData()
    }

    private func fileCell(_ file: Connection) -> NSView {
        let exists = FileManager.default.fileExists(atPath: file.path)
        let icon = NSImageView(image: NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        let frame = file.frameColor
        icon.contentTintColor = frame.isEmpty ? Theme.t2 : Theme.color(hex: frame, fallback: Theme.t2) // the window's frame colour
        let name = label(file.name, 13, .medium, exists ? Theme.t1 : Theme.t3)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sub = label(fileDetail(path: file.path, exists: exists, size: size), 11, .regular, exists ? Theme.t2 : Theme.red)
        sub.lineBreakMode = .byTruncatingMiddle // keep the file's own folder visible
        let row = NSView()
        let readOnly: Panel? = file.production ? badge(L("read-only"), Theme.t2, Theme.fill, weight: .medium, kern: 0) : nil
        readOnly?.radius = 9 // a capsule at its height; badge()'s 999 fills the whole row
        for v in [icon, name, sub] + (readOnly.map { [$0 as NSView] } ?? []) {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        let end = readOnly?.leadingAnchor ?? row.trailingAnchor
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20), // inside the row's rounded fill
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: end, constant: -10),
            name.bottomAnchor.constraint(equalTo: row.centerYAnchor, constant: 1),
            sub.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: end, constant: -10),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        if let readOnly {
            NSLayoutConstraint.activate([readOnly.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
                                         readOnly.centerYAnchor.constraint(equalTo: row.centerYAnchor)])
        }
        row.toolTip = file.path
        return row
    }

    @objc private func openFileRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < recent.count else { return }
        onOpenFile?(recent[row].path)
    }

    @objc private func openPanel(_ sender: Any?) {
        onOpenPanel?()
    }

    // Right-click on a file: read-only, frame colour ›, remove from the list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = files.clickedRow
        guard row >= 0, row < recent.count else { return }
        let file = recent[row]
        let readOnly = menu.addItem(withTitle: L("Read-only"), action: #selector(toggleFileReadOnly), keyEquivalent: "")
        readOnly.target = self
        readOnly.representedObject = file.path
        readOnly.state = file.production ? .on : .off
        let colors = NSMenu()
        addColorItems(to: colors, current: file.frame ?? "", action: #selector(setFileColor), key: file.path)
        colors.removeItem(at: 0) // the submenu's title says it already
        menu.addItem(withTitle: L("Frame Colour"), action: nil, keyEquivalent: "").submenu = colors
        menu.addItem(.separator())
        let forget = menu.addItem(withTitle: L("Remove from List"), action: #selector(forgetFile), keyEquivalent: "")
        forget.target = self
        forget.representedObject = file.path
    }

    private func updateFile(_ path: String, _ change: (inout Connection) -> Void) {
        var file = ConnectionStore.fileConnection(path: path)
        change(&file)
        ConnectionStore.rememberFile(file, moveToTop: false)
        reloadFiles()
    }

    @objc private func setFileColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String] else { return }
        updateFile(pair[0]) { $0.frame = pair[1] }
    }

    @objc private func toggleFileReadOnly(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let on = sender.state != .on
        updateFile(path) { $0.production = on }
    }

    @objc private func forgetFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        ConnectionStore.forgetFile(path)
        reloadFiles()
    }

    // Right-click on a local database: its window frame colour (the tile icon shows it too).
    private func colorMenu(forDatabase database: String) -> NSMenu {
        let menu = NSMenu()
        addColorItems(to: menu, current: ConnectionStore.localFrameColor(for: database), action: #selector(setLocalColor), key: database)
        return menu
    }

    // "Window frame" header and one item per colour; each item's representedObject is [key, hex].
    private func addColorItems(to menu: NSMenu, current: String, action: Selector, key: String) {
        menu.addItem(.sectionHeader(title: L("Window frame")))
        for c in [(hex: "", name: L("No color"))] + frameColorChoices() {
            let item = menu.addItem(withTitle: c.name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = [key, c.hex]
            item.state = c.hex == current ? .on : .off
            let color: NSColor? = c.hex.isEmpty ? nil : Theme.color(hex: c.hex, fallback: .clear)
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                let dot = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
                if let color {
                    color.setFill()
                    dot.fill()
                } else {
                    NSColor.tertiaryLabelColor.setStroke()
                    dot.stroke()
                }
                return true
            }
        }
    }

    @objc private func setLocalColor(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String] else { return }
        ConnectionStore.setLocalFrameColor(pair[1], for: pair[0])
        showTiles(localNames, animated: false)
    }

    private func showTiles(_ names: [String], animated: Bool) {
        localNames = names
        tilesView.subviews.forEach { $0.removeFromSuperview() }
        guard !names.isEmpty else { return }
        var rows: [[NSView]] = [], tiles: [NSView] = []
        for start in stride(from: 0, to: names.count, by: tileColumns) {
            rows.append((start..<start + tileColumns).map { j in
                guard j < names.count else { return NSGridCell.emptyContentView }
                let tile = DatabaseTile(names[j], frame: ConnectionStore.localFrameColor(for: names[j]), target: self, action: #selector(openLocal))
                tile.menu = colorMenu(forDatabase: names[j])
                tiles.append(tile)
                return tile
            })
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        tilesView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: tilesView.topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: tilesView.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: tilesView.centerXAnchor),
        ])
        guard animated else { return }
        tilesView.layoutSubtreeIfNeeded()
        for (i, tile) in tiles.prefix(25).enumerated() { Motion.enter(tile.layer, dy: -6, duration: 0.36, delay: 0.02 * Double(i)) }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if tabs.selectedIndex == 0 { reloadLocal(nil) }
        if tabs.selectedIndex == 2 { reloadFiles() }
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === files ? recent.count : connections.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = RowView()
        (view.inset, view.radius) = (8, 8)
        if tableView === files { return view } // clicking opens; no lasting selection
        view.selectionColor = Theme.sideSel
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === files { return fileCell(recent[row]) }
        let id = NSUserInterfaceItemIdentifier("connection")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ConnectionCell ?? ConnectionCell(id)
        cell.show(connections[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView !== files
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === list else { return }
        if selected >= 0 && selected < connections.count { storeForm(at: selected) }
        selected = list.selectedRow
        fillForm()
    }

    private func fillForm() {
        let has = selected >= 0
        let c = has ? connections[selected] : Connection()
        for (f, box) in fields {
            box.stringValue = f.keyPath.map { c[keyPath: $0] } ?? ""
            box.isEnabled = has
        }
        loadedPassword = has ? ConnectionStore.password(for: c.id) ?? "" : ""
        fields[.password]!.stringValue = loadedPassword
        production.state = c.production ? .on : .off
        production.isEnabled = has
        connectButton.isEnabled = has
        kindBox.isEnabled = has
        kindSwitch.select(c.kind == "sqlite-ssh" ? 1 : 0, animated: false)
        updateKindRows()
        frameColor = has ? c.frameColor : ""
        if colorPanelAttached { // an open colour panel must not recolour the next connection
            NSColorPanel.shared.setTarget(nil)
            colorPanelAttached = false
        }
        updateProductionRow()
        showStatus("", error: false)
    }

    // Every connection can have a frame colour; production always has one, so "no colour" is hidden there.
    private func updateProductionRow() {
        let isProduction = production.state == .on
        frameColor = formFrameColor(frameColor, production: isProduction)
        let preset = isPresetFrameColor(frameColor)
        for s in swatches {
            if s.custom { s.hex = preset ? "" : frameColor }
            s.isHidden = s.none && isProduction
            s.selectedSwatch = s.custom ? !preset : s.none ? frameColor.isEmpty : s.hex == frameColor
            s.needsDisplay = true
        }
    }

    private func storeForm(at index: Int) {
        var values: [FormField: String] = [:]
        for (f, box) in fields where f != .password { values[f] = box.stringValue }
        let (c, clearedDatabase) = applyForm(values, sqliteOverSSH: kindSwitch.selectedIndex == 1, production: production.state == .on,
                                             frame: frameColor, to: connections[index])
        if clearedDatabase { fields[.database]!.stringValue = "" }
        connections[index] = c
        let password = fields[.password]!.stringValue
        if password != loadedPassword {
            ConnectionStore.setPassword(password, for: c.id)
            loadedPassword = password
        }
        ConnectionStore.save(connections)
        list.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    private func showStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? Theme.red : Theme.t2
        errorIcon.isHidden = !error
    }

    // Postgres rows or the SQLite-over-SSH rows; the SSH field is optional for one and required for the other.
    private func updateKindRows() {
        let sqlite = kindSwitch.selectedIndex == 1
        for v in postgresViews { grid.cell(for: v)?.row?.isHidden = sqlite }
        for v in sqliteViews { grid.cell(for: v)?.row?.isHidden = !sqlite }
        sshLabel.stringValue = sqlite ? L("SSH host:") : L("SSH tunnel:")
        sshHint.stringValue = sqlite ? L("user@server or an alias from ~/.ssh/config. Keys or the agent only, the server must be in known_hosts.")
                                     : L("user@server or an alias from ~/.ssh/config. Empty: direct connection.")
    }

    // MARK: Actions

    private func kindChanged() {
        updateKindRows()
        if selected >= 0 { storeForm(at: selected) }
    }

    @objc private func productionToggled(_ sender: Any?) {
        updateProductionRow()
        if selected >= 0 { storeForm(at: selected) }
    }

    @objc private func swatchClicked(_ sender: SwatchButton) {
        setFrameColor(sender.hex)
    }

    private func setFrameColor(_ hex: String) {
        frameColor = hex
        updateProductionRow()
        if selected >= 0 { storeForm(at: selected) }
    }

    // Custom swatch: the system colour panel, starting from the current colour.
    @objc private func customColorClicked(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = Theme.color(hex: frameColor, fallback: .systemOrange)
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged))
        colorPanelAttached = true
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ panel: NSColorPanel) {
        if selected >= 0 { setFrameColor(hexString(panel.color)) }
    }

    @objc private func save(_ sender: Any?) {
        if selected >= 0 { storeForm(at: selected) }
    }

    @objc private func addConnection(_ sender: Any?) {
        connections.append(newSavedConnection())
        ConnectionStore.save(connections)
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: connections.count - 1), byExtendingSelection: false)
        window?.makeFirstResponder(fields[.name]!.field)
    }

    @objc private func removeConnection(_ sender: Any?) {
        guard selected >= 0, let window else { return }
        let index = selected
        let alert = NSAlert()
        alert.messageText = String(format: L("Remove the connection “%@”?"), connections[index].name)
        alert.informativeText = L("This only removes the saved settings and the password in the Keychain. The database is not touched.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            ConnectionStore.setPassword(nil, for: connections[index].id)
            selected = -1 // so the selection change doesn't store the form under the wrong index
            connections.remove(at: index)
            ConnectionStore.save(connections)
            list.reloadData()
            fillForm()
        }
    }

    private func switchMode(_ mode: Int) {
        tabs.selectedIndex = mode
        centerModeSwitch(animated: true)
        UserDefaults.standard.set(mode, forKey: modeKey)
        if mode == 0 { reloadLocal(nil) }
        if mode == 2 { reloadFiles() }
    }

    // Databases on the default local server: socket in /tmp, port 5432, OS user (like Postgres.app).
    @objc private func reloadLocal(_ sender: Any?) {
        localSpinner.startAnimation(nil)
        Task { @MainActor in
            let result = await Self.localDatabases()
            localSpinner.stopAnimation(nil)
            let names = (try? result.get()) ?? []
            showTiles(names, animated: true)
            localStatus.textColor = Theme.t2
            switch result {
            case .success: (localStatus.stringValue, localStatus.toolTip) = (LN("%lu databases", names.count), nil)
            case .failure(let error): (localStatus.stringValue, localStatus.toolTip) = (L("No server found on port 5432"), error.localizedDescription)
            }
        }
    }

    private nonisolated static func localDatabases() async -> Result<[String], any Error> {
        await withCheckedContinuation { done in
            let pg = PGConnection(params: ["dbname": "postgres"], readOnly: true)
            pg.queue.async {
                let result = Result { () throws -> [String] in
                    try pg.open()
                    return try pg.databases().rows.map { $0.first?.string ?? "" }
                }
                pg.close()
                done.resume(returning: result)
            }
        }
    }

    @objc private func openLocal(_ sender: DatabaseTile) {
        guard !connecting else { return }
        let db = sender.database
        localSpinner.startAnimation(nil)
        localStatus.textColor = Theme.t2
        localStatus.stringValue = String(format: L("Connecting to %@…"), db)
        startConnecting(localConnection(database: db, frame: ConnectionStore.localFrameColor(for: db)), password: "") { [weak self] error in
            guard let self else { return }
            localSpinner.stopAnimation(nil)
            localStatus.stringValue = error?.localizedDescription ?? ""
            localStatus.textColor = error == nil ? Theme.t2 : Theme.red
        }
    }

    @objc private func connectSelected(_ sender: Any?) {
        guard selected >= 0, !connecting else { return }
        storeForm(at: selected)
        let info = connections[selected]
        if let problem = connectProblem(info) { return showStatus(problem, error: true) }
        connectButton.isEnabled = false
        statusSpinner.startAnimation(nil)
        showStatus(connectingStatus(info), error: false)
        startConnecting(info, password: fields[.password]!.stringValue) { [weak self] error in
            guard let self else { return }
            statusSpinner.stopAnimation(nil)
            connectButton.isEnabled = true
            showStatus(error?.localizedDescription ?? "", error: error != nil)
        }
    }

    // Sets up the tunnel (if any) and the connection in the background. `done` runs on the main thread: nil = window opened.
    private func startConnecting(_ info: Connection, password: String, done: @escaping @MainActor (Error?) -> Void) {
        connecting = true
        Task { @MainActor in
            do {
                let (connection, tunnel) = try await connect(info, password: password)
                connecting = false
                onConnected?(connection, tunnel, info)
                done(nil)
            } catch {
                connecting = false
                done(error)
            }
        }
    }
}

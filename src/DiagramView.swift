import AppKit
import QuartzCore

private let margin: CGFloat = 24        // as schemaLayout's
private let rowsTop: CGFloat = 2        // padding between the header and the first row
private let boxRadius: CGFloat = 10
private let dotSpacing: CGFloat = 18
private let selectionDuration = 0.3     // lines of the selected box
private let dragShadowDuration = 0.2
private let resetDuration = 0.6         // Reset Layout's spring

private func isDefaultSchema(_ schema: String) -> Bool { schema == "public" || schema == "main" }

// cubic-bezier(x1, y1, x2, y2) at time t: solves x(s) = t for s (Newton, then bisection), returns y(s).
private func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
    func coord(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
    func slope(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * (1 - s) * (1 - s) + 6 * (b - a) * s * (1 - s) + 3 * (1 - b) * s * s }
    let t = min(max(t, 0), 1)
    var s = t
    for _ in 0..<8 {
        let d = slope(s, x1, x2)
        if abs(d) < 1e-6 { break }
        s -= (coord(s, x1, x2) - t) / d
    }
    if s < 0 || s > 1 || abs(coord(s, x1, x2) - t) > 1e-4 {
        var (lo, hi) = (0.0, 1.0)
        s = t
        for _ in 0..<30 {
            if coord(s, x1, x2) < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
    }
    return coord(s, y1, y2)
}

// Motion.ease as a function of time (0…1).
private func ease(_ t: Double) -> Double { cubicBezier(0.22, 0.8, 0.24, 1, t) }

// Motion.spring's spring (mass 1, stiffness 300, damping 24) at `t` seconds: 0 → 1 with about 5 % overshoot,
// settled after about 0.6 s.
private func spring(_ t: Double) -> Double {
    let w0 = 300.0.squareRoot(), zeta = 24 / (2 * w0), wd = w0 * (1 - zeta * zeta).squareRoot()
    return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ f: CGFloat) -> CGFloat { a + (b - a) * f }

private func mix(_ a: CGRect, _ b: CGRect, _ f: CGFloat) -> CGRect {
    CGRect(x: mix(a.minX, b.minX, f), y: mix(a.minY, b.minY, f), width: mix(a.width, b.width, f), height: mix(a.height, b.height, f))
}

// Two colours blended in sRGB; call while drawing, so dynamic colours resolve to the current appearance.
private func mix(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor {
    if f <= 0 { return a }
    if f >= 1 { return b }
    guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return f < 0.5 ? a : b }
    return NSColor(srgbRed: mix(x.redComponent, y.redComponent, f), green: mix(x.greenComponent, y.greenComponent, f),
                   blue: mix(x.blueComponent, y.blueComponent, f), alpha: mix(x.alphaComponent, y.alphaComponent, f))
}

// Draws a laid-out SchemaGraph on a dot grid: boxes with columns, and foreign key lines from the key column to the
// referenced column. Put it in a scroll view with magnification. A click selects a box (it and its lines are
// highlighted), a drag moves it, a double-click asks for its neighbours; opening a table only goes through the box's
// menu. Dragging the background or dragging with the middle button pans; ⌘ + mouse wheel zooms around the cursor.
final class DiagramView: NSView {
    // Setting a graph clears the selection and fits the view to it.
    var graph: SchemaGraph? {
        didSet {
            transition = nil
            moving = [:]
            dragLift = nil
            selectedTable = nil
            fitToContent()
            needsDisplay = true
        }
    }
    // Highlighted with its lines; changing it fades the highlight over.
    var selected: SchemaTable? {
        get { selectedTable }
        set {
            guard newValue !== selectedTable else { return }
            transition = (selectedTable, newValue, CACurrentMediaTime())
            selectedTable = newValue
            startTicking()
            needsDisplay = true
        }
    }
    var onSelect: ((SchemaTable?) -> Void)?
    var onShowNeighbours: ((SchemaTable) -> Void)?
    var onOpen: ((SchemaTable) -> Void)?
    var onOpenInNewTab: ((SchemaTable) -> Void)?
    var onMoved: ((SchemaTable) -> Void)? // after a drag ends
    // Schema editing from the box menu; `column` is the row that was right-clicked (nil on the header).
    var onAddColumn: ((SchemaTable) -> Void)?
    var onAddForeignKey: ((SchemaTable, String?) -> Void)?
    // When an item can't be used, why (shown as its tooltip); nil = enabled.
    var addColumnBlockedReason: String?
    var addForeignKeyBlockedReason: String?

    private weak var selectedTable: SchemaTable?
    // The selection change being faded: (previous, new, start time).
    private var transition: (from: SchemaTable?, to: SchemaTable?, start: CFTimeInterval)?
    // Reset Layout: where each moving box started, by qualified name; they spring to their frames from `moveStart`.
    private var moving: [String: CGRect] = [:]
    private var moveStart: CFTimeInterval = 0
    // The dragged box's deeper shadow: (box, lifting or settling, start time).
    private var dragLift: (table: SchemaTable, up: Bool, start: CFTimeInterval)?
    private var exporting = false // drawing for exportData: final state, opaque background, no dot grid
    private var timer: Timer?

    private var dragged: SchemaTable?
    private var grab = CGPoint.zero // where in the dragged box the mouse went down
    private var didDrag = false
    private var menuColumn: String? // the column row the box menu was opened on
    private var panning = false
    private var panStart = CGPoint.zero, panOrigin = CGPoint.zero // where the pan began (window coordinates), the clip view's origin then

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    // The boxes plus a margin: what an export contains, whatever the zoom.
    var contentRect: CGRect {
        let content = (graph?.tables ?? []).reduce(CGRect.null) { $0.union($1.frame) }
        return content.isNull || content.isEmpty ? .zero : CGRect(x: 0, y: 0, width: content.maxX + margin, height: content.maxY + margin)
    }

    // Every box's frame by qualified name, e.g. to pass to animateLayout(from:) after laying out again.
    var frames: [String: CGRect] {
        Dictionary((graph?.tables ?? []).map { ($0.qualifiedName, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    // Reset Layout: the boxes spring from `old` (frames by qualified name, as `frames` returned before the new layout)
    // to where they are now. Call after setting the graph.
    func animateLayout(from old: [String: CGRect]) {
        moving = [:]
        for t in graph?.tables ?? [] {
            if let from = old[t.qualifiedName], from != t.frame { moving[t.qualifiedName] = from }
        }
        guard !moving.isEmpty else { return }
        moveStart = CACurrentMediaTime()
        startTicking()
        needsDisplay = true
    }

    // Grows or shrinks the view to the boxes (at least the visible area), e.g. after a new layout. Also done by itself
    // after zooming and when the scroll view changes size.
    func fitToContent() {
        let content = contentRect
        let visible = enclosingScrollView?.contentView.bounds.size ?? .zero // in the view's coordinates, so zoom-aware
        setFrameSize(NSSize(width: max(content.width, visible.width), height: max(content.height, visible.height)))
    }

    // The whole diagram (contentRect, not only the part scrolled into view) as PNG at 2 pixels per point or as PDF:
    // the boxes where they end up, on an opaque background, without the dot grid.
    func exportData(pdf: Bool) -> Data? {
        let bounds = contentRect
        guard !bounds.isEmpty else { return nil }
        exporting = true
        defer { exporting = false }
        if pdf { return dataWithPDF(inside: bounds) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * 2, pixelsHigh: Int(bounds.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // Zooming out or a bigger window shows more of the document: the view grows to fill it (so clicks there still
    // reach it), and shrinks back to the boxes when zooming in again.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollViewChanged), name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }

    @objc private func scrollViewChanged(_ notification: Notification) {
        fitToContent()
    }

    // MARK: - Animation

    // Redraws every frame while something moves or fades. A timer in the common modes keeps running during drags.
    private func startTicking() {
        guard timer == nil, !exporting else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if let tr = transition, now - tr.start >= duration(selectionDuration) { transition = nil }
        if !moving.isEmpty, now - moveStart >= duration(resetDuration) { moving = [:] }
        if let lift = dragLift, !lift.up, now - lift.start >= duration(dragShadowDuration) { dragLift = nil }
        needsDisplay = true
        let lifting = dragLift.map { !$0.up || now - $0.start < duration(dragShadowDuration) } ?? false
        if transition == nil && moving.isEmpty && !lifting {
            timer?.invalidate()
            timer = nil
        }
    }

    private func duration(_ d: Double) -> Double { Motion.reduced ? min(d, 0.15) : d }

    // Where a box is drawn: its frame, or on its way there after Reset Layout.
    private func shownFrame(_ t: SchemaTable) -> CGRect {
        guard !exporting, let from = moving[t.qualifiedName] else { return t.frame }
        let elapsed = CACurrentMediaTime() - moveStart
        let f = Motion.reduced ? ease(elapsed / 0.15) : spring(elapsed)
        return elapsed >= duration(resetDuration) ? t.frame : mix(from, t.frame, CGFloat(f))
    }

    // How selected a box looks, 0…1, fading over `over` seconds after the selection changed.
    private func selection(_ t: SchemaTable, over d: Double) -> CGFloat {
        let on: CGFloat = t === selectedTable ? 1 : 0
        guard !exporting, let tr = transition, tr.from === t || tr.to === t else { return on }
        let p = CGFloat(ease((CACurrentMediaTime() - tr.start) / duration(d)))
        return tr.to === t ? p : 1 - p
    }

    // How far the dragged box is lifted (its deeper shadow), 0…1.
    private func lift(_ t: SchemaTable) -> CGFloat {
        guard !exporting, let l = dragLift, l.table === t else { return 0 }
        let p = CGFloat(ease((CACurrentMediaTime() - l.start) / duration(dragShadowDuration)))
        return l.up ? p : 1 - p
    }

    // MARK: - Drawing

    // Middle of a column's row in a box (the "+ N more" row for columns past the cap, the header if missing).
    private static func rowY(_ t: SchemaTable, _ frame: CGRect, _ column: String) -> CGFloat {
        guard let i = t.columns.firstIndex(where: { $0.name == column }) else { return frame.minY + schemaHeaderHeight / 2 }
        return frame.minY + schemaHeaderHeight + rowsTop + (CGFloat(min(i, schemaMaxRows)) + 0.5) * schemaRowHeight
    }

    private func drawDots(_ dirty: CGRect, _ ctx: CGContext) {
        let dirty = dirty.intersection(bounds)
        guard !dirty.isNull else { return }
        let r: CGFloat = 1
        let dots = CGMutablePath()
        var x = floor(dirty.minX / dotSpacing) * dotSpacing + dotSpacing / 2
        while x < dirty.maxX + r {
            var y = floor(dirty.minY / dotSpacing) * dotSpacing + dotSpacing / 2
            while y < dirty.maxY + r {
                dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                y += dotSpacing
            }
            x += dotSpacing
        }
        ctx.addPath(dots)
        ctx.setFillColor(Theme.dot.cgColor)
        ctx.fillPath()
    }

    private func drawEdge(_ e: SchemaEdge) {
        let lit = max(selection(e.from, over: selectionDuration), selection(e.to, over: selectionDuration))
        let from = shownFrame(e.from), to = shownFrame(e.to)
        let y1 = Self.rowY(e.from, from, e.column), y2 = Self.rowY(e.to, to, e.referencedColumn)
        let start: CGPoint, end: CGPoint
        let out1: CGFloat, out2: CGFloat // which way the curve leaves the start and enters the end (-1 left, +1 right)
        if from.minX >= to.maxX { // the usual case: the referenced table stands to the left
            (start, end, out1, out2) = (CGPoint(x: from.minX, y: y1), CGPoint(x: to.maxX, y: y2), -1, 1)
        } else if from.maxX <= to.minX {
            (start, end, out1, out2) = (CGPoint(x: from.maxX, y: y1), CGPoint(x: to.minX, y: y2), 1, -1)
        } else { // same column (or itself): a loop on the right
            (start, end, out1, out2) = (CGPoint(x: from.maxX, y: y1), CGPoint(x: to.maxX, y: y2), 1, 1)
        }
        let pull = max(40, abs(end.x - start.x) / 2)
        let path = NSBezierPath()
        path.move(to: start)
        path.curve(to: end, controlPoint1: CGPoint(x: start.x + out1 * pull, y: start.y), controlPoint2: CGPoint(x: end.x + out2 * pull, y: end.y))
        path.lineWidth = mix(1.1, 1.6, lit)
        if e.many { path.setLineDash([5, 4], count: 2, phase: 0) } // several references in one column (a PocketBase multi relation)
        let color = mix(Theme.t3, Theme.acc, lit)
        color.setStroke()
        path.stroke()
        color.setFill() // a dot at the referenced column
        NSBezierPath(ovalIn: CGRect(x: end.x - 2.6, y: end.y - 2.6, width: 5.2, height: 5.2)).fill()
    }

    private lazy var headerFont = Theme.mono(11.5, .bold)
    private lazy var nameAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(11), .foregroundColor: Theme.t1]
    private lazy var typeAttrs: [NSAttributedString.Key: Any] = {
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        right.lineBreakMode = .byTruncatingTail
        return [.font: Theme.mono(9.5), .foregroundColor: Theme.t3, .paragraphStyle: right]
    }()
    private lazy var moreAttrs: [NSAttributedString.Key: Any] = [.font: Theme.font(11), .foregroundColor: Theme.t3]
    private lazy var pkAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .bold), .foregroundColor: Theme.orange]
    private lazy var fkAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .bold), .foregroundColor: Theme.fkT]

    // Text vertically centred on `midY`, truncated to `width`.
    private func draw(_ text: NSAttributedString, x: CGFloat, midY: CGFloat, width: CGFloat) {
        let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        let height = font.map { ceil($0.ascender - $0.descender) } ?? 14
        text.draw(with: CGRect(x: x, y: midY - height / 2, width: max(0, width), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func draw(_ text: String, _ attrs: [NSAttributedString.Key: Any], x: CGFloat, midY: CGFloat, width: CGFloat) {
        draw(NSAttributedString(string: text, attributes: attrs), x: x, midY: midY, width: width)
    }

    private func drawTable(_ t: SchemaTable, _ ctx: CGContext) {
        let box = shownFrame(t)
        let sel = selection(t, over: 0.25), up = lift(t)
        let outline = NSBezierPath(roundedRect: box, xRadius: boxRadius, yRadius: boxRadius)

        // shadow, only outside the box as CSS draws it
        ctx.saveGState()
        let outside = NSBezierPath(rect: box.insetBy(dx: -80, dy: -80))
        outside.append(outline)
        outside.windingRule = .evenOdd
        outside.addClip()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -mix(1, 18, up))
        shadow.shadowBlurRadius = mix(1, 20, up)
        shadow.shadowColor = NSColor(white: 0, alpha: mix(0.12, 0.35, up))
        shadow.set()
        NSColor.black.setFill()
        outline.fill()
        ctx.restoreGState()

        if sel > 0 {
            let halo = NSBezierPath(roundedRect: box.insetBy(dx: -1.5, dy: -1.5), xRadius: boxRadius + 1.5, yRadius: boxRadius + 1.5)
            halo.lineWidth = 3
            Theme.acc.withAlphaComponent(0.22 * sel).setStroke()
            halo.stroke()
        }

        Theme.box.setFill()
        outline.fill()

        // header: [schema.]name
        let title = NSMutableAttributedString()
        if !isDefaultSchema(t.schema) {
            title.append(NSAttributedString(string: t.schema + ".", attributes: [.font: Theme.mono(11.5), .foregroundColor: Theme.t3]))
        }
        title.append(NSAttributedString(string: t.name, attributes: [.font: headerFont, .foregroundColor: Theme.t1]))
        draw(title, x: box.minX + 10, midY: box.minY + (schemaHeaderHeight - 1) / 2, width: box.width - 20)
        Theme.line.setFill()
        CGRect(x: box.minX, y: box.minY + schemaHeaderHeight - 1, width: box.width, height: 1).fill(using: .sourceOver)

        // rows: key, name, type (right-aligned)
        let shown = min(t.columns.count, schemaMaxRows)
        let left = box.minX + 10, right = box.maxX - 10, nameX = left + 16 + 6
        for i in 0..<shown {
            let c = t.columns[i]
            let midY = box.minY + schemaHeaderHeight + rowsTop + (CGFloat(i) + 0.5) * schemaRowHeight
            let pk = c.key == "PK", fk = t.foreignKeyColumns.contains(c.name)
            if pk || fk { draw(pk ? "PK" : "FK", pk ? pkAttrs : fkAttrs, x: left, midY: midY, width: 16) }
            let type = NSAttributedString(string: c.type.uppercased(), attributes: typeAttrs)
            let typeWidth = min(ceil(type.size().width), 90)
            draw(type, x: right - typeWidth, midY: midY, width: typeWidth)
            draw(c.name, nameAttrs, x: nameX, midY: midY, width: right - typeWidth - 6 - nameX)
        }
        if t.columns.count > schemaMaxRows {
            let midY = box.minY + schemaHeaderHeight + rowsTop + (CGFloat(schemaMaxRows) + 0.5) * schemaRowHeight
            draw(String(format: L("+ %lu more"), UInt(t.columns.count - schemaMaxRows)), moreAttrs, x: nameX, midY: midY, width: right - nameX)
        }

        let border = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: boxRadius - 0.5, yRadius: boxRadius - 0.5)
        border.lineWidth = 1
        mix(Theme.boxB, Theme.acc, sel).setStroke()
        border.stroke()
    }

    // Limits drawing to outside `boxes`: the boxes blur what lies under them (dots, lines, lower boxes), which a
    // translucent fill alone would let show through.
    private func clipOut(_ boxes: [CGRect], around area: CGRect, _ ctx: CGContext) {
        let clip = CGMutablePath()
        clip.addRect(area)
        for b in boxes where b.intersects(area) { clip.addRoundedRect(in: b, cornerWidth: boxRadius, cornerHeight: boxRadius) }
        ctx.addPath(clip)
        ctx.clip(using: .evenOdd)
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let dirty = dirty.intersection(bounds)
        guard !dirty.isNull else { return }
        if exporting {
            Theme.panelSolid.setFill()
            dirty.fill()
        }
        // bottom to top: the selected box last
        let top = selectedTable
        let order = (graph?.tables ?? []).filter { $0 !== top } + (top.map { [$0] } ?? [])
        let frames = order.map(shownFrame)
        ctx.saveGState()
        clipOut(frames, around: dirty, ctx)
        if !exporting { drawDots(dirty, ctx) }
        for e in graph?.edges ?? [] { drawEdge(e) }
        ctx.restoreGState()
        for (i, t) in order.enumerated() {
            let area = frames[i].insetBy(dx: -60, dy: -60) // with its shadow and halo
            guard area.intersects(dirty) else { continue }
            ctx.saveGState()
            clipOut(Array(frames[(i + 1)...]), around: area, ctx)
            drawTable(t, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Mouse

    // The box under a point (the selected one first: it is drawn on top).
    func table(at p: CGPoint) -> SchemaTable? {
        if let s = selectedTable, s.frame.contains(p) { return s }
        return graph?.tables.last(where: { $0.frame.contains(p) })
    }

    // The column whose row is under a point in a box, nil on the header, the "+ N more" row or below.
    func column(at p: CGPoint, in t: SchemaTable) -> String? {
        let row = Int(floor((p.y - t.frame.minY - schemaHeaderHeight - rowsTop) / schemaRowHeight))
        return p.y >= t.frame.minY + schemaHeaderHeight + rowsTop && row >= 0 && row < min(t.columns.count, schemaMaxRows) ? t.columns[row].name : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        moving = [:] // a spring still under way ends where it was going
        let p = convert(event.locationInWindow, from: nil)
        let hit = table(at: p)
        if event.clickCount == 2, let hit {
            onShowNeighbours?(hit)
            return
        }
        selected = hit
        onSelect?(hit)
        guard let hit else { return beginPan(event) }
        dragged = hit
        grab = CGPoint(x: p.x - hit.frame.minX, y: p.y - hit.frame.minY)
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if panning { return pan(event) }
        guard let dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragged.frame.origin = CGPoint(x: max(0, p.x - grab.x), y: max(0, p.y - grab.y))
        if !didDrag { // lifted: the deeper shadow, no spring on its position
            dragLift = (dragged, true, CACurrentMediaTime())
            startTicking()
        }
        didDrag = true
        fitToContent()
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if panning { return endPan(event) }
        if let dragged, didDrag {
            settle(dragged)
            onMoved?(dragged)
        }
        dragged = nil
    }

    // The lifted box's shadow goes back, from wherever its lift had got to.
    private func settle(_ t: SchemaTable) {
        let now = CACurrentMediaTime()
        let reached = lift(t), d = duration(dragShadowDuration)
        // start the way down as far along as the way up had come (the curve is close enough to symmetric here)
        dragLift = (t, false, now - d * (1 - Double(reached)))
        startTicking()
        needsDisplay = true
    }

    // MARK: - Panning

    // The empty background (left button) or anything (middle button) can be grabbed to move the view.
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { beginPan(event) } else { super.otherMouseDown(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if panning { pan(event) } else { super.otherMouseDragged(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if panning { endPan(event) } else { super.otherMouseUp(with: event) }
    }

    private func beginPan(_ event: NSEvent) {
        panning = true
        panStart = event.locationInWindow
        panOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.set()
    }

    private func pan(_ event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let p = event.locationInWindow, zoom = scroll.magnification
        // the document follows the mouse; the view is flipped, window coordinates aren't
        var bounds = clip.bounds
        bounds.origin = CGPoint(x: panOrigin.x - (p.x - panStart.x) / zoom, y: panOrigin.y + (p.y - panStart.y) / zoom)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func endPan(_ event: NSEvent) {
        panning = false
        updateCursor(event)
    }

    // An open hand over the background says it can be grabbed.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        guard !panning else { return }
        (table(at: convert(event.locationInWindow, from: nil)) != nil ? NSCursor.arrow : NSCursor.openHand).set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = table(at: p) else { return nil }
        selected = hit
        onSelect?(hit)
        menuColumn = column(at: p, in: hit) // the column row under the click, for "Add Foreign Key…"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [(L("Open Table"), #selector(openSelected)), (L("Open in New Tab"), #selector(openSelectedInNewTab)),
                                (L("Show Neighbours"), #selector(showSelectedNeighbours))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if onAddColumn != nil {
            menu.addItem(.separator())
            for (title, action, blocked) in [(L("Add Column…"), #selector(addColumn), addColumnBlockedReason),
                                             (L("Add Foreign Key…"), #selector(addForeignKey), addForeignKeyBlockedReason)] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = blocked?.isEmpty ?? true
                item.toolTip = blocked?.isEmpty == false ? blocked : nil
            }
        }
        return menu
    }

    @objc private func addColumn(_ sender: Any?) {
        if let s = selectedTable { onAddColumn?(s) }
    }

    @objc private func addForeignKey(_ sender: Any?) {
        if let s = selectedTable { onAddForeignKey?(s, menuColumn) }
    }

    @objc private func openSelected(_ sender: Any?) {
        if let s = selectedTable { onOpen?(s) }
    }

    @objc private func openSelectedInNewTab(_ sender: Any?) {
        if let s = selectedTable { onOpenInNewTab?(s) }
    }

    @objc private func showSelectedNeighbours(_ sender: Any?) {
        if let s = selectedTable { onShowNeighbours?(s) }
    }

    // MARK: - Zoom

    // ⌘+ / ⌘= zoom in, ⌘− zoom out, ⌘0 fit everything; pinching works through the scroll view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let scroll = enclosingScrollView, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": scroll.magnification = min(scroll.magnification * 1.25, scroll.maxMagnification)
        case "-": scroll.magnification = max(scroll.magnification / 1.25, scroll.minMagnification)
        case "0":
            let content = (graph?.tables ?? []).reduce(CGRect.null) { $0.union($1.frame) }
            if !content.isNull && !content.isEmpty { scroll.magnify(toFit: content.insetBy(dx: -margin, dy: -margin)) }
        default: return super.performKeyEquivalent(with: event)
        }
        fitToContent()
        return true
    }

    // ⌘ + mouse wheel zooms around the cursor; without ⌘ the wheel scrolls as usual.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let scroll = enclosingScrollView else { return super.scrollWheel(with: event) }
        // a wheel notch is about one line; a trackpad reports points
        let factor = event.hasPreciseScrollingDeltas ? pow(1.005, event.scrollingDeltaY) : pow(1.1, event.deltaY)
        let zoom = min(max(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification)
        scroll.setMagnification(zoom, centeredAt: convert(event.locationInWindow, from: nil))
        fitToContent()
    }
}

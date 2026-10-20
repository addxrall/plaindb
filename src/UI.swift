import AppKit
import QuartzCore

// Light / dark colour tokens. The names are the design's CSS variables (design_handoff_plaindb_2a/README.md), so a
// value can be looked up there.
@MainActor enum Theme {
    private static func rgba(_ c: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((c >> 24) & 0xff) / 255, green: CGFloat((c >> 16) & 0xff) / 255,
                blue: CGFloat((c >> 8) & 0xff) / 255, alpha: CGFloat(c & 0xff) / 255)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // RGBA hex, e.g. 0xffffff73 for rgba(255,255,255,.45).
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        let l = rgba(light), d = rgba(dark)
        return NSColor(name: nil) { isDark($0) ? d : l }
    }

    static let side = dynamic(0xffffff73, 0xffffff09)        // sidebar panel fill
    static let panel = dynamic(0xffffffb3, 0x1c1c218c)       // content panel fill
    static let inspBg = dynamic(0xffffffb3, 0x1c1c218c)      // JSON inspector panel fill
    static let hbg = dynamic(0xffffffd1, 0x202026bf)         // sticky grid header
    static let pb = dynamic(0xffffffbf, 0xffffff14)          // panel border
    static let line = dynamic(0x0000000f, 0xffffff0f)        // separators
    static let vline = dynamic(0x0000000b, 0xffffff09)       // column guides
    static let panelSolid = dynamic(0xffffffff, 0x1c1c21ff)  // opaque panel: inline editor, toast text
    static let pendBg = dynamic(0xffffff66, 0xffffff08)      // pending-changes bar
    static let zebra = dynamic(0x00000006, 0xffffff06)
    static let hover = dynamic(0x00000009, 0xffffff0b)
    static let sel = dynamic(0x4767d317, 0x7694e929)         // selected row
    static let selT = dynamic(0x18181bff, 0xf4f4f6ff)
    static let selCell = dynamic(0x3d5dcf14, 0x7fa0fc1f)
    static let ring = dynamic(0x3d5dcfff, 0x7fa0fcff)
    static let acc = dynamic(0x3d5dcfff, 0x7fa0fcff)
    static let accT = dynamic(0xffffffff, 0x111113ff)
    static let t1 = dynamic(0x18181bff, 0xececefff)
    static let t2 = dynamic(0x6b6b73ff, 0x96969dff)
    static let t3 = dynamic(0xa6a6adff, 0x5e5e65ff)
    static let fill = dynamic(0x0000000b, 0xffffff0e)        // filter field
    static let fieldB = dynamic(0xffffff99, 0xffffff0d)
    static let ctl = dynamic(0xffffffbf, 0xffffff12)         // button
    static let ctlB = dynamic(0x00000012, 0xffffff14)
    static let ctlH = dynamic(0xffffffff, 0xffffff21)
    static let seg = dynamic(0x0000000d, 0x00000047)         // segmented track
    static let segOn = dynamic(0xffffffff, 0xffffff24)       // segmented thumb
    static let segOnT = dynamic(0x18181bff, 0xf4f4f6ff)
    static let segT = dynamic(0x6b6b73ff, 0x8a8a91ff)
    static let segB = dynamic(0xffffffbf, 0xffffff14)
    static let sideSel = dynamic(0xffffffe0, 0xffffff17)
    static let sideSelT = dynamic(0x18181bff, 0xf4f4f6ff)
    static let sideIcon = dynamic(0xa6a6adff, 0x6a6a72ff)
    static let pill = dynamic(0xffffff99, 0xffffff0f)        // connection pill
    static let pillB = dynamic(0x0000000f, 0xffffff14)
    static let cbOff = dynamic(0xc4c4caff, 0x4a4a50ff)       // unchecked checkbox border
    static let chg = dynamic(0xffe38dff, 0xe1b75c29)
    static let chgDot = dynamic(0xdfa11aff, 0xeebc4aff)
    static let add = dynamic(0xd0f7d6ff, 0x6cc58121)
    static let del = dynamic(0xffe2deff, 0xe66e6824)
    static let find = dynamic(0xfbdd67ff, 0xe5c0574d)
    static let findT = dynamic(0x18181bff, 0xffffffff)
    static let kw = dynamic(0x3a58c3ff, 0x90aefeff)
    static let str = dynamic(0xb64e10ff, 0xf1a774ff)
    static let num = dynamic(0x007d50ff, 0x88d1a2ff)
    static let fn = dynamic(0x00708aff, 0x6ec6dbff)
    static let cm = dynamic(0xa6a6adff, 0x5e5e65ff)
    static let edBg = dynamic(0xffffff66, 0x00000026)        // SQL editor, JSON tree
    static let edBg2 = dynamic(0xf6f6f8ff, 0x00000040)       // SQL box in the confirmation
    static let green = dynamic(0x1c8742ff, 0x6fc884ff)
    static let red = dynamic(0xc92f33ff, 0xf2716aff)
    static let orange = dynamic(0xc66c00ff, 0xf1a774ff)      // PK badge
    static let errorFill = dynamic(0xc92f3314, 0xf2716a1f)   // error banners
    static let errorBorder = dynamic(0xc92f3333, 0xf2716a3d)
    static let box = dynamic(0xffffffd9, 0x28282eb8)         // diagram box, structure card
    static let boxB = dynamic(0x00000014, 0xffffff1a)
    static let dot = dynamic(0x00000014, 0xffffff12)         // diagram dot grid
    static let scrim = dynamic(0xebebf273, 0x0000004d)
    static let modal = dynamic(0xffffffe0, 0x24242ad1)
    static let fkT = dynamic(0x3d5dcfff, 0x7fa0fcff)
    static let prod = rgba(0x8b63f0ff) // production badge when the connection has no frame colour
    static let tl1 = rgba(0xff5f57ff), tl2 = rgba(0xfebc2eff), tl3 = rgba(0x28c840ff) // traffic lights

    // Window background: base colour and two radial glows (top left, bottom right).
    static let winBase = dynamic(0xe7e7ecff, 0x111114ff)
    static let winGlow1 = dynamic(0xffffffff, 0x33313fff)
    static let winGlow2 = dynamic(0xd8d6eaff, 0x24263aff)

    static func panelShadowColor(_ appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? NSColor(white: 0, alpha: 0.45) : NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 70 / 255, alpha: 0.12)
    }
    static let panelHighlight = dynamic(0xffffffff, 0xffffff0f)

    // "#rrggbb" → colour.
    static func color(hex: String?, fallback: NSColor) -> NSColor {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return fallback }
        return rgba(v << 8 | 0xff)
    }

    // Geist (UI) and Geist Mono (values, code), bundled in Resources/Fonts; the system fonts where they're missing
    // (tests run outside the app bundle).
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        geist("Geist", size, weight) ?? .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        geist("Geist Mono", size, weight) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static var fonts: [String: NSFont] = [:]

    private static func geist(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont? {
        let key = "\(family)/\(size)/\(weight.rawValue)"
        if let f = fonts[key] { return f }
        let css: Int = switch weight {
        case .bold, .heavy, .black: 700
        case .semibold: 600
        case .medium: 500
        default: 400
        }
        let wght = 0x7767_6874 // the 'wght' variation axis
        let d = NSFontDescriptor(fontAttributes: [.family: family, .variation: [wght: css]])
        guard let f = NSFont(descriptor: d, size: size), f.familyName == family else { return nil }
        fonts[key] = f
        return f
    }
}

// Animation curves and helpers that honour Reduce Motion.
@MainActor enum Motion {
    static let ease = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.24, 1)
    // Overshoots; for thumbs and pills animated with NSAnimationContext.
    static let springCurve = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.5, 1)

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // A spring on `keyPath` from `from` to `to`; with Reduce Motion a short ease instead.
    static func spring(_ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval) -> CAAnimation {
        if reduced {
            let a = CABasicAnimation(keyPath: keyPath)
            (a.fromValue, a.toValue, a.duration, a.timingFunction) = (from, to, 0.15, ease)
            return a
        }
        let s = CASpringAnimation(keyPath: keyPath)
        (s.mass, s.stiffness, s.damping, s.initialVelocity) = (1, 300, 24, 0)
        (s.fromValue, s.toValue) = (from, to)
        s.duration = max(duration, s.settlingDuration)
        return s
    }

    // Animates view and constraint changes made in `changes` (via .animator() or implicitly).
    static func animate(_ duration: TimeInterval, _ timing: CAMediaTimingFunction = ease, _ changes: () -> Void,
                        completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduced ? min(duration, 0.15) : duration
            ctx.timingFunction = reduced ? ease : timing
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    // Fades `layer` in while it moves from offset `dx`, `dy` to its place, after `delay`.
    static func enter(_ layer: CALayer?, dx: CGFloat = 0, dy: CGFloat = 0, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        guard let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        (fade.fromValue, fade.toValue) = (0, 1)
        let move = CABasicAnimation(keyPath: "transform.translation")
        (move.fromValue, move.toValue) = (NSValue(size: NSSize(width: dx, height: dy)), NSValue(size: .zero))
        let group = CAAnimationGroup()
        group.animations = reduced ? [fade] : [fade, move]
        group.duration = reduced ? 0.15 : duration
        group.timingFunction = ease
        group.beginTime = CACurrentMediaTime() + (reduced ? 0 : delay)
        group.fillMode = .backwards
        layer.add(group, forKey: "enter")
    }
}

// Copies text or an image for this Mac only: not to other devices through Universal Clipboard, and marked
// (nspasteboard.org Concealed / Transient) so clipboard managers don't keep a history of database values.
@MainActor func copyLocally(_ pasteboard: NSPasteboard, text: String?, image: NSImage? = nil) {
    let item = NSPasteboardItem()
    if let text { item.setString(text, forType: .string) }
    if let tiff = image?.tiffRepresentation {
        item.setData(tiff, forType: .tiff)
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
    }
    for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
    pasteboard.prepareForNewContents(with: .currentHostOnly) // also empties it
    pasteboard.writeObjects([item])
}

// A layer-backed view whose layer colours follow light / dark: override updateColors, which runs with the view's
// appearance current, so dynamic NSColors resolve to the right variant.
class LayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { self.updateColors() } }
    func updateColors() {}
}

// The window background: a base colour with two soft radial glows, top left and bottom right.
class WindowBackground: LayerView {
    private let glows = [CAGradientLayer(), CAGradientLayer()]

    override init(frame: NSRect) {
        super.init(frame: frame)
        for g in glows {
            g.type = .radial
            layer?.addSublayer(g)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateColors() {
        layer?.backgroundColor = Theme.winBase.cgColor
        for (g, (color, end)) in zip(glows, [(Theme.winGlow1, 0.6), (Theme.winGlow2, 0.55)]) {
            g.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            g.locations = [0, NSNumber(value: end)]
        }
    }

    // y runs upwards here, so the top-left glow's centre is at y 1.1.
    override func layout() {
        super.layout()
        let (w, h) = (max(bounds.width, 1), max(bounds.height, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (g, (center, radius)) in zip(glows, [(CGPoint(x: 0.08, y: 1.1), CGSize(width: 900, height: 600)),
                                                 (CGPoint(x: 1, y: -0.1), CGSize(width: 800, height: 600))]) {
            g.frame = bounds
            g.startPoint = center
            g.endPoint = CGPoint(x: center.x + radius.width / w, y: center.y + radius.height / h)
        }
        CATransaction.commit()
    }
}

// A rounded panel: fill, 1 px border and optionally the panel shadow and the inner top highlight. Panels are told
// apart by these, without hard separators.
class Panel: LayerView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 16 { didSet { needsDisplay = true } }
    var shadowed = false { didSet { needsDisplay = true } }
    var highlighted = false { didSet { needsDisplay = true } } // a light line along the top edge
    private let highlight = CALayer()

    convenience init(fill: NSColor?, border: NSColor? = nil, radius: CGFloat = 16, shadow: Bool = false) {
        self.init(frame: .zero)
        (fillColor, borderColor, self.radius, shadowed) = (fill, border, radius, shadow)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(highlight)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateColors() {
        guard let layer else { return }
        layer.cornerRadius = effectiveRadius
        layer.cornerCurve = .continuous
        layer.backgroundColor = fillColor?.cgColor
        layer.borderWidth = borderColor == nil ? 0 : 1
        layer.borderColor = borderColor?.cgColor
        layer.shadowOpacity = shadowed ? 1 : 0
        layer.shadowColor = Theme.panelShadowColor(effectiveAppearance).cgColor
        layer.shadowRadius = 30 // a CSS blur of 60
        layer.shadowOffset = CGSize(width: 0, height: -24)
        highlight.isHidden = !highlighted
        highlight.backgroundColor = Theme.panelHighlight.cgColor
    }

    override func layout() {
        super.layout()
        let r = effectiveRadius
        layer?.cornerRadius = r
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        highlight.frame = CGRect(x: r, y: bounds.height - 1, width: max(0, bounds.width - 2 * r), height: 1)
    }

    // A capsule asks for 999: Core Animation would draw a radius larger than the panel past its bounds.
    private var effectiveRadius: CGFloat {
        min(radius, min(bounds.width, bounds.height) / 2)
    }
}

@MainActor func label(_ text: String, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular, _ color: NSColor = Theme.t1,
                      mono: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? Theme.mono(size, weight) : Theme.font(size, weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return l
}

@MainActor func wrappingLabel(_ text: String, _ size: CGFloat = 12.5, _ color: NSColor = Theme.t2) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = Theme.font(size)
    l.textColor = color
    l.isSelectable = true
    return l
}

// Text button: secondary, accent or a custom fill. `shortcut` is shown dimmed after the title ("Save ⌘S"). Scales
// down while pressed.
final class PillButton: NSButton {
    enum Style { case secondary, accent, custom(NSColor, NSColor) } // custom: fill, text
    var style: Style = .secondary { didSet { restyle() } }
    var shortcut = "" { didSet { restyle() } }
    private var hovering = false

    convenience init(_ title: String, style: Style = .secondary, shortcut: String = "", height: CGFloat = 24,
                     target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        (self.target, self.action, self.style, self.shortcut) = (target, action, style, shortcut)
        isBordered = false
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        restyle()
    }

    override var title: String { didSet { restyle() } }
    override var isEnabled: Bool { didSet { restyle() } }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 24, height: super.intrinsicContentSize.height)
    }

    private var colors: (fill: NSColor, text: NSColor, border: NSColor?) {
        switch style {
        case .secondary: (hovering && isEnabled ? Theme.ctlH : Theme.ctl, Theme.t1, Theme.ctlB)
        case .accent: (Theme.acc, Theme.accT, nil)
        case .custom(let fill, let text): (fill, text, nil)
        }
    }

    private func restyle() {
        let c = colors
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: Theme.font(12, { if case .secondary = style { .medium } else { .semibold } }()), .foregroundColor: c.text,
        ])
        if !shortcut.isEmpty {
            s.append(NSAttributedString(string: " " + shortcut, attributes: [.font: Theme.font(12), .foregroundColor: c.text.withAlphaComponent(0.7)]))
        }
        attributedTitle = s
        alphaValue = isEnabled ? 1 : 0.45
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = colors
            layer?.cornerRadius = 8
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = c.fill.cgColor
            layer?.borderWidth = c.border == nil ? 0 : 1
            layer?.borderColor = c.border?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

    override func mouseDown(with event: NSEvent) {
        pressScale(0.97)
        super.mouseDown(with: event) // tracks until the mouse goes up
        pressScale(1)
    }
}

extension NSView {
    // Animates the layer's scale about its centre (pressed buttons).
    @MainActor func pressScale(_ scale: CGFloat) {
        guard let layer, !Motion.reduced else { return }
        // AppKit keeps the layer's anchor at its corner, so scale about the centre by translating around it
        let (cx, cy) = (layer.bounds.midX, layer.bounds.midY)
        let transform = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(cx, cy, 0), scale, scale, 1), -cx, -cy, 0)
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
        a.toValue = NSValue(caTransform3D: transform)
        a.duration = 0.15
        a.timingFunction = Motion.ease
        layer.add(a, forKey: "press")
        layer.transform = transform
    }
}

// Icon button in a bar, accent-filled when `on`. In a group (`grouped`), it has no own border: the group draws one
// around all its buttons.
final class ToolButton: NSButton {
    var on = false { didSet { needsDisplay = true; updateTint() } }
    var grouped = false { didSet { needsDisplay = true } }
    private var hovering = false

    convenience init(symbol: String, tip: String, size: NSSize = NSSize(width: 26, height: 22), target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        (self.target, self.action, toolTip) = (target, action, tip)
        isBordered = false
        wantsLayer = true
        symbolConfiguration = .init(pointSize: 11, weight: .medium)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        updateTint()
    }

    private func updateTint() { contentTintColor = on ? Theme.accT : Theme.t2 }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = grouped ? 0 : 8
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = (on ? Theme.acc : hovering && isEnabled ? Theme.ctlH : grouped ? .clear : Theme.ctl).cgColor
            layer?.borderWidth = on || grouped ? 0 : 1
            layer?.borderColor = Theme.ctlB.cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}

// Several ToolButtons in one bordered group, e.g. + / −.
@MainActor func toolGroup(_ buttons: [ToolButton]) -> NSView {
    let group = Panel(fill: Theme.ctl, border: Theme.ctlB, radius: 8)
    group.layer?.masksToBounds = true
    let stack = NSStackView(views: buttons)
    stack.spacing = 0
    buttons.forEach { $0.grouped = true }
    pin(stack, group)
    stack.setHuggingPriority(.required, for: .horizontal) // a Panel has no size of its own: the stack decides it
    return group
}

// Capsule badge, e.g. PRODUCTION or read-only.
@MainActor func badge(_ text: String, _ textColor: NSColor, _ fill: NSColor?, border: NSColor? = nil, size: CGFloat = 10.5,
                      weight: NSFont.Weight = .semibold, kern: CGFloat = 0.5) -> Panel {
    let box = Panel(fill: fill, border: border, radius: 999)
    let l = label("", size, weight, textColor)
    l.attributedStringValue = NSAttributedString(string: text, attributes: [.font: Theme.font(size, weight), .foregroundColor: textColor, .kern: kern])
    pin(l, box, NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7))
    box.setContentHuggingPriority(.required, for: .horizontal)
    box.setContentCompressionResistancePriority(.required, for: .horizontal)
    l.setContentCompressionResistancePriority(.required, for: .horizontal)
    return box
}

// Segmented control with one thumb that springs to the selected segment, labels cross-fading (the main tabs, the
// inspector's Tree / Text).
final class SlidingSegments: LayerView {
    var onChange: ((Int) -> Void)?
    private(set) var selectedIndex = 0
    private let titles: [String]
    private let segmentWidth, height, radius, inset: CGFloat
    private let thumb = CALayer()
    private var labels: [NSTextField] = []
    private let fontSize: CGFloat

    init(_ titles: [String], segmentWidth: CGFloat, height: CGFloat, radius: CGFloat, fontSize: CGFloat = 12.5, inset: CGFloat = 3) {
        (self.titles, self.segmentWidth, self.height, self.radius, self.fontSize, self.inset) = (titles, segmentWidth, height, radius, fontSize, inset)
        super.init(frame: .zero)
        layer?.addSublayer(thumb)
        for (i, t) in titles.enumerated() {
            let l = label(t, fontSize, .medium, Theme.segT)
            l.alignment = .center
            l.translatesAutoresizingMaskIntoConstraints = false
            addSubview(l)
            NSLayoutConstraint.activate([
                l.centerYAnchor.constraint(equalTo: centerYAnchor),
                l.centerXAnchor.constraint(equalTo: leadingAnchor, constant: inset + segmentWidth * (CGFloat(i) + 0.5)),
            ])
            labels.append(l)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: segmentWidth * CGFloat(titles.count) + 2 * inset),
            heightAnchor.constraint(equalToConstant: height),
        ])
        setAccessibilityRole(.radioGroup)
        select(0, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateColors() {
        layer?.cornerRadius = min(radius, height / 2)
        layer?.backgroundColor = Theme.seg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.segB.cgColor
        thumb.cornerRadius = min(radius == 8 ? 6 : radius, (height - 2 * inset) / 2)
        thumb.backgroundColor = Theme.segOn.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = Theme.isDark(effectiveAppearance) ? 0.25 : 0.1
        thumb.shadowRadius = 1.5
        thumb.shadowOffset = CGSize(width: 0, height: -1)
        for (i, l) in labels.enumerated() { l.textColor = i == selectedIndex ? Theme.segOnT : Theme.segT }
    }

    private func thumbFrame(_ i: Int) -> CGRect {
        CGRect(x: inset + segmentWidth * CGFloat(i), y: inset, width: segmentWidth, height: height - 2 * inset)
    }

    func select(_ index: Int, animated: Bool) {
        let from = thumb.position
        selectedIndex = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = thumbFrame(index)
        CATransaction.commit()
        if animated {
            thumb.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: thumb.position), duration: 0.5), forKey: "slide")
            Motion.animate(0.3) { for (i, l) in labels.enumerated() { l.animator().textColor = i == index ? Theme.segOnT : Theme.segT } }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x - inset
        let i = max(0, min(titles.count - 1, Int(x / segmentWidth)))
        guard i != selectedIndex else { return }
        select(i, animated: true)
        onChange?(i)
    }
}

// Shows exactly one of `views` at a time, all pinned to the edges; switching cross-fades.
final class Switcher: NSView {
    private let views: [NSView]
    var selectedIndex = 0 {
        didSet {
            for (i, v) in views.enumerated() { v.isHidden = i != selectedIndex }
            if oldValue != selectedIndex { views[selectedIndex].wantsLayer = true; Motion.enter(views[selectedIndex].layer, dy: -8, duration: 0.38) }
        }
    }

    init(_ views: [NSView]) {
        self.views = views
        super.init(frame: .zero)
        for v in views { pin(v, self) }
        for (i, v) in views.enumerated() { v.isHidden = i != 0 }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Top-down coordinates, e.g. for a scroll view's document that should start at the top.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor func pin(_ view: NSView, _ container: NSView, _ insets: NSEdgeInsets = NSEdgeInsets()) {
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
    ])
}

// Vertical stack where every view is full width (minus the side insets); `grow` takes the remaining height.
@MainActor func column(_ views: [NSView], grow: NSView? = nil, insets: NSEdgeInsets = NSEdgeInsets(), spacing: CGFloat = 0) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.alignment = .leading
    s.distribution = .fill
    s.spacing = spacing
    s.edgeInsets = insets
    // Explicit widths: .width alignment leaves views with an intrinsic width narrow.
    for v in views {
        v.leadingAnchor.constraint(equalTo: s.leadingAnchor, constant: insets.left).isActive = true
        v.trailingAnchor.constraint(equalTo: s.trailingAnchor, constant: -insets.right).isActive = true
        if v !== grow { v.setContentHuggingPriority(.defaultHigh, for: .vertical) }
    }
    grow?.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
    return s
}

// Horizontal bar: views pinned to the leading and trailing edges.
@MainActor func bar(_ leading: [NSView], _ trailing: [NSView], height: CGFloat, left: CGFloat = 18, right: CGFloat = 12, spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView()
    s.orientation = .horizontal
    s.spacing = spacing
    s.edgeInsets = NSEdgeInsets(top: 0, left: left, bottom: 0, right: right)
    for v in leading { s.addView(v, in: .leading) }
    for v in trailing { s.addView(v, in: .trailing) }
    s.heightAnchor.constraint(equalToConstant: height).isActive = true
    return s
}

// A 1 px horizontal separator.
@MainActor func separator() -> NSView {
    let line = Panel(fill: Theme.line, radius: 0)
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

// Centred message, e.g. an empty or loading state.
@MainActor func centeredState(_ views: [NSView]) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -80),
    ])
    return container
}

@MainActor func spinner(_ size: NSControl.ControlSize = .small) -> NSProgressIndicator {
    let s = NSProgressIndicator()
    s.style = .spinning
    s.controlSize = size
    s.isDisplayedWhenStopped = false
    return s
}

// Row drawn as a rounded fill inset from the table's edges (zebra, hover, selection), so cell text keeps its normal
// colour.
class RowView: NSTableRowView {
    var selectionColor: NSColor? = Theme.sel
    var baseColor: NSColor? { didSet { needsDisplay = true } } // zebra, added, deleted
    var inset: CGFloat = 8, radius: CGFloat = 8
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: 0), xRadius: radius, yRadius: radius)
        if let baseColor { baseColor.setFill(); path.fill() }
        if hovered && !isSelected { Theme.hover.setFill(); path.fill() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (selectionColor ?? Theme.sel).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: 0), xRadius: radius, yRadius: radius).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

// Cell with a fill and an optional ring (the selected cell), redrawn correctly when light / dark changes.
class CellView: NSTableCellView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var ring = false { didSet { needsDisplay = true } }
    var radius: CGFloat = 6

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = radius
            layer?.backgroundColor = fill?.cgColor
            layer?.borderWidth = ring ? 1.5 : 0
            layer?.borderColor = Theme.ring.cgColor
        }
    }
}

// Reusable cell with a text field (and optionally an icon), vertically centred.
@MainActor func makeCell(_ table: NSTableView, _ identifier: String, image: Bool = false, padding: CGFloat = 12) -> CellView {
    let id = NSUserInterfaceItemIdentifier(identifier)
    if let cell = table.makeView(withIdentifier: id, owner: nil) as? CellView { return cell }
    let cell = CellView()
    cell.identifier = id
    cell.wantsLayer = true
    let field = NSTextField(labelWithString: "")
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    cell.addSubview(field)
    cell.textField = field
    var leading = cell.leadingAnchor, inset = padding
    if image {
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
        ])
        leading = imageView.trailingAnchor
        inset = 9
    }
    NSLayoutConstraint.activate([
        field.leadingAnchor.constraint(equalTo: leading, constant: inset),
        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -padding),
        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
}

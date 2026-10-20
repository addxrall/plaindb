import AppKit

// a quoted identifier is matched so the words in it aren't taken for keywords
private let sqlTokens = try! NSRegularExpression(pattern: "(--[^\\n]*)|('(?:[^']|'')*'?)|(\"(?:[^\"]|\"\")*\"?)|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_][A-Za-z0-9_]*)")
private let sqlKeywords = Set(("select from where join on as and or not group by order desc asc limit offset update set "
    + "delete insert into values begin commit rollback inner left right outer full cross having "
    + "distinct is null default case when then else end returning true false with union all in "
    + "like ilike between exists create table alter drop index primary key references add column constraint foreign "
    + "cascade restrict no action check unique").components(separatedBy: " "))
private let sqlFunctions = Set("count sum avg min max now coalesce lower upper length concat".components(separatedBy: " "))

// Colours SQL keywords, functions, strings, numbers and comments.
@MainActor func sqlHighlight(_ storage: NSTextStorage) {
    let text = storage.string as NSString
    let all = NSRange(location: 0, length: text.length)
    storage.beginEditing()
    storage.addAttribute(.foregroundColor, value: Theme.t1, range: all)
    for m in sqlTokens.matches(in: storage.string, range: all) {
        let color: NSColor? =
            if m.range(at: 1).location != NSNotFound { Theme.cm }
            else if m.range(at: 2).location != NSNotFound { Theme.str }
            else if m.range(at: 3).location != NSNotFound { nil }
            else if m.range(at: 4).location != NSNotFound { Theme.num }
            else {
                switch text.substring(with: m.range).lowercased() {
                case let w where sqlKeywords.contains(w): Theme.kw
                case let w where sqlFunctions.contains(w): Theme.fn
                default: nil
                }
            }
        if let color { storage.addAttribute(.foregroundColor, value: color, range: m.range) }
    }
    storage.endEditing()
}

// Monospace code view: no smart quotes or substitutions, live highlighting (SQL unless `highlighter` is replaced,
// e.g. by the JSON inspector), a fixed line height with the text centred in each line as CSS line-height does, and
// separate left and right padding. Copy and cut put the selection on the clipboard for this Mac only (see
// copyLocally); drags and Services, which use other pasteboards, work as usual.
final class SQLTextView: NSTextView, NSTextStorageDelegate {
    var highlighter: @MainActor (NSTextStorage) -> Void = sqlHighlight { didSet { rehighlight() } }
    var lineHeight: CGFloat = 20 { didSet { updateMetrics() } }
    // Horizontal padding around the text; top and bottom are textContainerInset.height.
    var padding: (left: CGFloat, right: CGFloat) = (4, 12) { didSet { updateMetrics() } }

    override var font: NSFont? { didSet { updateMetrics() } }

    // Colours and line metrics for the current text; runs by itself after every edit.
    func rehighlight() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        for (key, value) in lineAttributes() { storage.addAttribute(key, value: value, range: all) }
        highlighter(storage)
        storage.endEditing()
    }

    private func lineAttributes() -> [NSAttributedString.Key: Any] {
        let font = font ?? Theme.mono(12.5)
        let style = NSMutableParagraphStyle()
        (style.minimumLineHeight, style.maximumLineHeight) = (lineHeight, lineHeight)
        // TextKit puts a line's extra height above the text; raising the baseline by half centres it
        let natural = layoutManager?.defaultLineHeight(for: font) ?? font.ascender - font.descender + font.leading
        return [.font: font, .paragraphStyle: style, .baselineOffset: max(0, (lineHeight - natural) / 2)]
    }

    private func updateMetrics() {
        // the inset is the same on both sides; textContainerOrigin moves the text to the left padding
        textContainerInset = NSSize(width: (padding.left + padding.right) / 2, height: textContainerInset.height)
        textContainer?.lineFragmentPadding = 0
        invalidateTextContainerOrigin()
        var typing = typingAttributes
        for (key, value) in lineAttributes() { typing[key] = value }
        typingAttributes = typing
        rehighlight()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: padding.left, y: super.textContainerOrigin.y)
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // not while the storage is still processing
        DispatchQueue.main.async { MainActor.assumeIsolated { self.rehighlight() } }
    }

    override func didChangeText() {
        super.didChangeText()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard pboard == NSPasteboard.general else { return super.writeSelection(to: pboard, types: types) }
        let text = string as NSString
        copyLocally(pboard, text: selectedRanges.map { text.substring(with: $0.rangeValue) }.joined())
        return true
    }
}

// Line number gutter. No fill or edge line of its own: the scroll view's background shows through.
private final class LineNumberRuler: NSRulerView {
    override func draw(_ dirtyRect: NSRect) { drawHashMarksAndLabels(in: dirtyRect) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(12), .foregroundColor: Theme.t3]
        let offset = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y
        let visible = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)

        func draw(_ line: Int, in r: NSRect) {
            let label = String(line) as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: offset + r.minY + (r.height - size.height) / 2), withAttributes: attrs)
        }

        var line = 1
        let start = layout.characterIndexForGlyph(at: visible.location)
        for i in 0..<start where text.character(at: i) == 10 { line += 1 }

        var glyph = visible.location
        while glyph < NSMaxRange(visible) {
            let lineRange = text.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: glyph), length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            draw(line, in: layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil))
            line += 1
            glyph = max(NSMaxRange(glyphs), glyph + 1)
        }
        if text.length == 0 || text.hasSuffix("\n") { // empty last line
            let r = layout.extraLineFragmentRect
            if !r.isEmpty { draw(line, in: r) }
        }
    }
}

// Scrollable code text view for SQL (see SQLTextView), optionally with the line number gutter. Set the scroll view's
// backgroundColor (or drawsBackground = false) for another background; the gutter follows it.
@MainActor func sqlTextScrollView(editable: Bool, lineNumbers: Bool) -> (scroll: NSScrollView, textView: SQLTextView) {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = Theme.edBg

    // TextKit 1: the gutter reads line fragments from the layout manager
    let t = SQLTextView(usingTextLayoutManager: false)
    t.minSize = .zero
    t.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    t.isVerticallyResizable = true
    t.isHorizontallyResizable = false
    t.autoresizingMask = .width
    t.textContainer?.widthTracksTextView = true
    t.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    t.drawsBackground = false // the scroll view's background shows through, also behind the gutter
    t.isRichText = false
    t.importsGraphics = false
    t.allowsUndo = true
    t.isEditable = editable
    t.isAutomaticQuoteSubstitutionEnabled = false
    t.isAutomaticDashSubstitutionEnabled = false
    t.isAutomaticTextReplacementEnabled = false
    t.isAutomaticSpellingCorrectionEnabled = false
    t.isContinuousSpellCheckingEnabled = false
    t.insertionPointColor = Theme.t1
    t.textContainerInset = NSSize(width: 8, height: 10)
    t.font = Theme.mono(12.5)
    t.textStorage?.delegate = t
    scroll.documentView = t
    if lineNumbers {
        let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = t
        ruler.ruleThickness = 40
        ruler.reservedThicknessForMarkers = 0
        ruler.reservedThicknessForAccessoryView = 0
        ruler.clipsToBounds = true // otherwise it draws past the scroll view (views don't clip by default)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
    }
    return (scroll, t)
}

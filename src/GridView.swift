import AppKit
import QuartzCore

// Grid showing a DBResult. Columns are built from the result, NULL is shown in grey italics,
// numeric columns are right-aligned. With `editable` it collects changes (cell edits, new and
// deleted rows) without sending them to the database.
final class GridView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let table: NSTableView

    // Setting a result clears unsaved changes.
    var result: DBResult? {
        get { data }
        set { setResult(newValue) }
    }
    // When set, column headers are clickable (ascending → descending → off) and the caller does the sorting (e.g.
    // ORDER BY in SQL). nil column: no sorting.
    var onSort: ((_ column: String?, _ ascending: Bool) -> Void)?
    func resetSort() {
        sortColumn = nil
        table.headerView?.needsDisplay = true
    }

    // Leading column with row numbers (on by default). Set before `result`.
    var showsRowNumbers = true
    // Number shown for the first row minus one, e.g. the page offset.
    var rowNumberOffset = 0
    // Text shown for SQL NULL.
    var nullText = "NULL"
    // Text colour per column index, for non-NULL values.
    var columnColors: [Int: NSColor] = [:]
    // Search term: every cell where it occurs (ignoring case) is marked, or nil.
    var highlight: String? { didSet { reconfigure() } }
    // Whole cells marked like a search match: column index → values. For foreign keys whose referenced row matched.
    var highlightedValues: [Int: Set<String>]? {
        didSet { if highlightedValues != oldValue { reconfigure() } }
    }

    var editable = false
    // Columns with a default value: new rows show "DEFAULT" there instead of "NULL".
    var defaultColumns = IndexSet() { didSet { widen(defaultColumns, to: Metrics.defaultWidth); reconfigure() } }
    // Called whenever the set of unsaved changes changes.
    var onChange: (() -> Void)?

    // row → (column → new value)
    private(set) var edits: [Int: [Int: DBValue]] = [:]
    private(set) var deletedRows = IndexSet()
    // column → value; a missing column means DEFAULT
    private(set) var insertedRows: [[Int: DBValue]] = []
    // Number of changed rows.
    var changeCount: Int { deletedRows.union(IndexSet(edits.keys)).count + insertedRows.count }
    var editedCellCount: Int { edits.filter { !deletedRows.contains($0.key) }.reduce(0) { $0 + $1.value.count } }

    // Columns with a foreign key. Their values get a ↗ that calls onOpenReference; editing them calls onPickReference
    // (instead of a text field) so the caller can offer a search in the referenced table. Rects are in `table` coordinates.
    var referenceColumns = IndexSet() {
        didSet {
            reconfigure()
            table.headerView?.needsDisplay = true // foreign keys are right-aligned
        }
    }
    var onOpenReference: ((_ row: Int, _ column: Int, _ cellRect: NSRect) -> Void)?
    var onPickReference: ((_ row: Int, _ column: Int, _ cellRect: NSRect) -> Void)?

    // Column index → kind (see DatePicker.swift). Booleans show a checkbox that toggles (click on it, double-click,
    // Enter); date/time columns call onPickDate instead of inline editing.
    var columnKinds: [Int: ValueKind] = [:] { didSet { columnKindsChanged() } }
    var onPickDate: ((_ row: Int, _ column: Int, _ cellRect: NSRect, _ kind: ValueKind) -> Void)?
    // How booleans are written back when toggled (Postgres t / f, SQLite 1 / 0). Reading accepts t, true and 1.
    var booleanTrue = "t", booleanFalse = "f"

    // Cells whose value looks like an image (see isImageValue) get a 🖼 badge; it, double-click and Enter call this.
    var onOpenImage: ((_ row: Int, _ column: Int, _ cellRect: NSRect) -> Void)?

    // Files kept elsewhere (S3, PocketBase storage): a 🖼 badge calling onOpenFile on every non-empty value of
    // fileColumns, and, with detectsFileKeys, on any value that looks like file keys (see fileKeys(in:)).
    var fileColumns = IndexSet() { didSet { reconfigure() } }
    var detectsFileKeys = false { didSet { reconfigure() } }
    var onOpenFile: ((_ row: Int, _ column: Int, _ cellRect: NSRect) -> Void)?

    // Double-click / Enter on a cell holding a JSON object or array calls this instead of inline editing.
    var onOpenJSON: ((_ row: Int, _ column: Int) -> Void)?
    // Called when the user clicks a cell.
    var onSelectCell: ((_ row: Int, _ column: Int) -> Void)?

    // How rows enter in animateRowsIn: rising and fading in (a table was opened) or sliding in from the left
    // (query results). Only the first 26 visible rows move.
    enum RowEntrance { case rise, slide }

    // The text field over the cell being edited, nil otherwise (internal for tests).
    private(set) var editor: NSTextField?

    private var data: DBResult?
    private var generation = 0 // bumped per result, so views showing an older one don't animate into the new one
    private var numericColumns = IndexSet()
    private var sortColumn: String?, sortAscending = true
    private var editRow = -1, editColumn = 0, selectedColumn = 0, ringRow = -1
    private var editOriginal = ""
    private var visibleColumns = IndexSet()
    private var shownSelection = IndexSet()
    private var hoverRow = -1
    private weak var hoveredBadge: GridCellView?
    private var entrance: (style: RowEntrance, start: CFTimeInterval)?
    private var enteringRow = -1 // a row just added, slid in once its view appears

    private static let gutterID = NSUserInterfaceItemIdentifier("#"), fillerID = NSUserInterfaceItemIdentifier("filler")

    override init(frame frameRect: NSRect) {
        let table = GridTable()
        self.table = table
        super.init(frame: frameRect)
        table.grid = self
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false // zebra stripes are the rows' rounded fills
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: Metrics.rowGap)
        table.rowHeight = Metrics.rowHeight
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle // the filler column takes the rest
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false // columns are found by position
        table.focusRingType = .none
        table.headerView = GridHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: Metrics.headerHeight + 1 + Metrics.headerGap))
        table.cornerView = HeaderCorner(frame: NSRect(x: 0, y: 0, width: Metrics.scroller, height: Metrics.headerHeight + 1 + Metrics.headerGap))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = buildMenu()
        documentView = table
        // in a translucent panel: nothing behind the rows is painted
        drawsBackground = false
        contentView.drawsBackground = false
        verticalScroller = ThinScroller()
        horizontalScroller = ThinScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .legacy
        borderType = .noBorder
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: contentView)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Cells skip drawing while off screen, so cells in columns that just scrolled into view are redrawn here.
    // The row under a resting mouse changes too.
    @objc private func scrolled(_ notification: Notification) {
        if let window, window.isVisible { hover(at: table.convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        let visible = table.columnIndexes(in: table.visibleRect)
        let entered = visible.subtracting(visibleColumns)
        visibleColumns = visible
        guard !entered.isEmpty else { return }
        let rows = table.rows(in: table.visibleRect)
        for col in entered {
            for row in rows.location..<NSMaxRange(rows) { table.view(atColumn: col, row: row, makeIfNecessary: false)?.needsDisplay = true }
        }
    }

    // Always classic, visible scroll bars: wide tables need a horizontal bar you can see and grab,
    // even when the system shows overlay scroll bars only while scrolling. AppKit resets the style
    // whenever the system preference changes, so it is pinned here.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .legacy }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Set NULL"), action: #selector(setNull(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Copy"), action: #selector(copyValue(_:)), keyEquivalent: "c").target = self
        menu.addItem(withTitle: L("Show Referenced Row"), action: #selector(openReference(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "", action: #selector(deleteClickedRows(_:)), keyEquivalent: "").target = self // titled in validateMenuItem
        return menu
    }

    // Right-click "Delete Row": the clicked row, or the whole selection when the click is inside it.
    private func rows(forClickedRow row: Int) -> IndexSet {
        table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)
    }

    // Like ⌫: deletes those rows, or restores them when all of them are already marked as deleted.
    func toggleDeletion(fromRow row: Int) {
        guard row >= 0, row < table.numberOfRows else { return }
        table.selectRowIndexes(rows(forClickedRow: row), byExtendingSelection: false)
        deleteSelectedRows()
    }

    @objc private func deleteClickedRows(_ sender: Any?) {
        toggleDeletion(fromRow: table.clickedRow)
    }

    func deleteTitle(forRow row: Int) -> String {
        let rows = rows(forClickedRow: row)
        let existing = rows.filteredIndexSet { $0 < (data?.rows.count ?? 0) }
        let restore = !existing.isEmpty && deletedRows.isSuperset(of: existing)
        return restore ? LN("Restore %lu rows", rows.count) : LN("Delete %lu rows", rows.count)
    }

    // MARK: - Columns

    // Table column index → result column index (-1 for the leading gutter with the row numbers and the trailing
    // filler), and back.
    private func dataColumn(_ tableColumn: Int) -> Int {
        let col = tableColumn - 1
        return col >= 0 && col < (data?.columns.count ?? 0) ? col : -1
    }

    private func tableColumn(_ dataColumn: Int) -> Int { dataColumn + 1 }

    private func isRightAligned(_ col: Int) -> Bool {
        (numericColumns.contains(col) || referenceColumns.contains(col)) && !isBool(col)
    }

    // MARK: - Result

    private func setResult(_ result: DBResult?) {
        // Empty the grid first: addTableColumn builds cells for visible rows right away,
        // so old rows must not reach into the new, shorter result.
        data = nil
        clearChanges()
        table.reloadData()
        while let last = table.tableColumns.last { table.removeTableColumn(last) }
        generation += 1
        hoverRow = -1
        shownSelection = []

        var numeric = IndexSet()
        if let result {
            let gutter = NSTableColumn(identifier: Self.gutterID)
            gutter.title = ""
            gutter.width = Metrics.inset + (showsRowNumbers ? Metrics.numberWidth : 0) // the rows' inset, then the numbers
            (gutter.minWidth, gutter.maxWidth, gutter.resizingMask) = (gutter.width, gutter.width, [])
            table.addTableColumn(gutter)
            let sample = result.rows.prefix(50)
            let charWidth = "0".size(withAttributes: [.font: Theme.mono(12)]).width // cells are monospaced
            for (i, name) in result.columns.enumerated() {
                var chars = name.utf16.count, numbers = 0, values = 0
                for row in sample {
                    guard let v = row[i].string else { continue }
                    values += 1
                    chars = max(chars, v.utf16.count)
                    if Self.isNumber(v) { numbers += 1 }
                }
                if values > 0 && numbers == values { numeric.insert(i) }
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                col.title = name
                // the old widths, scaled up for the roomier cells
                col.width = (min(max(ceil(CGFloat(chars) * charWidth) + 18, 60), 320) * Metrics.widthScale).rounded()
                col.minWidth = 40
                col.resizingMask = .userResizingMask
                table.addTableColumn(col)
            }
            let filler = NSTableColumn(identifier: Self.fillerID)
            filler.title = ""
            (filler.minWidth, filler.width, filler.resizingMask) = (Metrics.fillerWidth, Metrics.fillerWidth, .autoresizingMask)
            table.addTableColumn(filler)
        }
        numericColumns = numeric
        data = result
        table.reloadData()
        table.sizeLastColumnToFit()
        visibleColumns = []
    }

    // -12, 3.5, 1000: plain numbers as Postgres and SQLite print them. Stops at the first other character, so a
    // long text costs nothing. (Internal for tests, as is looksLikeJSON.)
    static func isNumber(_ s: String) -> Bool {
        var digits = 0, afterPoint = -1
        for (i, c) in s.utf8.enumerated() {
            switch c {
            case UInt8(ascii: "-") where i == 0: continue
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if afterPoint >= 0 { afterPoint += 1 } else { digits += 1 }
            case UInt8(ascii: "."):
                guard digits > 0, afterPoint < 0 else { return false }
                afterPoint = 0
            default: return false
            }
        }
        return digits > 0 && afterPoint != 0
    }

    // Postgres arrays look like objects ({1,2}); only {"…": or {} counts. For the colour only: cheap, not a parse.
    static func looksLikeJSON(_ s: String) -> Bool {
        var opened: UInt8 = 0
        for c in s.utf8 where c != 0x20 && c != 0x0a && c != 0x09 && c != 0x0d {
            if opened == 0 {
                guard c == UInt8(ascii: "{") || c == UInt8(ascii: "[") else { return false }
                if c == UInt8(ascii: "[") { return true }
                opened = c
            } else {
                return c == UInt8(ascii: "\"") || c == UInt8(ascii: "}")
            }
        }
        return false
    }

    // A JSON object or array (what the inspector shows).
    private static func isJSON(_ value: DBValue?) -> Bool {
        guard let s = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("{") || s.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
    }

    // MARK: - Changes

    private func clearChanges() {
        edits = [:]
        deletedRows = []
        insertedRows = []
        editRow = -1
        ringRow = -1
        if editor != nil { endEditor() } // its edit belonged to the rows just dropped
    }

    func discardChanges() {
        clearChanges()
        table.reloadData()
        changed()
    }

    private func changed() {
        onChange?()
    }

    private func isInserted(_ row: Int) -> Bool { row >= (data?.rows.count ?? 0) }

    // Current cell value; nil for an unset column of a new row (DEFAULT).
    func value(row: Int, column col: Int) -> DBValue? {
        guard let data else { return nil }
        if isInserted(row) {
            let i = row - data.rows.count
            return i < insertedRows.count ? insertedRows[i][col] : nil
        }
        return edits[row]?[col] ?? data.rows[row][col]
    }

    // Sets a value as a pending edit (internal for tests; callers use updateValue).
    func setCell(_ value: DBValue, row: Int, column col: Int) {
        guard let data else { return }
        if isInserted(row) {
            insertedRows[row - data.rows.count][col] = value
        } else {
            var rowEdits = edits[row] ?? [:]
            // the same text as the original is no change (SQLite values keep their storage class until saved)
            if data.rows[row][col].string == value.string { rowEdits.removeValue(forKey: col) } else { rowEdits[col] = value }
            edits[row] = rowEdits.isEmpty ? nil : rowEdits
        }
        reconfigure(rows: IndexSet(integer: row))
        changed()
    }

    // Setting a value as a pending edit, from outside (date picker, inspector, reference picker).
    func updateValue(_ value: DBValue, row: Int, column col: Int) {
        if editable && row >= 0 && row < table.numberOfRows && !deletedRows.contains(row) { setCell(value, row: row, column: col) }
    }

    func isRowDeleted(_ row: Int) -> Bool { deletedRows.contains(row) }

    func addRow() {
        guard editable, let data else { return }
        insertedRows.append([:])
        let row = data.rows.count + insertedRows.count - 1
        enteringRow = row
        table.insertRows(at: IndexSet(integer: row), withAnimation: [])
        if enteringRow == row, let view = loadedRowView(row) { slideIn(view) } // its view came without didAdd
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        changed()
    }

    // Calling it again on deleted rows restores them.
    func deleteSelectedRows() {
        let selected = table.selectedRowIndexes
        guard editable, !selected.isEmpty, let data else { return }
        let existing = data.rows.count
        var rows = IndexSet(), newRows = IndexSet()
        for row in selected {
            if row >= existing { newRows.insert(row - existing) } else { rows.insert(row) }
        }
        if !rows.isEmpty && deletedRows.isSuperset(of: rows) { deletedRows.subtract(rows) } else { deletedRows.formUnion(rows) }
        for i in newRows.reversed() { insertedRows.remove(at: i) } // a new row just disappears
        if newRows.isEmpty { reconfigure(rows: rows) } else { table.reloadData() }
        table.selectRowIndexes(rows, byExtendingSelection: false) // a second ⌫ must restore the same rows
        changed()
    }

    // MARK: - Selection and cell editing

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow, col = dataColumn(table.clickedColumn)
        if col >= 0 { selectedColumn = col }
        updateRing()
        guard col >= 0, row >= 0 else { return }
        // a click on the checkbox of a boolean, or on the ↗ / 🖼 badge
        let cell = cellRect(row: row, column: col)
        let click = table.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
        if click.x < cell.minX + Metrics.checkboxEnd - 2 && isBool(col) && editable && !deletedRows.contains(row) {
            return toggle(row: row, column: col)
        }
        if let view = table.view(atColumn: tableColumn(col), row: row, makeIfNecessary: false) as? GridCellView,
           view.badge != .none, view.badgeRect.insetBy(dx: -3, dy: -4).contains(view.convert(click, from: table)) { // a little slack
            let value = value(row: row, column: col)
            if hasReference(row: row, column: col), let onOpenReference { return onOpenReference(row, col, cell) }
            if hasFileValue(value, column: col), let onOpenFile { return onOpenFile(row, col, cell) }
            if let onOpenImage, isImageValue(value) { return onOpenImage(row, col, cell) }
        }
        onSelectCell?(row, col)
    }

    // Boolean columns show "☑ false", wider than the t / f the width was estimated from.
    private func columnKindsChanged() {
        widen(IndexSet(columnKinds.filter { $0.value == .bool }.keys), to: Metrics.boolWidth)
        reconfigure()
        table.headerView?.needsDisplay = true
    }

    // Columns at least this wide: for what new rows or booleans show instead of the values the width was estimated from.
    private func widen(_ columns: IndexSet, to width: CGFloat) {
        for col in columns where dataColumn(tableColumn(col)) >= 0 {
            let column = table.tableColumns[tableColumn(col)]
            column.width = max(column.width, width)
        }
    }

    private func isBool(_ col: Int) -> Bool { columnKinds[col] == .bool }

    private static func isTrue(_ value: DBValue?) -> Bool {
        guard let s = value?.string else { return false }
        return ["t", "true", "1"].contains(s.lowercased())
    }

    // true → false → true; NULL (or unset) → true. Set NULL is in the context menu.
    private func toggle(row: Int, column col: Int) {
        setCell(.text(Self.isTrue(value(row: row, column: col)) ? booleanFalse : booleanTrue), row: row, column: col)
    }

    private func cellRect(row: Int, column col: Int) -> NSRect {
        table.frameOfCell(atColumn: tableColumn(col), row: row)
    }

    private func hasFileValue(_ value: DBValue?, column col: Int) -> Bool {
        guard onOpenFile != nil, let value, let s = value.string, !s.isEmpty else { return false }
        if fileColumns.contains(col) { return s != "[]" } // a multi file field without files
        return detectsFileKeys && !fileKeys(in: value).isEmpty
    }

    private func hasReference(row: Int, column col: Int) -> Bool {
        referenceColumns.contains(col) && value(row: row, column: col)?.string != nil
    }

    // Double-click / Enter: foreign keys get the picker, JSON goes to the inspector, anything else is edited in place
    // (internal for tests).
    func activate(row: Int, column col: Int) {
        guard row >= 0, col >= 0, row < table.numberOfRows, col < (data?.columns.count ?? 0) else { return }
        let rect = cellRect(row: row, column: col)
        if let onPickReference, editable, referenceColumns.contains(col), !deletedRows.contains(row) {
            return onPickReference(row, col, rect)
        }
        let value = value(row: row, column: col)
        if let kind = columnKinds[col], editable, !deletedRows.contains(row) {
            if kind == .bool { return toggle(row: row, column: col) }
            // a value that isn't a date (e.g. Unix seconds in an SQLite DATETIME column) is edited as text
            let parses = value?.string.map { kind.date(from: $0) != nil } ?? true
            if let onPickDate, parses { return onPickDate(row, col, rect, kind) }
        }
        if let onOpenImage, isImageValue(value) { return onOpenImage(row, col, rect) } // raw image bytes aren't for editing by hand
        if let onOpenJSON, Self.isJSON(value) { return onOpenJSON(row, col) }
        beginEditing(row: row, column: col)
    }

    @objc private func openReference(_ sender: Any?) {
        let row = table.clickedRow, col = dataColumn(table.clickedColumn)
        onOpenReference?(row, col, cellRect(row: row, column: col))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selection = table.selectedRowIndexes
        let changedRows = selection.symmetricDifference(shownSelection) // their text colour changes
        shownSelection = selection
        updateRing(also: changedRows)
    }

    // The selected cell gets an accent ring (single row selection in an editable grid).
    private func updateRing(also rows: IndexSet = []) {
        let old = ringRow
        ringRow = editable && table.numberOfSelectedRows == 1 ? table.selectedRow : -1
        var refresh = rows
        if old >= 0 { refresh.insert(old) }
        if ringRow >= 0 { refresh.insert(ringRow) }
        reconfigure(rows: refresh)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        activate(row: table.clickedRow, column: dataColumn(table.clickedColumn))
    }

    // Internal for tests.
    func beginEditing(row: Int, column col: Int) {
        guard editable, row >= 0, col >= 0, row < table.numberOfRows, col < (data?.columns.count ?? 0), !deletedRows.contains(row) else { return }
        table.scrollRowToVisible(row)
        table.scrollColumnToVisible(tableColumn(col))
        editOriginal = value(row: row, column: col)?.string ?? ""
        editRow = row
        editColumn = col
        selectedColumn = col
        updateRing()

        // A text field exists only while editing, laid over the cell.
        editor?.removeFromSuperview()
        let field = GridEditor(frame: cellRect(row: row, column: col))
        field.alignment = isRightAligned(col) ? .right : .left
        field.stringValue = editOriginal
        field.delegate = self
        table.addSubview(field)
        editor = field
        window?.makeFirstResponder(field)
    }

    private func endEditor() {
        editor?.removeFromSuperview()
        editor = nil
        window?.makeFirstResponder(table)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let row = editRow, col = editColumn
        guard row >= 0, let editor else { return }
        editRow = -1
        let value = editor.stringValue
        let changed = value != editOriginal, shown = generation
        // after editing has ended, not in the middle of it
        Task { @MainActor [weak self] in
            guard let self else { return }
            endEditor()
            if changed && shown == generation { setCell(.text(value), row: row, column: col) }
        }
    }

    // Esc cancels editing without changing the value.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)) else { return false }
        editRow = -1
        control.abortEditing()
        endEditor()
        return true
    }

    // ⌫ deletes the selected rows, Enter edits the selected cell.
    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        if editable && (key == 51 || key == 117) { deleteSelectedRows() }
        else if (key == 36 || key == 76) && table.selectedRow >= 0 { activate(row: table.selectedRow, column: selectedColumn) }
        else { super.keyDown(with: event) }
    }

    // MARK: - Hover and motion

    // The row under the mouse is highlighted; a ↗ / 🖼 under it grows a little.
    fileprivate func hover(at point: NSPoint?) {
        let inside = point.map { table.visibleRect.contains($0) } ?? false
        let row = inside ? table.row(at: point!) : -1
        if row != hoverRow {
            loadedRowView(hoverRow)?.hovered = false
            hoverRow = row
            loadedRowView(row)?.hovered = true
        }
        var badgeCell: GridCellView?
        if let point, row >= 0, case let col = table.column(at: point), col >= 0,
           let cell = table.view(atColumn: col, row: row, makeIfNecessary: false) as? GridCellView,
           cell.badge != .none, cell.badgeRect.insetBy(dx: -3, dy: -4).contains(cell.convert(point, from: table)) {
            badgeCell = cell
        }
        if badgeCell !== hoveredBadge {
            hoveredBadge?.setBadgeHovered(false)
            badgeCell?.setBadgeHovered(true)
            hoveredBadge = badgeCell
        }
    }

    // The view of a row, if it has one; nil also for rows that no longer exist (AppKit throws for those).
    private func loadedRowView(_ row: Int) -> GridRowView? {
        row >= 0 && row < table.numberOfRows ? table.rowView(atRow: row, makeIfNecessary: false) as? GridRowView : nil
    }

    // The rows on screen enter staggered (call it after setting a new result).
    func animateRowsIn(_ style: RowEntrance = .rise) {
        entrance = (style, CACurrentMediaTime())
        table.enumerateAvailableRowViews { view, row in enter(view, row: row) }
    }

    private func enter(_ view: NSTableRowView, row: Int) {
        guard let entrance else { return }
        guard CACurrentMediaTime() - entrance.start < 0.25 else { return self.entrance = nil } // only rows of that first layout
        let i = row - table.rows(in: table.visibleRect).location
        guard i >= 0, i < 26 else { return }
        view.wantsLayer = true
        switch entrance.style {
        case .rise: Motion.enter(view.layer, dy: down(view, 6), duration: 0.36, delay: 0.014 * Double(i))
        case .slide: Motion.enter(view.layer, dx: -10, duration: 0.45, delay: 0.03 * Double(i))
        }
    }

    private func slideIn(_ view: NSTableRowView) {
        enteringRow = -1
        view.wantsLayer = true
        Motion.enter(view.layer, dx: -10, duration: 0.45)
    }

    // A translation `dy` points down in the table, whichever way its layer counts.
    private func down(_ view: NSView, _ dy: CGFloat) -> CGFloat {
        view.layer?.superlayer?.isGeometryFlipped == true ? dy : -dy
    }

    // MARK: - Menu and pasteboard

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let row = table.clickedRow, col = dataColumn(table.clickedColumn)
        let onCell = row >= 0 && col >= 0
        switch item.action {
        case #selector(copyValue(_:)): return onCell
        case #selector(openReference(_:)):
            item.isHidden = !referenceColumns.contains(col)
            return onCell && onOpenReference != nil && hasReference(row: row, column: col)
        case #selector(setNull(_:)): return editable && onCell && !deletedRows.contains(row)
        case #selector(deleteClickedRows(_:)):
            item.isHidden = !editable
            if let menu = item.menu, menu.index(of: item) > 0 { menu.item(at: menu.index(of: item) - 1)?.isHidden = !editable } // its separator
            if row >= 0 { item.title = deleteTitle(forRow: row) }
            return editable && row >= 0
        case #selector(copy(_:)): return !table.selectedRowIndexes.isEmpty
        default: return true
        }
    }

    private func text(row: Int, column col: Int) -> String { value(row: row, column: col)?.string ?? "" }

    @objc private func copyValue(_ sender: Any?) {
        copyLocally(.general, text: text(row: table.clickedRow, column: dataColumn(table.clickedColumn)))
    }

    // ⌘C: selected rows as tab-separated text, ready to paste into a spreadsheet.
    @objc func copy(_ sender: Any?) {
        copyLocally(.general, text: selectedRowsText())
    }

    // Internal for tests.
    func selectedRowsText() -> String {
        let columns = data?.columns.count ?? 0
        return table.selectedRowIndexes.map { row in (0..<columns).map { text(row: row, column: $0) }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    @objc private func setNull(_ sender: Any?) {
        setCell(.null, row: table.clickedRow, column: dataColumn(table.clickedColumn))
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int {
        data.map { $0.rows.count + insertedRows.count } ?? 0
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let view = tableView.makeView(withIdentifier: id, owner: nil) as? GridRowView ?? GridRowView()
        view.identifier = id
        configure(view, row: row)
        return view
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        if row == enteringRow { slideIn(rowView) } else { enter(rowView, row: row) }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, data != nil, tableColumn.identifier != Self.fillerID else { return nil }
        let isGutter = tableColumn.identifier == Self.gutterID
        if isGutter && !showsRowNumbers { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? GridCellView ?? GridCellView()
        cell.identifier = id
        configure(cell, row: row, column: isGutter ? -1 : Int(tableColumn.identifier.rawValue) ?? 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let onSort, let index = table.tableColumns.firstIndex(of: tableColumn), case let col = dataColumn(index), col >= 0,
              let name = data?.columns[col] else { return }
        if sortColumn != name { (sortColumn, sortAscending) = (name, true) }
        else if sortAscending { sortAscending = false }
        else { sortColumn = nil }
        table.headerView?.needsDisplay = true
        onSort(sortColumn, sortAscending)
    }

    // Brings visible cells (and rows) up to date in place, so their fills animate. Rows without views get theirs
    // when they scroll into view.
    private func reconfigure(rows: IndexSet? = nil) {
        guard data != nil else { return }
        table.enumerateAvailableRowViews { rowView, row in
            guard rows?.contains(row) ?? true, let rowView = rowView as? GridRowView else { return }
            configure(rowView, row: row)
            for c in 0..<rowView.numberOfColumns {
                guard let cell = rowView.view(atColumn: c) as? GridCellView else { continue }
                configure(cell, row: row, column: dataColumn(c) >= 0 ? dataColumn(c) : -1)
            }
        }
    }

    private func configure(_ view: GridRowView, row: Int) {
        let inserted = isInserted(row), deleted = !inserted && deletedRows.contains(row)
        let key = GridRowView.Key(generation: generation, row: row)
        let animated = view.shownKey == key
        view.shownKey = key
        view.configure(base: deleted ? Theme.del : inserted ? Theme.add : nil, zebra: row % 2 == 1, hovered: row == hoverRow,
                       selected: table.isRowSelected(row), animated: animated)
    }

    // column -1: the row number.
    private func configure(_ cell: GridCellView, row: Int, column col: Int) {
        let key = GridCellView.Key(generation: generation, row: row, column: col)
        let animated = cell.shownKey == key
        cell.shownKey = key
        let inserted = isInserted(row), deleted = !inserted && deletedRows.contains(row), selected = table.isRowSelected(row)

        if col < 0 {
            let number = inserted ? "+" : String(row + 1 + rowNumberOffset)
            cell.update(text: NSAttributedString(string: number, attributes: [
                .font: CellStyle.number, .foregroundColor: selected ? Theme.selT : Theme.t3, .paragraphStyle: CellStyle.right,
            ]), rightAligned: true, padding: (Metrics.inset, 10), guide: false, fill: nil, ring: false, checkbox: .none, badge: .none,
                        animated: animated)
            return
        }

        let edited = !inserted && edits[row]?[col] != nil
        let value = value(row: row, column: col)
        let isDefault = value == nil && defaultColumns.contains(col)
        let string = value?.string, placeholder = string == nil
        let isBool = isBool(col) && !isDefault // NULL gets an empty box too
        let shown: String
        if isDefault { shown = "DEFAULT" }
        else if placeholder { shown = nullText }
        else if isBool { shown = Self.isTrue(value) ? "true" : "false" } // Postgres prints t / f, SQLite 1 / 0
        else {
            // Only what fits in the column (monospace: ~7.5 pt per character) gets laid out.
            let fits = Int(table.tableColumns[tableColumn(col)].width / 7) + 2
            shown = String(string!.prefix(fits)).replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        // marked like a search match: matched through the row this key points to, or the search term anywhere in it
        // (ignoring case, as the search)
        let matched = string.map { s in
            highlightedValues?[col]?.contains(s) == true || (highlight.map { !$0.isEmpty && s.range(of: $0, options: .caseInsensitive) != nil } ?? false)
        } ?? false
        let color: NSColor = placeholder ? Theme.t3
            : matched ? Theme.findT
            : columnColors[col] ?? (isBool && !Self.isTrue(value) ? Theme.t2 : !isBool && Self.looksLikeJSON(string!) ? Theme.t2
                : selected ? Theme.selT : Theme.t1)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: placeholder ? CellStyle.italic : CellStyle.regular, .foregroundColor: color,
            .paragraphStyle: isRightAligned(col) ? CellStyle.right : CellStyle.left,
        ]
        if deleted { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let ring = row == ringRow && col == selectedColumn && !deleted
        let fill: NSColor? = deleted ? nil : edited ? Theme.chg : matched ? Theme.find : ring ? Theme.selCell : nil
        let badge: GridCellView.Badge = placeholder ? .none
            : referenceColumns.contains(col) ? .reference
            : hasFileValue(value, column: col) || (onOpenImage != nil && isImageValue(value)) ? .image : .none
        cell.update(text: NSAttributedString(string: shown, attributes: attrs), rightAligned: isRightAligned(col),
                    padding: (Metrics.cellPad, Metrics.cellPad), guide: true, fill: fill, ring: ring,
                    checkbox: !isBool ? .none : Self.isTrue(value) ? .on : .off, badge: badge, animated: animated)
    }

    // The sticky header: titles right-aligned over numbers, the sort arrow after the title.
    fileprivate func drawHeader(column index: Int, in rect: NSRect) {
        let col = dataColumn(index)
        guard col >= 0, let name = data?.columns[col] else { return }
        Theme.vline.setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        let font = Theme.font(11.5, .medium)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.t2, .paragraphStyle: style]
        let arrowAttrs: [NSAttributedString.Key: Any] = [.font: Theme.font(10, .semibold), .foregroundColor: Theme.acc]
        let arrow = sortColumn == name ? (sortAscending ? "↑" : "↓") : nil
        let inner = rect.insetBy(dx: Metrics.cellPad, dy: 0)
        let arrowWidth = arrow.map { ceil($0.size(withAttributes: arrowAttrs).width) + 4 } ?? 0
        let titleWidth = max(0, min(ceil(name.size(withAttributes: titleAttrs).width), inner.width - arrowWidth))
        let x = isRightAligned(col) ? inner.maxX - arrowWidth - titleWidth : inner.minX
        let height = ceil(font.ascender - font.descender)
        name.draw(with: NSRect(x: x, y: floor(rect.midY - height / 2), width: titleWidth, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: titleAttrs)
        if let arrow {
            let size = arrow.size(withAttributes: arrowAttrs)
            arrow.draw(at: NSPoint(x: x + titleWidth + 4, y: floor(rect.midY - size.height / 2)), withAttributes: arrowAttrs)
        }
    }
}

private enum Metrics {
    static let rowHeight: CGFloat = 34, rowGap: CGFloat = 1, inset: CGFloat = 8, radius: CGFloat = 8
    static let headerHeight: CGFloat = 34, headerGap: CGFloat = 6
    static let numberWidth: CGFloat = 52, cellPad: CGFloat = 12, fillerWidth: CGFloat = 32
    static let boolWidth: CGFloat = 84, defaultWidth: CGFloat = 80 // ☑ false, DEFAULT (7 × 7.5 pt) with the padding
    static let widthScale: CGFloat = 1.12
    static let checkbox: CGFloat = 14, badge: CGFloat = 14, gap: CGFloat = 6
    static let checkboxEnd = cellPad + checkbox + gap // the checkbox and its gap: text starts here
    static let scroller: CGFloat = 11
}

@MainActor private enum CellStyle {
    static let regular = Theme.mono(12.5)
    static let number = Theme.mono(11)
    // Geist Mono has no italic: NULL and DEFAULT get the regular face slanted.
    static let italic: NSFont = {
        let converted = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
        if converted.fontDescriptor.symbolicTraits.contains(.italic) { return converted }
        let slant = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
        return NSFont(descriptor: regular.fontDescriptor.withMatrix(slant), size: regular.pointSize) ?? regular
    }()
    static let left = paragraph(.left), right = paragraph(.right)
    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byClipping // GridCellView adds the ellipsis itself
        p.alignment = alignment
        return p
    }
}

// Sets a layer property, animating from what is on screen when `duration` > 0. Views' own layers don't animate
// implicitly, other layers would: both get an explicit animation or none.
@MainActor private func setLayer(_ layer: CALayer, _ key: String, from: Any?, duration: CFTimeInterval, timing: CAMediaTimingFunction = Motion.ease,
                                 _ change: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    change()
    CATransaction.commit()
    guard duration > 0 else { return layer.removeAnimation(forKey: key) }
    let a = CABasicAnimation(keyPath: key)
    a.fromValue = from
    a.duration = Motion.reduced ? min(duration, 0.15) : duration
    a.timingFunction = Motion.reduced ? Motion.ease : timing
    layer.add(a, forKey: key)
}

// A transform scaling a view's layer about its centre (AppKit keeps the anchor at the corner).
private func scaled(_ bounds: CGRect, _ s: CGFloat) -> CATransform3D {
    CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0), s, s, 1), -bounds.midX, -bounds.midY, 0)
}

// Table with hover tracking and smooth scrolling to a row (↑ / ↓, a new row, editing).
private final class GridTable: NSTableView {
    weak var grid: GridView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        grid?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        grid?.hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        grid?.hover(at: nil)
    }

    override func scrollRowToVisible(_ row: Int) {
        guard !Motion.reduced, window?.isVisible == true, row >= 0, row < numberOfRows, let scroll = enclosingScrollView else {
            return super.scrollRowToVisible(row)
        }
        let target = rect(ofRow: row), visible = visibleRect
        let dy = target.minY < visible.minY ? target.minY - visible.minY : target.maxY > visible.maxY ? target.maxY - visible.maxY : 0
        guard dy != 0 else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.y += dy
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = Motion.ease
            clip.animator().setBoundsOrigin(origin)
        }
        scroll.reflectScrolledClipView(clip)
    }
}

// Row with a rounded fill (selected, deleted, added, hovered, zebra) in a layer of its own, so changes fade.
private final class GridRowView: RowView {
    struct Key: Equatable { var generation, row: Int }
    var shownKey = Key(generation: -1, row: -1)
    private var zebra = false
    private let fillLayer = CALayer()
    private var shownColor: NSColor?
    private var configuring = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        fillLayer.cornerRadius = Metrics.radius
        fillLayer.cornerCurve = .continuous
        layer?.insertSublayer(fillLayer, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}

    override var isSelected: Bool { didSet { if !configuring { updateFill(selected: isSelected, animated: true) } } }
    override var hovered: Bool { didSet { if !configuring { updateFill(selected: isSelected, animated: true) } } }

    func configure(base: NSColor?, zebra: Bool, hovered: Bool, selected: Bool, animated: Bool) {
        configuring = true
        (baseColor, self.zebra, self.hovered) = (base, zebra, hovered)
        configuring = false
        updateFill(selected: selected, animated: animated)
    }

    private func color(selected: Bool) -> NSColor? {
        selected ? selectionColor ?? Theme.sel : baseColor ?? (hovered ? Theme.hover : zebra ? Theme.zebra : nil)
    }

    private func updateFill(selected: Bool, animated: Bool, force: Bool = false) {
        let color = color(selected: selected)
        guard force || color !== shownColor else { return }
        shownColor = color
        var cg: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color?.cgColor }
        let from = fillLayer.presentation()?.backgroundColor ?? fillLayer.backgroundColor
        setLayer(fillLayer, "backgroundColor", from: from, duration: animated && !force ? 0.22 : 0) { fillLayer.backgroundColor = cg }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill(selected: isSelected, animated: false, force: true)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // behind the cells, leaving the row gap below clear (the layer counts from the bottom
        // unless its geometry is flipped)
        let height = min(Metrics.rowHeight, newSize.height)
        let y = isFlipped != (layer?.isGeometryFlipped ?? false) ? newSize.height - height : 0
        fillLayer.frame = CGRect(x: inset, y: y, width: max(0, newSize.width - 2 * inset), height: height)
        CATransaction.commit()
    }
}

// Grid cell that draws one line of text (and its column guide) itself: no NSTextField and no constraints. With
// hundreds of visible cells, a text field per cell (its own layer, backing store and layout) made scrolling miss
// frames. Its layer carries the fill and the ring, which animate; a checkbox (booleans) and a ↗ / 🖼 badge are
// small subviews, made when first needed.
private final class GridCellView: NSView {
    enum Badge { case none, reference, image }
    enum Checkbox { case none, off, on }
    struct Key: Equatable { var generation, row, column: Int }
    var shownKey = Key(generation: -1, row: -1, column: 0)
    private(set) var badge = Badge.none
    var badgeRect: NSRect { badge == .none ? .zero : badgeView?.frame ?? .zero } // for clicks

    private var text = NSAttributedString()
    private var rightAligned = false, guide = true
    private var padding: (left: CGFloat, right: CGFloat) = (12, 12)
    private var fill: NSColor?, ring = false
    private var checkbox = Checkbox.none
    private var checkboxView: CheckboxView?
    private var badgeView: BadgeView?
    // laid out for the current width
    private var shownText = NSAttributedString(), textRect = NSRect.zero

    private static var charWidths: [NSFont: CGFloat] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(text: NSAttributedString, rightAligned: Bool, padding: (CGFloat, CGFloat), guide: Bool, fill: NSColor?, ring: Bool,
                checkbox: Checkbox, badge: Badge, animated: Bool) {
        (self.text, self.rightAligned, self.padding, self.guide) = (text, rightAligned, padding, guide)
        let fillChanged = fill !== self.fill, ringChanged = ring != self.ring
        (self.fill, self.ring) = (fill, ring)
        if fillChanged || ringChanged || !animated { applyLayer(fill: fillChanged && animated, ring: ringChanged && animated) }

        self.checkbox = checkbox
        if checkbox != .none && checkboxView == nil {
            let box = CheckboxView(frame: NSRect(x: 0, y: 0, width: Metrics.checkbox, height: Metrics.checkbox))
            addSubview(box)
            checkboxView = box
        }
        checkboxView?.isHidden = checkbox == .none
        checkboxView?.set(checkbox == .on, animated: animated)

        if badge != self.badge || !animated { badgeView?.setHovered(false, animated: false) } // another value, or another cell
        self.badge = badge
        if badge != .none && badgeView == nil {
            let view = BadgeView(frame: NSRect(x: 0, y: 0, width: Metrics.badge, height: Metrics.badge))
            addSubview(view)
            badgeView = view
        }
        badgeView?.isHidden = badge == .none
        badgeView?.kind = badge
        layoutContent()
        needsDisplay = true
    }

    func setBadgeHovered(_ hovered: Bool) {
        badgeView?.setHovered(hovered, animated: true)
    }

    private func applyLayer(fill animateFill: Bool, ring animateRing: Bool) {
        guard let layer else { return }
        var (background, border): (CGColor?, CGColor?) = (nil, nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = fill?.cgColor
            border = Theme.ring.cgColor
        }
        setLayer(layer, "backgroundColor", from: layer.presentation()?.backgroundColor ?? layer.backgroundColor,
                 duration: animateFill ? 0.3 : 0) { layer.backgroundColor = background }
        layer.borderColor = border
        setLayer(layer, "borderWidth", from: layer.presentation()?.borderWidth ?? layer.borderWidth,
                 duration: animateRing ? 0.18 : 0) { layer.borderWidth = ring ? 1.5 : 0 }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayer(fill: false, ring: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { layoutContent() }
    }

    // Cells use monospaced fonts, so the cut for the ellipsis is plain arithmetic. Letting the
    // typesetter truncate (NSStringDrawingTruncatesLastVisibleLine) took most of the drawing time.
    private func layoutContent() {
        let (width, height) = (bounds.width, bounds.height)
        var left = padding.left
        if checkbox != .none {
            checkboxView?.setFrameOrigin(NSPoint(x: left, y: floor((height - Metrics.checkbox) / 2)))
            left += Metrics.checkbox + Metrics.gap
        }
        let attrs = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
        let font = attrs[.font] as? NSFont
        let available = max(0, width - left - padding.right - (badge != .none ? Metrics.badge + Metrics.gap : 0))
        var shown = text
        var charWidth: CGFloat = 0
        if let font {
            charWidth = Self.charWidths[font] ?? {
                let w = "0".size(withAttributes: [.font: font]).width
                Self.charWidths[font] = w
                return w
            }()
            let fits = max(Int(floor((available + 0.5) / charWidth)), 1)
            if text.length > fits {
                let keep = (text.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: fits - 1))
                let cut = NSMutableAttributedString(attributedString: text.attributedSubstring(from: keep))
                cut.append(NSAttributedString(string: "…", attributes: attrs))
                shown = cut
            }
        }
        shownText = shown
        let line = font.map { ceil($0.ascender - $0.descender + $0.leading) } ?? 16
        textRect = NSRect(x: left, y: floor((height - line) / 2), width: available, height: line)
        if badge != .none { // right after the text; after right-aligned (numeric) text that is the right edge
            let textWidth = font != nil ? min(CGFloat(shown.length) * charWidth, available) : available
            let x = rightAligned ? width - padding.right - Metrics.badge : left + textWidth + Metrics.gap
            badgeView?.setFrameOrigin(NSPoint(x: x, y: floor((height - Metrics.badge) / 2)))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit redraws a whole row (all columns, ~6000 pt wide) when the grid scrolls sideways.
        // Cells off screen skip their drawing; GridView redraws cells as their columns scroll into view.
        // (self.visibleRect isn't reliable here: during that row redraw it isn't clipped by the scroll view.)
        guard let scroll = enclosingScrollView, convert(bounds, to: scroll.documentView).intersects(scroll.documentVisibleRect) else { return }
        if guide {
            Theme.vline.setFill()
            NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        shownText.draw(with: textRect, options: .usesLineFragmentOrigin)
    }

    // VoiceOver reads the value like a label.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { text.string }
}

// Boolean cell's box; the tick springs in when checked.
private final class CheckboxView: NSView {
    private let tick = TickView(frame: NSRect(x: 0, y: 0, width: Metrics.checkbox, height: Metrics.checkbox))
    private var on: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1.2
        tick.wantsLayer = true
        addSubview(tick)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ on: Bool, animated: Bool) {
        let changed = on != self.on
        let animate = animated && changed && self.on != nil
        self.on = on
        guard changed else { return }
        applyColors(animated: animate)
        guard let tl = tick.layer else { return }
        let target = scaled(tick.bounds, on ? 1 : 0.3)
        let fromTransform = tl.presentation()?.transform ?? tl.transform, fromOpacity = tl.presentation()?.opacity ?? tl.opacity
        tick.alphaValue = on ? 1 : 0
        setLayer(tl, "transform", from: nil, duration: 0) { tl.transform = target }
        guard animate else { return tl.removeAllAnimations() }
        tl.add(Motion.spring("transform", from: NSValue(caTransform3D: fromTransform), to: NSValue(caTransform3D: target), duration: 0.35),
               forKey: "transform")
        let fade = CABasicAnimation(keyPath: "opacity")
        (fade.fromValue, fade.toValue, fade.duration) = (fromOpacity, on ? 1 : 0, 0.15)
        tl.add(fade, forKey: "opacity")
    }

    private func applyColors(animated: Bool) {
        guard let layer else { return }
        var (fill, border): (CGColor?, CGColor?) = (nil, nil)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = on == true ? Theme.acc.cgColor : NSColor.clear.cgColor
            border = (on == true ? Theme.acc : Theme.cbOff).cgColor
        }
        setLayer(layer, "backgroundColor", from: layer.presentation()?.backgroundColor ?? layer.backgroundColor,
                 duration: animated ? 0.22 : 0) { layer.backgroundColor = fill }
        setLayer(layer, "borderColor", from: layer.presentation()?.borderColor ?? layer.borderColor,
                 duration: animated ? 0.22 : 0) { layer.borderColor = border }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors(animated: false)
    }
}

private final class TickView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 3.8, y: 7.3))
        p.line(to: NSPoint(x: 6.1, y: 9.6))
        p.line(to: NSPoint(x: 10.3, y: 4.6))
        (p.lineWidth, p.lineCapStyle, p.lineJoinStyle) = (1.7, .round, .round)
        NSColor.white.setStroke()
        p.stroke()
    }
}

// ↗ (foreign key) or a small picture (image, file) after a value, growing while the mouse is over it.
private final class BadgeView: NSView {
    var kind = GridCellView.Badge.reference { didSet { if kind != oldValue { needsDisplay = true } } }
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard hovered != self.hovered, let layer else { return }
        self.hovered = hovered
        let from = layer.presentation()?.transform ?? layer.transform
        setLayer(layer, "transform", from: NSValue(caTransform3D: from), duration: animated ? 0.2 : 0, timing: Motion.springCurve) {
            layer.transform = scaled(bounds, hovered ? 1.18 : 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.fkT.set()
        let p = NSBezierPath()
        (p.lineCapStyle, p.lineJoinStyle) = (.round, .round)
        if kind == .reference { // ↗ in a 7 × 7 box
            let o = NSPoint(x: 3.5, y: 3.5)
            p.move(to: NSPoint(x: o.x + 1.2, y: o.y + 5.8))
            p.line(to: NSPoint(x: o.x + 5.6, y: o.y + 1.4))
            p.move(to: NSPoint(x: o.x + 2.4, y: o.y + 1.2))
            p.line(to: NSPoint(x: o.x + 5.8, y: o.y + 1.2))
            p.line(to: NSPoint(x: o.x + 5.8, y: o.y + 4.6))
            p.lineWidth = 1.3
            p.stroke()
        } else { // picture: frame, hills and a sun in a 10 × 8 box
            let o = NSPoint(x: 2, y: 3)
            let frame = NSBezierPath(roundedRect: NSRect(x: o.x + 0.6, y: o.y + 0.6, width: 8.8, height: 6.8), xRadius: 1.2, yRadius: 1.2)
            frame.lineWidth = 1.1
            frame.stroke()
            p.move(to: NSPoint(x: o.x + 1.6, y: o.y + 6.4))
            p.line(to: NSPoint(x: o.x + 4, y: o.y + 3.8))
            p.line(to: NSPoint(x: o.x + 5.6, y: o.y + 5.3))
            p.line(to: NSPoint(x: o.x + 6.8, y: o.y + 4.2))
            p.line(to: NSPoint(x: o.x + 8.4, y: o.y + 6.4))
            p.lineWidth = 1
            p.stroke()
            NSBezierPath(ovalIn: NSRect(x: o.x + 6.1, y: o.y + 1.6, width: 1.6, height: 1.6)).fill()
        }
    }
}

// The inline editor: an opaque field with an outline at the cell's edge.
private final class GridEditor: NSTextField {
    override class var cellClass: AnyClass? {
        get { EditorCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = CellStyle.regular
        textColor = Theme.t1
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 2
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.panelSolid.cgColor
            layer?.borderColor = Theme.acc.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

// Text inset and centred vertically, also while editing.
private final class EditorCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let r = super.drawingRect(forBounds: rect).insetBy(dx: 6, dy: 0)
        let height = cellSize(forBounds: rect).height
        return NSRect(x: r.minX, y: rect.minY + floor((rect.height - height) / 2), width: r.width, height: height)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

// Header background and bottom line; the titles are drawn by GridView.
private final class GridHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.hbg.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.headerHeight).fill()
        Theme.line.setFill()
        NSRect(x: 0, y: Metrics.headerHeight, width: bounds.width, height: 1).fill()
        guard let table = tableView, let grid = (table as? GridTable)?.grid else { return }
        for i in 0..<table.numberOfColumns {
            let r = headerRect(ofColumn: i)
            guard r.intersects(dirtyRect) else { continue }
            grid.drawHeader(column: i, in: NSRect(x: r.minX, y: 0, width: r.width, height: Metrics.headerHeight))
        }
    }
}

// Above the vertical scroll bar, continuing the header.
private final class HeaderCorner: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        Theme.hbg.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.headerHeight).fill()
        Theme.line.setFill()
        NSRect(x: 0, y: Metrics.headerHeight, width: bounds.width, height: 1).fill()
    }
}

// Slim, always visible scroll bar: a clear track (the panel shows through) and a rounded knob.
private final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        Metrics.scroller
    }

    private var horizontal: Bool { bounds.width > bounds.height }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob)
        knob = horizontal ? knob.insetBy(dx: 2, dy: (knob.height - 7) / 2) : knob.insetBy(dx: (knob.width - 7) / 2, dy: 2)
        Theme.t3.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 3.5, yRadius: 3.5).fill()
    }
}

import AppKit

// Sheets for changing the schema from the diagram: "Add Column…" and "Add Foreign Key…". Both show the exact SQL
// as the fields change and only run it on Execute; the owner executes it and reports back. A database error stays
// in the sheet; success closes it.
final class SchemaSheet: NSWindowController, NSComboBoxDelegate {
    private enum Kind { case addColumn, addForeignKey }

    // Runs the statement; call `done` with nil on success (the sheet closes) or the error (shown in the sheet).
    var onRun: ((String, @escaping (Error?) -> Void) -> Void)?
    // The Execute button's fill on production; the connection's colour when it has one.
    var productionColor: NSColor = Theme.prod {
        didSet {
            styleRun()
            productionBadge?.fillColor = productionColor
        }
    }

    private let kind: Kind
    private let table: SchemaTable
    private var tables: [SchemaTable] = []
    private let production: Bool
    private var productionBadge: Panel?
    // Add Column (internal for the tests)
    let nameField = SchemaSheet.field("")
    let typeField = NSComboBox()
    let notNullBox = NSButton(checkboxWithTitle: "NOT NULL", target: nil, action: nil)
    let defaultField = SchemaSheet.field(L("none"))
    // Add Foreign Key
    let columnPopup = NSPopUpButton()
    let refTablePopup = NSPopUpButton()
    let refColumnPopup = NSPopUpButton()
    let onDeletePopup = NSPopUpButton()
    // both
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = wrappingLabel("", 12, Theme.red)
    private lazy var run = PillButton(L("Execute"), style: .accent, target: self, action: #selector(runClicked))
    private lazy var cancel = PillButton(L("Cancel"), target: self, action: #selector(cancelClicked))
    private let progress = spinner(.small)

    static func addColumn(for table: SchemaTable, types: [String], production: Bool) -> SchemaSheet {
        let sheet = SchemaSheet(kind: .addColumn, table: table, production: production)
        sheet.typeField.addItems(withObjectValues: types)
        if let text = types.first(where: { $0.caseInsensitiveCompare("text") == .orderedSame }) { // text first: the type most new columns get
            sheet.typeField.stringValue = text
        }
        sheet.typeField.completes = true
        sheet.typeField.font = Theme.mono(12)
        sheet.typeField.delegate = sheet
        sheet.notNullBox.target = sheet
        sheet.notNullBox.action = #selector(changed)
        sheet.notNullBox.font = Theme.mono(12)
        for f in [sheet.nameField, sheet.defaultField] { f.delegate = sheet }
        sheet.build(title: String(format: L("Add a column to %@"), table.name), rows: [
            (L("Name:"), sheet.nameField), (L("Type:"), sheet.typeField), ("", sheet.notNullBox), (L("Default:"), sheet.defaultField),
        ])
        return sheet
    }

    // `column`: preselected (the row that was right-clicked), or nil for the table's first column that isn't the
    // primary key or already a key.
    static func addForeignKey(for table: SchemaTable, column: String?, tables: [SchemaTable], production: Bool) -> SchemaSheet {
        let sheet = SchemaSheet(kind: .addForeignKey, table: table, production: production)
        sheet.tables = tables.sorted { $0.qualifiedName < $1.qualifiedName }
        for p in [sheet.columnPopup, sheet.refTablePopup, sheet.refColumnPopup, sheet.onDeletePopup] {
            p.target = sheet
            p.action = #selector(changed)
            p.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }
        for p in [sheet.columnPopup, sheet.refTablePopup, sheet.refColumnPopup] { p.font = Theme.mono(12) }
        sheet.columnPopup.addItems(withTitles: table.columns.map(\.name))
        let preselect = column ?? table.columns.first { $0.key != "PK" && !table.foreignKeyColumns.contains($0.name) }?.name
        if let preselect { sheet.columnPopup.selectItem(withTitle: preselect) }
        sheet.refTablePopup.addItems(withTitles: sheet.tables.map(\.qualifiedName))
        sheet.onDeletePopup.addItems(withTitles: [L("No Action"), "CASCADE", "SET NULL"])
        sheet.onDeletePopup.font = Theme.font(12.5)
        sheet.build(title: String(format: L("Add a foreign key to %@"), table.name), rows: [
            (L("Column:"), sheet.columnPopup), (L("References:"), sheet.refTablePopup), (L("Referenced column:"), sheet.refColumnPopup),
            (L("On delete:"), sheet.onDeletePopup),
        ])
        sheet.referencedTableChanged()
        return sheet
    }

    private static func field(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = Theme.mono(12)
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return f
    }

    private init(kind: Kind, table: SchemaTable, production: Bool) {
        (self.kind, self.table, self.production) = (kind, table, production)
        super.init(window: NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(title: String, rows: [(String, NSView)]) {
        // [PRODUCTION] title, on one line
        let heading = NSView(), titleLabel = label(title, 14, .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        heading.addSubview(titleLabel)
        var titleLeading = heading.leadingAnchor, gap: CGFloat = 0
        if production {
            let b = badge(L("PRODUCTION"), .white, productionColor)
            b.translatesAutoresizingMaskIntoConstraints = false
            heading.addSubview(b)
            NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo: heading.leadingAnchor), b.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)])
            (titleLeading, gap, productionBadge) = (b.trailingAnchor, 8, b)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titleLeading, constant: gap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: heading.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: heading.bottomAnchor),
        ])

        let grid = NSGridView(views: rows.map { r in
            [r.0.isEmpty ? NSGridCell.emptyContentView : label(r.0, 12.5, .regular, Theme.t2), r.1]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 10

        let sqlLabel = label(L("This SQL will run:"), 11.5, .semibold, Theme.t2)
        preview.isSelectable = true
        preview.preferredMaxLayoutWidth = 436
        let box = Panel(fill: Theme.edBg2, border: Theme.line, radius: 10)
        pin(preview, box, NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        errorLabel.preferredMaxLayoutWidth = 460
        errorLabel.isHidden = true
        let note = wrappingLabel(L("Production: this changes the schema of the production database."), 12, Theme.red)
        note.preferredMaxLayoutWidth = 460
        note.isHidden = !production

        cancel.keyEquivalent = "\u{1b}"
        run.keyEquivalent = "\r"
        styleRun()
        let buttons = bar([progress], [cancel, run], height: 28, left: 0, right: 0)

        let content = column([heading, grid, sqlLabel, box, errorLabel, note, buttons],
                             insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), spacing: 12)
        content.setCustomSpacing(6, after: sqlLabel)
        content.setCustomSpacing(16, after: note)
        content.widthAnchor.constraint(equalToConstant: 500).isActive = true
        window?.contentView = content
        changed(nil)
    }

    private func styleRun() {
        run.style = production ? .custom(productionColor, .white) : .accent
    }

    func beginSheet(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        window.makeFirstResponder(kind == .addColumn ? nameField : columnPopup)
    }

    // MARK: - Fields

    func controlTextDidChange(_ notification: Notification) {
        changed(nil)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { self.changed(nil) } // the combo's text updates after this call
    }

    // After any field changed: the statement again, Execute only when it is complete. (Internal for the tests.)
    @objc func changed(_ sender: Any?) {
        if let sender = sender as? NSPopUpButton, sender === refTablePopup { return referencedTableChanged() }
        let sql = self.sql
        let lines = NSMutableParagraphStyle()
        (lines.minimumLineHeight, lines.maximumLineHeight) = (19, 19)
        lines.headIndent = ceil(("    " as NSString).size(withAttributes: [.font: Theme.mono(12)]).width) // a wrapped clause stays indented
        let text = NSTextStorage(string: sql ?? L("Fill in the fields above."), attributes: [
            .font: Theme.mono(12), .paragraphStyle: lines, .foregroundColor: Theme.t3,
        ])
        if sql != nil { sqlHighlight(text) }
        preview.attributedStringValue = text
        run.isEnabled = sql != nil
        errorLabel.isHidden = true
    }

    // The referenced table's columns, its primary key preselected.
    private func referencedTableChanged() {
        let ref = referencedTable
        refColumnPopup.removeAllItems()
        refColumnPopup.addItems(withTitles: ref?.columns.map(\.name) ?? [])
        if let pk = ref?.columns.first(where: { $0.key == "PK" }) { refColumnPopup.selectItem(withTitle: pk.name) }
        changed(nil)
    }

    private var referencedTable: SchemaTable? {
        let i = refTablePopup.indexOfSelectedItem
        return i >= 0 && i < tables.count ? tables[i] : nil
    }

    // The statement as it stands, nil while incomplete.
    var sql: String? {
        let space = CharacterSet.whitespacesAndNewlines
        switch kind {
        case .addColumn:
            let name = nameField.stringValue.trimmingCharacters(in: space), type = typeField.stringValue.trimmingCharacters(in: space)
            guard !name.isEmpty, !type.isEmpty else { return nil }
            return addColumnStatement(schema: table.schema, table: table.name, column: name, type: type, notNull: notNullBox.state == .on,
                                      defaultExpr: defaultField.stringValue.trimmingCharacters(in: space))
        case .addForeignKey:
            guard let column = columnPopup.titleOfSelectedItem, !column.isEmpty, let ref = referencedTable,
                  let refColumn = refColumnPopup.titleOfSelectedItem, !refColumn.isEmpty else { return nil }
            let onDelete = onDeletePopup.indexOfSelectedItem > 0 ? onDeletePopup.titleOfSelectedItem ?? "" : ""
            return addForeignKeyStatement(schema: table.schema, table: table.name, column: column, refSchema: ref.schema, refTable: ref.name,
                                          refColumn: refColumn, onDelete: onDelete)
        }
    }

    // What the SQL box shows, the error shown (nil when none) and whether Execute can be clicked; for the tests.
    var previewText: String { preview.stringValue }
    var errorText: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var canRun: Bool { run.isEnabled }

    // MARK: - Buttons

    @objc private func runClicked(_ sender: Any?) {
        guard let sql, let onRun else { return }
        run.isEnabled = false
        cancel.isEnabled = false
        progress.startAnimation(nil)
        onRun(sql) { [weak self] error in
            guard let self else { return }
            progress.stopAnimation(nil)
            run.isEnabled = true
            cancel.isEnabled = true
            guard let error else { return close() }
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        close()
    }

    override func close() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
    }
}

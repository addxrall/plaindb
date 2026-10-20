// The schema sheets, the foreign key popovers and the diagram's hit-testing, without a database. `make test`.
@testable import PlainDBKit
import AppKit

@main enum SheetsTest {
    // orders (id PK, customer_id FK, status, note) → customers (id PK, name); crm.contacts (id PK)
    @MainActor static func graph() -> SchemaGraph {
        SchemaGraph(columns: DBResult(rows: [
            ["public", "orders", "id", "integer", "PK"], ["public", "orders", "customer_id", "integer", ""],
            ["public", "orders", "status", "text", ""], ["public", "orders", "note", "text", ""],
            ["public", "customers", "id", "integer", "PK"], ["public", "customers", "name", "text", ""],
            ["crm", "contacts", "code", "text", "PK"], ["crm", "contacts", "email", "text", ""],
        ]), foreignKeys: DBResult(rows: [["public", "orders", "customer_id", "public", "customers", "id"]]))
    }

    @MainActor static func addColumn() {
        let orders = graph().table(named: "public.orders")!
        let sheet = SchemaSheet.addColumn(for: orders, types: ["integer", "TEXT", "boolean"], production: false)
        // the type starts as text (in the engine's spelling); nothing to run without a name
        check(sheet.typeField.stringValue == "TEXT")
        check(sheet.sql == nil && !sheet.canRun && sheet.previewText == L("Fill in the fields above."))
        sheet.nameField.stringValue = "  paid "
        sheet.changed(nil)
        check(sheet.sql == addColumnStatement(schema: "public", table: "orders", column: "paid", type: "TEXT", notNull: false, defaultExpr: ""))
        check(sheet.canRun && sheet.previewText == sheet.sql)
        sheet.typeField.stringValue = "boolean"
        sheet.notNullBox.state = .on
        sheet.defaultField.stringValue = "false"
        sheet.changed(nil)
        check(sheet.sql == "ALTER TABLE \"public\".\"orders\" ADD COLUMN \"paid\" boolean NOT NULL DEFAULT false;")
        sheet.typeField.stringValue = " "
        sheet.changed(nil)
        check(sheet.sql == nil && !sheet.canRun)
        // no text type offered: the type starts empty
        check(SchemaSheet.addColumn(for: orders, types: ["INTEGER"], production: true).typeField.stringValue.isEmpty)
    }

    @MainActor static func addForeignKey() {
        let g = graph()
        let orders = g.table(named: "public.orders")!
        // the first column that is neither the primary key nor already a key; referenced tables sorted, their PK chosen
        let sheet = SchemaSheet.addForeignKey(for: orders, column: nil, tables: g.tables, production: false)
        check(sheet.columnPopup.titleOfSelectedItem == "status")
        check(sheet.refTablePopup.itemTitles == ["crm.contacts", "public.customers", "public.orders"])
        check(sheet.refColumnPopup.itemTitles == ["code", "email"] && sheet.refColumnPopup.titleOfSelectedItem == "code")
        check(sheet.sql == addForeignKeyStatement(schema: "public", table: "orders", column: "status", refSchema: "crm", refTable: "contacts",
                                                  refColumn: "code", onDelete: ""))
        // another referenced table: its columns, its key
        sheet.refTablePopup.selectItem(withTitle: "public.customers")
        sheet.changed(sheet.refTablePopup)
        check(sheet.refColumnPopup.itemTitles == ["id", "name"] && sheet.refColumnPopup.titleOfSelectedItem == "id")
        sheet.onDeletePopup.selectItem(withTitle: "CASCADE")
        sheet.changed(sheet.onDeletePopup)
        check(sheet.sql?.hasSuffix("REFERENCES \"public\".\"customers\" (\"id\")\n  ON DELETE CASCADE;") == true)
        sheet.onDeletePopup.selectItem(at: 0) // No Action: no clause
        sheet.changed(sheet.onDeletePopup)
        check(sheet.sql?.contains("ON DELETE") == false)
        // the right-clicked row is preselected
        check(SchemaSheet.addForeignKey(for: orders, column: "note", tables: g.tables, production: true).columnPopup.titleOfSelectedItem == "note")
    }

    @MainActor static func running() {
        let sheet = SchemaSheet.addColumn(for: graph().table(named: "public.orders")!, types: ["text"], production: false)
        sheet.nameField.stringValue = "note"
        sheet.changed(nil)
        var ran: [String] = [], finish: ((Error?) -> Void)?
        sheet.onRun = { sql, done in
            ran.append(sql)
            finish = done
        }
        let run = sheet.window!.contentView!.descendants.compactMap { $0 as? PillButton }.first { $0.title == L("Execute") }!
        run.performClick(nil)
        check(ran == [sheet.sql!] && !sheet.canRun) // waiting for the database
        finish?(DBError("column \"note\" already exists"))
        check(sheet.errorText == "column \"note\" already exists" && sheet.canRun) // the error stays in the sheet
        sheet.changed(nil)
        check(sheet.errorText == nil) // until a field changes
        run.performClick(nil)
        finish?(nil) // success closes the sheet (not shown here: nothing to end)
        check(ran.count == 2 && sheet.canRun)
    }

    @MainActor static func highlighting() {
        let text = NSTextStorage(string: "ALTER TABLE \"t\" ADD COLUMN \"n\" text DEFAULT 'a' || now() + 12; -- x")
        sqlHighlight(text)
        func color(_ word: String) -> NSColor? {
            text.attribute(.foregroundColor, at: (text.string as NSString).range(of: word).location, effectiveRange: nil) as? NSColor
        }
        check(color("ALTER") == Theme.kw && color("DEFAULT") == Theme.kw)
        check(color("'a'") == Theme.str && color("now") == Theme.fn && color("12") == Theme.num && color("-- x") == Theme.cm)
        check(color("\"t\"") == Theme.t1 && color("text") == Theme.t1) // names and types as the text
    }

    @MainActor static func popovers() {
        // values: NULL, newlines shown, long ones cut
        check(referenceShownValue(.null) == "NULL" && referenceShownValue("a\nb") == "a ⏎ b" && referenceShownValue(.integer("7")) == "7")
        check(referenceShownValue(.text(String(repeating: "x", count: 301))) == String(repeating: "x", count: 300) + "…")

        // the preview: every field, NULLs marked; no row → nil (the "doesn't exist" message)
        let row = DBResult(columns: ["id", "name", "note"], rows: [["4131", "Ada", .null]])
        let fields = ReferencePreview.fields(row)!
        check(fields.map(\.column) == ["id", "name", "note"] && fields.map(\.value) == ["4131", "Ada", "NULL"] && fields.map(\.isNull) == [false, false, true])
        check(ReferencePreview.fields(DBResult(columns: ["id"], rows: [])) == nil)
        let preview = ReferencePreview(title: "customers", subtitle: "id = 4131", result: row)
        check(preview.view.fittingSize.width == ReferencePreview.width)
        var opened = 0
        preview.onOpenTable = { opened += 1 }
        preview.view.descendants.compactMap { $0 as? PillButton }.first?.performClick(nil)
        check(opened == 1)

        // the picker's rows: the key, then up to four other non-empty values, each at most 40 characters
        let long = String(repeating: "y", count: 45)
        let text = ReferencePicker.rowText(["7", "", .null, "a\nb", .text(long), "c", "d", "e"], keyIndex: 0)
        check(text.key == "7" && text.rest == "a b · " + String(repeating: "y", count: 40) + "… · c · d")
        check(ReferencePicker.rowText([.null, "x"], keyIndex: 0) == ("NULL", "x"))
        check(ReferencePicker.rowText(["1", "x"], keyIndex: nil) == ("", "1 · x"))
        check(ReferencePicker.statusText(DBResult(columns: ["id"], rows: []), error: nil) == L("Nothing found"))
        check(ReferencePicker.statusText(nil, error: DBError("canceling statement due to statement timeout")) == "canceling statement due to statement timeout")
        check(ReferencePicker.statusText(DBResult(columns: ["id"], rows: [["1"], ["2"]]), error: nil) == LN("%lu rows", 2))

        // picking: the selected row's key value as returned (its storage class kept), or NULL
        let picker = ReferencePicker(column: "customer_id", table: "customers", keyColumn: "id")
        var picked: [DBValue] = []
        picker.onPick = { picked.append($0) }
        _ = picker.view
        picker.showResult(DBResult(columns: ["name", "id"], rows: [["Ada", .integer("1")], ["Grace", .integer("2")]]), error: nil)
        let buttons = picker.view.descendants.compactMap { $0 as? PillButton }
        buttons.first { $0.title == L("Choose") }!.performClick(nil) // the first row starts selected
        buttons.first { $0.title == L("Set NULL") }!.performClick(nil)
        check(picked == [.integer("1"), .null])
    }

    @MainActor static func diagram() {
        let g = graph()
        schemaLayout(g, focus: nil, saved: [:])
        let view = DiagramView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        check(view.contentRect == .zero && view.exportData(pdf: false) == nil)
        view.graph = g
        let all = g.tables.reduce(CGRect.null) { $0.union($1.frame) }
        check(view.contentRect == CGRect(x: 0, y: 0, width: all.maxX + 24, height: all.maxY + 24))
        check(view.frame.size == view.contentRect.size) // fitted (no scroll view: nothing visible to fill)
        let orders = g.table(named: "public.orders")!
        check(view.frames["public.orders"] == orders.frame && view.frames.count == 3)

        // hits: boxes, nothing between them; rows below the 30 pt header (2 pt in), 20 pt each
        check(view.table(at: CGPoint(x: orders.frame.midX, y: orders.frame.midY)) === orders)
        check(view.table(at: CGPoint(x: 1, y: 1)) == nil)
        let x = orders.frame.midX, top = orders.frame.minY
        check(view.column(at: CGPoint(x: x, y: top + 10), in: orders) == nil) // header
        check(view.column(at: CGPoint(x: x, y: top + 33), in: orders) == "id")
        check(view.column(at: CGPoint(x: x, y: top + 32 + 20 * 3 + 5), in: orders) == "note")
        check(view.column(at: CGPoint(x: x, y: top + 32 + 20 * 4 + 1), in: orders) == nil) // below the last row
        // overlapping boxes: the selected one is on top
        let customers = g.table(named: "public.customers")!
        customers.frame.origin = orders.frame.origin
        check(view.table(at: CGPoint(x: x, y: top + 40)) === g.tables.last { $0.frame.contains(CGPoint(x: x, y: top + 40)) })
        view.selected = orders
        check(view.table(at: CGPoint(x: x, y: top + 40)) === orders)
        // a new graph starts unselected
        view.graph = g
        check(view.selected == nil)

        // Reset Layout: boxes spring from the old frames; the model frames are already the new ones
        let old = view.frames
        schemaLayout(g, focus: nil, saved: [:])
        view.graph = g
        view.animateLayout(from: old)
        check(old["public.customers"] != view.frames["public.customers"])

        // the box menu, right-clicked on a row of orders: blocked items disabled with the reason as tooltip
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.documentView = view
        window.contentView = scroll
        view.fitToContent()
        var added: [(String, String?)] = []
        view.onAddColumn = { added.append(($0.name, nil)) }
        view.onAddForeignKey = { added.append(($0.name, $1)) }
        view.addForeignKeyBlockedReason = "SQLite can't"
        let p = CGPoint(x: orders.frame.midX, y: orders.frame.minY + 32 + 20 * 2 + 10) // the status row
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = view.menu(for: event)!
        check(view.selected === orders)
        check(menu.items.map(\.title) == [L("Open Table"), L("Open in New Tab"), L("Show Neighbours"), "", L("Add Column…"), L("Add Foreign Key…")])
        check(menu.items[4].isEnabled && menu.items[4].toolTip == nil)
        check(!menu.items[5].isEnabled && menu.items[5].toolTip == "SQLite can't")
        menu.performActionForItem(at: 4)
        NSApplication.shared.sendAction(menu.items[5].action!, to: menu.items[5].target, from: menu.items[5]) // what it would do if it were enabled
        check(added.count == 2 && added[0] == ("orders", nil) && added[1] == ("orders", "status"))
        // without onAddColumn: no schema editing items; on the background: no menu
        view.onAddColumn = nil
        check(view.menu(for: event)!.items.count == 3)
        let away = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(CGPoint(x: 2, y: 2), to: nil), modifierFlags: [],
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        check(view.menu(for: away) == nil)

        // export: PNG at 2× of the content rect, and PDF
        let png = view.exportData(pdf: false).flatMap(NSBitmapImageRep.init(data:))
        check(png?.pixelsWide == Int(view.contentRect.width) * 2 && png?.pixelsHigh == Int(view.contentRect.height) * 2)
        check(view.exportData(pdf: true)?.starts(with: Array("%PDF".utf8)) == true)
    }

    @MainActor static func main() {
        addColumn()
        addForeignKey()
        running()
        highlighting()
        popovers()
        diagram()
        print("sheets_test: OK")
    }
}

extension NSView {
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}

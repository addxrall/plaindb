// GridView: swapping in a shorter result while rows are visible must not crash; change model and ⌫ handling.
@testable import PlainDBKit
import AppKit

@main enum GridTest {
    // Ending an edit is asynchronous; under load (the whole `make test`) a fixed short wait wasn't always enough.
    @MainActor static func waitForEditorToClose(_ grid: GridView) {
        let limit = Date(timeIntervalSinceNow: 2)
        while grid.editor != nil && limit.timeIntervalSinceNow > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
    }

    static func result(_ columns: [String], _ rows: Int) -> DBResult {
        DBResult(columns: columns, rows: (0..<rows).map { r in columns.map { _ in .text(String(r)) } })
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let grid = GridView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = grid

        // scroll bars stay classic (visible) even if the system asks for overlay ones
        grid.scrollerStyle = .overlay
        check(grid.scrollerStyle == .legacy && grid.hasHorizontalScroller)
        // in a translucent panel: the grid paints no background
        check(!grid.drawsBackground && !grid.contentView.drawsBackground && grid.table.backgroundColor == .clear)

        grid.result = result(["a", "b"], 50)
        window.layoutIfNeeded()
        grid.displayIfNeeded()
        check(grid.table.rowView(atRow: 10, makeIfNecessary: false) != nil) // rows really exist
        // rows 34 high plus a 1 pt gap, header 34 + its line + a 6 pt gap
        check(grid.table.rowHeight == 34 && grid.table.rect(ofRow: 1).minY == 35)
        check(grid.table.headerView?.frame.height == 41)
        // row numbers 52 wide after the 8 pt inset, then the data columns, then a filler taking the rest of the width
        check(grid.table.numberOfColumns == 4 && grid.table.tableColumns[0].width == 60)
        check(grid.table.rect(ofColumn: 3).maxX >= grid.contentView.bounds.width - 1)
        check(grid.table.tableColumns[1].width == (60 * 1.12).rounded()) // today's minimum width × 1.12
        grid.animateRowsIn() // must not disturb anything

        grid.result = result(["x", "y", "z"], 3) // used to crash here
        window.layoutIfNeeded()
        grid.displayIfNeeded()
        check(grid.table.numberOfRows == 3 && grid.table.numberOfColumns == 5) // 3 data columns + row numbers + filler

        // editing: changes are collected locally
        grid.editable = true
        grid.setCell("nowa", row: 0, column: 1)
        grid.setCell("1", row: 1, column: 0) // same value as the original = no change
        check(grid.changeCount == 1 && grid.edits[0]?[1] == "nowa" && grid.edits[1] == nil)
        // the same text in another storage class (an SQLite integer) is no change either
        grid.setCell(.integer("1"), row: 1, column: 0)
        check(grid.changeCount == 1)

        // cell editing: a text field appears over the cell only while editing, Enter/focus change commits
        grid.beginEditing(row: 2, column: 0)
        check(grid.editor?.stringValue == "2" && grid.editor?.superview === grid.table)
        check(grid.editor?.frame == grid.table.frameOfCell(atColumn: 1, row: 2)) // the outline sits at the cell's edge
        grid.editor?.stringValue = "typed"
        window.makeFirstResponder(grid.table) // ends editing
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1)) // the commit is async
        check(grid.edits[2]?[0] == "typed" && grid.editor == nil)
        grid.setCell("2", row: 2, column: 0) // back to the original: no change

        // Esc cancels: no change
        grid.beginEditing(row: 2, column: 0)
        grid.editor?.stringValue = "discarded"
        let field = grid.editor!, fieldEditor = field.currentEditor() as! NSTextView
        check(grid.control(field, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        waitForEditorToClose(grid)
        check(grid.edits[2] == nil && grid.editor == nil)

        // double-click / Enter: JSON opens the inspector, other values are edited in place
        var openedRow = -1
        grid.onOpenJSON = { row, _ in openedRow = row }
        grid.setCell("{\"a\": [1, 2]}", row: 1, column: 1)
        grid.activate(row: 1, column: 1)
        check(openedRow == 1 && grid.editor == nil)
        grid.activate(row: 0, column: 2)
        check(grid.editor != nil)
        window.makeFirstResponder(grid.table)
        waitForEditorToClose(grid)
        grid.setCell("1", row: 1, column: 1) // back to the original
        // a Postgres array isn't JSON: edited in place
        grid.setCell("{1,2}", row: 1, column: 1)
        grid.activate(row: 1, column: 1)
        check(openedRow == 1 && grid.editor != nil)
        window.makeFirstResponder(grid.table)
        waitForEditorToClose(grid)
        grid.setCell("1", row: 1, column: 1)

        // foreign key columns: editing opens the picker instead of a text field (only in editable grids)
        var pickedColumn = -1
        grid.referenceColumns = [2]
        grid.onPickReference = { _, column, _ in pickedColumn = column }
        grid.activate(row: 0, column: 2)
        check(pickedColumn == 2 && grid.editor == nil)
        grid.editable = false
        pickedColumn = -1
        grid.activate(row: 0, column: 2)
        check(pickedColumn == -1)
        grid.editable = true
        grid.referenceColumns = []

        // boolean columns toggle t ↔ f instead of opening a text field; NULL toggles to true
        grid.columnKinds = [0: .bool]
        check(grid.table.tableColumns[1].width >= 84) // room for the checkbox and "false"
        grid.setCell("t", row: 2, column: 0)
        grid.activate(row: 2, column: 0)
        check(grid.value(row: 2, column: 0) == "f" && grid.editor == nil)
        grid.setCell(.null, row: 2, column: 0)
        grid.activate(row: 2, column: 0)
        check(grid.value(row: 2, column: 0) == "t")
        grid.setCell("2", row: 2, column: 0) // back to the original
        grid.columnKinds = [:]

        // SQLite booleans: 1 / 0, read in either form
        grid.booleanTrue = "1"
        grid.booleanFalse = "0"
        grid.columnKinds = [0: .bool]
        grid.setCell("1", row: 2, column: 0)
        grid.activate(row: 2, column: 0)
        check(grid.value(row: 2, column: 0) == "0")
        grid.setCell("t", row: 2, column: 0)
        grid.activate(row: 2, column: 0)
        check(grid.value(row: 2, column: 0) == "0")
        grid.setCell(.null, row: 2, column: 0)
        grid.activate(row: 2, column: 0)
        check(grid.value(row: 2, column: 0) == "1")
        grid.setCell("2", row: 2, column: 0)
        grid.booleanTrue = "t"
        grid.booleanFalse = "f"

        // a date column whose value isn't a date (e.g. Unix seconds) is edited as text, not with the calendar
        var pickedDate = false
        grid.onPickDate = { _, _, _, _ in pickedDate = true }
        grid.columnKinds = [0: .timestamp]
        grid.activate(row: 2, column: 0) // value "2"
        check(!pickedDate && grid.editor != nil)
        window.makeFirstResponder(grid.table)
        waitForEditorToClose(grid)
        grid.setCell("2025-04-04 12:00:00", row: 2, column: 0) // a real one gets the calendar
        grid.activate(row: 2, column: 0)
        check(pickedDate && grid.editor == nil)
        grid.setCell("2", row: 2, column: 0)
        grid.columnKinds = [:]
        grid.onPickDate = nil

        // ⌫ in the table must reach GridView through the responder chain
        grid.table.selectRowIndexes([2], byExtendingSelection: false)
        let backspace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        grid.table.keyDown(with: backspace)
        check(grid.deletedRows.contains(2) && grid.changeCount == 2)
        grid.table.keyDown(with: backspace) // second press restores
        check(grid.deletedRows.isEmpty)

        // right-click "Delete Row": the clicked row, or the whole selection when the click is inside it
        grid.table.selectRowIndexes([0], byExtendingSelection: false)
        // (titles through LN: the test binary has no .lproj, so they come out as the keys)
        check(grid.deleteTitle(forRow: 2) == LN("Delete %lu rows", 1))
        grid.toggleDeletion(fromRow: 2) // outside the selection: only row 2
        check(grid.deletedRows == [2])
        check(grid.deleteTitle(forRow: 2) == LN("Restore %lu rows", 1))
        grid.table.selectRowIndexes([0, 1], byExtendingSelection: false)
        check(grid.deleteTitle(forRow: 1) == LN("Delete %lu rows", 2))
        grid.toggleDeletion(fromRow: 1) // inside the selection: rows 0 and 1
        check(grid.deletedRows.count == 3)
        grid.toggleDeletion(fromRow: 0) // again: restores the selection, row 2 stays deleted
        check(grid.deletedRows == [2])
        // a deleted row can't be edited, also not from outside (inspector, pickers)
        grid.updateValue("x", row: 2, column: 0)
        check(grid.edits[2] == nil)
        grid.toggleDeletion(fromRow: 2)
        check(grid.deletedRows.isEmpty)

        // edits per cell, and the cells of deleted rows don't count
        grid.setCell("a", row: 0, column: 0)
        grid.setCell("b", row: 0, column: 1)
        grid.setCell("c", row: 1, column: 0)
        check(grid.editedCellCount == 3 && grid.changeCount == 2)
        grid.toggleDeletion(fromRow: 1)
        check(grid.editedCellCount == 2 && grid.changeCount == 2)
        grid.discardChanges()
        check(grid.changeCount == 0 && grid.edits.isEmpty && grid.deletedRows.isEmpty)

        grid.addRow()
        check(grid.table.numberOfRows == 4 && grid.insertedRows.count == 1 && grid.table.selectedRow == 3)
        check(grid.value(row: 3, column: 2) == nil) // unset: DEFAULT
        grid.setCell(.null, row: 3, column: 2)
        check(grid.insertedRows[0][2] == .null)
        grid.deleteSelectedRows() // the new row is selected: it disappears entirely
        check(grid.table.numberOfRows == 3 && grid.changeCount == 0)

        // header clicks sort ascending, then descending, then not at all
        var sorts: [String] = []
        grid.onSort = { column, ascending in sorts.append("\(column ?? "-") \(ascending)") }
        for _ in 0..<3 { grid.tableView(grid.table, didClick: grid.table.tableColumns[2]) }
        grid.tableView(grid.table, didClick: grid.table.tableColumns[0]) // the row numbers: nothing
        grid.tableView(grid.table, didClick: grid.table.tableColumns[1])
        grid.tableView(grid.table, didClick: grid.table.tableColumns[2]) // another column starts ascending
        check(sorts == ["y true", "y false", "- false", "x true", "y true"])
        grid.resetSort()
        grid.tableView(grid.table, didClick: grid.table.tableColumns[2])
        check(sorts.last == "y true")

        // ⌘C: the selected rows, tab-separated, edits included and NULL as nothing
        grid.table.selectRowIndexes([0, 2], byExtendingSelection: false)
        grid.updateValue(.null, row: 2, column: 1)
        check(grid.validateMenuItem(NSMenuItem(title: "", action: #selector(GridView.copy(_:)), keyEquivalent: "")))
        check(grid.selectedRowsText() == "0\t0\t0\n2\t\t2")
        grid.discardChanges()

        // numbers are right-aligned (the editor too), text and booleans left
        grid.beginEditing(row: 0, column: 0)
        check(grid.editor?.alignment == .right)
        window.makeFirstResponder(grid.table)
        waitForEditorToClose(grid)
        grid.columnKinds = [0: .bool]
        grid.beginEditing(row: 0, column: 0)
        check(grid.editor?.alignment == .left)
        window.makeFirstResponder(grid.table)
        waitForEditorToClose(grid)
        grid.columnKinds = [:]
        check(GridView.isNumber("-12") && GridView.isNumber("3.5") && GridView.isNumber("1000"))
        check(!GridView.isNumber("1.") && !GridView.isNumber(".5") && !GridView.isNumber("-") && !GridView.isNumber("1e5")
              && !GridView.isNumber("") && !GridView.isNumber("1-2") && !GridView.isNumber("1.2.3"))
        // Postgres arrays look like JSON but aren't
        check(GridView.looksLikeJSON(" {\"a\": 1}") && GridView.looksLikeJSON("[1]") && GridView.looksLikeJSON("{}"))
        check(!GridView.looksLikeJSON("{1,2}") && !GridView.looksLikeJSON("text") && !GridView.looksLikeJSON(""))

        // DEFAULT has to fit in the columns that have one
        grid.defaultColumns = [1]
        check(grid.table.tableColumns[2].width >= 80)

        grid.result = result([], 0) // a new result clears changes
        check(grid.table.numberOfRows == 0 && grid.changeCount == 0)
        // copies stay on this Mac and are marked so clipboard managers don't keep them (a private pasteboard here)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        copyLocally(board, text: "anna.kowalska@example.com")
        check(board.string(forType: .string) == "anna.kowalska@example.com")
        let types = board.types ?? []
        check(types.contains(.init("org.nspasteboard.ConcealedType")) && types.contains(.init("org.nspasteboard.TransientType")))
        let dot = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { r in r.fill(); return true }
        copyLocally(board, text: nil, image: dot)
        check((board.data(forType: .png)?.count ?? 0) > 0 && board.string(forType: .string) == nil)
        check(board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true)
        board.releaseGlobally()
        print("grid_test: OK")
    }
}

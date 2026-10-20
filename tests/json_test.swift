// JSON helpers behind the JSON inspector (formatting keeps key order and never touches string contents), the
// inspector itself, SQL highlighting and the completion list: `make test`.
@testable import PlainDBKit
import AppKit

@main enum JSONTest {
    @MainActor static func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let src = "{\"zeta\":1,\"alpha\":{\"b\":[1,2,{\"c\":null}],\"a\":\"x, {y}: [z] \\\"q\\\"\"},\"empty\":{},\"list\":[],\"t\":true}"

        let pretty = jsonPretty(src)
        check(pretty.hasPrefix("{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"b\": [\n      1,"))
        check(pretty.contains("\"a\": \"x, {y}: [z] \\\"q\\\"\"")) // string untouched
        check(pretty.contains("\"empty\": {},\n  \"list\": [],"))  // empty containers stay on one line
        check(jsonMinify(pretty) == src)                            // round trip, key order kept
        check(jsonMinify("{ \"a b\" : [ 1 , \"  \\\\\" ] }") == "{\"a b\":[1,\"  \\\\\"]}") // spaces in strings kept, escaped backslash ends no string

        check(jsonIsValid(src) && jsonIsValid("  [1, 2]  ") && !jsonIsValid("{\"a\": }") && !jsonIsValid("42") && !jsonIsValid(nil as String?))
        check(!jsonIsValid("hello") && !jsonIsValid(DBValue.null))
        check(jsonIsValid(DBValue.text("{\"a\":1}")) && !jsonIsValid(DBValue.text("")))

        guard let root = jsonParse(src) else { fatalError("no tree") }
        check(root.kind == .object && root.children.count == 5)
        check(root.children[0].key == "zeta" && root.children[1].key == "alpha") // order
        let alpha = root.children[1]
        check(alpha.children[0].kind == .array && alpha.children[0].children.count == 3)
        check(alpha.children[0].children[2].children[0].kind == .null)
        check(alpha.children[0].children[2].key == nil && alpha.children[0].children[2].index == 2)
        check(alpha.children[1].kind == .string && alpha.children[1].text == "x, {y}: [z] \"q\"")
        check(root.children[4].kind == .bool && root.children[4].text == "true")
        check(jsonParse("{\"a\": }") == nil)
        check(jsonParse("[-1.5e3, \"\\u00e9\\n\"]")?.children.map(\.text) == ["-1.5e3", "é\n"])
        check(jsonParse("[1] x") == nil && jsonParse("[nul]") == nil && jsonParse(String(repeating: "[", count: 300) + String(repeating: "]", count: 300)) == nil)

        // SQL highlighting
        let sql = NSTextStorage(string: "SELECT count(id), 'it''s' FROM t -- note\nLIMIT 42")
        sqlHighlight(sql)
        let s = sql.string as NSString
        check(color(sql, at: 0) === Theme.kw)                                        // SELECT
        check(color(sql, at: s.range(of: "count").location) === Theme.fn)
        check(color(sql, at: s.range(of: "id").location) === Theme.t1)               // plain word
        check(color(sql, at: s.range(of: "'it''s'").location + 4) === Theme.str)    // '' stays inside the string
        check(color(sql, at: s.range(of: "-- note").location + 4) === Theme.cm)
        check(color(sql, at: s.range(of: "42").location) === Theme.num)

        // the editor: gutter 40 wide, Geist Mono (or the system mono) 12.5 on 20 pt lines, SQL colours as it's edited
        let (editor, editorText) = sqlTextScrollView(editable: true, lineNumbers: true)
        check(editor.verticalRulerView?.ruleThickness == 40 && editor.rulersVisible && editorText.isEditable)
        check(!editorText.isAutomaticQuoteSubstitutionEnabled && !editorText.isRichText && editorText.layoutManager != nil)
        editorText.string = "select 1"
        editorText.rehighlight()
        let lines = editorText.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        check(lines?.minimumLineHeight == 20 && lines?.maximumLineHeight == 20)
        check(color(editorText.textStorage!, at: 0) === Theme.kw && editorText.textContainerOrigin.x == 4)
        check(sqlTextScrollView(editable: false, lineNumbers: false).scroll.verticalRulerView == nil)

        // JSON highlighting
        let json = NSTextStorage(string: "{\"k\": \"v\", \"n\": -2.5, \"b\": null}")
        jsonHighlight(json)
        let j = json.string as NSString
        check(color(json, at: 1) === Theme.fn && color(json, at: j.range(of: "\"v\"").location) === Theme.str)
        check(color(json, at: j.range(of: "-2.5").location) === Theme.num && color(json, at: j.range(of: "null").location) === Theme.kw)

        // the inspector
        let inspector = JSONInspector()
        var applied: [String] = []
        var closed = false
        inspector.onApply = { applied.append($0) }
        inspector.onClose = { closed = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = inspector.view
        window.layoutIfNeeded()
        check(inspector.pages.selectedIndex == 2 && inspector.titleLabel.stringValue == L("JSON") && !inspector.applyButton.isEnabled)

        inspector.showJSON(src, title: "meta", subtitle: "orders · id 10231 · jsonb", editable: true)
        check(inspector.pages.selectedIndex == 0 && inspector.titleLabel.stringValue == "meta")
        check(inspector.textView.string == pretty && inspector.statusLabel.stringValue == "✓ " + L("Valid JSON"))
        check(inspector.statusLabel.textColor === Theme.green && !inspector.applyButton.isEnabled && inspector.formatButton.isEnabled)
        // containers open, except objects inside arrays: zeta, alpha, b, 1, 2, [2], a, empty, list, t
        let outline = inspector.outline
        check(outline.numberOfRows == 10)
        let item2 = outline.item(atRow: 5) as? JSONNode
        check(item2?.index == 2 && item2?.key == nil && !outline.isItemExpanded(item2))
        outline.expandItem(item2)
        check(outline.numberOfRows == 11 && (outline.item(atRow: 6) as? JSONNode)?.key == "c")

        // editing the text: Apply only for a valid change, with the minified JSON
        inspector.mode.select(1, animated: false)
        inspector.mode.onChange?(1)
        check(inspector.pages.selectedIndex == 1)
        inspector.textView.string = "{\"zeta\": 2}"
        inspector.textDidChange(Notification(name: NSText.didChangeNotification))
        check(inspector.applyButton.isEnabled)
        inspector.applyButton.performClick(nil)
        check(applied == ["{\"zeta\":2}"] && !inspector.applyButton.isEnabled)
        inspector.textView.string = "{\"zeta\": }"
        inspector.textDidChange(Notification(name: NSText.didChangeNotification))
        check(inspector.statusLabel.stringValue.hasPrefix("✕ ") && inspector.statusLabel.textColor === Theme.red)
        check(!inspector.applyButton.isEnabled && !inspector.formatButton.isEnabled)
        // no tree for broken JSON
        inspector.mode.select(0, animated: false)
        inspector.mode.onChange?(0)
        check(inspector.mode.selectedIndex == 1 && inspector.pages.selectedIndex == 1)
        // Format re-indents
        inspector.textView.string = "{\"a\":[1,2]}"
        inspector.formatButton.isEnabled = true
        inspector.formatButton.performClick(nil)
        check(inspector.textView.string == "{\n  \"a\": [\n    1,\n    2\n  ]\n}")

        // read-only: no Format / Apply
        inspector.showJSON("[{\"a\":1}]", title: "x", subtitle: "", editable: false)
        check(inspector.applyButton.isHidden && inspector.formatButton.isHidden && !inspector.textView.isEditable)
        inspector.showPlaceholder()
        check(inspector.pages.selectedIndex == 2 && inspector.statusLabel.stringValue.isEmpty && closed == false)

        // the completion list: becomes the delegate, inserts the chosen word
        let (_, sqlView) = sqlTextScrollView(editable: true, lineNumbers: true)
        let completer = SQLCompleter(textView: sqlView)
        check(sqlView.delegate === completer && !completer.isShown)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = sqlView
        host.orderFront(nil) // the list is a child window, shown only with a visible parent
        sqlView.string = "sel"
        sqlView.setSelectedRange(NSRange(location: 3, length: 0))
        completer.show()
        check(completer.isShown)
        check(completer.textView(sqlView, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        check(sqlView.string == "select" && !completer.isShown)
        // a function gets its parentheses, the cursor between them
        sqlView.string = "select coun"
        sqlView.setSelectedRange(NSRange(location: 11, length: 0))
        completer.show()
        check(completer.textView(sqlView, doCommandBy: #selector(NSResponder.insertTab(_:))))
        check(sqlView.string == "select count()" && sqlView.selectedRange() == NSRange(location: 13, length: 0))
        // Esc closes the list
        sqlView.string = "se"
        sqlView.setSelectedRange(NSRange(location: 2, length: 0))
        completer.show()
        check(completer.isShown && completer.textView(sqlView, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && !completer.isShown)
        completer.show()
        completer.hide()
        check(!completer.isShown && !completer.textView(sqlView, doCommandBy: #selector(NSResponder.moveDown(_:))))

        host.orderOut(nil)
        print("json_test: OK")
    }
}

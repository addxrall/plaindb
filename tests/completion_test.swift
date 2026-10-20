// SQL completion: what the editor offers at the cursor. `make test`.
@testable import PlainDBKit
import Foundation

@main enum CompletionTest {
    // "|" marks the cursor
    static func run(_ sql: String, _ g: SchemaGraph) -> (texts: [String], replace: NSRange) {
        let cursor = (sql as NSString).range(of: "|").location
        let r = sqlSuggestions(sql.replacingOccurrences(of: "|", with: ""), cursor: cursor, schema: g)
        return (r.suggestions.map(\.text), r.replace)
    }

    static func texts(_ sql: String, _ g: SchemaGraph) -> [String] { run(sql, g).texts }

    static func main() {
        let columns: [[DBValue]] = [
            ["public", "claims", "id", "integer", "PK"], ["public", "claims", "driver_id", "integer", ""],
            ["public", "claims", "amount", "numeric", ""], ["public", "drivers", "id", "integer", "PK"],
            ["public", "drivers", "last_name", "text", ""], ["crm", "contacts", "id", "integer", "PK"],
        ]
        let g = SchemaGraph(columns: DBResult(rows: columns), foreignKeys: DBResult())

        // after FROM / JOIN: tables
        check(texts("SELECT * FROM cl|", g) == ["claims"])
        check(texts("select * from claims c join dr|", g) == ["drivers"])
        check(texts("SELECT * FROM con|", g) == ["crm.contacts"]) // other schemas qualified
        // after "alias." or "table.": that table's columns, also with nothing typed yet
        check(texts("SELECT c.| FROM claims c", g) == ["id", "driver_id", "amount"])
        check(texts("SELECT c.dr| FROM claims AS c", g) == ["driver_id"])
        check(texts("SELECT drivers.la| FROM drivers", g) == ["last_name"])
        check(texts("SELECT * FROM crm.| ", g) == ["contacts"]) // schema. → its tables
        // elsewhere: columns of the statement's tables first, then tables, functions and keywords
        check(texts("SELECT * FROM claims WHERE am|", g).first == "amount")
        check(texts("sel|", g).contains("select")) // keywords in the case being typed
        check(texts("SEL|", g).contains("SELECT"))
        check(texts("SELECT co|", g).contains("count(")) // functions open their parenthesis
        // only the current statement's tables count
        check(!texts("SELECT * FROM drivers; SELECT * FROM claims WHERE la|", g).contains("last_name"))
        // nothing inside strings or comments, nothing with nothing typed (except after a dot)
        check(texts("SELECT 'cl| FROM claims", g).isEmpty)
        check(texts("-- from cl|", g).isEmpty)
        check(texts("SELECT * FROM |", g).isEmpty)
        // asked for (⌃Space): also with nothing typed
        let forced = sqlSuggestions("SELECT * FROM ", cursor: 14, schema: g, evenWithoutWord: true)
        check(forced.suggestions.count == 3 && forced.replace.length == 0)
        // the range to replace is the word being typed, in UTF-16 units like NSTextView's
        check(NSEqualRanges(run("SELECT c.dr| FROM claims c", g).replace, NSRange(location: 9, length: 2)))
        check(NSEqualRanges(run("SELECT '😀', c.dr| FROM claims c", g).replace, NSRange(location: 15, length: 2)))
        print("completion_test: OK")
    }
}

// Tests PGConnection and changeStatements against a real local Postgres: `make test`.
// Database from PLAINDB_TEST_DB (default "postgres"). Only creates temporary tables.
@testable import PlainDBKit
import Foundation

@main enum PGTest {
    static let database = ProcessInfo.processInfo.environment["PLAINDB_TEST_DB"] ?? "postgres"

    static func fails(_ work: () throws -> Any) -> DBError? {
        do { _ = try work(); return nil } catch { return error as? DBError }
    }

    static func main() throws {
        let pg = PGConnection(params: ["dbname": database], readOnly: false)
        try pg.open()

        // an identifier with a quote inside exercises quoteIdent
        let table = "we\"ird", q = quoteIdent(table)
        _ = try pg.execute("CREATE TEMP TABLE \(q) (id serial PRIMARY KEY, name text NOT NULL DEFAULT 'x', note text);"
                           + "INSERT INTO \(q) (name, note) VALUES ('a', NULL), ('b', 'zażółć');")
        let schema = try pg.execute("SELECT nspname FROM pg_namespace WHERE oid = pg_my_temp_schema()").rows[0][0].string!
        let s = DBValue.text(schema)

        let databases = try pg.databases().rows
        check(databases.contains([.text(database)]) && !databases.contains(["template0"]))

        var tables = try pg.tables().rows
        var mine = tables.first { $0[1] == .text(table) }!
        check(mine[0] == s && mine[2] == "table" && mine.count == 4) // + estimated rows (NULL until analyzed)
        _ = try pg.execute("ANALYZE \(q)")
        tables = try pg.tables().rows
        mine = tables.first { $0[1] == .text(table) }!
        check(mine[3] == "2")

        // foreign keys: single-column only, with the referenced table and column
        _ = try pg.execute("""
            CREATE TEMP TABLE drivers (id serial PRIMARY KEY, name text);
            CREATE TEMP TABLE pairs (x int, y int, UNIQUE (x, y));
            CREATE TEMP TABLE cars (id serial PRIMARY KEY, plate text, driver_id int REFERENCES drivers(id),
             a int, b int, FOREIGN KEY (a, b) REFERENCES pairs (x, y))
            """) // composite: left out
        check(try pg.foreignKeys(schema: schema, table: "cars").rows == [["driver_id", s, "drivers", "id"]])

        let cols = try pg.columns(schema: schema, table: table).rows
        check(cols.count == 3)
        check(cols[0][0] == "id" && cols[0][4] == "PK")
        check(cols[1][2] == "NOT NULL" && cols[1][3] == "'x'::text")
        check(cols[2][4] == "")

        let idx = try pg.indexes(schema: schema, table: table).rows
        check(idx.count == 1 && idx[0][1].string!.contains("UNIQUE"))

        let select = "SELECT name, note FROM \(q) WHERE id = $1"
        var r = try pg.execute(select, ["1"])
        check(r.columns == ["name", "note"] && r.rows[0][1] == .null)
        r = try pg.execute(select, ["2"])
        check(r.rows[0][1] == "zażółć")
        check(try pg.execute("UPDATE \(q) SET note = $1 WHERE id = $2", [nil, "2"]).affected == 1)
        check(fails { try pg.execute("SELECT nope") }?.sqlstate == "42703")

        // grid changes → SQL → database
        let before = try pg.execute("SELECT * FROM \(q) ORDER BY id") // (1,a,NULL) (2,b,NULL)
        let stmts = changeStatements(schema: schema, table: table, result: before, primaryKey: ["id"],
                                     edits: [0: [1: "a'2", 2: nil], 1: [1: "ignored"]], deleted: IndexSet(integer: 1), inserted: [[1: "c"], [:]])
        check(stmts.count == 4) // DELETE row 1 (its edit is skipped), UPDATE row 0, 2× INSERT
        check(stmts[0].sql.hasPrefix("DELETE") && stmts[1].sql.hasPrefix("UPDATE") && stmts[3].sql.hasSuffix("DEFAULT VALUES"))
        check(inlineParams(stmts[1].sql, stmts[1].params).hasSuffix("SET \"name\" = 'a''2', \"note\" = NULL WHERE \"id\" = '1'"))
        for st in stmts {
            let res = try pg.execute(st.sql, st.params)
            check(!st.expectsOneRow || res.affected == 1)
        }
        check(try pg.execute("SELECT name, note FROM \"we\"\"ird\" ORDER BY id").rows == [["a'2", nil], ["c", nil], ["x", nil]])
        check(changeStatements(schema: schema, table: table, result: before, primaryKey: [], edits: [:], deleted: IndexSet(integer: 0), inserted: []).isEmpty)

        // search across all columns: case-insensitive, %, _ and \ literal, numbers and NULLs fine
        _ = try pg.execute("CREATE TEMP TABLE s (id int PRIMARY KEY, name text, price numeric, note text);"
                           + "INSERT INTO s VALUES (1, 'Zażółć Gęślą', 9.99, NULL), (2, '50% off_now', 50, 'a\\b'), (3, 'plain', 1234, 'x')")
        let condition = pg.searchCondition(columns: ["id", "name", "price", "note"])
        func ids(_ term: String) -> [DBValue] {
            try! pg.execute("SELECT id FROM s WHERE \(condition) ORDER BY id", [.text(likePattern(term))]).rows.map { $0[0] }
        }
        check(ids("żółć") == ["1"])   // inside a word, Polish letters
        check(ids("ZAŻÓŁĆ") == ["1"]) // case-insensitive
        check(ids("50%") == ["2"])    // % is literal: not "50 followed by anything"
        check(ids("o_f") == [])       // _ is literal: as a wildcard it would match "off"
        check(ids("f_n") == ["2"])    // ...and a real underscore still matches
        check(ids("a\\b") == ["2"])   // backslash is literal
        check(ids("123") == ["3"])    // numbers match as text
        check(ids("9.9") == ["1"])

        // the whole database's schema at once (for the diagram): tables only, single-column keys only
        let carColumns = try pg.allColumns().rows.filter { $0[0] == s && $0[1] == "cars" }
        check(carColumns.count == 5) // id, plate, driver_id, a, b
        check(carColumns[0] == [s, "cars", "id", "integer", "PK"])
        check(carColumns[2] == [s, "cars", "driver_id", "integer", ""])
        check(try pg.allForeignKeys().rows.filter { $0[0] == s && $0[1] == "cars" } == [[s, "cars", "driver_id", s, "drivers", "id", ""]])
        check(!pg.managesOwnSchema)

        // schema editing: add a column and a foreign key; a NOT NULL column without a default on a table with rows fails
        // and leaves the table as it was
        check(pg.canAddForeignKeys && pg.commonTypes.contains("jsonb"))
        func alter(_ sql: String) throws { _ = try pg.inWriteTransaction { try pg.execute(sql) } }
        try alter(addColumnStatement(schema: schema, table: "cars", column: "note", type: "text", notNull: false, defaultExpr: nil))
        try alter(addForeignKeyStatement(schema: schema, table: "cars", column: "b", refSchema: schema, refTable: "drivers", refColumn: "id", onDelete: "SET NULL"))
        check(try pg.allColumns().rows.contains { $0[1] == "cars" && $0[2] == "note" })
        check(try pg.allForeignKeys().rows.contains { $0[1] == "cars" && $0[2] == "b" })
        _ = try pg.execute("INSERT INTO cars (plate) VALUES ('ROW')")
        check(fails { try alter(addColumnStatement(schema: schema, table: "cars", column: "must", type: "integer", notNull: true, defaultExpr: nil)) } != nil)
        check(!(try pg.allColumns().rows.contains { $0[1] == "cars" && $0[2] == "must" }))

        // search through foreign keys: a car is found by its driver's name
        _ = try pg.execute("INSERT INTO drivers (name) VALUES ('Anna Kowalska'), ('Jan Nowak');"
                           + "INSERT INTO cars (plate, driver_id) VALUES ('WA 1', 1), ('KR 2', 2), ('PO 3', NULL)")
        let linked = searchCondition(pg, columns: ["id", "plate", "driver_id", "a", "b"],
                                     references: ["driver_id": SearchReference(schema: schema, table: "drivers", column: "id", columns: ["id", "name"])])
        func cars(_ term: String) -> [DBValue] {
            try! pg.execute("SELECT plate FROM cars WHERE \(linked) ORDER BY id", [.text(likePattern(term))]).rows.map { $0[0] }
        }
        check(cars("kowal") == ["WA 1"])     // only in the referenced row
        check(cars("KR") == ["KR 2"])        // own columns still count
        check(cars("a") == ["WA 1", "KR 2"]) // both drivers' names; the car without a driver isn't matched
        check(searchCondition(pg, columns: ["id"], references: [:]) == pg.searchCondition(columns: ["id"]))

        // engine operations behind the protocol
        check(pg.booleanTrue == "t" && pg.booleanFalse == "f")
        check(pg.emptyTableStatement(schema: schema, table: "s") == "TRUNCATE TABLE \"\(schema)\".\"s\"")
        check(fails { try pg.execute("SELECT pg_sleep(2)", [], timeout: 0.2) }?.sqlstate == "57014")
        _ = try pg.execute("SELECT pg_sleep(0.3)") // the timeout was reset afterwards
        check(try pg.inWriteTransaction { try pg.execute("UPDATE s SET note = 'w' WHERE id = 1") }.affected == 1)
        check(fails {
            try pg.inWriteTransaction {
                _ = try? pg.execute("UPDATE s SET note = 'rolled back' WHERE id = 1")
                return try pg.execute("SELECT nope")
            }
        } != nil)
        check(try pg.execute("SELECT note FROM s WHERE id = 1").rows[0][0] == "w")

        // production mode: the server rejects writes until BEGIN READ WRITE
        let ro = PGConnection(params: ["dbname": database], readOnly: true)
        try ro.open()
        check(fails { try ro.execute("CREATE TEMP TABLE t (x int)") }?.sqlstate == "25006")
        _ = try ro.execute("BEGIN READ WRITE")
        check(try ro.execute("CREATE TEMP TABLE t (x int); INSERT INTO t VALUES (1), (2)").affected == 2)
        _ = try ro.execute("COMMIT")
        _ = try ro.inWriteTransaction { try ro.execute("CREATE TEMP TABLE rw (x int)") } // allowed explicitly, like a confirmed production write
        print("pg_test: OK")
    }
}

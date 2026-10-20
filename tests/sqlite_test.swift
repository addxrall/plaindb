// Tests SQLiteConnection on temporary files: `make test`. Everything runs twice, on a local file and through the
// remote helper (the same helper ssh starts on a server, here run by the local python3), so both behave alike.
@testable import PlainDBKit
import Foundation

@main enum SQLiteTest {
    static func column(_ r: DBResult) -> [DBValue] { r.rows.map { $0[0] } }

    static let helper = try! String(contentsOfFile: "Resources/sqlite_remote.py", encoding: .utf8)
    static let python = ["/usr/bin/python3", "-I", "-u", "-c", sqliteRemoteBootstrap]

    // The remote helper started by a local command instead of ssh.
    static func remote(_ command: [String], _ path: String, _ readOnly: Bool) -> SQLiteConnection {
        SQLiteConnection(command: command, helper: helper, path: path, readOnly: readOnly)
    }

    static func newDirectory() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fails(_ work: () throws -> Any) -> DBError? {
        do { _ = try work(); return nil } catch { return error as? DBError ?? DBError(error.localizedDescription) }
    }

    static func run(_ label: String, _ make: (String, Bool) -> SQLiteConnection) throws {
        let files = FileManager.default
        let dir = newDirectory()
        let path = (dir as NSString).appendingPathComponent("test.db")

        // a missing file is an error, and no file is created
        check(fails { try make(path, false).open() } != nil)
        check(!files.fileExists(atPath: path))

        // not a database
        let png = (dir as NSString).appendingPathComponent("picture.db")
        try Data("\u{89}PNG\r\n\u{1a}\n not really a database, just bytes long enough to fill SQLite's 100 byte header .........".utf8)
            .write(to: URL(fileURLWithPath: png))
        check(!(fails { try make(png, false).open() }?.message.isEmpty ?? true))

        files.createFile(atPath: path, contents: nil) // an empty file is a valid empty database
        let db = make(path, false)
        try db.open()
        _ = try db.execute("""
            CREATE TABLE drivers (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x', photo BLOB, score REAL);
            CREATE TABLE cars (id INTEGER PRIMARY KEY, plate TEXT, driver_id INTEGER REFERENCES drivers, active BOOLEAN, bought DATE);
            CREATE UNIQUE INDEX cars_plate ON cars (plate);
            CREATE VIEW plates AS SELECT plate FROM cars;
            INSERT INTO drivers (name, photo, score) VALUES ('Anna Kowalska', x'89504e47', 1.5), ('Jan Nowak', NULL, 2);
            INSERT INTO cars (plate, driver_id, active, bought) VALUES ('WA 1', 1, 1, '2023-05-10'), ('KR 2', 2, 0, NULL), ('PO 3', NULL, NULL, NULL)
            """)

        // schema
        check(try db.tables().rows == [["main", "cars", "table", nil], ["main", "drivers", "table", nil], ["main", "plates", "view", nil]])
        let cols = try db.columns(schema: "main", table: "drivers")
        check(cols.rows[0].map(\.string) == ["id", "INTEGER", "", nil, "PK"])
        check(cols.rows[1].map(\.string) == ["name", "TEXT", "NOT NULL", "'x'", ""])
        // REFERENCES drivers → its primary key
        check(try db.foreignKeys(schema: "main", table: "cars").rows == [["driver_id", "main", "drivers", "id"]])
        let idx = try db.indexes(schema: "main", table: "cars")
        check(idx.rows.count == 1 && idx.rows[0][0] == "cars_plate" && idx.rows[0][1].string!.contains("UNIQUE"))
        check(try db.databases().rows.isEmpty)

        // values as text; BLOB as \x hex like Postgres bytea
        var r = try db.execute("SELECT id, photo, score FROM drivers ORDER BY id")
        check(r.columns == ["id", "photo", "score"])
        check(r.rows.map { $0.map(\.string) } == [["1", "\\x89504e47", "1.5"], ["2", nil, "2.0"]])
        r = try db.execute("SELECT 9223372036854775807, -9223372036854775808, 'a\nb ''q'' 😀 zażółć'")
        check(r.rows[0].map(\.string) == ["9223372036854775807", "-9223372036854775808", "a\nb 'q' 😀 zażółć"])
        // an empty result still has its columns; duplicate names stay
        r = try db.execute("SELECT id, plate, id FROM cars WHERE 0")
        check(r.columns == ["id", "plate", "id"] && r.rows.isEmpty)

        // named parameters: $2 appears before $1
        r = try db.execute("SELECT plate FROM cars WHERE id IN ($2, $3) AND plate LIKE $1 ORDER BY id", ["%2%", "1", "2"])
        check(column(r) == ["KR 2"])
        check(try db.execute("SELECT $1, $1", [nil]).rows[0][0] == .null)

        // several statements: the last one with columns is the result; affected rows
        check(try db.execute("UPDATE cars SET plate = plate WHERE id < 3; SELECT count(*) FROM cars").rows[0][0].string == "3")
        check(try db.execute("UPDATE cars SET plate = plate WHERE id < 3").affected == 2)
        check(try db.execute("SELECT 1; -- a comment at the end\n").rows.count == 1)
        check(!(fails { try db.execute("SELECT nope") }?.message.isEmpty ?? true))

        // search: Polish letters ignoring case, wildcards literal, through foreign keys
        _ = try db.execute("INSERT INTO drivers (name) VALUES ('Zażółć Gęślą'), ('50% off_now'), ('a\\b')")
        func find(_ term: String) -> [String?] {
            let q = "SELECT name FROM drivers WHERE \(db.searchCondition(columns: ["id", "name", "score"])) ORDER BY id"
            return column(try! db.execute(q, [.text(likePattern(term))])).map(\.string)
        }
        check(find("ŻÓŁĆ") == ["Zażółć Gęślą"])
        check(find("50%") == ["50% off_now"])
        check(find("o_f") == [])
        check(find("a\\b") == ["a\\b"])
        check(find("1.5") == ["Anna Kowalska"])
        let linked = searchCondition(db, columns: ["id", "plate", "driver_id"],
                                     references: ["driver_id": SearchReference(schema: "main", table: "drivers", column: "id", columns: ["id", "name"])])
        r = try db.execute("SELECT plate FROM cars WHERE \(linked) ORDER BY id", [.text(likePattern("kowal"))])
        check(column(r) == ["WA 1"])

        // the whole database's schema at once (for the diagram): tables only, not the view
        let allCols = try db.allColumns()
        check(Set(allCols.rows.map { $0[1] }) == ["cars", "drivers"])
        check(allCols.rows[0] == ["main", "cars", "id", "INTEGER", "PK"]) // cars first, in column order
        check(try db.allForeignKeys().rows == [["main", "cars", "driver_id", "main", "drivers", "id", ""]])

        // schema editing: columns can be added; foreign keys can't without rebuilding the table
        check(!db.canAddForeignKeys && db.commonTypes.contains("TEXT"))
        _ = try db.inWriteTransaction {
            try db.execute(addColumnStatement(schema: "main", table: "drivers", column: "note", type: "TEXT", notNull: false, defaultExpr: "'none'"))
        }
        check(try db.execute("SELECT note FROM drivers WHERE id = 1").rows[0][0] == "none")

        // timeout
        let slow = fails { try db.execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n", [], timeout: 0.2) }
        check(slow?.sqlstate == "57014")
        _ = try db.execute("SELECT count(*) FROM cars") // no deadline left behind

        // grid changes → SQL → file, with "main" as the schema
        let before = try db.execute("SELECT * FROM cars ORDER BY id")
        let stmts = changeStatements(schema: "main", table: "cars", result: before, primaryKey: ["id"], edits: [0: [1: "WA 9"]],
                                     deleted: IndexSet(integer: 2), inserted: [[1: "GD 4"]])
        _ = try db.inWriteTransaction {
            var last = DBResult()
            for s in stmts { last = try db.execute(s.sql, s.params) }
            return last
        }
        check(column(try db.execute("SELECT plate FROM cars ORDER BY id")) == ["WA 9", "KR 2", "GD 4"])
        check(db.emptyTableStatement(schema: "main", table: "cars") == "DELETE FROM \"main\".\"cars\"")
        check(db.booleanTrue == "1" && db.booleanFalse == "0")

        // columns without a declared type keep what they store: rows are found by their integer key,
        // and edits keep the storage class of the value they replace (integer stays integer, BLOB stays BLOB)
        _ = try db.execute("CREATE TABLE u (id PRIMARY KEY, v, b, t, f); INSERT INTO u VALUES (5, 7, x'0102', '12', 0.5)")
        let u = try db.execute("SELECT * FROM u")
        let row = u.rows[0]
        check(row[2].string == "\\x0102" && row[4].string == "0.5")
        let edits: [Int: [Int: DBValue]] = [0: [1: db.value(forText: "8", replacing: row[1]), 2: db.value(forText: "\\x0a0b", replacing: row[2]),
                                                3: db.value(forText: "13", replacing: row[3]), 4: db.value(forText: "2.25", replacing: row[4])]]
        let untyped = changeStatements(schema: "main", table: "u", result: u, primaryKey: ["id"], edits: edits, deleted: [], inserted: [])
        let changed = try db.inWriteTransaction { try db.execute(untyped[0].sql, untyped[0].params) }
        check(changed.affected == 1) // the WHERE on the untyped key matched
        check(try db.execute("SELECT typeof(v), v, typeof(b), hex(b), typeof(t), t, typeof(f), f FROM u").rows[0].map(\.string)
                     == ["integer", "8", "blob", "0A0B", "text", "13", "real", "2.25"])
        check(db.value(forText: "abc", replacing: row[1]) == "abc") // not a number: stored as typed

        // several statements run all or nothing, as one Postgres PQexec does
        check(fails { try db.execute("UPDATE cars SET plate = 'ZZ' WHERE id = 1; UPDATE nope SET x = 1") } != nil)
        check(try db.execute("SELECT plate FROM cars WHERE id = 1").rows[0][0] == "WA 9")
        _ = try db.execute("UPDATE cars SET plate = 'WA 9' WHERE id = 1; SELECT 1") // and still work when they succeed
        db.close()

        // PocketBase keeps relations in _collections (JSON), not as foreign keys: single ones act as foreign keys
        // (preview, picker, search), multi ones (JSON arrays of ids) only show on the diagram, marked "many"
        let pbPath = (dir as NSString).appendingPathComponent("pb_data.db")
        files.createFile(atPath: pbPath, contents: nil)
        let pb = make(pbPath, false)
        try pb.open()
        _ = try pb.execute("""
            CREATE TABLE _collections (id TEXT PRIMARY KEY, name TEXT, type TEXT, fields JSON);
            INSERT INTO _collections VALUES ('u1', 'users', 'auth', '[{"name":"id","type":"text"},{"name":"email","type":"email"}]'),
             ('t1', 'tags', 'base', '[{"name":"id","type":"text"},{"name":"label","type":"text"}]'),
             ('p1', 'posts', 'base', '[{"name":"id","type":"text"},{"name":"author","type":"relation","collectionId":"u1","maxSelect":1},
              {"name":"tags","type":"relation","collectionId":"t1","maxSelect":5}]');
            CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT); INSERT INTO users VALUES ('abc', 'anna.kowalska@example.com');
            CREATE TABLE tags (id TEXT PRIMARY KEY, label TEXT);
            CREATE TABLE posts (id TEXT PRIMARY KEY, author TEXT, tags JSON, editor TEXT REFERENCES users);
            INSERT INTO posts VALUES ('p', 'abc', '[]', NULL)
            """)
        let plain = make(path, false)
        try plain.open()
        check(pb.managesOwnSchema && !plain.managesOwnSchema)
        plain.close()
        check(try pb.foreignKeys(schema: "main", table: "posts").rows
                     == [["editor", "main", "users", "id"], ["author", "main", "users", "id"]]) // a real key and a relation
        let pbKeys = try pb.allForeignKeys().rows
        check(pbKeys.contains(["main", "posts", "author", "main", "users", "id", ""]))
        check(pbKeys.contains(["main", "posts", "tags", "main", "tags", "id", "many"]))
        let throughAuthor = searchCondition(pb, columns: ["id", "author"],
                                            references: ["author": SearchReference(schema: "main", table: "users", column: "id", columns: ["id", "email"])])
        check(try pb.execute("SELECT id FROM posts WHERE \(throughAuthor)", [.text(likePattern("kowalska"))]).rows.count == 1)

        // PocketBase files: which columns hold them, and where they are (S3 settings without the keys, or pb_data/storage)
        _ = try pb.execute("""
            UPDATE _collections SET fields = json_insert(fields, '$[#]', json('{"name":"avatar","type":"file","maxSelect":1}')) WHERE id = 'u1';
            UPDATE _collections SET fields = json_insert(fields, '$[#]', json('{"name":"files","type":"file","maxSelect":3}')) WHERE id = 'p1';
            CREATE TABLE _params (id TEXT PRIMARY KEY, value JSON);
            INSERT INTO _params VALUES ('settings', '{"s3":{"enabled":false,"bucket":"pb-files","region":"eu-central-1",\
            "endpoint":"https://s3.eu-central-1.amazonaws.com","accessKey":"AKIAEXAMPLE","secret":"s3cr3t"}}')
            """)
        check(pb.pocketBaseFiles(table: "posts") == PocketBaseFiles(collection: "p1", columns: ["files": true])) // S3 off: no s3
        check(pb.pocketBaseFiles(table: "tags") == nil)
        _ = try pb.execute("UPDATE _params SET value = json_set(value, '$.s3.enabled', json('true'))")
        let users = pb.pocketBaseFiles(table: "users")
        check(users == PocketBaseFiles(collection: "u1", columns: ["avatar": false],
                                              s3: .init(bucket: "pb-files", region: "eu-central-1", endpoint: "https://s3.eu-central-1.amazonaws.com")))
        check(!"\(users!)".contains("s3cr3t") && !"\(users!)".contains("AKIA"))

        let storage = (dir as NSString).appendingPathComponent("storage/u1/abc")
        try files.createDirectory(atPath: storage, withIntermediateDirectories: true)
        let picture = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + Array("-picture-".utf8))
        try picture.write(to: URL(fileURLWithPath: (storage as NSString).appendingPathComponent("face_x1.png")))
        try files.createSymbolicLink(atPath: (storage as NSString).appendingPathComponent("escape.png"), withDestinationPath: path)
        check(try pb.pocketBaseFile(collection: "u1", record: "abc", name: "face_x1.png", maxBytes: 1024) == picture)
        for bad in [["u1", "abc", "../../test.db"], ["..", "abc", "face_x1.png"], ["u1", "abc", "escape.png"], ["u1", "abc", "missing.png"], ["u1", "abc", ""]] {
            // a limit far above test.db's size, so only the name and path checks can refuse these
            check(!(fails { try pb.pocketBaseFile(collection: bad[0], record: bad[1], name: bad[2], maxBytes: 100_000_000) }?.message.isEmpty ?? true))
        }
        check(fails { try pb.pocketBaseFile(collection: "u1", record: "abc", name: "face_x1.png", maxBytes: 8) } != nil) // too big
        // a missing file says where it was looked for; no storage folder or no permission say so
        let missing = fails { try pb.pocketBaseFile(collection: "u1", record: "abc", name: "missing.png", maxBytes: 1024) }
        check(missing!.message.contains(((dir as NSString).resolvingSymlinksInPath as NSString).appendingPathComponent("storage/u1/abc/missing.png")))
        check(fails { try pb.pocketBaseFile(collection: "u9", record: "abc", name: "x.png", maxBytes: 1024) }!.message.contains("storage/u9/abc/x.png"))
        let locked = (dir as NSString).appendingPathComponent("storage/u1/locked")
        try files.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try picture.write(to: URL(fileURLWithPath: (locked as NSString).appendingPathComponent("secret.png")))
        try files.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        check(fails { try pb.pocketBaseFile(collection: "u1", record: "locked", name: "secret.png", maxBytes: 1024) }!.message.lowercased().contains("permission"))
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
        // encrypted settings (PocketBase's --encryptionEnv): where the files are is unknown, and said so
        _ = try pb.execute("UPDATE _params SET value = 'q83vEjRWeJA=' WHERE id = 'settings'")
        let encrypted = pb.pocketBaseFiles(table: "users")!
        check(encrypted.s3 == nil && encrypted.settingsUnreadable)
        pb.close()

        // read-only: refused with 25006, allowed in a write transaction, read-only again afterwards
        let ro = make(path, true)
        try ro.open()
        check(fails { try ro.execute("UPDATE cars SET plate = 'X'") }?.sqlstate == "25006")
        _ = try ro.inWriteTransaction { try ro.execute("UPDATE cars SET plate = 'RO' WHERE id = 2") }
        check(fails { try ro.execute("UPDATE cars SET plate = 'X'") }?.sqlstate == "25006")
        ro.close()

        // the directory stays: it's unique per run, under the system's temporary folder, which macOS cleans up itself
        print("sqlite_test (\(label)): OK")
    }

    // What only the remote connection does: guards that hold even against SQL typed by hand, the process around it.
    static func runRemoteOnly() throws {
        let files = FileManager.default
        let dir = newDirectory()
        let path = (dir as NSString).appendingPathComponent("it's a \"file\" $HOME.db") // nothing in a path is interpreted
        files.createFile(atPath: path, contents: nil)
        let rw = remote(python, path, false)
        try rw.open()
        _ = try rw.execute("""
            CREATE TABLE cars (id INTEGER PRIMARY KEY, plate TEXT, price REAL, photo BLOB, note);
            INSERT INTO cars (plate, price, photo, note) VALUES ('WA 1', 0.1, x'00ff', 1e20), ('KR 2', 1.0 / 3, NULL, -0.0), ('PO 3', 1e300 * 1e300, zeroblob(3), 7)
            """)

        // the remote connection reads exactly what a local one reads, storage classes included
        let local = SQLiteConnection(path: path, readOnly: false)
        try local.open()
        for q in ["SELECT * FROM cars ORDER BY id", "SELECT typeof(price), price * 3, note || '' FROM cars", "SELECT 1.5e-7, 123456789012345.678"] {
            let a = try local.execute(q), b = try rw.execute(q)
            check(a.columns == b.columns && a.rows == b.rows)
        }
        local.close()

        // read-only is enforced by the helper on the server, not only by PlainDB
        let ro = remote(python, path, true)
        try ro.open()
        let attached = (dir as NSString).appendingPathComponent("attached.db"), vacuumed = (dir as NSString).appendingPathComponent("copy.db")
        for sql in ["PRAGMA query_only = OFF", "PRAGMA main.QUERY_ONLY=0", "PRAGMA journal_mode = DELETE", "PRAGMA user_version = 5",
                    "ATTACH '\(attached)' AS other", "VACUUM INTO '\(vacuumed)'"] {
            check(fails { try ro.execute(sql) }?.sqlstate == "25006")
        }
        check(!files.fileExists(atPath: attached) && !files.fileExists(atPath: vacuumed))
        check(fails { try ro.execute("UPDATE cars SET plate = 'X'") } != nil) // still refused after the attempts
        check(try ro.execute("PRAGMA query_only").rows[0][0].string == "1") // reading it is fine
        _ = try ro.tables()
        _ = try ro.indexes(schema: "main", table: "cars")
        check(try ro.allColumns().rows.count == 5)
        // the write transaction ends at COMMIT even when the statements run on: what follows is read-only again
        check(fails {
            try ro.inWriteTransaction { try ro.execute("UPDATE cars SET plate = 'A' WHERE id = 1; COMMIT; UPDATE cars SET plate = 'B' WHERE id = 2") }
        } != nil)
        check(column(try ro.execute("SELECT plate FROM cars ORDER BY id")) == ["A", "KR 2", "PO 3"])
        check(fails { try ro.execute("UPDATE cars SET plate = 'X'") }?.sqlstate == "25006")

        // a dead helper is restarted for the next request, read-only again
        let pidFile = (dir as NSString).appendingPathComponent("pid")
        let recorded = ["/bin/sh", "-c", "echo $$ > \"$0\"; exec /usr/bin/python3 -I -u -c \"$1\"", pidFile, sqliteRemoteBootstrap]
        let flaky = remote(recorded, path, true)
        try flaky.open()
        let pid = Int32(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        check(pid > 0 && kill(pid, SIGKILL) == 0)
        usleep(300_000)
        check(try flaky.execute("SELECT count(*) FROM cars").rows[0][0].string == "3")
        check(fails { try flaky.execute("UPDATE cars SET plate = 'X'") }?.sqlstate == "25006")
        flaky.close()

        // a banner printed by the remote shell before the helper starts is skipped
        let chatty = ["/bin/sh", "-c", "echo 'Welcome to prod-1'; echo '{\"id\": 1, \"rows\": []}'; exec /usr/bin/python3 -I -u -c \"$0\"", sqliteRemoteBootstrap]
        let banner = remote(chatty, path, false)
        try banner.open()
        check(try banner.execute("SELECT count(*) FROM cars").rows[0][0].string == "3")
        banner.close()

        // no python3 on the server: said so
        check(fails { try remote(["/bin/sh", "-c", "echo 'sh: python3: command not found' >&2; exit 127"], path, false).open() }!.message.contains("python3"))
        // ssh failing: its message is shown
        check(fails { try remote(["/bin/sh", "-c", "echo 'ssh: Could not resolve hostname nowhere' >&2; exit 255"], path, false).open() }!
            .message.contains("Could not resolve hostname"))
        rw.close()
        ro.close()
        print("sqlite_test (remote only): OK")
    }

    static func main() throws {
        try run("local") { SQLiteConnection(path: $0, readOnly: $1) }
        try run("remote") { remote(python, $0, $1) }
        try runRemoteOnly()
    }
}

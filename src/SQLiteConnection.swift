import Foundation
import SQLite3

// Python code that reads the helper from the first line of stdin and runs it; the remote command is
// `python3 -I -u -c '<this>'`, the same for every connection, with nothing from the user in it.
let sqliteRemoteBootstrap = "import sys,base64;exec(base64.b64decode(sys.stdin.readline()))"

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func text(_ s: UnsafePointer<UInt8>?) -> String {
    s.map { String(cString: $0) } ?? ""
}

private func hex(_ bytes: UnsafeRawBufferPointer) -> String {
    "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
}

// "\x0a0b" (the form BLOBs are shown in) → bytes, or nil.
private func hexBytes(_ s: String) -> Data? {
    guard s.hasPrefix("\\x"), s.utf8.count % 2 == 0 else { return nil }
    var data = Data()
    var digits = s.utf8.dropFirst(2).makeIterator()
    while let hi = digits.next(), let lo = digits.next() {
        guard let byte = UInt8(String(decoding: [hi, lo], as: UTF8.self), radix: 16) else { return nil }
        data.append(byte)
    }
    return data
}

private func isWholeNumber(_ s: String, real: Bool) -> Bool {
    let scanner = Scanner(string: s)
    scanner.charactersToBeSkipped = nil
    scanner.locale = nil // "1.5", whatever the user's locale
    return (real ? scanner.scanDouble() != nil : scanner.scanInt64() != nil) && scanner.isAtEnd
}

// LIKE with \ as the escape character, on already case-folded text. % matches any run, _ one character.
func likeMatch(_ s: [UInt16], _ p: [UInt16]) -> Bool {
    let n = s.count, m = p.count
    var i = 0, j = 0, star: Int?, mark = 0
    let percent = UInt16(UInt8(ascii: "%")), underscore = UInt16(UInt8(ascii: "_")), backslash = UInt16(UInt8(ascii: "\\"))
    while i < n {
        if j < m && p[j] == percent {
            j += 1
            star = j
            mark = i
            continue
        }
        if j < m {
            let escaped = p[j] == backslash && j + 1 < m
            let c = escaped ? p[j + 1] : p[j]
            if (!escaped && c == underscore) || c == s[i] {
                i += 1
                j += escaped ? 2 : 1
                continue
            }
        }
        guard let star else { return false }
        j = star // let the last % take one more character
        mark += 1
        i = mark
    }
    while j < m && p[j] == percent { j += 1 }
    return j == m
}

// plaindb_like(value, pattern): LIKE ignoring case for all of Unicode (SQLite's own LIKE folds ASCII only).
private func likeFunction(_ context: OpaquePointer?, _ argc: Int32, _ argv: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let argv, sqlite3_value_type(argv[0]) != SQLITE_NULL, sqlite3_value_type(argv[1]) != SQLITE_NULL else {
        return sqlite3_result_null(context)
    }
    let value = text(sqlite3_value_text(argv[0])).folding(options: .caseInsensitive, locale: nil)
    let pattern = text(sqlite3_value_text(argv[1])).folding(options: .caseInsensitive, locale: nil)
    sqlite3_result_int(context, likeMatch(Array(value.utf16), Array(pattern.utf16)) ? 1 : 0)
}

// Why a PocketBase storage file can't be read (codes from read_file in the helper, and the local check), worded
// for the user, with the path it concerns.
private func fileProblemMessage(_ code: String?, _ path: String) -> String? {
    switch code {
    case "badname": L("Not a PocketBase file name.")
    case "nostorage": String(format: L("PocketBase's storage folder wasn't found: %@"), path)
    case "permission": String(format: L("No permission to read %@"), path)
    case "notfound": String(format: L("The file isn't in PocketBase's storage: %@"), path)
    case "toobig": L("The file is too big to preview.")
    default: nil
    }
}

// The helper's value tags (see Resources/sqlite_remote.py) ↔ what a local connection reads and binds.
private func remoteValue(_ v: Any) -> DBValue {
    if let s = v as? String { return .text(s) }
    guard let d = v as? [String: Any] else { return .null }
    if let i = d["i"] as? String { return .integer(i) }
    if let r = d["r"] as? String { return .real(r) }
    let blob = Data(base64Encoded: d["b"] as? String ?? "") ?? Data()
    return .blob(blob.withUnsafeBytes { hex($0) })
}

private func remoteParam(_ p: DBValue) -> Any {
    switch p {
    case .null: NSNull()
    case .text(let s): s
    case .integer(let s): ["i": s]
    case .real(let s): ["r": s]
    case .blob(let s): hexBytes(s).map { ["b": $0.base64EncodedString()] } ?? s
    }
}

// SQLite database file, local or on a server. The schema is always "main".
// readOnly sets PRAGMA query_only, so the session refuses writes (sqlstate 25006) except in inWriteTransaction.
final class SQLiteConnection: DBConnection, @unchecked Sendable { // state is only touched on `queue`
    let queue = DispatchQueue(label: "plaindb.sqlite")
    private var db: OpaquePointer?
    private let remote: RemoteSQLite? // set for a file on a server; then db stays nil
    private let path: String
    private let readOnly: Bool
    fileprivate var deadline: CFAbsoluteTime = 0 // 0 = no time limit

    init(path: String, readOnly: Bool) {
        self.path = path
        self.readOnly = readOnly
        remote = nil
    }

    // A file on a server, through PlainDB's helper (Resources/sqlite_remote.py) started over ssh: keys or the agent
    // only (BatchMode), python3 on the server. A read-only connection is also guarded by the helper itself.
    convenience init(sshHost: String, path: String, readOnly: Bool) {
        let command = [
            "/usr/bin/ssh", "-T",
            "-o", "BatchMode=yes", // keys or the agent only: the app has no terminal for prompts
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            // whatever ~/.ssh/config says for this host: no agent, X11 or port forwarding into a long-lived session
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "--", sshHost, // so a host can't be taken for an option
            // -I: no PYTHON* variables, user site or current directory, so nothing planted on the server runs
            "python3 -I -u -c '\(sqliteRemoteBootstrap)'",
        ]
        let helper = Bundle.main.path(forResource: "sqlite_remote", ofType: "py").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        self.init(command: command, helper: helper ?? "", path: path, readOnly: readOnly)
    }

    // The same with any command starting the helper (tests run it with the local python3).
    init(command: [String], helper: String, path: String, readOnly: Bool) {
        self.path = path
        self.readOnly = readOnly
        remote = RemoteSQLite(command: command, helper: helper)
    }

    deinit { close() }

    private func lastError() -> DBError {
        let code = sqlite3_errcode(db) & 0xff
        let state = code == SQLITE_INTERRUPT ? "57014" : code == SQLITE_READONLY ? "25006" : nil
        return DBError(String(cString: sqlite3_errmsg(db)), sqlstate: state)
    }

    func open() throws {
        if let remote { return try remote.start(path: path, readOnly: readOnly) } // the helper does the checks below
        // never create a file: a missing one is an error, not a new empty database
        guard FileManager.default.fileExists(atPath: path) else {
            throw DBError(String(format: L("The file %@ doesn't exist."), (path as NSString).lastPathComponent))
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let error = lastError()
            close()
            throw error
        }
        sqlite3_busy_timeout(db, 3000) // another program may be writing to the file
        // Called every 1000 VM steps; non-zero interrupts the statement (SQLITE_INTERRUPT).
        sqlite3_progress_handler(db, 1000, { context in
            let c = Unmanaged<SQLiteConnection>.fromOpaque(context!).takeUnretainedValue()
            return c.deadline > 0 && CFAbsoluteTimeGetCurrent() > c.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
        sqlite3_create_function_v2(db, "plaindb_like", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, likeFunction, nil, nil, nil)
        do {
            // reading the schema also fails for files that aren't SQLite databases
            _ = try execute("SELECT count(*) FROM sqlite_master")
            _ = try execute("PRAGMA foreign_keys = ON")
            if readOnly { _ = try execute("PRAGMA query_only = ON") }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        remote?.stop()
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    private func remoteExecute(_ remote: RemoteSQLite, _ sql: String, _ params: [DBValue]) throws -> DBResult {
        var request: [String: Any] = ["op": "execute", "sql": sql, "params": params.map(remoteParam)]
        if deadline > 0 { request["timeout"] = max(0.001, deadline - CFAbsoluteTimeGetCurrent()) }
        let answer = try remote.send(request)
        if let message = answer["error"] as? String {
            let code = answer["code"] as? String
            throw DBError(message, sqlstate: code == "interrupted" ? "57014" : code == "readonly" ? "25006" : nil)
        }
        var result = DBResult()
        result.columns = answer["columns"] as? [String] ?? []
        result.rows = (answer["rows"] as? [[Any]] ?? []).map { $0.map(remoteValue) }
        result.affected = (answer["affected"] as? NSNumber)?.intValue ?? 0
        return result
    }

    // Lifts or restores read-only around a confirmed write; on a server the helper does it (and guards the rest).
    private func setQueryOnly(_ on: Bool) {
        if let remote { _ = try? remote.send(["op": "writable", "on": !on]) }
        else { _ = try? execute(on ? "PRAGMA query_only = ON" : "PRAGMA query_only = OFF") }
    }

    private static let transactional = try! NSRegularExpression(pattern: "\\b(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|END\\s+TRANSACTION)\\b",
                                                                options: .caseInsensitive)

    // Runs the statements one after another; the result is the last one that returned columns (or the last
    // statement, if none did). $1, $2 … are bound by name: SQLite numbers parameters in order of first
    // appearance, so `IN ($2, $3) AND … $1` would bind wrongly by position.
    func execute(_ sql: String, _ params: [DBValue]) throws -> DBResult {
        if let remote { return try remoteExecute(remote, sql, params) }
        guard db != nil else { throw DBError(L("Not connected to the database.")) }
        // Several statements outside a transaction run all or nothing, as one Postgres PQexec does: inside a
        // savepoint, unless the script handles transactions itself.
        let handlesTransactions = Self.transactional.firstMatch(in: sql, range: NSRange(location: 0, length: (sql as NSString).length)) != nil
        var batch = false
        var last: DBResult?
        func fail(_ error: DBError) -> DBError {
            if batch { sqlite3_exec(db, "ROLLBACK TO plaindb_batch; RELEASE plaindb_batch", nil, nil, nil) }
            return error
        }
        let source = Array(sql.utf8CString)
        try source.withUnsafeBufferPointer { buffer in
            var tail: UnsafePointer<CChar>? = buffer.baseAddress
            while let t = tail, t.pointee != 0 {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, t, -1, &stmt, &tail) == SQLITE_OK else { throw fail(lastError()) }
                guard let stmt else { continue } // only whitespace or a comment was left
                defer { sqlite3_finalize(stmt) }
                if last == nil, let rest = tail, rest.pointee != 0, sqlite3_get_autocommit(db) != 0, !handlesTransactions {
                    batch = sqlite3_exec(db, "SAVEPOINT plaindb_batch", nil, nil, nil) == SQLITE_OK // more statements follow
                }
                for (i, p) in params.enumerated() {
                    let index = sqlite3_bind_parameter_index(stmt, "$\(i + 1)")
                    guard index != 0 else { continue }
                    switch p {
                    case .null: sqlite3_bind_null(stmt, index)
                    case .integer(let s): sqlite3_bind_int64(stmt, index, Int64(s) ?? (s as NSString).longLongValue)
                    case .real(let s): sqlite3_bind_double(stmt, index, (s as NSString).doubleValue)
                    case .blob(let s):
                        if let blob = hexBytes(s) {
                            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
                        } else {
                            sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
                        }
                    case .text(let s): sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
                    }
                }
                let columns = sqlite3_column_count(stmt)
                var result = DBResult()
                result.columns = (0..<columns).map { String(cString: sqlite3_column_name(stmt, $0)) }
                var rc: Int32
                while true {
                    rc = sqlite3_step(stmt)
                    guard rc == SQLITE_ROW else { break }
                    result.rows.append((0..<columns).map { value(stmt, $0) })
                }
                guard rc == SQLITE_DONE else { throw fail(lastError()) }
                result.affected = columns > 0 ? -1 : Int(sqlite3_changes(db))
                if columns > 0 || (last?.columns.isEmpty ?? true) { last = result }
            }
        }
        if batch && sqlite3_exec(db, "RELEASE plaindb_batch", nil, nil, nil) != SQLITE_OK { throw lastError() }
        return last ?? DBResult(affected: 0)
    }

    // Everything as text, like Postgres: numbers as SQLite prints them, BLOBs as \x hex (the form of Postgres bytea).
    private func value(_ stmt: OpaquePointer, _ c: Int32) -> DBValue {
        switch sqlite3_column_type(stmt, c) {
        case SQLITE_NULL: return .null
        case SQLITE_TEXT: return .text(text(sqlite3_column_text(stmt, c)))
        case SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, c))
            return .blob(hex(UnsafeRawBufferPointer(start: sqlite3_column_blob(stmt, c), count: n)))
        case SQLITE_INTEGER: return .integer(text(sqlite3_column_text(stmt, c)))
        default: return .real(text(sqlite3_column_text(stmt, c)))
        }
    }

    func execute(_ sql: String, _ params: [DBValue], timeout seconds: TimeInterval) throws -> DBResult {
        deadline = CFAbsoluteTimeGetCurrent() + seconds
        defer { deadline = 0 }
        return try execute(sql, params)
    }

    func inWriteTransaction(_ work: () throws -> DBResult) throws -> DBResult {
        if readOnly { setQueryOnly(false) }
        defer { if readOnly { setQueryOnly(true) } }
        _ = try execute("BEGIN")
        do {
            let r = try work()
            _ = try execute("COMMIT")
            return r
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    func emptyTableStatement(schema: String, table: String) -> String {
        "DELETE FROM \(quoteIdent(schema)).\(quoteIdent(table))"
    }

    // Typed text takes the storage class of the value it replaces when it fits it; otherwise it's stored as typed
    // (and a column with a declared type applies its own affinity).
    func value(forText text: String, replacing original: DBValue) -> DBValue {
        switch original {
        case .integer where isWholeNumber(text, real: false): .integer(text)
        case .real where isWholeNumber(text, real: true): .real(text)
        case .blob where hexBytes(text) != nil: .blob(text)
        default: .text(text)
        }
    }

    // ALTER TABLE can't add a constraint in SQLite: the table would have to be rebuilt.
    let canAddForeignKeys = false
    let commonTypes = ["INTEGER", "TEXT", "REAL", "NUMERIC", "BLOB", "BOOLEAN", "DATE", "DATETIME"]
    let booleanTrue = "1", booleanFalse = "0"

    func tables() throws -> DBResult {
        try execute("SELECT 'main', name, CASE type WHEN 'view' THEN 'view' ELSE 'table' END, NULL"
                    + " FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name")
    }

    func columns(schema: String, table: String) throws -> DBResult {
        var info = try execute("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info($1)", [.text(table)])
        info.rows = info.rows.map { c in
            [c[0], c[1], c[2].string == "1" ? "NOT NULL" : "", c[3], c[4].string == "0" ? "" : "PK"]
        }
        return info
    }

    func foreignKeys(schema: String, table: String) throws -> DBResult {
        DBResult(columns: ["column", "schema", "table", "referenced"],
                 rows: try keys(of: table).map { [.text($0.column), "main", .text($0.refTable), .text($0.refColumn)] })
    }

    private struct Key { var table, column, refTable, refColumn: String }

    // Single-column keys of one table, or of every table (nil). A key without a target column points at the other
    // table's primary key. One query for all tables, so a database on a server doesn't cost a round trip per table.
    private func keys(of table: String?) throws -> [Key] {
        let list = try execute("SELECT m.name, f.id, f.\"from\", f.\"table\", f.\"to\" FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) f"
                               + " WHERE m.type = 'table' AND ($1 IS NULL OR m.name = $1) ORDER BY m.name, f.id, f.seq",
                               [table.map { .text($0) } ?? .null])
        var parts: [[DBValue]: Int] = [:]
        for k in list.rows { parts[[k[0], k[1]], default: 0] += 1 }
        var primaryKeys: [String: String]? // looked up only when a key needs it
        var out: [Key] = []
        var keyed = Set<[String]>()
        for k in list.rows where parts[[k[0], k[1]]] == 1 {
            let name = k[0].string ?? "", column = k[2].string ?? "", refTable = k[3].string ?? ""
            var to = k[4].string
            if to == nil {
                if primaryKeys == nil { primaryKeys = self.primaryKeys() }
                to = primaryKeys?[refTable.lowercased()]
            }
            guard let to else { continue }
            out.append(Key(table: name, column: column, refTable: refTable, refColumn: to))
            keyed.insert([name, column])
        }
        for r in pocketBaseRelations() // single PocketBase relations work like foreign keys
            where (table == nil || r.table == table) && !r.many && !keyed.contains([r.table, r.column]) {
            out.append(Key(table: r.table, column: r.column, refTable: r.refTable, refColumn: "id"))
        }
        return out
    }

    // Lower-cased table name → its primary key column (the first one of a composite key), for REFERENCES without a column.
    private func primaryKeys() -> [String: String] {
        let pk = try? execute("SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type = 'table' AND p.pk = 1")
        var keys: [String: String] = [:]
        for r in pk?.rows ?? [] { keys[(r[0].string ?? "").lowercased()] = r[1].string }
        return keys
    }

    // MARK: - PocketBase

    // PocketBase describes its collections in _collections: a JSON list of fields per collection, in a column named
    // "fields" (v0.23+) or "schema" (older, with the relation's settings under "options"). nil for other files.
    private func pocketBaseFieldsColumn() -> String? {
        let columns = try? execute("SELECT name FROM pragma_table_info('_collections') WHERE name IN ('fields', 'schema') ORDER BY name")
        return columns?.rows.first?.first?.string
    }

    var managesOwnSchema: Bool { pocketBaseFieldsColumn() != nil }

    private struct Relation { var table, column, refTable: String; var many: Bool } // the referenced column is always "id"

    private func pocketBaseRelations() -> [Relation] {
        guard let fields = pocketBaseFieldsColumn() else { return [] }
        let sql = """
            SELECT c.name, json_extract(f.value, '$.name'), t.name,
             CASE WHEN COALESCE(json_extract(f.value, '$.maxSelect'), json_extract(f.value, '$.options.maxSelect'), 1) > 1 THEN 'many' ELSE '' END
             FROM _collections c, json_each(c.\(quoteIdent(fields))) f
             JOIN _collections t ON t.id = COALESCE(json_extract(f.value, '$.collectionId'), json_extract(f.value, '$.options.collectionId'))
             WHERE json_extract(f.value, '$.type') = 'relation'
             ORDER BY 1, 2
            """
        return (try? execute(sql))?.rows.map {
            Relation(table: $0[0].string ?? "", column: $0[1].string ?? "", refTable: $0[2].string ?? "", many: $0[3].string == "many")
        } ?? []
    }

    func pocketBaseFiles(table: String) -> PocketBaseFiles? {
        guard let fields = pocketBaseFieldsColumn() else { return nil }
        let sql = """
            SELECT c.id, json_extract(f.value, '$.name'),
             COALESCE(json_extract(f.value, '$.maxSelect'), json_extract(f.value, '$.options.maxSelect'), 1) > 1
             FROM _collections c, json_each(c.\(quoteIdent(fields))) f WHERE c.name = $1 AND json_extract(f.value, '$.type') = 'file'
            """
        guard let rows = (try? execute(sql, [.text(table)]))?.rows, let first = rows.first else { return nil }
        var columns: [String: Bool] = [:]
        for r in rows { columns[r[1].string ?? ""] = r[2].string == "1" }
        var files = PocketBaseFiles(collection: first[0].string ?? "", columns: columns)
        // only where the files are; the access keys next to them stay in the database
        let s3 = (try? execute("SELECT json_extract(value, '$.s3.bucket'), json_extract(value, '$.s3.region'), json_extract(value, '$.s3.endpoint')"
                               + " FROM _params WHERE id = 'settings' AND json_valid(value) AND json_extract(value, '$.s3.enabled')"))?.rows.first
        if let s3, let bucket = s3[0].string, !bucket.isEmpty {
            files.s3 = .init(bucket: bucket, region: s3[1].string ?? "", endpoint: s3[2].string ?? "")
        }
        files.settingsUnreadable = !((try? execute("SELECT 1 FROM _params WHERE id = 'settings' AND NOT json_valid(value)"))?.rows.isEmpty ?? true)
        return files
    }

    func pocketBaseFile(collection: String, record: String, name: String, maxBytes: Int) throws -> Data {
        guard [collection, record, name].allSatisfy(pocketBaseFileNameValid) else { throw DBError(L("Not a PocketBase file name.")) }
        if let remote {
            let answer = try remote.send(["op": "file", "collection": collection, "record": record, "name": name, "max": maxBytes])
            if let message = answer["error"] as? String {
                throw DBError(fileProblemMessage(answer["code"] as? String, answer["path"] as? String ?? "") ?? message)
            }
            return Data(base64Encoded: answer["data"] as? String ?? "") ?? Data()
        }
        // the same checks as the helper's read_file, so both say why a file can't be read, and where
        let files = FileManager.default
        func isFolder(_ p: String) -> Bool {
            var folder: ObjCBool = false
            return files.fileExists(atPath: p, isDirectory: &folder) && folder.boolValue
        }
        var storage = (((path as NSString).resolvingSymlinksInPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("storage")
        var code: String?, location: String?
        if !isFolder(storage) { (code, location) = ("nostorage", storage) }
        storage = (storage as NSString).resolvingSymlinksInPath
        let wanted = [collection, record, name].reduce(storage) { ($0 as NSString).appendingPathComponent($1) }
        for dir in [storage, (storage as NSString).appendingPathComponent(collection), (wanted as NSString).deletingLastPathComponent]
            where code == nil && isFolder(dir) && access(dir, R_OK | X_OK) != 0 {
            (code, location) = ("permission", dir)
        }
        let file = (wanted as NSString).resolvingSymlinksInPath
        let attributes = code == nil ? try? files.attributesOfItem(atPath: file) : nil
        if code == nil {
            if !file.hasPrefix(storage + "/") { code = "badname" }
            else if attributes?[.type] as? FileAttributeType != .typeRegular { (code, location) = ("notfound", wanted) }
            else if access(file, R_OK) != 0 { (code, location) = ("permission", file) }
            else if (attributes?[.size] as? NSNumber)?.intValue ?? 0 > maxBytes { (code, location) = ("toobig", file) }
        }
        if code == nil, let data = files.contents(atPath: file) { return data }
        throw DBError(fileProblemMessage(code ?? "notfound", location ?? wanted) ?? "")
    }

    func indexes(schema: String, table: String) throws -> DBResult {
        let list = try execute("SELECT name, sql, \"unique\" FROM pragma_index_list($1) JOIN sqlite_master USING (name) ORDER BY name", [.text(table)])
        let rows: [[DBValue]] = try list.rows.map { i in
            if !i[1].isNull { return [i[0], i[1]] }
            let names = try execute("SELECT name FROM pragma_index_info($1) ORDER BY seqno", [i[0]]).rows.map { $0[0].string ?? "" }
            return [i[0], .text("\(L("automatic")): \(i[2].string == "1" ? "UNIQUE " : "")(\(names.joined(separator: ", ")))")]
        }
        return DBResult(columns: ["name", "definition"], rows: rows)
    }

    // One query for the whole database, which matters over ssh.
    func allColumns() throws -> DBResult {
        try execute("SELECT 'main', m.name, p.name, p.type, CASE WHEN p.pk > 0 THEN 'PK' ELSE '' END"
                    + " FROM sqlite_master m JOIN pragma_table_info(m.name) p"
                    + " WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY m.name, p.cid")
    }

    func allForeignKeys() throws -> DBResult {
        var rows: [[DBValue]] = try keys(of: nil).map { ["main", .text($0.table), .text($0.column), "main", .text($0.refTable), .text($0.refColumn), ""] }
        for r in pocketBaseRelations() where r.many { // multi relations: only on the diagram
            rows.append(["main", .text(r.table), .text(r.column), "main", .text(r.refTable), "id", "many"])
        }
        return DBResult(columns: ["schema", "table", "column", "referenced schema", "referenced table", "referenced column", "many"], rows: rows)
    }

    func databases() throws -> DBResult { DBResult(columns: ["name"]) }

    func searchCondition(columns: [String]) -> String {
        "(" + columns.map { "plaindb_like(CAST(\(quoteIdent($0)) AS TEXT), $1)" }.joined(separator: " OR ") + ")"
    }
}

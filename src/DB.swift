import Foundation

// A value as the database prints it; SQL NULL is .null. SQLite values that aren't TEXT remember their storage
// class, so binding them back keeps it: a row is found by its integer key even in a column without a declared
// type, and an edited number stays a number. A BLOB is shown as \x hex, the form of Postgres bytea.
enum DBValue: Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    case null
    case text(String)
    case integer(String), real(String), blob(String)

    init(stringLiteral value: String) { self = .text(value) }
    init(nilLiteral: ()) { self = .null }

    var string: String? {
        switch self {
        case .null: nil
        case .text(let s), .integer(let s), .real(let s), .blob(let s): s
        }
    }
    var isNull: Bool { self == .null }
}

struct DBResult: Sendable {
    var columns: [String] = []
    var rows: [[DBValue]] = []
    var affected = -1 // for INSERT/UPDATE/DELETE, -1 otherwise
}

struct DBError: LocalizedError, Sendable {
    var message: String
    var sqlstate: String?
    init(_ message: String, sqlstate: String? = nil) {
        self.message = message
        self.sqlstate = sqlstate
    }
    var errorDescription: String? { message }
}

// PocketBase files of a table: its collection id, the file columns (true: several files), and where the files are
// when PocketBase keeps them in S3 (never its access keys).
struct PocketBaseFiles: Equatable, Sendable {
    struct S3: Equatable, Sendable { var bucket, region, endpoint: String }
    var collection: String
    var columns: [String: Bool]
    var s3: S3?
    var settingsUnreadable = false // encrypted settings (--encryptionEnv): whether files are in S3 can't be read
}

// Common interface for database engines. All methods block; call them on `queue`.
protocol DBConnection: AnyObject, Sendable {
    var queue: DispatchQueue { get }
    func open() throws
    func close()
    func execute(_ sql: String, _ params: [DBValue]) throws -> DBResult
    // rows: [schema, name, kind, estimated row count (NULL when unknown)]
    func tables() throws -> DBResult
    // rows: [column, referenced schema, referenced table, referenced column]; single-column foreign keys only
    func foreignKeys(schema: String, table: String) throws -> DBResult
    // rows: [column, type, null, default, pk]
    func columns(schema: String, table: String) throws -> DBResult
    // The whole database at once, for the diagram. rows: [schema, table, column, type, "PK" or ""] for every
    // table (not views), in column order.
    func allColumns() throws -> DBResult
    // rows: [schema, table, column, referenced schema, referenced table, referenced column, "many" or ""];
    // single-column keys only. "many": the column holds several references (a PocketBase multi relation), so it's
    // only drawn on the diagram, not treated as a foreign key elsewhere.
    func allForeignKeys() throws -> DBResult
    // rows: [index name, index definition]
    func indexes(schema: String, table: String) throws -> DBResult
    // rows: [database name], the other databases this connection's server offers
    func databases() throws -> DBResult
    // WHERE fragment matching parameter $1 (a pattern from likePattern) against every column as text, ignoring case.
    func searchCondition(columns: [String]) -> String
    // Like execute, but stopped after `seconds`; the error then has sqlstate 57014 (query_canceled).
    func execute(_ sql: String, _ params: [DBValue], timeout seconds: TimeInterval) throws -> DBResult
    // Runs `work` in a transaction that may write even when the session is read-only (production after
    // confirmation). Commits when `work` returns, rolls back when it throws.
    func inWriteTransaction(_ work: () throws -> DBResult) throws -> DBResult
    // Statement that deletes every row of a table, e.g. for "Empty Table…".
    func emptyTableStatement(schema: String, table: String) -> String
    // The value to write for text the user typed into a cell that held `original` (a value this connection returned).
    // SQLite keeps the original's storage class (an integer stays an integer); Postgres returns the text as is.
    func value(forText text: String, replacing original: DBValue) -> DBValue
    // Schema editing: whether a foreign key can be added to an existing table (SQLite would have to rebuild it),
    // and the types offered when adding a column (any other type can be typed).
    var canAddForeignKeys: Bool { get }
    // The schema belongs to an application that keeps its own description of it (PocketBase's _collections):
    // PlainDB reads its relations but doesn't change its schema, which would leave that description behind.
    var managesOwnSchema: Bool { get }
    var commonTypes: [String] { get }
    // How the engine prints booleans, and what the grid writes back.
    var booleanTrue: String { get }
    var booleanFalse: String { get }
    // PocketBase files of a table; nil without file fields (and for engines without PocketBase).
    func pocketBaseFiles(table: String) -> PocketBaseFiles?
    // A file from PocketBase's own storage, pb_data/storage/<collection>/<record>/<name> next to the database (on the
    // server for a remote one); names are checked so the path can't leave that folder. At most maxBytes.
    func pocketBaseFile(collection: String, record: String, name: String, maxBytes: Int) throws -> Data
}

extension DBConnection {
    func execute(_ sql: String) throws -> DBResult { try execute(sql, []) }
    func pocketBaseFiles(table: String) -> PocketBaseFiles? { nil }
    func pocketBaseFile(collection: String, record: String, name: String, maxBytes: Int) throws -> Data {
        throw DBError(L("Not a PocketBase file name."))
    }
}

// UI strings: the English text is the key, translations live in Resources/<lang>.lproj.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

// Plural forms come from Localizable.stringsdict, e.g. LN("%lu rows", n).
func LN(_ format: String, _ n: Int) -> String {
    String.localizedStringWithFormat(L(format), UInt(max(n, 0)))
}

// Identifier quoting, identical in Postgres and SQLite.
func quoteIdent(_ name: String) -> String {
    "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

// LIKE pattern finding `term` anywhere, with %, _ and \ in it matched literally.
func likePattern(_ term: String) -> String {
    let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return "%" + escaped + "%"
}

// Where a foreign key column points, with the referenced table's columns (for ⌘F through it).
struct SearchReference: Sendable {
    var schema, table, column: String
    var columns: [String]
}

// ⌘F condition on $1: any of `columns` matches, or a foreign key points to a row in which any column matches
// (one level deep).
func searchCondition(_ conn: DBConnection, columns: [String], references: [String: SearchReference]) -> String {
    var parts = [conn.searchCondition(columns: columns)]
    for column in references.keys.sorted() {
        let ref = references[column]!
        parts.append("\(quoteIdent(column)) IN (SELECT \(quoteIdent(ref.column)) FROM \(quoteIdent(ref.schema)).\(quoteIdent(ref.table))"
                     + " WHERE \(conn.searchCondition(columns: ref.columns)))")
    }
    return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " OR ") + ")"
}

struct ChangeStatement: Sendable {
    var sql: String
    var params: [DBValue]
    var expectsOneRow: Bool
}

// Turns grid changes into statements. Order: DELETE, UPDATE, INSERT. Rows are matched by primary key using the
// original values in `result`. edits: row → column → value; inserted: one column → value map per new row.
// $1…$n placeholders work in both Postgres and SQLite.
func changeStatements(schema: String, table: String, result: DBResult, primaryKey: [String],
                      edits: [Int: [Int: DBValue]], deleted: IndexSet, inserted: [[Int: DBValue]]) -> [ChangeStatement] {
    guard !primaryKey.isEmpty else { return [] }
    let keyIndexes = primaryKey.compactMap { result.columns.firstIndex(of: $0) }
    guard keyIndexes.count == primaryKey.count else { return [] }

    let qualified = "\(quoteIdent(schema)).\(quoteIdent(table))"
    func whereClause(_ row: Int, _ params: inout [DBValue]) -> String {
        var parts: [String] = []
        for (pk, index) in zip(primaryKey, keyIndexes) {
            params.append(result.rows[row][index])
            parts.append("\(quoteIdent(pk)) = $\(params.count)")
        }
        return parts.joined(separator: " AND ")
    }

    var out: [ChangeStatement] = []
    for row in deleted {
        var params: [DBValue] = []
        let w = whereClause(row, &params)
        out.append(ChangeStatement(sql: "DELETE FROM \(qualified) WHERE \(w)", params: params, expectsOneRow: true))
    }
    for row in edits.keys.sorted() {
        guard !deleted.contains(row), let values = edits[row], !values.isEmpty else { continue }
        var params: [DBValue] = [], sets: [String] = []
        for col in values.keys.sorted() {
            params.append(values[col]!)
            sets.append("\(quoteIdent(result.columns[col])) = $\(params.count)")
        }
        let w = whereClause(row, &params)
        out.append(ChangeStatement(sql: "UPDATE \(qualified) SET \(sets.joined(separator: ", ")) WHERE \(w)", params: params, expectsOneRow: true))
    }
    for values in inserted {
        if values.isEmpty {
            out.append(ChangeStatement(sql: "INSERT INTO \(qualified) DEFAULT VALUES", params: [], expectsOneRow: false))
            continue
        }
        var params: [DBValue] = [], cols: [String] = [], marks: [String] = []
        for col in values.keys.sorted() {
            params.append(values[col]!)
            cols.append(quoteIdent(result.columns[col]))
            marks.append("$\(params.count)")
        }
        out.append(ChangeStatement(sql: "INSERT INTO \(qualified) (\(cols.joined(separator: ", "))) VALUES (\(marks.joined(separator: ", ")))",
                                   params: params, expectsOneRow: false))
    }
    return out
}

// Schema editing from the diagram. Names are quoted; `type` and `defaultExpr` are SQL as the user typed them
// (the statement is always shown before it runs). An empty default means none.
func addColumnStatement(schema: String, table: String, column: String, type: String, notNull: Bool, defaultExpr: String?) -> String {
    var sql = "ALTER TABLE \(quoteIdent(schema)).\(quoteIdent(table)) ADD COLUMN \(quoteIdent(column)) \(type)"
    if notNull { sql += " NOT NULL" }
    if let d = defaultExpr, !d.isEmpty { sql += " DEFAULT \(d)" }
    return sql + ";"
}

// onDelete: "" (no action), "CASCADE" or "SET NULL". The constraint is named <table>_<column>_fkey, as Postgres would.
func addForeignKeyStatement(schema: String, table: String, column: String, refSchema: String, refTable: String,
                            refColumn: String, onDelete: String) -> String {
    var sql = "ALTER TABLE \(quoteIdent(schema)).\(quoteIdent(table))\n  ADD CONSTRAINT \(quoteIdent("\(table)_\(column)_fkey")) FOREIGN KEY (\(quoteIdent(column)))\n"
        + "  REFERENCES \(quoteIdent(refSchema)).\(quoteIdent(refTable)) (\(quoteIdent(refColumn)))"
    if !onDelete.isEmpty { sql += "\n  ON DELETE \(onDelete)" }
    return sql + ";"
}

// Preview only: inlines params as literals. Execution always uses real params.
func inlineParams(_ sql: String, _ params: [DBValue]) -> String {
    let re = try! NSRegularExpression(pattern: "\\$(\\d+)")
    let ns = sql as NSString
    var out = ""
    var last = 0
    for m in re.matches(in: sql, range: NSRange(location: 0, length: ns.length)) {
        let i = Int(ns.substring(with: m.range(at: 1))) ?? 0
        guard i >= 1, i <= params.count else { continue }
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        if let s = params[i - 1].string { out += "'" + s.replacingOccurrences(of: "'", with: "''") + "'" } else { out += "NULL" }
        last = NSMaxRange(m.range)
    }
    return out + ns.substring(from: last)
}

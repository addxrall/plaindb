import CLibPQ
import Foundation

private func str(_ s: UnsafePointer<CChar>?) -> String {
    guard let s else { return "" }
    return String(validatingCString: s) ?? String(cString: s, encoding: .isoLatin1) ?? ""
}

// Postgres on libpq; the schema is read from pg_catalog.
final class PGConnection: DBConnection, @unchecked Sendable { // state is only touched on `queue`
    let queue = DispatchQueue(label: "plaindb.pg")
    private var conn: OpaquePointer?
    private let params: [String: String]

    // params: libpq keywords (host, port, user, password, dbname).
    // readOnly sets default_transaction_read_only, so the server itself rejects writes
    // (SQLSTATE 25006) unless you explicitly open BEGIN READ WRITE.
    init(params: [String: String], readOnly: Bool) {
        var p = params
        p["client_encoding"] = "UTF8"
        p["connect_timeout"] = "10"
        p["application_name"] = "PlainDB"
        if readOnly { p["options"] = "-c default_transaction_read_only=on" }
        self.params = p
    }

    deinit { close() }

    func open() throws {
        let keys = Array(params.keys)
        let k = keys.map { strdup($0) } + [nil], v = keys.map { strdup(params[$0]!) } + [nil]
        defer { (k + v).forEach { free($0) } }
        let c = k.map { UnsafePointer($0) }.withUnsafeBufferPointer { kp in
            v.map { UnsafePointer($0) }.withUnsafeBufferPointer { vp in PQconnectdbParams(kp.baseAddress, vp.baseAddress, 0) }
        }
        if PQstatus(c) == CONNECTION_OK {
            conn = c
            return
        }
        let message = str(PQerrorMessage(c))
        PQfinish(c)
        throw DBError(message)
    }

    func close() {
        if let conn { PQfinish(conn) }
        conn = nil
    }

    func execute(_ sql: String, _ params: [DBValue]) throws -> DBResult {
        guard let conn else { throw DBError(L("Not connected to the database.")) }
        // E.g. after the SSH tunnel was restarted. A query that failed mid-flight is not retried,
        // because it may already have written something. Only the next one reconnects.
        if PQstatus(conn) == CONNECTION_BAD { PQreset(conn) }

        // ponytail: the whole result is loaded into memory; huge SELECTs in the SQL tab
        // will need a limit or PQsetSingleRowMode.
        let res: OpaquePointer?
        if params.isEmpty {
            res = PQexec(conn, sql) // allows several statements at once
        } else {
            let values = params.map { $0.string.map { strdup($0) } ?? nil }
            defer { values.forEach { free($0) } }
            res = values.map { UnsafePointer($0) }.withUnsafeBufferPointer {
                PQexecParams(conn, sql, Int32(params.count), nil, $0.baseAddress, nil, nil, 0)
            }
        }
        defer { PQclear(res) }

        let status = PQresultStatus(res)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            var message = res.map { str(PQresultErrorMessage($0)) } ?? ""
            if message.isEmpty { message = str(PQerrorMessage(conn)) }
            let state = PQresultErrorField(res, Int32(UInt8(ascii: "C"))) // PG_DIAG_SQLSTATE
            throw DBError(message.trimmingCharacters(in: .whitespacesAndNewlines), sqlstate: state.map { str($0) })
        }

        let nf = PQnfields(res), nt = PQntuples(res)
        var result = DBResult()
        result.columns = (0..<nf).map { str(PQfname(res, $0)) }
        result.rows.reserveCapacity(Int(nt))
        for r in 0..<nt {
            result.rows.append((0..<nf).map { c in PQgetisnull(res, r, c) != 0 ? .null : .text(str(PQgetvalue(res, r, c))) })
        }
        result.affected = status == PGRES_COMMAND_OK ? Int(str(PQcmdTuples(res))) ?? 0 : -1
        return result
    }

    func tables() throws -> DBResult {
        // reltuples is the planner's estimate: free to read, -1 when the table was never analyzed (PG 14+).
        try execute("""
            SELECT n.nspname, c.relname,
             CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'view' ELSE 'table' END,
             CASE WHEN c.relkind IN ('r','p','m') AND c.reltuples >= 0 THEN c.reltuples::bigint END
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE c.relkind IN ('r','p','v','m')
               AND n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg_toast%'
             ORDER BY n.nspname = 'public' DESC, 1, 2
            """)
    }

    func columns(schema: String, table: String) throws -> DBResult {
        // pg_catalog instead of information_schema: the latter hides constraints from users with SELECT only.
        try execute("""
            SELECT a.attname AS kolumna,
             format_type(a.atttypid, a.atttypmod) AS typ,
             CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE '' END AS "null",
             pg_get_expr(d.adbin, d.adrelid) AS "default",
             CASE WHEN a.attnum = ANY(i.indkey) THEN 'PK' ELSE '' END AS pk
             FROM pg_attribute a
             LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             LEFT JOIN pg_index i ON i.indrelid = a.attrelid AND i.indisprimary
             WHERE a.attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                                 WHERE n.nspname = $1 AND c.relname = $2)
               AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY a.attnum
            """, [.text(schema), .text(table)])
    }

    func foreignKeys(schema: String, table: String) throws -> DBResult {
        try execute("""
            SELECT a.attname, nf.nspname, cf.relname, af.attname
             FROM pg_constraint con
             JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_class cf ON cf.oid = con.confrelid JOIN pg_namespace nf ON nf.oid = cf.relnamespace
             JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
             JOIN pg_attribute af ON af.attrelid = con.confrelid AND af.attnum = con.confkey[1]
             WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1 AND n.nspname = $1 AND c.relname = $2
             ORDER BY a.attnum
            """, [.text(schema), .text(table)])
    }

    func allColumns() throws -> DBResult {
        try execute("""
            SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod),
             CASE WHEN a.attnum = ANY(i.indkey) THEN 'PK' ELSE '' END
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
             LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
             WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname NOT LIKE 'pg_toast%'
             ORDER BY n.nspname, c.relname, a.attnum
            """)
    }

    func allForeignKeys() throws -> DBResult {
        try execute("""
            SELECT n.nspname, c.relname, a.attname, nf.nspname, cf.relname, af.attname, ''
             FROM pg_constraint con
             JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_class cf ON cf.oid = con.confrelid JOIN pg_namespace nf ON nf.oid = cf.relnamespace
             JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
             JOIN pg_attribute af ON af.attrelid = con.confrelid AND af.attnum = con.confkey[1]
             WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1
             ORDER BY 1, 2, 3
            """)
    }

    func indexes(schema: String, table: String) throws -> DBResult {
        try execute("SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 ORDER BY indexname",
                    [.text(schema), .text(table)])
    }

    func databases() throws -> DBResult {
        try execute("SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
    }

    func searchCondition(columns: [String]) -> String {
        "(" + columns.map { "\(quoteIdent($0))::text ILIKE $1" }.joined(separator: " OR ") + ")"
    }

    func execute(_ sql: String, _ params: [DBValue], timeout seconds: TimeInterval) throws -> DBResult {
        _ = try? execute("SET statement_timeout = \(Int((seconds * 1000).rounded()))")
        defer { _ = try? execute("RESET statement_timeout") }
        return try execute(sql, params)
    }

    // READ WRITE explicitly: a production session is read-only by default.
    func inWriteTransaction(_ work: () throws -> DBResult) throws -> DBResult {
        _ = try execute("BEGIN READ WRITE")
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
        "TRUNCATE TABLE \(quoteIdent(schema)).\(quoteIdent(table))"
    }

    // Params go in as untyped text and Postgres infers the column's type.
    func value(forText text: String, replacing original: DBValue) -> DBValue { .text(text) }

    let canAddForeignKeys = true
    let managesOwnSchema = false
    let commonTypes = ["integer", "bigint", "text", "varchar(255)", "boolean", "numeric(10,2)", "date", "timestamp",
                       "timestamptz", "jsonb", "uuid", "bytea"]
    let booleanTrue = "t", booleanFalse = "f"
}

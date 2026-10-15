#import "PGConnection.h"
#import <libpq-fe.h>

static NSString *Str(const char *s) {
    if (!s) return @"";
    return [NSString stringWithUTF8String:s] ?: [NSString stringWithCString:s encoding:NSISOLatin1StringEncoding];
}

@implementation PGConnection {
    PGconn *_conn;
    NSDictionary<NSString *, NSString *> *_params;
}
@synthesize queue = _queue;

- (instancetype)initWithParams:(NSDictionary<NSString *, NSString *> *)params readOnly:(BOOL)readOnly {
    if ((self = [super init])) {
        NSMutableDictionary *p = [params mutableCopy];
        p[@"client_encoding"] = @"UTF8";
        p[@"connect_timeout"] = @"10";
        p[@"application_name"] = @"PlainDB";
        if (readOnly) p[@"options"] = @"-c default_transaction_read_only=on";
        _params = p;
        _queue = dispatch_queue_create("plaindb.pg", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (BOOL)open:(NSError **)error {
    NSArray<NSString *> *keys = _params.allKeys;
    const char *k[keys.count + 1], *v[keys.count + 1];
    for (NSUInteger i = 0; i < keys.count; i++) {
        k[i] = keys[i].UTF8String;
        v[i] = _params[keys[i]].UTF8String;
    }
    k[keys.count] = v[keys.count] = NULL;
    _conn = PQconnectdbParams(k, v, 0);
    if (PQstatus(_conn) == CONNECTION_OK) return YES;
    if (error) *error = DBError(Str(PQerrorMessage(_conn)), nil);
    PQfinish(_conn);
    _conn = NULL;
    return NO;
}

- (void)close {
    if (_conn) PQfinish(_conn);
    _conn = NULL;
}

- (DBResult *)execute:(NSString *)sql params:(NSArray *)params error:(NSError **)error {
    if (!_conn) {
        if (error) *error = DBError(L(@"Not connected to the database."), nil);
        return nil;
    }
    // E.g. after the SSH tunnel was restarted. A query that failed mid-flight is not retried,
    // because it may already have written something. Only the next one reconnects.
    if (PQstatus(_conn) == CONNECTION_BAD) PQreset(_conn);

    // ponytail: the whole result is loaded into memory; huge SELECTs in the SQL tab
    // will need a limit or PQsetSingleRowMode.
    PGresult *res;
    if (params.count == 0) {
        res = PQexec(_conn, sql.UTF8String); // allows several statements at once
    } else {
        NSMutableArray *strings = [NSMutableArray arrayWithCapacity:params.count];
        const char *values[params.count];
        for (NSUInteger i = 0; i < params.count; i++) {
            id p = params[i];
            NSString *s = p == NSNull.null ? nil : [p description];
            if (s) [strings addObject:s]; // keeps the UTF8String buffer alive
            values[i] = s.UTF8String;
        }
        res = PQexecParams(_conn, sql.UTF8String, (int)params.count, NULL, values, NULL, NULL, 0);
    }

    ExecStatusType status = PQresultStatus(res);
    if (status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK) {
        if (error) {
            const char *msg = res ? PQresultErrorMessage(res) : "";
            if (!*msg) msg = PQerrorMessage(_conn);
            const char *state = PQresultErrorField(res, PG_DIAG_SQLSTATE);
            *error = DBError([Str(msg) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                             state ? Str(state) : nil);
        }
        PQclear(res);
        return nil;
    }

    int nf = PQnfields(res), nt = PQntuples(res);
    NSMutableArray *columns = [NSMutableArray arrayWithCapacity:nf];
    for (int c = 0; c < nf; c++) [columns addObject:Str(PQfname(res, c))];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:nt];
    for (int r = 0; r < nt; r++) {
        NSMutableArray *row = [NSMutableArray arrayWithCapacity:nf];
        for (int c = 0; c < nf; c++)
            [row addObject:PQgetisnull(res, r, c) ? NSNull.null : Str(PQgetvalue(res, r, c))];
        [rows addObject:row];
    }

    DBResult *result = [DBResult new];
    result.columns = columns;
    result.rows = rows;
    result.affected = status == PGRES_COMMAND_OK ? atol(PQcmdTuples(res)) : -1;
    PQclear(res);
    return result;
}

- (DBResult *)tables:(NSError **)error {
    // reltuples is the planner's estimate: free to read, -1 when the table was never analyzed (PG 14+).
    return [self execute:@"SELECT n.nspname, c.relname,"
                          " CASE c.relkind WHEN 'v' THEN 'view' WHEN 'm' THEN 'view' ELSE 'table' END,"
                          " CASE WHEN c.relkind IN ('r','p','m') AND c.reltuples >= 0 THEN c.reltuples::bigint END"
                          " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                          " WHERE c.relkind IN ('r','p','v','m')"
                          "   AND n.nspname NOT IN ('pg_catalog','information_schema')"
                          "   AND n.nspname NOT LIKE 'pg_toast%'"
                          " ORDER BY n.nspname = 'public' DESC, 1, 2"
                  params:nil error:error];
}

- (DBResult *)columnsInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    // pg_catalog instead of information_schema: the latter hides constraints from users with SELECT only.
    return [self execute:@"SELECT a.attname AS kolumna,"
                          " format_type(a.atttypid, a.atttypmod) AS typ,"
                          " CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE '' END AS \"null\","
                          " pg_get_expr(d.adbin, d.adrelid) AS \"default\","
                          " CASE WHEN a.attnum = ANY(i.indkey) THEN 'PK' ELSE '' END AS pk"
                          " FROM pg_attribute a"
                          " LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum"
                          " LEFT JOIN pg_index i ON i.indrelid = a.attrelid AND i.indisprimary"
                          " WHERE a.attrelid = (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                          "                     WHERE n.nspname = $1 AND c.relname = $2)"
                          "   AND a.attnum > 0 AND NOT a.attisdropped"
                          " ORDER BY a.attnum"
                  params:@[schema, table] error:error];
}

- (DBResult *)foreignKeysInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    return [self execute:@"SELECT a.attname, nf.nspname, cf.relname, af.attname"
                          " FROM pg_constraint con"
                          " JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace"
                          " JOIN pg_class cf ON cf.oid = con.confrelid JOIN pg_namespace nf ON nf.oid = cf.relnamespace"
                          " JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]"
                          " JOIN pg_attribute af ON af.attrelid = con.confrelid AND af.attnum = con.confkey[1]"
                          " WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1 AND n.nspname = $1 AND c.relname = $2"
                          " ORDER BY a.attnum"
                  params:@[schema, table] error:error];
}

- (DBResult *)allColumns:(NSError **)error {
    return [self execute:@"SELECT n.nspname, c.relname, a.attname, format_type(a.atttypid, a.atttypmod),"
                          " CASE WHEN a.attnum = ANY(i.indkey) THEN 'PK' ELSE '' END"
                          " FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace"
                          " JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped"
                          " LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary"
                          " WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema')"
                          "   AND n.nspname NOT LIKE 'pg_toast%'"
                          " ORDER BY n.nspname, c.relname, a.attnum"
                  params:nil error:error];
}

- (DBResult *)allForeignKeys:(NSError **)error {
    return [self execute:@"SELECT n.nspname, c.relname, a.attname, nf.nspname, cf.relname, af.attname, ''"
                          " FROM pg_constraint con"
                          " JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace"
                          " JOIN pg_class cf ON cf.oid = con.confrelid JOIN pg_namespace nf ON nf.oid = cf.relnamespace"
                          " JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]"
                          " JOIN pg_attribute af ON af.attrelid = con.confrelid AND af.attnum = con.confkey[1]"
                          " WHERE con.contype = 'f' AND array_length(con.conkey, 1) = 1"
                          " ORDER BY 1, 2, 3"
                  params:nil error:error];
}

- (BOOL)managesOwnSchema {
    return NO;
}

- (DBResult *)databases:(NSError **)error {
    return [self execute:@"SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" params:nil error:error];
}

- (NSString *)searchConditionForColumns:(NSArray<NSString *> *)columns {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *c in columns) [parts addObject:[NSString stringWithFormat:@"%@::text ILIKE $1", DBQuoteIdent(c)]];
    return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@" OR "]];
}

- (DBResult *)execute:(NSString *)sql params:(NSArray *)params timeout:(NSTimeInterval)seconds error:(NSError **)error {
    [self execute:[NSString stringWithFormat:@"SET statement_timeout = %ld", lround(seconds * 1000)] params:nil error:NULL];
    DBResult *r = [self execute:sql params:params error:error];
    [self execute:@"RESET statement_timeout" params:nil error:NULL];
    return r;
}

// READ WRITE explicitly: a production session is read-only by default.
- (DBResult *)inWriteTransaction:(DBResult *(^)(NSError **))work error:(NSError **)error {
    if (![self execute:@"BEGIN READ WRITE" params:nil error:error]) return nil;
    DBResult *r = work(error);
    if (r && [self execute:@"COMMIT" params:nil error:error]) return r;
    [self execute:@"ROLLBACK" params:nil error:NULL];
    return nil;
}

- (NSString *)emptyTableStatementForSchema:(NSString *)schema table:(NSString *)table {
    return [NSString stringWithFormat:@"TRUNCATE TABLE %@.%@", DBQuoteIdent(schema), DBQuoteIdent(table)];
}

// Params go in as untyped text and Postgres infers the column's type.
- (id)valueForText:(NSString *)text replacing:(id)original {
    return text;
}

- (BOOL)canAddForeignKeys {
    return YES;
}

- (NSArray<NSString *> *)commonTypes {
    return @[@"integer", @"bigint", @"text", @"varchar(255)", @"boolean", @"numeric(10,2)", @"date", @"timestamp",
             @"timestamptz", @"jsonb", @"uuid", @"bytea"];
}

- (NSString *)booleanTrue {
    return @"t";
}

- (NSString *)booleanFalse {
    return @"f";
}

- (DBResult *)indexesInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    return [self execute:@"SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2 ORDER BY indexname"
                  params:@[schema, table] error:error];
}

@end

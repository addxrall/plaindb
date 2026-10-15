#import "SQLiteConnection.h"
#import <sqlite3.h>

static NSString *Text(const unsigned char *s) {
    return s ? ([NSString stringWithUTF8String:(const char *)s] ?: @"") : @"";
}

// A value read from SQLite that isn't TEXT (an integer, real or BLOB), shown as text like everything else but
// remembering its storage class, so binding it back keeps it: a row is found by its integer key even in a
// column without a declared type, and an edited number stays a number. TEXT values stay plain strings.
@interface SQLiteValue : NSString
@property (nonatomic, readonly) int storage; // SQLITE_INTEGER, SQLITE_FLOAT or SQLITE_BLOB
- (instancetype)initWithString:(NSString *)string storage:(int)storage;
@end

@implementation SQLiteValue {
    NSString *_string;
}
- (instancetype)initWithString:(NSString *)string storage:(int)storage {
    if ((self = [super init])) {
        _string = [string copy];
        _storage = storage;
    }
    return self;
}
- (NSUInteger)length { return _string.length; }
- (unichar)characterAtIndex:(NSUInteger)index { return [_string characterAtIndex:index]; }
- (void)getCharacters:(unichar *)buffer range:(NSRange)range { [_string getCharacters:buffer range:range]; }
- (id)copyWithZone:(NSZone *)zone { return self; } // immutable; a plain copy would drop the storage class
@end

// "\x0a0b" (the form BLOBs are shown in) → bytes, or nil.
static NSData *HexBytes(NSString *s) {
    if (![s hasPrefix:@"\\x"] || s.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(s.length - 2) / 2];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned value;
        NSScanner *scanner = [NSScanner scannerWithString:[s substringWithRange:NSMakeRange(2 + 2 * i, 2)]];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
        bytes[i] = value;
    }
    return data;
}

static BOOL IsWholeNumber(NSString *s, BOOL real) {
    NSScanner *scanner = [NSScanner scannerWithString:s];
    scanner.charactersToBeSkipped = nil;
    scanner.locale = nil; // "1.5", whatever the user's locale
    return (real ? [scanner scanDouble:NULL] : [scanner scanLongLong:NULL]) && scanner.isAtEnd;
}

// LIKE with \ as the escape character, on already case-folded text. % matches any run, _ one character.
static BOOL LikeMatch(const unichar *s, NSUInteger n, const unichar *p, NSUInteger m) {
    NSUInteger i = 0, j = 0, star = NSNotFound, mark = 0;
    while (i < n) {
        if (j < m && p[j] == '%') {
            star = ++j;
            mark = i;
            continue;
        }
        if (j < m) {
            BOOL escaped = p[j] == '\\' && j + 1 < m;
            unichar c = escaped ? p[j + 1] : p[j];
            if ((!escaped && c == '_') || c == s[i]) {
                i++;
                j += escaped ? 2 : 1;
                continue;
            }
        }
        if (star == NSNotFound) return NO;
        j = star; // let the last % take one more character
        i = ++mark;
    }
    while (j < m && p[j] == '%') j++;
    return j == m;
}

// plaindb_like(value, pattern): LIKE ignoring case for all of Unicode (SQLite's own LIKE folds ASCII only).
static void LikeFunction(sqlite3_context *context, int argc, sqlite3_value **argv) {
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL || sqlite3_value_type(argv[1]) == SQLITE_NULL) return sqlite3_result_null(context);
    @autoreleasepool {
        NSString *value = [Text(sqlite3_value_text(argv[0])) stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil];
        NSString *pattern = [Text(sqlite3_value_text(argv[1])) stringByFoldingWithOptions:NSCaseInsensitiveSearch locale:nil];
        NSUInteger n = value.length, m = pattern.length;
        unichar *s = malloc(MAX(n, 1) * sizeof(unichar)), *p = malloc(MAX(m, 1) * sizeof(unichar));
        [value getCharacters:s range:NSMakeRange(0, n)];
        [pattern getCharacters:p range:NSMakeRange(0, m)];
        sqlite3_result_int(context, LikeMatch(s, n, p, m));
        free(s);
        free(p);
    }
}

@implementation SQLiteConnection {
    sqlite3 *_db;
    NSString *_path;
    BOOL _readOnly;
    CFAbsoluteTime _deadline; // 0 = no time limit
}
@synthesize queue = _queue;

// Called by SQLite every 1000 VM steps; non-zero interrupts the statement (SQLITE_INTERRUPT).
static int Progress(void *context) {
    SQLiteConnection *c = (__bridge SQLiteConnection *)context;
    return c->_deadline > 0 && CFAbsoluteTimeGetCurrent() > c->_deadline;
}

- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly {
    if ((self = [super init])) {
        _path = [path copy];
        _readOnly = readOnly;
        _queue = dispatch_queue_create("plaindb.sqlite", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (NSError *)lastError {
    int code = sqlite3_errcode(_db) & 0xff;
    NSString *state = code == SQLITE_INTERRUPT ? @"57014" : code == SQLITE_READONLY ? @"25006" : nil;
    return DBError(Text((const unsigned char *)sqlite3_errmsg(_db)), state);
}

- (BOOL)open:(NSError **)error {
    // never create a file: a missing one is an error, not a new empty database
    if (![NSFileManager.defaultManager fileExistsAtPath:_path]) {
        if (error) *error = DBError([NSString stringWithFormat:L(@"The file %@ doesn't exist."), _path.lastPathComponent], nil);
        return NO;
    }
    if (sqlite3_open_v2(_path.fileSystemRepresentation, &_db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        if (error) *error = [self lastError];
        [self close];
        return NO;
    }
    sqlite3_busy_timeout(_db, 3000); // another program may be writing to the file
    sqlite3_progress_handler(_db, 1000, Progress, (__bridge void *)self);
    sqlite3_create_function_v2(_db, "plaindb_like", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, NULL, LikeFunction, NULL, NULL, NULL);
    // reading the schema also fails for files that aren't SQLite databases
    if (![self execute:@"SELECT count(*) FROM sqlite_schema" params:nil error:error] ||
        ![self execute:@"PRAGMA foreign_keys = ON" params:nil error:error] ||
        (_readOnly && ![self execute:@"PRAGMA query_only = ON" params:nil error:error])) {
        [self close];
        return NO;
    }
    return YES;
}

- (void)close {
    if (_db) sqlite3_close_v2(_db);
    _db = NULL;
}

// Runs the statements one after another; the result is the last one that returned columns (or the last
// statement, if none did). $1, $2 … are bound by name: SQLite numbers parameters in order of first
// appearance, so `IN ($2, $3) AND … $1` would bind wrongly by position.
- (DBResult *)execute:(NSString *)sql params:(NSArray *)params error:(NSError **)error {
    if (!_db) {
        if (error) *error = DBError(L(@"Not connected to the database."), nil);
        return nil;
    }
    NSData *source = [sql dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *buffer = [source mutableCopy];
    [buffer appendBytes:"" length:1];
    const char *tail = buffer.bytes;
    // Several statements outside a transaction run all or nothing, as one Postgres PQexec does: inside a savepoint,
    // unless the script handles transactions itself.
    static NSRegularExpression *transactional;
    if (!transactional)
        transactional = [NSRegularExpression regularExpressionWithPattern:@"\\b(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|END\\s+TRANSACTION)\\b"
                                                                  options:NSRegularExpressionCaseInsensitive error:nil];
    BOOL batch = NO;
    DBResult *last = nil;
    while (tail && *tail) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(_db, tail, -1, &stmt, &tail) != SQLITE_OK) {
            if (error) *error = [self lastError];
            if (batch) sqlite3_exec(_db, "ROLLBACK TO plaindb_batch; RELEASE plaindb_batch", NULL, NULL, NULL);
            return nil;
        }
        if (!stmt) continue; // only whitespace or a comment was left
        if (!last && *tail && sqlite3_get_autocommit(_db) &&
            ![transactional firstMatchInString:sql options:0 range:NSMakeRange(0, sql.length)]) {
            batch = sqlite3_exec(_db, "SAVEPOINT plaindb_batch", NULL, NULL, NULL) == SQLITE_OK; // more statements follow
        }
        for (NSUInteger i = 0; i < params.count; i++) {
            int index = sqlite3_bind_parameter_index(stmt, [NSString stringWithFormat:@"$%lu", (unsigned long)i + 1].UTF8String);
            if (!index) continue;
            id p = params[i];
            int storage = [p isKindOfClass:SQLiteValue.class] ? ((SQLiteValue *)p).storage : SQLITE_TEXT;
            NSData *blob = storage == SQLITE_BLOB ? HexBytes(p) : nil;
            if (p == NSNull.null) sqlite3_bind_null(stmt, index);
            else if (storage == SQLITE_INTEGER) sqlite3_bind_int64(stmt, index, [p longLongValue]);
            else if (storage == SQLITE_FLOAT) sqlite3_bind_double(stmt, index, [p doubleValue]);
            else if (blob) sqlite3_bind_blob(stmt, index, blob.bytes, (int)blob.length, SQLITE_TRANSIENT);
            else sqlite3_bind_text(stmt, index, [p description].UTF8String, -1, SQLITE_TRANSIENT);
        }
        int columns = sqlite3_column_count(stmt);
        NSMutableArray *names = [NSMutableArray arrayWithCapacity:columns];
        for (int c = 0; c < columns; c++) [names addObject:Text((const unsigned char *)sqlite3_column_name(stmt, c))];
        NSMutableArray *rows = [NSMutableArray new];
        int rc;
        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            NSMutableArray *row = [NSMutableArray arrayWithCapacity:columns];
            for (int c = 0; c < columns; c++) [row addObject:[self valueOf:stmt column:c]];
            [rows addObject:row];
        }
        if (rc != SQLITE_DONE) {
            if (error) *error = [self lastError];
            sqlite3_finalize(stmt);
            if (batch) sqlite3_exec(_db, "ROLLBACK TO plaindb_batch; RELEASE plaindb_batch", NULL, NULL, NULL);
            return nil;
        }
        sqlite3_finalize(stmt);
        DBResult *result = [DBResult new];
        result.columns = names;
        result.rows = rows;
        result.affected = columns ? -1 : sqlite3_changes(_db);
        if (columns || !last.columns.count) last = result;
    }
    if (batch && sqlite3_exec(_db, "RELEASE plaindb_batch", NULL, NULL, NULL) != SQLITE_OK) {
        if (error) *error = [self lastError];
        return nil;
    }
    if (!last) {
        last = [DBResult new];
        last.columns = @[];
        last.rows = @[];
        last.affected = 0;
    }
    return last;
}

// Everything as text, like Postgres: numbers as SQLite prints them, BLOBs as \x hex (the form of Postgres bytea).
- (id)valueOf:(sqlite3_stmt *)stmt column:(int)c {
    int storage = sqlite3_column_type(stmt, c);
    switch (storage) {
    case SQLITE_NULL: return NSNull.null;
    case SQLITE_TEXT: return Text(sqlite3_column_text(stmt, c));
    case SQLITE_BLOB: {
        const uint8_t *bytes = sqlite3_column_blob(stmt, c);
        int n = sqlite3_column_bytes(stmt, c);
        NSMutableString *hex = [NSMutableString stringWithCapacity:2 + 2 * n];
        [hex appendString:@"\\x"];
        for (int i = 0; i < n; i++) [hex appendFormat:@"%02x", bytes[i]];
        return [[SQLiteValue alloc] initWithString:hex storage:SQLITE_BLOB];
    }
    default: return [[SQLiteValue alloc] initWithString:Text(sqlite3_column_text(stmt, c)) storage:storage];
    }
}

- (DBResult *)execute:(NSString *)sql params:(NSArray *)params timeout:(NSTimeInterval)seconds error:(NSError **)error {
    _deadline = CFAbsoluteTimeGetCurrent() + seconds;
    DBResult *r = [self execute:sql params:params error:error];
    _deadline = 0;
    return r;
}

- (DBResult *)inWriteTransaction:(DBResult *(^)(NSError **))work error:(NSError **)error {
    if (_readOnly) [self execute:@"PRAGMA query_only = OFF" params:nil error:NULL];
    DBResult *r = nil;
    if ([self execute:@"BEGIN" params:nil error:error]) {
        r = work(error);
        if (r && ![self execute:@"COMMIT" params:nil error:error]) r = nil;
        if (!r) [self execute:@"ROLLBACK" params:nil error:NULL];
    }
    if (_readOnly) [self execute:@"PRAGMA query_only = ON" params:nil error:NULL];
    return r;
}

- (NSString *)emptyTableStatementForSchema:(NSString *)schema table:(NSString *)table {
    return [NSString stringWithFormat:@"DELETE FROM %@.%@", DBQuoteIdent(schema), DBQuoteIdent(table)];
}

// Typed text takes the storage class of the value it replaces when it fits it; otherwise it's stored as typed
// (and a column with a declared type applies its own affinity).
- (id)valueForText:(NSString *)text replacing:(id)original {
    if (![original isKindOfClass:SQLiteValue.class] || ![text isKindOfClass:NSString.class]) return text;
    int storage = ((SQLiteValue *)original).storage;
    BOOL fits = storage == SQLITE_BLOB ? HexBytes(text) != nil : IsWholeNumber(text, storage == SQLITE_FLOAT);
    return fits ? [[SQLiteValue alloc] initWithString:text storage:storage] : text;
}

// ALTER TABLE can't add a constraint in SQLite: the table would have to be rebuilt.
- (BOOL)canAddForeignKeys {
    return NO;
}

- (NSArray<NSString *> *)commonTypes {
    return @[@"INTEGER", @"TEXT", @"REAL", @"NUMERIC", @"BLOB", @"BOOLEAN", @"DATE", @"DATETIME"];
}

- (NSString *)booleanTrue {
    return @"1";
}

- (NSString *)booleanFalse {
    return @"0";
}

- (DBResult *)tables:(NSError **)error {
    return [self execute:@"SELECT 'main', name, CASE type WHEN 'view' THEN 'view' ELSE 'table' END, NULL"
                          " FROM sqlite_schema WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name"
                  params:nil error:error];
}

- (DBResult *)columnsInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    DBResult *info = [self execute:@"SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_info($1)" params:@[table] error:error];
    if (!info) return nil;
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *c in info.rows)
        [rows addObject:@[c[0], c[1], [c[2] isEqual:@"1"] ? @"NOT NULL" : @"", c[3], [c[4] isEqual:@"0"] ? @"" : @"PK"]];
    info.rows = rows;
    return info;
}

// Single-column keys only; a key without a target column points at the other table's primary key.
- (DBResult *)foreignKeysInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    DBResult *list = [self execute:@"SELECT id, \"from\", \"table\", \"to\" FROM pragma_foreign_key_list($1) ORDER BY id, seq" params:@[table] error:error];
    if (!list) return nil;
    NSCountedSet *parts = [NSCountedSet new];
    for (NSArray *k in list.rows) [parts addObject:k[0]];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *k in list.rows) {
        if ([parts countForObject:k[0]] != 1) continue;
        id to = k[3];
        if (to == NSNull.null) {
            DBResult *pk = [self execute:@"SELECT name FROM pragma_table_info($1) WHERE pk = 1" params:@[k[2]] error:NULL];
            if (pk.rows.count != 1) continue;
            to = pk.rows[0][0];
        }
        [rows addObject:@[k[1], @"main", k[2], to]];
    }
    NSMutableSet *keyed = [NSMutableSet new];
    for (NSArray *k in rows) [keyed addObject:k[0]];
    for (NSArray *r in [self pocketBaseRelations]) // single PocketBase relations work like foreign keys
        if ([r[0] isEqual:table] && ![r[3] isEqual:@"many"] && ![keyed containsObject:r[1]])
            [rows addObject:@[r[1], @"main", r[2], @"id"]];
    list.columns = @[@"column", @"schema", @"table", @"referenced"];
    list.rows = rows;
    return list;
}

#pragma mark - PocketBase

// PocketBase describes its collections in _collections: a JSON list of fields per collection, in a column named
// "fields" (v0.23+) or "schema" (older, with the relation's settings under "options"). nil for other files.
- (NSString *)pocketBaseFieldsColumn {
    DBResult *columns = [self execute:@"SELECT name FROM pragma_table_info('_collections') WHERE name IN ('fields', 'schema') ORDER BY name"
                               params:nil error:NULL];
    return columns.rows.firstObject.firstObject;
}

- (BOOL)managesOwnSchema {
    return [self pocketBaseFieldsColumn] != nil;
}

// rows: [table, column, referenced table, @"many" or @""]; the referenced column is always "id".
- (NSArray<NSArray *> *)pocketBaseRelations {
    NSString *fields = [self pocketBaseFieldsColumn];
    if (!fields) return @[];
    NSString *sql = [NSString stringWithFormat:
        @"SELECT c.name, json_extract(f.value, '$.name'), t.name,"
         " CASE WHEN COALESCE(json_extract(f.value, '$.maxSelect'), json_extract(f.value, '$.options.maxSelect'), 1) > 1 THEN 'many' ELSE '' END"
         " FROM _collections c, json_each(c.%@) f"
         " JOIN _collections t ON t.id = COALESCE(json_extract(f.value, '$.collectionId'), json_extract(f.value, '$.options.collectionId'))"
         " WHERE json_extract(f.value, '$.type') = 'relation'"
         " ORDER BY 1, 2", DBQuoteIdent(fields)];
    return [self execute:sql params:nil error:NULL].rows ?: @[];
}

- (DBResult *)indexesInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error {
    DBResult *list = [self execute:@"SELECT name, sql, \"unique\" FROM pragma_index_list($1) JOIN sqlite_schema USING (name) ORDER BY name"
                            params:@[table] error:error];
    if (!list) return nil;
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *i in list.rows) {
        if (i[1] != NSNull.null) {
            [rows addObject:@[i[0], i[1]]];
            continue;
        }
        DBResult *cols = [self execute:@"SELECT name FROM pragma_index_info($1) ORDER BY seqno" params:@[i[0]] error:NULL];
        NSMutableArray *names = [NSMutableArray new];
        for (NSArray *c in cols.rows) [names addObject:c[0]];
        [rows addObject:@[i[0], [NSString stringWithFormat:@"%@: %@(%@)", L(@"automatic"), [i[2] isEqual:@"1"] ? @"UNIQUE " : @"",
                                                          [names componentsJoinedByString:@", "]]]];
    }
    list.columns = @[@"name", @"definition"];
    list.rows = rows;
    return list;
}

// A local file: one PRAGMA per table is fast enough.
- (DBResult *)allColumns:(NSError **)error {
    NSMutableArray *rows = [NSMutableArray new];
    DBResult *tables = [self tables:error];
    for (NSArray *t in tables.rows) {
        if (![t[2] isEqual:@"table"]) continue;
        for (NSArray *c in [self columnsInSchema:t[0] table:t[1] error:NULL].rows) [rows addObject:@[t[0], t[1], c[0], c[1], c[4]]];
    }
    DBResult *all = [DBResult new];
    all.columns = @[@"schema", @"table", @"column", @"type", @"pk"];
    all.rows = rows;
    return tables ? all : nil;
}

- (DBResult *)allForeignKeys:(NSError **)error {
    NSMutableArray *rows = [NSMutableArray new];
    DBResult *tables = [self tables:error];
    for (NSArray *t in tables.rows) {
        if (![t[2] isEqual:@"table"]) continue;
        for (NSArray *k in [self foreignKeysInSchema:t[0] table:t[1] error:NULL].rows) [rows addObject:@[t[0], t[1], k[0], k[1], k[2], k[3], @""]];
    }
    for (NSArray *r in [self pocketBaseRelations]) // multi relations: only on the diagram
        if ([r[3] isEqual:@"many"]) [rows addObject:@[@"main", r[0], r[1], @"main", r[2], @"id", @"many"]];
    DBResult *all = [DBResult new];
    all.columns = @[@"schema", @"table", @"column", @"referenced schema", @"referenced table", @"referenced column", @"many"];
    all.rows = rows;
    return tables ? all : nil;
}

- (DBResult *)databases:(NSError **)error {
    DBResult *none = [DBResult new];
    none.columns = @[@"name"];
    none.rows = @[];
    return none;
}

- (NSString *)searchConditionForColumns:(NSArray<NSString *> *)columns {
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *c in columns) [parts addObject:[NSString stringWithFormat:@"plaindb_like(CAST(%@ AS TEXT), $1)", DBQuoteIdent(c)]];
    return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@" OR "]];
}

@end

// Tests SQLiteConnection on temporary files: `make test`. Everything runs twice, on a local file and through the
// remote helper (the same helper ssh starts on a server, here run by the local python3), so both behave alike.
#import "SQLiteConnection.h"
#import <assert.h>
#import <signal.h>

static NSArray *Column(DBResult *r) {
    NSMutableArray *values = [NSMutableArray new];
    for (NSArray *row in r.rows) [values addObject:row[0]];
    return values;
}

typedef SQLiteConnection *(^Maker)(NSString *path, BOOL readOnly);

static NSString *Helper(void) {
    return [NSString stringWithContentsOfFile:@"Resources/sqlite_remote.py" encoding:NSUTF8StringEncoding error:NULL];
}

// The remote helper started by a local command instead of ssh.
static SQLiteConnection *Remote(NSArray *command, NSString *path, BOOL readOnly) {
    return [[SQLiteConnection alloc] initWithCommand:command helper:Helper() path:path readOnly:readOnly];
}

static NSArray *Python(void) {
    return @[@"/usr/bin/python3", @"-I", @"-u", @"-c", SQLiteRemoteBootstrap];
}

static NSString *NewDirectory(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static void Run(NSString *label, Maker make) {
    NSError *err = nil;
    NSString *dir = NewDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"test.db"];

    // a missing file is an error, and no file is created
    SQLiteConnection *missing = make(path, NO);
    assert(![missing open:&err] && err);
    assert(![NSFileManager.defaultManager fileExistsAtPath:path]);

    // not a database
    NSString *png = [dir stringByAppendingPathComponent:@"picture.db"];
    const char bytes[] = "\x89PNG\r\n\x1a\n not really a database, just bytes long enough to fill SQLite's 100 byte header .........";
    [[NSData dataWithBytes:bytes length:sizeof bytes] writeToFile:png atomically:YES];
    err = nil;
    assert(![make(png, NO) open:&err] && err.localizedDescription.length);

    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]; // an empty file is a valid empty database
    SQLiteConnection *db = make(path, NO);
    assert([db open:&err]);
    assert([db execute:@"CREATE TABLE drivers (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x', photo BLOB, score REAL);"
                        "CREATE TABLE cars (id INTEGER PRIMARY KEY, plate TEXT, driver_id INTEGER REFERENCES drivers, active BOOLEAN, bought DATE);"
                        "CREATE UNIQUE INDEX cars_plate ON cars (plate);"
                        "CREATE VIEW plates AS SELECT plate FROM cars;"
                        "INSERT INTO drivers (name, photo, score) VALUES ('Anna Kowalska', x'89504e47', 1.5), ('Jan Nowak', NULL, 2);"
                        "INSERT INTO cars (plate, driver_id, active, bought) VALUES ('WA 1', 1, 1, '2023-05-10'), ('KR 2', 2, 0, NULL), ('PO 3', NULL, NULL, NULL)"
                params:nil error:&err]);

    // schema
    DBResult *tables = [db tables:&err];
    assert(([tables.rows isEqual:(@[@[@"main", @"cars", @"table", NSNull.null], @[@"main", @"drivers", @"table", NSNull.null],
                                    @[@"main", @"plates", @"view", NSNull.null]])]));
    DBResult *cols = [db columnsInSchema:@"main" table:@"drivers" error:&err];
    assert(([cols.rows[0] isEqual:(@[@"id", @"INTEGER", @"", NSNull.null, @"PK"])]));
    assert(([cols.rows[1] isEqual:(@[@"name", @"TEXT", @"NOT NULL", @"'x'", @""])]));
    DBResult *fks = [db foreignKeysInSchema:@"main" table:@"cars" error:&err];
    assert(([fks.rows isEqual:(@[@[@"driver_id", @"main", @"drivers", @"id"]])])); // REFERENCES drivers → its primary key
    DBResult *idx = [db indexesInSchema:@"main" table:@"cars" error:&err];
    assert(idx.rows.count == 1 && [idx.rows[0][0] isEqual:@"cars_plate"] && [idx.rows[0][1] containsString:@"UNIQUE"]);
    assert([db databases:&err].rows.count == 0);

    // values as text; BLOB as \x hex like Postgres bytea
    DBResult *r = [db execute:@"SELECT id, photo, score FROM drivers ORDER BY id" params:nil error:&err];
    assert(([r.columns isEqual:(@[@"id", @"photo", @"score"])]));
    assert(([r.rows isEqual:(@[@[@"1", @"\\x89504e47", @"1.5"], @[@"2", NSNull.null, @"2.0"]])]));
    r = [db execute:@"SELECT 9223372036854775807, -9223372036854775808, 'a\nb ''q'' 😀 zażółć'" params:nil error:&err];
    assert(([r.rows[0] isEqual:(@[@"9223372036854775807", @"-9223372036854775808", @"a\nb 'q' 😀 zażółć"])]));
    // an empty result still has its columns; duplicate names stay
    r = [db execute:@"SELECT id, plate, id FROM cars WHERE 0" params:nil error:&err];
    assert(([r.columns isEqual:(@[@"id", @"plate", @"id"])]) && r.rows.count == 0);

    // named parameters: $2 appears before $1
    r = [db execute:@"SELECT plate FROM cars WHERE id IN ($2, $3) AND plate LIKE $1 ORDER BY id" params:@[@"%2%", @"1", @"2"] error:&err];
    assert([Column(r) isEqual:@[@"KR 2"]]);
    r = [db execute:@"SELECT $1, $1" params:@[NSNull.null] error:&err];
    assert(r.rows[0][0] == NSNull.null);

    // several statements: the last one with columns is the result; affected rows
    r = [db execute:@"UPDATE cars SET plate = plate WHERE id < 3; SELECT count(*) FROM cars" params:nil error:&err];
    assert([r.rows[0][0] isEqual:@"3"]);
    assert([db execute:@"UPDATE cars SET plate = plate WHERE id < 3" params:nil error:&err].affected == 2);
    assert([db execute:@"SELECT 1; -- a comment at the end\n" params:nil error:&err].rows.count == 1);
    assert(![db execute:@"SELECT nope" params:nil error:&err] && err.localizedDescription.length);

    // search: Polish letters ignoring case, wildcards literal, through foreign keys
    assert([db execute:@"INSERT INTO drivers (name) VALUES ('Zażółć Gęślą'), ('50% off_now'), ('a\\b')" params:nil error:&err]);
    NSArray *(^find)(NSString *) = ^NSArray *(NSString *term) {
        NSString *q = [NSString stringWithFormat:@"SELECT name FROM drivers WHERE %@ ORDER BY id", [db searchConditionForColumns:@[@"id", @"name", @"score"]]];
        return Column([db execute:q params:@[DBLikePattern(term)] error:NULL]);
    };
    assert([find(@"ŻÓŁĆ") isEqual:@[@"Zażółć Gęślą"]]);
    assert([find(@"50%") isEqual:@[@"50% off_now"]]);
    assert([find(@"o_f") isEqual:@[]]);
    assert([find(@"a\\b") isEqual:@[@"a\\b"]]);
    assert([find(@"1.5") isEqual:@[@"Anna Kowalska"]]);
    NSString *linked = DBSearchCondition(db, @[@"id", @"plate", @"driver_id"],
                                         @{@"driver_id": @[@"main", @"drivers", @"id", @[@"id", @"name"]]});
    r = [db execute:[NSString stringWithFormat:@"SELECT plate FROM cars WHERE %@ ORDER BY id", linked] params:@[DBLikePattern(@"kowal")] error:&err];
    assert([Column(r) isEqual:@[@"WA 1"]]);

    // the whole database's schema at once (for the diagram): tables only, not the view
    DBResult *allCols = [db allColumns:&err];
    NSMutableSet *tablesSeen = [NSMutableSet new];
    for (NSArray *c in allCols.rows) [tablesSeen addObject:c[1]];
    assert(([tablesSeen isEqual:[NSSet setWithArray:@[@"cars", @"drivers"]]]));
    assert(([allCols.rows[0] isEqual:(@[@"main", @"cars", @"id", @"INTEGER", @"PK"])])); // cars first, in column order
    assert(([[db allForeignKeys:&err].rows isEqual:(@[@[@"main", @"cars", @"driver_id", @"main", @"drivers", @"id", @""]])]));

    // schema editing: columns can be added; foreign keys can't without rebuilding the table
    assert(!db.canAddForeignKeys && [db.commonTypes containsObject:@"TEXT"]);
    assert([db inWriteTransaction:^DBResult *(NSError **e) {
        return [db execute:DBAddColumnStatement(@"main", @"drivers", @"note", @"TEXT", NO, @"'none'") params:nil error:e];
    } error:&err]);
    assert([[db execute:@"SELECT note FROM drivers WHERE id = 1" params:nil error:&err].rows[0][0] isEqual:@"none"]);

    // timeout
    NSError *slow = nil;
    assert(![db execute:@"WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT count(*) FROM n" params:nil timeout:0.2 error:&slow]);
    assert([slow.userInfo[@"sqlstate"] isEqual:@"57014"]);
    assert([db execute:@"SELECT count(*) FROM cars" params:nil error:&err]); // no deadline left behind

    // grid changes → SQL → file, with "main" as the schema
    DBResult *before = [db execute:@"SELECT * FROM cars ORDER BY id" params:nil error:&err];
    NSArray *stmts = DBChangeStatements(@"main", @"cars", before, @[@"id"], @{@0: @{@1: @"WA 9"}}, [NSIndexSet indexSetWithIndex:2], @[@{@1: @"GD 4"}]);
    DBResult *saved = [db inWriteTransaction:^DBResult *(NSError **e) {
        DBResult *last = nil;
        for (NSArray *s in stmts) if (!(last = [db execute:s[0] params:s[1] error:e])) return nil;
        return last;
    } error:&err];
    assert(saved);
    assert(([Column([db execute:@"SELECT plate FROM cars ORDER BY id" params:nil error:&err]) isEqual:(@[@"WA 9", @"KR 2", @"GD 4"])]));
    assert([[db emptyTableStatementForSchema:@"main" table:@"cars"] isEqual:@"DELETE FROM \"main\".\"cars\""]);
    assert([db.booleanTrue isEqual:@"1"] && [db.booleanFalse isEqual:@"0"]);

    // columns without a declared type keep what they store: rows are found by their integer key,
    // and edits keep the storage class of the value they replace (integer stays integer, BLOB stays BLOB)
    assert([db execute:@"CREATE TABLE u (id PRIMARY KEY, v, b, t, f); INSERT INTO u VALUES (5, 7, x'0102', '12', 0.5)" params:nil error:&err]);
    DBResult *u = [db execute:@"SELECT * FROM u" params:nil error:&err];
    NSArray *row = u.rows[0];
    assert([row[2] isEqual:@"\\x0102"] && [row[4] isEqual:@"0.5"]);
    NSDictionary *edits = @{@0: @{@1: [db valueForText:@"8" replacing:row[1]], @2: [db valueForText:@"\\x0a0b" replacing:row[2]],
                                 @3: [db valueForText:@"13" replacing:row[3]], @4: [db valueForText:@"2.25" replacing:row[4]]}};
    NSArray *untyped = DBChangeStatements(@"main", @"u", u, @[@"id"], edits, [NSIndexSet new], @[]);
    DBResult *changed = [db inWriteTransaction:^DBResult *(NSError **e) { return [db execute:untyped[0][0] params:untyped[0][1] error:e]; } error:&err];
    assert(changed.affected == 1); // the WHERE on the untyped key matched
    assert(([[db execute:@"SELECT typeof(v), v, typeof(b), hex(b), typeof(t), t, typeof(f), f FROM u" params:nil error:&err].rows[0]
             isEqual:(@[@"integer", @"8", @"blob", @"0A0B", @"text", @"13", @"real", @"2.25"])]));
    assert([[db valueForText:@"abc" replacing:row[1]] isEqual:@"abc"]); // not a number: stored as typed

    // several statements run all or nothing, as one Postgres PQexec does
    assert(![db execute:@"UPDATE cars SET plate = 'ZZ' WHERE id = 1; UPDATE nope SET x = 1" params:nil error:&err]);
    assert([[db execute:@"SELECT plate FROM cars WHERE id = 1" params:nil error:&err].rows[0][0] isEqual:@"WA 9"]);
    assert([db execute:@"UPDATE cars SET plate = 'WA 9' WHERE id = 1; SELECT 1" params:nil error:&err]); // and still work when they succeed
    [db close];

    // PocketBase keeps relations in _collections (JSON), not as foreign keys: single ones act as foreign keys
    // (preview, picker, search), multi ones (JSON arrays of ids) only show on the diagram, marked "many"
    NSString *pbPath = [dir stringByAppendingPathComponent:@"pb_data.db"];
    [NSFileManager.defaultManager createFileAtPath:pbPath contents:nil attributes:nil];
    SQLiteConnection *pb = make(pbPath, NO);
    assert([pb open:&err]);
    assert([pb execute:@"CREATE TABLE _collections (id TEXT PRIMARY KEY, name TEXT, type TEXT, fields JSON);"
                        "INSERT INTO _collections VALUES ('u1', 'users', 'auth', '[{\"name\":\"id\",\"type\":\"text\"},{\"name\":\"email\",\"type\":\"email\"}]'),"
                        " ('t1', 'tags', 'base', '[{\"name\":\"id\",\"type\":\"text\"},{\"name\":\"label\",\"type\":\"text\"}]'),"
                        " ('p1', 'posts', 'base', '[{\"name\":\"id\",\"type\":\"text\"},{\"name\":\"author\",\"type\":\"relation\",\"collectionId\":\"u1\",\"maxSelect\":1},"
                        "  {\"name\":\"tags\",\"type\":\"relation\",\"collectionId\":\"t1\",\"maxSelect\":5}]');"
                        "CREATE TABLE users (id TEXT PRIMARY KEY, email TEXT); INSERT INTO users VALUES ('abc', 'anna.kowalska@example.com');"
                        "CREATE TABLE tags (id TEXT PRIMARY KEY, label TEXT);"
                        "CREATE TABLE posts (id TEXT PRIMARY KEY, author TEXT, tags JSON, editor TEXT REFERENCES users);"
                        "INSERT INTO posts VALUES ('p', 'abc', '[]', NULL)"
                params:nil error:&err]);
    SQLiteConnection *plain = make(path, NO);
    assert([plain open:&err]);
    assert(pb.managesOwnSchema && !plain.managesOwnSchema);
    [plain close];
    assert(([[pb foreignKeysInSchema:@"main" table:@"posts" error:&err].rows
             isEqual:(@[@[@"editor", @"main", @"users", @"id"], @[@"author", @"main", @"users", @"id"]])])); // a real key and a relation
    NSArray *pbKeys = [pb allForeignKeys:&err].rows;
    assert(([pbKeys containsObject:(@[@"main", @"posts", @"author", @"main", @"users", @"id", @""])]));
    assert(([pbKeys containsObject:(@[@"main", @"posts", @"tags", @"main", @"tags", @"id", @"many"])]));
    NSString *throughAuthor = DBSearchCondition(pb, @[@"id", @"author"], @{@"author": @[@"main", @"users", @"id", @[@"id", @"email"]]});
    r = [pb execute:[NSString stringWithFormat:@"SELECT id FROM posts WHERE %@", throughAuthor] params:@[DBLikePattern(@"kowalska")] error:&err];
    assert(r.rows.count == 1);

    // PocketBase files: which columns hold them, and where they are (S3 settings without the keys, or pb_data/storage)
    assert([pb execute:@"UPDATE _collections SET fields = json_insert(fields, '$[#]', json('{\"name\":\"avatar\",\"type\":\"file\",\"maxSelect\":1}')) WHERE id = 'u1';"
                        "UPDATE _collections SET fields = json_insert(fields, '$[#]', json('{\"name\":\"files\",\"type\":\"file\",\"maxSelect\":3}')) WHERE id = 'p1';"
                        "CREATE TABLE _params (id TEXT PRIMARY KEY, value JSON);"
                        "INSERT INTO _params VALUES ('settings', '{\"s3\":{\"enabled\":false,\"bucket\":\"pb-files\",\"region\":\"eu-central-1\","
                        "\"endpoint\":\"https://s3.eu-central-1.amazonaws.com\",\"accessKey\":\"AKIAEXAMPLE\",\"secret\":\"s3cr3t\"}}')"
                params:nil error:&err]);
    NSDictionary *files = [pb pocketBaseFilesOfTable:@"posts"];
    assert(([files isEqual:(@{@"collection": @"p1", @"columns": @{@"files": @YES}})])); // S3 off: no "s3"
    assert([pb pocketBaseFilesOfTable:@"tags"] == nil);
    assert([pb execute:@"UPDATE _params SET value = json_set(value, '$.s3.enabled', json('true'))" params:nil error:&err]);
    files = [pb pocketBaseFilesOfTable:@"users"];
    assert(([files isEqual:(@{@"collection": @"u1", @"columns": @{@"avatar": @NO},
                              @"s3": @{@"bucket": @"pb-files", @"region": @"eu-central-1", @"endpoint": @"https://s3.eu-central-1.amazonaws.com"}})]));
    assert(![files.description containsString:@"s3cr3t"] && ![files.description containsString:@"AKIA"]);

    NSString *storage = [dir stringByAppendingPathComponent:@"storage/u1/abc"];
    [NSFileManager.defaultManager createDirectoryAtPath:storage withIntermediateDirectories:YES attributes:nil error:NULL];
    NSData *picture = [NSData dataWithBytes:"\x89PNG\r\n\x1a\n-picture-" length:17];
    [picture writeToFile:[storage stringByAppendingPathComponent:@"face_x1.png"] atomically:YES];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:[storage stringByAppendingPathComponent:@"escape.png"] withDestinationPath:path error:NULL];
    assert([[pb pocketBaseFileInCollection:@"u1" record:@"abc" name:@"face_x1.png" maxBytes:1024 error:&err] isEqual:picture]);
    for (NSArray *bad in @[@[@"u1", @"abc", @"../../test.db"], @[@"..", @"abc", @"face_x1.png"], @[@"u1", @"abc", @"escape.png"],
                           @[@"u1", @"abc", @"missing.png"], @[@"u1", @"abc", @""]]) {
        err = nil;
        // a limit far above test.db's size, so only the name and path checks can refuse these
        assert(![pb pocketBaseFileInCollection:bad[0] record:bad[1] name:bad[2] maxBytes:100000000 error:&err] && err.localizedDescription.length);
    }
    err = nil;
    assert(![pb pocketBaseFileInCollection:@"u1" record:@"abc" name:@"face_x1.png" maxBytes:8 error:&err] && err); // too big
    // a missing file says where it was looked for; no storage folder or no permission say so
    err = nil;
    assert(![pb pocketBaseFileInCollection:@"u1" record:@"abc" name:@"missing.png" maxBytes:1024 error:&err]);
    assert([err.localizedDescription containsString:[dir.stringByResolvingSymlinksInPath stringByAppendingPathComponent:@"storage/u1/abc/missing.png"]]);
    err = nil;
    assert(![pb pocketBaseFileInCollection:@"u9" record:@"abc" name:@"x.png" maxBytes:1024 error:&err] && [err.localizedDescription containsString:@"storage/u9/abc/x.png"]);
    NSString *locked = [dir stringByAppendingPathComponent:@"storage/u1/locked"];
    [NSFileManager.defaultManager createDirectoryAtPath:locked withIntermediateDirectories:YES attributes:nil error:NULL];
    [picture writeToFile:[locked stringByAppendingPathComponent:@"secret.png"] atomically:YES];
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0} ofItemAtPath:locked error:NULL];
    err = nil;
    assert(![pb pocketBaseFileInCollection:@"u1" record:@"locked" name:@"secret.png" maxBytes:1024 error:&err]);
    assert([err.localizedDescription.lowercaseString containsString:@"permission"]);
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:locked error:NULL];
    // encrypted settings (PocketBase's --encryptionEnv): where the files are is unknown, and said so
    assert([pb execute:@"UPDATE _params SET value = 'q83vEjRWeJA=' WHERE id = 'settings'" params:nil error:&err]);
    files = [pb pocketBaseFilesOfTable:@"users"];
    assert(!files[@"s3"] && [files[@"settingsUnreadable"] isEqual:@YES]);
    [pb close];

    // read-only: refused with 25006, allowed in a write transaction, read-only again afterwards
    SQLiteConnection *ro = make(path, YES);
    assert([ro open:&err]);
    NSError *refused = nil;
    assert(![ro execute:@"UPDATE cars SET plate = 'X'" params:nil error:&refused]);
    assert([refused.userInfo[@"sqlstate"] isEqual:@"25006"]);
    assert([ro inWriteTransaction:^DBResult *(NSError **e) { return [ro execute:@"UPDATE cars SET plate = 'RO' WHERE id = 2" params:nil error:e]; } error:&err]);
    refused = nil;
    assert(![ro execute:@"UPDATE cars SET plate = 'X'" params:nil error:&refused]);
    assert([refused.userInfo[@"sqlstate"] isEqual:@"25006"]);
    [ro close];

    // the directory stays: it's unique per run, under the system's temporary folder, which macOS cleans up itself
    printf("sqlite_test (%s): OK\n", label.UTF8String);
}

// What only the remote connection does: guards that hold even against SQL typed by hand, the process around it.
static void RunRemoteOnly(void) {
    NSError *err = nil;
    NSString *dir = NewDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"it's a \"file\" $HOME.db"]; // nothing in a path is interpreted
    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    SQLiteConnection *rw = Remote(Python(), path, NO);
    assert([rw open:&err]);
    assert([rw execute:@"CREATE TABLE cars (id INTEGER PRIMARY KEY, plate TEXT, price REAL, photo BLOB, note);"
                        "INSERT INTO cars (plate, price, photo, note) VALUES ('WA 1', 0.1, x'00ff', 1e20), ('KR 2', 1.0 / 3, NULL, -0.0), ('PO 3', 1e300 * 1e300, zeroblob(3), 7)"
                params:nil error:&err]);

    // the remote connection reads exactly what a local one reads, storage classes included
    SQLiteConnection *local = [[SQLiteConnection alloc] initWithPath:path readOnly:NO];
    assert([local open:&err]);
    for (NSString *q in @[@"SELECT * FROM cars ORDER BY id", @"SELECT typeof(price), price * 3, note || '' FROM cars", @"SELECT 1.5e-7, 123456789012345.678"]) {
        DBResult *a = [local execute:q params:nil error:&err], *b = [rw execute:q params:nil error:&err];
        assert([a.columns isEqual:b.columns] && [a.rows isEqual:b.rows]);
        for (NSUInteger i = 0; i < a.rows.count; i++)
            for (NSUInteger j = 0; j < [a.rows[i] count]; j++) assert([a.rows[i][j] class] == [b.rows[i][j] class]);
    }
    [local close];

    // read-only is enforced by the helper on the server, not only by PlainDB
    SQLiteConnection *ro = Remote(Python(), path, YES);
    assert([ro open:&err]);
    NSString *attached = [dir stringByAppendingPathComponent:@"attached.db"], *vacuumed = [dir stringByAppendingPathComponent:@"copy.db"];
    for (NSString *sql in @[@"PRAGMA query_only = OFF", @"PRAGMA main.QUERY_ONLY=0", @"PRAGMA journal_mode = DELETE", @"PRAGMA user_version = 5",
                            [NSString stringWithFormat:@"ATTACH '%@' AS other", attached], [NSString stringWithFormat:@"VACUUM INTO '%@'", vacuumed]]) {
        NSError *refused = nil;
        assert(![ro execute:sql params:nil error:&refused]);
        assert([refused.userInfo[@"sqlstate"] isEqual:@"25006"]);
    }
    assert(![NSFileManager.defaultManager fileExistsAtPath:attached] && ![NSFileManager.defaultManager fileExistsAtPath:vacuumed]);
    NSError *refused = nil;
    assert(![ro execute:@"UPDATE cars SET plate = 'X'" params:nil error:&refused]); // still refused after the attempts
    assert([[ro execute:@"PRAGMA query_only" params:nil error:&err].rows[0][0] isEqual:@"1"]); // reading it is fine
    assert([ro tables:&err] && [ro indexesInSchema:@"main" table:@"cars" error:&err] && [ro allColumns:&err].rows.count == 5);
    // the write transaction ends at COMMIT even when the statements run on: what follows is read-only again
    assert(![ro inWriteTransaction:^DBResult *(NSError **e) {
        return [ro execute:@"UPDATE cars SET plate = 'A' WHERE id = 1; COMMIT; UPDATE cars SET plate = 'B' WHERE id = 2" params:nil error:e];
    } error:&err]);
    assert(([Column([ro execute:@"SELECT plate FROM cars ORDER BY id" params:nil error:&err]) isEqual:(@[@"A", @"KR 2", @"PO 3"])]));
    refused = nil;
    assert(![ro execute:@"UPDATE cars SET plate = 'X'" params:nil error:&refused] && [refused.userInfo[@"sqlstate"] isEqual:@"25006"]);

    // a dead helper is restarted for the next request, read-only again
    NSString *pidFile = [dir stringByAppendingPathComponent:@"pid"];
    NSArray *recorded = @[@"/bin/sh", @"-c", @"echo $$ > \"$0\"; exec /usr/bin/python3 -I -u -c \"$1\"", pidFile, SQLiteRemoteBootstrap];
    SQLiteConnection *flaky = Remote(recorded, path, YES);
    assert([flaky open:&err]);
    pid_t pid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:NULL] intValue];
    assert(pid > 0 && kill(pid, SIGKILL) == 0);
    usleep(300000);
    assert([[flaky execute:@"SELECT count(*) FROM cars" params:nil error:&err].rows[0][0] isEqual:@"3"]);
    refused = nil;
    assert(![flaky execute:@"UPDATE cars SET plate = 'X'" params:nil error:&refused] && [refused.userInfo[@"sqlstate"] isEqual:@"25006"]);
    [flaky close];

    // a banner printed by the remote shell before the helper starts is skipped
    NSArray *chatty = @[@"/bin/sh", @"-c", @"echo 'Welcome to prod-1'; echo '{\"id\": 1, \"rows\": []}'; exec /usr/bin/python3 -I -u -c \"$0\"", SQLiteRemoteBootstrap];
    SQLiteConnection *banner = Remote(chatty, path, NO);
    assert([banner open:&err] && [[banner execute:@"SELECT count(*) FROM cars" params:nil error:&err].rows[0][0] isEqual:@"3"]);
    [banner close];

    // no python3 on the server: said so
    err = nil;
    assert(![Remote(@[@"/bin/sh", @"-c", @"echo 'sh: python3: command not found' >&2; exit 127"], path, NO) open:&err]);
    assert([err.localizedDescription containsString:@"python3"]);
    // ssh failing: its message is shown
    err = nil;
    assert(![Remote(@[@"/bin/sh", @"-c", @"echo 'ssh: Could not resolve hostname nowhere' >&2; exit 255"], path, NO) open:&err]);
    assert([err.localizedDescription containsString:@"Could not resolve hostname"]);
    [rw close];
    [ro close];
    puts("sqlite_test (remote only): OK");
}

int main(void) {
    @autoreleasepool {
        Run(@"local", ^SQLiteConnection *(NSString *path, BOOL readOnly) { return [[SQLiteConnection alloc] initWithPath:path readOnly:readOnly]; });
        Run(@"remote", ^SQLiteConnection *(NSString *path, BOOL readOnly) { return Remote(Python(), path, readOnly); });
        RunRemoteOnly();
    }
    return 0;
}

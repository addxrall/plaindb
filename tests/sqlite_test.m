// Tests SQLiteConnection on a temporary file: `make test`.
#import "SQLiteConnection.h"
#import <assert.h>

static NSArray *Column(DBResult *r) {
    NSMutableArray *values = [NSMutableArray new];
    for (NSArray *row in r.rows) [values addObject:row[0]];
    return values;
}

int main(void) {
    @autoreleasepool {
        NSError *err = nil;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"test.db"];

        // a missing file is an error, and no file is created
        SQLiteConnection *missing = [[SQLiteConnection alloc] initWithPath:path readOnly:NO];
        assert(![missing open:&err] && err);
        assert(![NSFileManager.defaultManager fileExistsAtPath:path]);

        // not a database
        NSString *png = [dir stringByAppendingPathComponent:@"picture.db"];
        const char bytes[] = "\x89PNG\r\n\x1a\n not really a database, just bytes long enough to fill SQLite's 100 byte header .........";
        [[NSData dataWithBytes:bytes length:sizeof bytes] writeToFile:png atomically:YES];
        err = nil;
        assert(![[[SQLiteConnection alloc] initWithPath:png readOnly:NO] open:&err] && err.localizedDescription.length);

        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil]; // an empty file is a valid empty database
        SQLiteConnection *db = [[SQLiteConnection alloc] initWithPath:path readOnly:NO];
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

        // named parameters: $2 appears before $1
        r = [db execute:@"SELECT plate FROM cars WHERE id IN ($2, $3) AND plate LIKE $1 ORDER BY id" params:@[@"%2%", @"1", @"2"] error:&err];
        assert([Column(r) isEqual:@[@"KR 2"]]);
        r = [db execute:@"SELECT $1, $1" params:@[NSNull.null] error:&err];
        assert(r.rows[0][0] == NSNull.null);

        // several statements: the last one with columns is the result; affected rows
        r = [db execute:@"UPDATE cars SET plate = plate WHERE id < 3; SELECT count(*) FROM cars" params:nil error:&err];
        assert([r.rows[0][0] isEqual:@"3"]);
        assert([db execute:@"UPDATE cars SET plate = plate WHERE id < 3" params:nil error:&err].affected == 2);
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
        assert([db execute:@"CREATE TABLE u (id PRIMARY KEY, v, b, t); INSERT INTO u VALUES (5, 7, x'0102', '12')" params:nil error:&err]);
        DBResult *u = [db execute:@"SELECT * FROM u" params:nil error:&err];
        NSArray *row = u.rows[0];
        assert([row[2] isEqual:@"\\x0102"]);
        NSDictionary *edits = @{@0: @{@1: [db valueForText:@"8" replacing:row[1]], @2: [db valueForText:@"\\x0a0b" replacing:row[2]],
                                     @3: [db valueForText:@"13" replacing:row[3]]}};
        NSArray *untyped = DBChangeStatements(@"main", @"u", u, @[@"id"], edits, [NSIndexSet new], @[]);
        DBResult *changed = [db inWriteTransaction:^DBResult *(NSError **e) { return [db execute:untyped[0][0] params:untyped[0][1] error:e]; } error:&err];
        assert(changed.affected == 1); // the WHERE on the untyped key matched
        assert(([[db execute:@"SELECT typeof(v), v, typeof(b), hex(b), typeof(t), t FROM u" params:nil error:&err].rows[0]
                 isEqual:(@[@"integer", @"8", @"blob", @"0A0B", @"text", @"13"])]));
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
        SQLiteConnection *pb = [[SQLiteConnection alloc] initWithPath:pbPath readOnly:NO];
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
        assert(pb.managesOwnSchema && !db.managesOwnSchema);
        assert(([[pb foreignKeysInSchema:@"main" table:@"posts" error:&err].rows
                 isEqual:(@[@[@"editor", @"main", @"users", @"id"], @[@"author", @"main", @"users", @"id"]])])); // a real key and a relation
        NSArray *pbKeys = [pb allForeignKeys:&err].rows;
        assert(([pbKeys containsObject:(@[@"main", @"posts", @"author", @"main", @"users", @"id", @""])]));
        assert(([pbKeys containsObject:(@[@"main", @"posts", @"tags", @"main", @"tags", @"id", @"many"])]));
        NSString *throughAuthor = DBSearchCondition(pb, @[@"id", @"author"], @{@"author": @[@"main", @"users", @"id", @[@"id", @"email"]]});
        r = [pb execute:[NSString stringWithFormat:@"SELECT id FROM posts WHERE %@", throughAuthor] params:@[DBLikePattern(@"kowalska")] error:&err];
        assert(r.rows.count == 1);
        [pb close];

        // read-only: refused with 25006, allowed in a write transaction, read-only again afterwards
        SQLiteConnection *ro = [[SQLiteConnection alloc] initWithPath:path readOnly:YES];
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
        puts("sqlite_test: OK");
    }
    return 0;
}

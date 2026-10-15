// Tests PGConnection and DBChangeStatements against a real local Postgres: `make test`.
// Database from PLAINDB_TEST_DB (default "postgres"). Only creates temporary tables.
#import "PGConnection.h"
#import <assert.h>

static NSDictionary *Params(void) {
    NSString *db = NSProcessInfo.processInfo.environment[@"PLAINDB_TEST_DB"] ?: @"postgres";
    return @{@"dbname": db};
}

int main(void) {
    @autoreleasepool {
        NSError *err = nil;
        PGConnection *pg = [[PGConnection alloc] initWithParams:Params() readOnly:NO];
        assert([pg open:&err]);

        // an identifier with a quote inside exercises DBQuoteIdent
        NSString *table = @"we\"ird";
        NSString *create = [NSString stringWithFormat:
            @"CREATE TEMP TABLE %@ (id serial PRIMARY KEY, name text NOT NULL DEFAULT 'x', note text);"
             "INSERT INTO %@ (name, note) VALUES ('a', NULL), ('b', 'zażółć');",
            DBQuoteIdent(table), DBQuoteIdent(table)];
        assert([pg execute:create params:nil error:&err]);

        NSString *schema = [pg execute:@"SELECT nspname FROM pg_namespace WHERE oid = pg_my_temp_schema()"
                                params:nil error:&err].rows[0][0];

        DBResult *databases = [pg databases:&err];
        assert([databases.rows containsObject:(@[Params()[@"dbname"]])] && ![databases.rows containsObject:(@[@"template0"])]);

        DBResult *tables = [pg tables:&err];
        NSUInteger mine = [tables.rows indexOfObjectPassingTest:^BOOL(NSArray *r, NSUInteger i, BOOL *s) { return [r[1] isEqual:table]; }];
        assert(mine != NSNotFound && [tables.rows[mine][0] isEqual:schema] && [tables.rows[mine][2] isEqual:@"table"]);
        assert(tables.rows[mine].count == 4); // + estimated rows (NULL until analyzed)
        assert(([pg execute:[NSString stringWithFormat:@"ANALYZE %@", DBQuoteIdent(table)] params:nil error:&err]));
        DBResult *analyzed = [pg tables:&err];
        mine = [analyzed.rows indexOfObjectPassingTest:^BOOL(NSArray *r, NSUInteger i, BOOL *s) { return [r[1] isEqual:table]; }];
        assert([analyzed.rows[mine][3] isEqual:@"2"]);

        // foreign keys: single-column only, with the referenced table and column
        assert([pg execute:@"CREATE TEMP TABLE drivers (id serial PRIMARY KEY, name text);"
                            "CREATE TEMP TABLE pairs (x int, y int, UNIQUE (x, y));"
                            "CREATE TEMP TABLE cars (id serial PRIMARY KEY, plate text, driver_id int REFERENCES drivers(id),"
                            " a int, b int, FOREIGN KEY (a, b) REFERENCES pairs (x, y))" // composite: left out
                    params:nil error:&err]);
        DBResult *fks = [pg foreignKeysInSchema:schema table:@"cars" error:&err];
        assert([fks.rows isEqual:(@[@[@"driver_id", schema, @"drivers", @"id"]])]);

        DBResult *cols = [pg columnsInSchema:schema table:table error:&err];
        assert(cols.rows.count == 3);
        assert([cols.rows[0][0] isEqual:@"id"] && [cols.rows[0][4] isEqual:@"PK"]);
        assert([cols.rows[1][2] isEqual:@"NOT NULL"] && [cols.rows[1][3] isEqual:@"'x'::text"]);
        assert([cols.rows[2][4] isEqual:@""]);

        DBResult *idx = [pg indexesInSchema:schema table:table error:&err];
        assert(idx.rows.count == 1 && [idx.rows[0][1] containsString:@"UNIQUE"]);

        NSString *select = [NSString stringWithFormat:@"SELECT name, note FROM %@ WHERE id = $1", DBQuoteIdent(table)];
        DBResult *r = [pg execute:select params:@[@1] error:&err];
        assert([r.columns isEqual:(@[@"name", @"note"])]);
        assert(r.rows[0][1] == NSNull.null);
        r = [pg execute:select params:@[@2] error:&err];
        assert([r.rows[0][1] isEqual:@"zażółć"]);

        NSString *update = [NSString stringWithFormat:@"UPDATE %@ SET note = $1 WHERE id = $2", DBQuoteIdent(table)];
        assert([pg execute:update params:(@[NSNull.null, @2]) error:&err].affected == 1);

        assert(![pg execute:@"SELECT nope" params:nil error:&err]);
        assert([err.userInfo[@"sqlstate"] isEqual:@"42703"]);

        // grid changes → SQL → database
        NSString *selectAll = [NSString stringWithFormat:@"SELECT * FROM %@ ORDER BY id", DBQuoteIdent(table)];
        DBResult *before = [pg execute:selectAll params:nil error:&err]; // (1,a,NULL) (2,b,NULL)
        NSArray *stmts = DBChangeStatements(schema, table, before, @[@"id"],
                                            @{@0: @{@1: @"a'2", @2: NSNull.null}, @1: @{@1: @"ignored"}},
                                            [NSIndexSet indexSetWithIndex:1],
                                            @[@{@1: @"c"}, @{}]);
        assert(stmts.count == 4); // DELETE row 1 (its edit is skipped), UPDATE row 0, 2× INSERT
        assert([stmts[0][0] hasPrefix:@"DELETE"] && [stmts[1][0] hasPrefix:@"UPDATE"] && [stmts[3][0] hasSuffix:@"DEFAULT VALUES"]);
        assert([DBInlineParams(stmts[1][0], stmts[1][1]) hasSuffix:@"SET \"name\" = 'a''2', \"note\" = NULL WHERE \"id\" = '1'"]);
        for (NSArray *s in stmts) {
            DBResult *res = [pg execute:s[0] params:s[1] error:&err];
            assert(res && (![s[2] boolValue] || res.affected == 1));
        }
        DBResult *after = [pg execute:@"SELECT name, note FROM \"we\"\"ird\" ORDER BY id" params:nil error:&err];
        assert([after.rows isEqual:(@[@[@"a'2", NSNull.null], @[@"c", NSNull.null], @[@"x", NSNull.null]])]);
        assert(DBChangeStatements(schema, table, before, @[], @{}, [NSIndexSet indexSetWithIndex:0], @[]).count == 0);

        // search across all columns: case-insensitive, %, _ and \ literal, numbers and NULLs fine
        assert([pg execute:@"CREATE TEMP TABLE s (id int PRIMARY KEY, name text, price numeric, note text);"
                            "INSERT INTO s VALUES (1, 'Zażółć Gęślą', 9.99, NULL), (2, '50% off_now', 50, 'a\\b'), (3, 'plain', 1234, 'x')"
                    params:nil error:&err]);
        NSString *where = [pg searchConditionForColumns:@[@"id", @"name", @"price", @"note"]];
        NSArray *(^ids)(NSString *) = ^NSArray *(NSString *term) {
            NSString *q = [NSString stringWithFormat:@"SELECT id FROM s WHERE %@ ORDER BY id", where];
            NSMutableArray *found = [NSMutableArray new];
            for (NSArray *row in [pg execute:q params:@[DBLikePattern(term)] error:NULL].rows) [found addObject:row[0]];
            return found;
        };
        assert([ids(@"żółć") isEqual:@[@"1"]]);         // inside a word, Polish letters
        assert([ids(@"ZAŻÓŁĆ") isEqual:@[@"1"]]);       // case-insensitive
        assert([ids(@"50%") isEqual:@[@"2"]]);          // % is literal: not "50 followed by anything"
        assert([ids(@"o_f") isEqual:@[]]);              // _ is literal: as a wildcard it would match "off"
        assert([ids(@"f_n") isEqual:@[@"2"]]);          // ...and a real underscore still matches
        assert([ids(@"a\\b") isEqual:@[@"2"]]);         // backslash is literal
        assert([ids(@"123") isEqual:@[@"3"]]);          // numbers match as text
        assert([ids(@"9.9") isEqual:@[@"1"]]);

        // the whole database's schema at once (for the diagram): tables only, single-column keys only
        DBResult *allCols = [pg allColumns:&err];
        NSMutableArray *carColumns = [NSMutableArray new];
        for (NSArray *c in allCols.rows) if ([c[0] isEqual:schema] && [c[1] isEqual:@"cars"]) [carColumns addObject:c];
        assert(carColumns.count == 5); // id, plate, driver_id, a, b
        assert(([carColumns[0] isEqual:(@[schema, @"cars", @"id", @"integer", @"PK"])]));
        assert(([carColumns[2] isEqual:(@[schema, @"cars", @"driver_id", @"integer", @""])]));
        DBResult *allKeys = [pg allForeignKeys:&err];
        NSMutableArray *carKeys = [NSMutableArray new];
        for (NSArray *k in allKeys.rows) if ([k[0] isEqual:schema] && [k[1] isEqual:@"cars"]) [carKeys addObject:k];
        assert(([carKeys isEqual:(@[@[schema, @"cars", @"driver_id", schema, @"drivers", @"id", @""]])]));
        assert(!pg.managesOwnSchema);

        // schema editing: add a column and a foreign key; a NOT NULL column without a default on a table with rows fails
        // and leaves the table as it was
        assert(pg.canAddForeignKeys && [pg.commonTypes containsObject:@"jsonb"]);
        DBResult *(^alter)(NSString *, NSError **) = ^DBResult *(NSString *sql, NSError **e) {
            return [pg inWriteTransaction:^DBResult *(NSError **e2) { return [pg execute:sql params:nil error:e2]; } error:e];
        };
        assert(alter(DBAddColumnStatement(schema, @"cars", @"note", @"text", NO, nil), &err));
        assert(alter(DBAddForeignKeyStatement(schema, @"cars", @"b", schema, @"drivers", @"id", @"SET NULL"), &err));
        BOOL noteSeen = NO, keySeen = NO;
        for (NSArray *c in [pg allColumns:&err].rows) noteSeen |= [c[1] isEqual:@"cars"] && [c[2] isEqual:@"note"];
        for (NSArray *k in [pg allForeignKeys:&err].rows) keySeen |= [k[1] isEqual:@"cars"] && [k[2] isEqual:@"b"];
        assert(noteSeen && keySeen);
        assert([pg execute:@"INSERT INTO cars (plate) VALUES ('ROW')" params:nil error:&err]);
        NSError *refused = nil;
        assert(!alter(DBAddColumnStatement(schema, @"cars", @"must", @"integer", YES, nil), &refused) && refused);
        BOOL mustSeen = NO;
        for (NSArray *c in [pg allColumns:&err].rows) mustSeen |= [c[1] isEqual:@"cars"] && [c[2] isEqual:@"must"];
        assert(!mustSeen);

        // search through foreign keys: a car is found by its driver's name
        assert([pg execute:@"INSERT INTO drivers (name) VALUES ('Anna Kowalska'), ('Jan Nowak');"
                            "INSERT INTO cars (plate, driver_id) VALUES ('WA 1', 1), ('KR 2', 2), ('PO 3', NULL)"
                    params:nil error:&err]);
        NSString *linked = DBSearchCondition(pg, @[@"id", @"plate", @"driver_id", @"a", @"b"],
                                             @{@"driver_id": @[schema, @"drivers", @"id", @[@"id", @"name"]]});
        NSArray *(^cars)(NSString *) = ^NSArray *(NSString *term) {
            NSString *q = [NSString stringWithFormat:@"SELECT plate FROM cars WHERE %@ ORDER BY id", linked];
            NSMutableArray *found = [NSMutableArray new];
            DBResult *res = [pg execute:q params:@[DBLikePattern(term)] error:NULL];
            assert(res);
            for (NSArray *row in res.rows) [found addObject:row[0]];
            return found;
        };
        assert([cars(@"kowal") isEqual:@[@"WA 1"]]);         // only in the referenced row
        assert([cars(@"KR") isEqual:@[@"KR 2"]]);            // own columns still count
        assert([cars(@"a") isEqual:(@[@"WA 1", @"KR 2"])]);  // both drivers' names; the car without a driver isn't matched
        assert([DBSearchCondition(pg, @[@"id"], @{}) isEqual:[pg searchConditionForColumns:@[@"id"]]]);

        // engine operations behind the protocol
        assert([pg.booleanTrue isEqual:@"t"] && [pg.booleanFalse isEqual:@"f"]);
        assert(([[pg emptyTableStatementForSchema:schema table:@"s"] isEqual:[NSString stringWithFormat:@"TRUNCATE TABLE \"%@\".\"s\"", schema]]));
        NSError *slow = nil;
        assert(![pg execute:@"SELECT pg_sleep(2)" params:nil timeout:0.2 error:&slow]);
        assert([slow.userInfo[@"sqlstate"] isEqual:@"57014"]);
        assert([pg execute:@"SELECT pg_sleep(0.3)" params:nil error:&err]); // the timeout was reset afterwards
        DBResult *written = [pg inWriteTransaction:^DBResult *(NSError **e) {
            return [pg execute:@"UPDATE s SET note = 'w' WHERE id = 1" params:nil error:e];
        } error:&err];
        assert(written.affected == 1);
        assert(![pg inWriteTransaction:^DBResult *(NSError **e) {
            [pg execute:@"UPDATE s SET note = 'rolled back' WHERE id = 1" params:nil error:e];
            return [pg execute:@"SELECT nope" params:nil error:e];
        } error:&err]);
        assert([[pg execute:@"SELECT note FROM s WHERE id = 1" params:nil error:&err].rows[0][0] isEqual:@"w"]);

        // production mode: the server rejects writes until BEGIN READ WRITE
        PGConnection *ro = [[PGConnection alloc] initWithParams:Params() readOnly:YES];
        assert([ro open:&err]);
        assert(![ro execute:@"CREATE TEMP TABLE t (x int)" params:nil error:&err]);
        assert([err.userInfo[@"sqlstate"] isEqual:@"25006"]);
        assert([ro execute:@"BEGIN READ WRITE" params:nil error:&err]);
        assert([ro execute:@"CREATE TEMP TABLE t (x int); INSERT INTO t VALUES (1), (2)" params:nil error:&err].affected == 2);
        assert([ro execute:@"COMMIT" params:nil error:&err]);
        assert([ro inWriteTransaction:^DBResult *(NSError **e) {
            return [ro execute:@"CREATE TEMP TABLE rw (x int)" params:nil error:e];
        } error:&err]); // allowed explicitly, like a confirmed production write

        puts("pg_test: OK");
    }
    return 0;
}

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

        DBResult *tables = [pg tables:&err];
        assert([tables.rows containsObject:(@[schema, table, @"table"])]);

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

        // production mode: the server rejects writes until BEGIN READ WRITE
        PGConnection *ro = [[PGConnection alloc] initWithParams:Params() readOnly:YES];
        assert([ro open:&err]);
        assert(![ro execute:@"CREATE TEMP TABLE t (x int)" params:nil error:&err]);
        assert([err.userInfo[@"sqlstate"] isEqual:@"25006"]);
        assert([ro execute:@"BEGIN READ WRITE" params:nil error:&err]);
        assert([ro execute:@"CREATE TEMP TABLE t (x int); INSERT INTO t VALUES (1), (2)" params:nil error:&err].affected == 2);
        assert([ro execute:@"COMMIT" params:nil error:&err]);

        puts("pg_test: OK");
    }
    return 0;
}

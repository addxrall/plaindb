// Test PGConnection na prawdziwym, lokalnym Postgresie: `make test`.
// Baza z TABULA_TEST_DB (domyślnie "postgres"). Tworzy tylko tabele tymczasowe.
#import "PGConnection.h"
#import <assert.h>

static NSDictionary *Params(void) {
    NSString *db = NSProcessInfo.processInfo.environment[@"TABULA_TEST_DB"] ?: @"postgres";
    return @{@"dbname": db};
}

int main(void) {
    @autoreleasepool {
        NSError *err = nil;
        PGConnection *pg = [[PGConnection alloc] initWithParams:Params() readOnly:NO];
        assert([pg open:&err]);

        // identyfikator z cudzysłowem w środku sprawdza DBQuoteIdent
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
        assert(idx.rows.count == 1 && [idx.rows[0][0] containsString:@"UNIQUE"]);

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

        // tryb produkcyjny: baza odrzuca zapis, dopóki nie ma BEGIN READ WRITE
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

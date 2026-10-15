// SQL completion: what the editor offers at the cursor. `make test`.
#import "SQLCompletion.h"
#import <assert.h>

static DBResult *Rows(NSArray *rows) {
    DBResult *r = [DBResult new];
    r.columns = @[];
    r.rows = rows;
    return r;
}

static NSArray<NSString *> *Texts(NSString *sql, SchemaGraph *g) {
    NSRange cursor = [sql rangeOfString:@"|"];
    NSString *text = [sql stringByReplacingCharactersInRange:cursor withString:@""];
    NSRange replace;
    NSMutableArray *out = [NSMutableArray new];
    for (SQLSuggestion *s in SQLSuggestions(text, cursor.location, g, &replace)) [out addObject:s.text];
    return out;
}

static NSRange Replace(NSString *sql, SchemaGraph *g) {
    NSRange cursor = [sql rangeOfString:@"|"];
    NSRange replace = NSMakeRange(NSNotFound, 0);
    SQLSuggestions([sql stringByReplacingCharactersInRange:cursor withString:@""], cursor.location, g, &replace);
    return replace;
}

int main(void) {
    @autoreleasepool {
        SchemaGraph *g = [SchemaGraph graphWithColumns:Rows(@[
            @[@"public", @"claims", @"id", @"integer", @"PK"], @[@"public", @"claims", @"driver_id", @"integer", @""],
            @[@"public", @"claims", @"amount", @"numeric", @""], @[@"public", @"drivers", @"id", @"integer", @"PK"],
            @[@"public", @"drivers", @"last_name", @"text", @""], @[@"crm", @"contacts", @"id", @"integer", @"PK"],
        ]) foreignKeys:Rows(@[])];

        // after FROM / JOIN: tables
        assert([Texts(@"SELECT * FROM cl|", g) isEqual:@[@"claims"]]);
        assert([Texts(@"select * from claims c join dr|", g) isEqual:@[@"drivers"]]);
        assert([Texts(@"SELECT * FROM con|", g) isEqual:@[@"crm.contacts"]]); // other schemas qualified
        // after "alias." or "table.": that table's columns, also with nothing typed yet
        assert([Texts(@"SELECT c.| FROM claims c", g) isEqual:(@[@"id", @"driver_id", @"amount"])]);
        assert([Texts(@"SELECT c.dr| FROM claims AS c", g) isEqual:@[@"driver_id"]]);
        assert([Texts(@"SELECT drivers.la| FROM drivers", g) isEqual:@[@"last_name"]]);
        assert([Texts(@"SELECT * FROM crm.| ", g) isEqual:@[@"contacts"]]); // schema. → its tables
        // elsewhere: columns of the statement's tables first, then tables, functions and keywords
        NSArray *where = Texts(@"SELECT * FROM claims WHERE am|", g);
        assert([where.firstObject isEqual:@"amount"]);
        NSArray *se = Texts(@"sel|", g);
        assert([se containsObject:@"select"]); // keywords in the case being typed
        assert([Texts(@"SEL|", g) containsObject:@"SELECT"]);
        assert([Texts(@"SELECT co|", g) containsObject:@"count("]); // functions open their parenthesis
        // only the current statement's tables count
        assert(![Texts(@"SELECT * FROM drivers; SELECT * FROM claims WHERE la|", g) containsObject:@"last_name"]);
        // nothing inside strings or comments, nothing with nothing typed (except after a dot)
        assert(Texts(@"SELECT 'cl| FROM claims", g).count == 0);
        assert(Texts(@"-- from cl|", g).count == 0);
        assert(Texts(@"SELECT * FROM |", g).count == 0);
        // asked for (⌃Space): also with nothing typed
        NSRange none;
        NSArray *forced = SQLSuggestionsAt(@"SELECT * FROM ", 14, g, YES, &none);
        assert(forced.count == 3 && none.length == 0);
        // the range to replace is the word being typed
        assert(NSEqualRanges(Replace(@"SELECT c.dr| FROM claims c", g), NSMakeRange(9, 2)));
        puts("completion_test: OK");
    }
    return 0;
}

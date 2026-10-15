// Schema editing statements, without a database. `make test`.
#import "DBConnection.h"
#import <assert.h>

int main(void) {
    @autoreleasepool {
        assert([DBAddColumnStatement(@"public", @"claims", @"note", @"text", NO, nil)
                isEqual:@"ALTER TABLE \"public\".\"claims\" ADD COLUMN \"note\" text"]);
        assert([DBAddColumnStatement(@"public", @"claims", @"paid", @"boolean", YES, @"false")
                isEqual:@"ALTER TABLE \"public\".\"claims\" ADD COLUMN \"paid\" boolean NOT NULL DEFAULT false"]);
        assert([DBAddColumnStatement(@"main", @"we\"ird", @"a b", @"INTEGER", NO, @"")
                isEqual:@"ALTER TABLE \"main\".\"we\"\"ird\" ADD COLUMN \"a b\" INTEGER"]); // empty default = none
        assert([DBAddForeignKeyStatement(@"public", @"claims", @"driver_id", @"public", @"drivers", @"id", @"")
                isEqual:@"ALTER TABLE \"public\".\"claims\" ADD CONSTRAINT \"claims_driver_id_fkey\" FOREIGN KEY (\"driver_id\") "
                         "REFERENCES \"public\".\"drivers\" (\"id\")"]);
        assert([DBAddForeignKeyStatement(@"public", @"claims", @"driver_id", @"crm", @"drivers", @"id", @"CASCADE")
                hasSuffix:@"REFERENCES \"crm\".\"drivers\" (\"id\") ON DELETE CASCADE"]);
        assert([DBAddForeignKeyStatement(@"public", @"claims", @"driver_id", @"public", @"drivers", @"id", @"SET NULL")
                hasSuffix:@" ON DELETE SET NULL"]);
        puts("schema_test: OK");
    }
    return 0;
}

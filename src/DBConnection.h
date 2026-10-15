#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Query result. Every value is an NSString or NSNull (SQL NULL).
@interface DBResult : NSObject
@property (nonatomic, copy) NSArray<NSString *> *columns;
@property (nonatomic, copy) NSArray<NSArray *> *rows;
@property (nonatomic) NSInteger affected; // for INSERT/UPDATE/DELETE, -1 otherwise
@end

// Common interface for database engines. All methods block; call them on `queue`.
@protocol DBConnection <NSObject>
@property (nonatomic, readonly) dispatch_queue_t queue;
- (BOOL)open:(NSError **)error;
- (void)close;
- (nullable DBResult *)execute:(NSString *)sql params:(nullable NSArray *)params error:(NSError **)error;
// rows: [schema, name, kind, estimated row count (NSNull when unknown)]
- (nullable DBResult *)tables:(NSError **)error;
// rows: [column, referenced schema, referenced table, referenced column]; single-column foreign keys only
- (nullable DBResult *)foreignKeysInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// rows: [column, type, null, default, pk]
- (nullable DBResult *)columnsInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// The whole database at once, for the diagram. rows: [schema, table, column, type, @"PK" or @""] for every table
// (not views), in column order.
- (nullable DBResult *)allColumns:(NSError **)error;
// rows: [schema, table, column, referenced schema, referenced table, referenced column, @"many" or @""];
// single-column keys only. "many": the column holds several references (a PocketBase multi relation), so it's only
// drawn on the diagram, not treated as a foreign key elsewhere.
- (nullable DBResult *)allForeignKeys:(NSError **)error;
// rows: [index name, index definition]
- (nullable DBResult *)indexesInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// rows: [database name], the other databases this connection's server offers
- (nullable DBResult *)databases:(NSError **)error;
// WHERE fragment matching parameter $1 (a pattern from DBLikePattern) against every column as text, ignoring case.
- (NSString *)searchConditionForColumns:(NSArray<NSString *> *)columns;
// Like execute, but stopped after `seconds`; the error then has sqlstate 57014 (query_canceled).
- (nullable DBResult *)execute:(NSString *)sql params:(nullable NSArray *)params timeout:(NSTimeInterval)seconds error:(NSError **)error;
// Runs `work` in a transaction that may write even when the session is read-only (production after confirmation).
// Commits when `work` returns a result, rolls back otherwise. Returns `work`'s result, or nil with `error` set.
- (nullable DBResult *)inWriteTransaction:(DBResult *_Nullable (^)(NSError **error))work error:(NSError **)error;
// Statement that deletes every row of a table, e.g. for "Empty Table…".
- (NSString *)emptyTableStatementForSchema:(NSString *)schema table:(NSString *)table;
// The value to write for text the user typed into a cell that held `original` (a value this connection returned).
// SQLite keeps the original's storage class (an integer stays an integer); Postgres returns the text as is.
- (id)valueForText:(NSString *)text replacing:(nullable id)original;
// Schema editing: whether a foreign key can be added to an existing table (SQLite would have to rebuild it),
// and the types offered when adding a column (any other type can be typed).
@property (nonatomic, readonly) BOOL canAddForeignKeys;
// The schema belongs to an application that keeps its own description of it (PocketBase's _collections): PlainDB
// reads its relations but doesn't change its schema, which would leave that description behind.
@property (nonatomic, readonly) BOOL managesOwnSchema;
@property (nonatomic, readonly) NSArray<NSString *> *commonTypes;
// How the engine prints booleans, and what the grid writes back.
@property (nonatomic, readonly) NSString *booleanTrue, *booleanFalse;
@end

// LIKE pattern finding `term` anywhere, with %, _ and \ in it matched literally.
NSString *DBLikePattern(NSString *term);

// ⌘F condition on $1: any of `columns` matches, or a foreign key points to a row in which any column matches
// (one level deep). references: column → @[referenced schema, table, column, @[that table's columns]].
NSString *DBSearchCondition(id<DBConnection> conn, NSArray<NSString *> *columns, NSDictionary<NSString *, NSArray *> *references);

// UI strings: the English text is the key, translations live in Resources/<lang>.lproj.
#define L(key) NSLocalizedString(key, nil)

// Plural forms come from Localizable.stringsdict, e.g. LN(@"%lu rows", n).
static inline NSString *LN(NSString *format, NSUInteger n) {
    return [NSString localizedStringWithFormat:NSLocalizedString(format, nil), (unsigned long)n];
}

// Identifier quoting, identical in Postgres and SQLite.
static inline NSString *DBQuoteIdent(NSString *name) {
    return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

// Turns grid changes into statements: each is @[sql, params, @(expect exactly 1 affected row)].
// Order: DELETE, UPDATE, INSERT. Rows are matched by primary key using the original values in `result`.
// $1…$n placeholders work in both Postgres and SQLite.
NSArray<NSArray *> *DBChangeStatements(NSString *schema, NSString *table, DBResult *result, NSArray<NSString *> *pkColumns,
                                      NSDictionary<NSNumber *, NSDictionary<NSNumber *, id> *> *edits, NSIndexSet *deleted,
                                      NSArray<NSDictionary<NSNumber *, id> *> *inserted);

// Schema editing from the diagram. Names are quoted; `type` and `defaultExpr` are SQL as the user typed them
// (the statement is always shown before it runs). An empty default means none.
NSString *DBAddColumnStatement(NSString *schema, NSString *table, NSString *column, NSString *type, BOOL notNull, NSString *_Nullable defaultExpr);
// onDelete: "" (no action), "CASCADE" or "SET NULL". The constraint is named <table>_<column>_fkey, as Postgres would.
NSString *DBAddForeignKeyStatement(NSString *schema, NSString *table, NSString *column, NSString *refSchema, NSString *refTable,
                                   NSString *refColumn, NSString *onDelete);

// Preview only: inlines params as literals. Execution always uses real params.
NSString *DBInlineParams(NSString *sql, NSArray *params);

static inline NSError *DBError(NSString *message, NSString *_Nullable sqlstate) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (sqlstate) info[@"sqlstate"] = sqlstate;
    return [NSError errorWithDomain:@"PlainDB" code:1 userInfo:info];
}

NS_ASSUME_NONNULL_END

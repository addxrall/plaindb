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
// rows: [schema, name, kind]
- (nullable DBResult *)tables:(NSError **)error;
// rows: [column, type, null, default, pk]
- (nullable DBResult *)columnsInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// rows: [index name, index definition]
- (nullable DBResult *)indexesInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// WHERE fragment matching parameter $1 (a pattern from DBLikePattern) against every column as text, ignoring case.
- (NSString *)searchConditionForColumns:(NSArray<NSString *> *)columns;
@end

// LIKE pattern finding `term` anywhere, with %, _ and \ in it matched literally.
NSString *DBLikePattern(NSString *term);

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

// Preview only: inlines params as literals. Execution always uses real params.
NSString *DBInlineParams(NSString *sql, NSArray *params);

static inline NSError *DBError(NSString *message, NSString *_Nullable sqlstate) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (sqlstate) info[@"sqlstate"] = sqlstate;
    return [NSError errorWithDomain:@"PlainDB" code:1 userInfo:info];
}

NS_ASSUME_NONNULL_END

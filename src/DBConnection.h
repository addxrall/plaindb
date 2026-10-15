#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Wynik zapytania. Każda wartość to NSString albo NSNull (SQL NULL).
@interface DBResult : NSObject
@property (nonatomic, copy) NSArray<NSString *> *columns;
@property (nonatomic, copy) NSArray<NSArray *> *rows;
@property (nonatomic) NSInteger affected; // dla INSERT/UPDATE/DELETE, -1 gdy nie dotyczy
@end

// Wspólny interfejs silników. Wszystkie metody są blokujące, wołaj je z `queue`.
@protocol DBConnection <NSObject>
@property (nonatomic, readonly) dispatch_queue_t queue;
- (BOOL)open:(NSError **)error;
- (void)close;
- (nullable DBResult *)execute:(NSString *)sql params:(nullable NSArray *)params error:(NSError **)error;
// wiersze: [schemat, nazwa, rodzaj]
- (nullable DBResult *)tables:(NSError **)error;
// wiersze: [kolumna, typ, null, default, pk]
- (nullable DBResult *)columnsInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
// wiersze: [definicja indeksu]
- (nullable DBResult *)indexesInSchema:(NSString *)schema table:(NSString *)table error:(NSError **)error;
@end

// Cudzysłów identyfikatora, taki sam w Postgresie i SQLite.
static inline NSString *DBQuoteIdent(NSString *name) {
    return [NSString stringWithFormat:@"\"%@\"", [name stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

static inline NSError *DBError(NSString *message, NSString *_Nullable sqlstate) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (sqlstate) info[@"sqlstate"] = sqlstate;
    return [NSError errorWithDomain:@"Tabula" code:1 userInfo:info];
}

NS_ASSUME_NONNULL_END

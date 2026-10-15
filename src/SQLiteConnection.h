#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// SQLite database file. The schema is always "main".
// readOnly sets PRAGMA query_only, so the session refuses writes (sqlstate 25006) except in inWriteTransaction.
@interface SQLiteConnection : NSObject <DBConnection>
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
@end

NS_ASSUME_NONNULL_END

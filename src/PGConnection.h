#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface PGConnection : NSObject <DBConnection>
// params: libpq keywords (host, port, user, password, dbname).
// readOnly sets default_transaction_read_only, so the server itself rejects writes
// (SQLSTATE 25006) unless you explicitly open BEGIN READ WRITE.
- (instancetype)initWithParams:(NSDictionary<NSString *, NSString *> *)params readOnly:(BOOL)readOnly;
@end

NS_ASSUME_NONNULL_END

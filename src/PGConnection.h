#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface PGConnection : NSObject <DBConnection>
// params: słowa kluczowe libpq (host, port, user, password, dbname).
// readOnly ustawia default_transaction_read_only, więc baza sama odrzuca zapisy
// (SQLSTATE 25006), dopóki nie otworzysz jawnie BEGIN READ WRITE.
- (instancetype)initWithParams:(NSDictionary<NSString *, NSString *> *)params readOnly:(BOOL)readOnly;
@end

NS_ASSUME_NONNULL_END

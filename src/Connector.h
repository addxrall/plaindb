#import <Foundation/Foundation.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Opens the connection a connection dictionary describes (see ConnectionStore), through an SSH tunnel when it
// has one. Runs in the background; `done` is called on the main thread with a connection (and its tunnel) or an error.
void TBConnect(NSDictionary *info, NSString *password,
               void (^done)(id<DBConnection> _Nullable connection, SSHTunnel *_Nullable tunnel, NSError *_Nullable error));

NS_ASSUME_NONNULL_END

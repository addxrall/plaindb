#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Start window: local databases and saved connections. Sets up the tunnel and opens the connection.
@interface ConnectWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onConnected)(id<DBConnection> connection, SSHTunnel *_Nullable tunnel, NSDictionary *info);
@end

NS_ASSUME_NONNULL_END

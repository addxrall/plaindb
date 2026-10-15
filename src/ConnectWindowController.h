#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Okno startowe: lista zapisanych połączeń i formularz. Zestawia tunel i otwiera połączenie.
@interface ConnectWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onConnected)(id<DBConnection> connection, SSHTunnel *_Nullable tunnel, NSDictionary *info);
@end

NS_ASSUME_NONNULL_END

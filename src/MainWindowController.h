#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Window for one connection: table list on the left, Data / Structure / SQL tabs on the right.
@interface MainWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onClose)(MainWindowController *controller);
// The user switched to another database or connection from the toolbar: the new connection is open,
// and the owner should show it in place of `controller` (whose unsaved changes were already confirmed).
@property (nonatomic, copy, nullable) void (^onReplace)(MainWindowController *controller, id<DBConnection> connection,
                                                        SSHTunnel *_Nullable tunnel, NSDictionary *info);
- (instancetype)initWithConnection:(id<DBConnection>)connection tunnel:(nullable SSHTunnel *)tunnel info:(NSDictionary *)info;
// Asks whether to discard unsaved changes. YES = OK to continue (also when there is nothing to lose).
- (BOOL)confirmDiscard;
@end

NS_ASSUME_NONNULL_END

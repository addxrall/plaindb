#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Window for one connection: table list on the left, Data / Structure / SQL tabs on the right.
@interface MainWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onClose)(MainWindowController *controller);
- (instancetype)initWithConnection:(id<DBConnection>)connection tunnel:(nullable SSHTunnel *)tunnel info:(NSDictionary *)info;
// Asks whether to discard unsaved changes. YES = OK to continue (also when there is nothing to lose).
- (BOOL)confirmDiscard;
@end

NS_ASSUME_NONNULL_END

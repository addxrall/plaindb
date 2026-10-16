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
// Tabs: windows of one connection share it. The owner closes the connection with its last window.
@property (nonatomic, readonly) id<DBConnection> connection;
@property (nonatomic, readonly, nullable) SSHTunnel *tunnel;
@property (nonatomic, readonly) NSDictionary *info;
// "Open in New Tab" (sidebar menu, ⌘-click): the owner makes a tab of the same connection showing that table.
// table nil: an empty tab (the tab bar's "+" or ⌘T with no table open)
@property (nonatomic, copy, nullable) void (^onOpenInNewTab)(MainWindowController *controller, NSString *_Nullable schema, NSString *_Nullable table);
// The window's table or Data / Structure / SQL tab changed (the owner saves the open tabs).
@property (nonatomic, copy, nullable) void (^onTabsChanged)(MainWindowController *controller);
// Shows that table in `tab` (0 Data, 1 Structure, 2 SQL), now or as soon as the table list has loaded.
// A table that doesn't exist (any more) is ignored.
- (void)openTableSchema:(NSString *)schema name:(NSString *)name tab:(NSInteger)tab;
// @[schema, table, @(tab)] of the open table, or nil.
@property (nonatomic, readonly, nullable) NSArray *openTable;
// Asks whether to discard unsaved changes. YES = OK to continue (also when there is nothing to lose).
- (BOOL)confirmDiscard;
@end

NS_ASSUME_NONNULL_END

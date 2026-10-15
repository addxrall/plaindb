#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

@class SSHTunnel;

NS_ASSUME_NONNULL_BEGIN

// Okno jednego połączenia: lista tabel po lewej, zakładki Dane / Struktura / SQL po prawej.
@interface MainWindowController : NSWindowController <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, copy, nullable) void (^onClose)(MainWindowController *controller);
- (instancetype)initWithConnection:(id<DBConnection>)connection tunnel:(nullable SSHTunnel *)tunnel info:(NSDictionary *)info;
@end

NS_ASSUME_NONNULL_END

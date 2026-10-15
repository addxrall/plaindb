#import <Cocoa/Cocoa.h>
#import "ConnectWindowController.h"
#import "MainWindowController.h"
#import "SettingsWindowController.h"
#import "SSHTunnel.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    ConnectWindowController *_connect;
    SettingsWindowController *_settings;
    NSMutableArray<MainWindowController *> *_windows;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSApp.mainMenu = [self buildMenu];
    _windows = [NSMutableArray new];
    _connect = [ConnectWindowController new];
    __weak AppDelegate *weakSelf = self;
    _connect.onConnected = ^(id<DBConnection> connection, SSHTunnel *tunnel, NSDictionary *info) {
        [weakSelf openWindowWithConnection:connection tunnel:tunnel info:info];
    };
    [_connect showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)openWindowWithConnection:(id<DBConnection>)connection tunnel:(SSHTunnel *)tunnel info:(NSDictionary *)info {
    MainWindowController *controller = [[MainWindowController alloc] initWithConnection:connection tunnel:tunnel info:info];
    NSMutableArray *windows = _windows;
    controller.onClose = ^(MainWindowController *c) { [windows removeObject:c]; };
    [_windows addObject:controller];
    [controller showWindow:nil];
    [_connect.window orderOut:nil];
}

- (void)showConnections:(id)sender {
    [_connect showWindow:nil];
}

- (void)showSettings:(id)sender {
    if (!_settings) _settings = [SettingsWindowController new];
    [_settings showWindow:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (!visible) [self showConnections:nil];
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    for (MainWindowController *c in _windows)
        if (![c confirmDiscard]) return NSTerminateCancel;
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    for (MainWindowController *c in [_windows copy]) [c.window close]; // closes ssh tunnels
}

- (NSMenu *)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [self submenu:@"PlainDB" in:bar];
    [app addItemWithTitle:L(@"About PlainDB") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:L(@"Settings…") action:@selector(showSettings:) keyEquivalent:@","];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:L(@"Hide PlainDB") action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:L(@"Quit PlainDB") action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenu *file = [self submenu:L(@"File") in:bar];
    [file addItemWithTitle:L(@"Connections…") action:@selector(showConnections:) keyEquivalent:@"n"];
    [file addItemWithTitle:L(@"Close Window") action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenu *edit = [self submenu:L(@"Edit") in:bar];
    [edit addItemWithTitle:L(@"Undo") action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:L(@"Redo") action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:L(@"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:L(@"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:L(@"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:L(@"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:L(@"Find…") action:NSSelectorFromString(@"showFind:") keyEquivalent:@"f"];

    NSMenu *query = [self submenu:L(@"Query") in:bar];
    [query addItemWithTitle:L(@"Run / Refresh") action:NSSelectorFromString(@"runQuery:") keyEquivalent:@"r"];
    [query addItemWithTitle:L(@"Save Changes") action:NSSelectorFromString(@"saveChanges:") keyEquivalent:@"s"];

    NSMenu *window = [self submenu:L(@"Window") in:bar];
    [window addItemWithTitle:L(@"Minimize") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSApp.windowsMenu = window;
    return bar;
}

- (NSMenu *)submenu:(NSString *)title in:(NSMenu *)bar {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    [bar addItemWithTitle:title action:nil keyEquivalent:@""].submenu = menu;
    return menu;
}

@end

int main(void) {
    @autoreleasepool {
        AppDelegate *delegate = [AppDelegate new];
        NSApplication.sharedApplication.delegate = delegate;
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
        [NSApp run];
    }
    return 0;
}

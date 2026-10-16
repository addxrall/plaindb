#import <Cocoa/Cocoa.h>
#import "ConnectionStore.h"
#import "ConnectWindowController.h"
#import "Connector.h"
#import "MainWindowController.h"
#import "SettingsWindowController.h"
#import "SSHTunnel.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    ConnectWindowController *_connect;
    SettingsWindowController *_settings;
    NSMutableArray<MainWindowController *> *_windows;
    BOOL _terminating;
}

// Before launching finishes: a file opened from Finder arrives (openURLs) before applicationDidFinishLaunching.
- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    _windows = [NSMutableArray new];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSApp.mainMenu = [self buildMenu];
    _connect = [ConnectWindowController new];
    __weak AppDelegate *weakSelf = self;
    _connect.onConnected = ^(id<DBConnection> connection, SSHTunnel *tunnel, NSDictionary *info) {
        [weakSelf openWindowWithConnection:connection tunnel:tunnel info:info];
    };
    _connect.onOpenFile = ^(NSString *path) { [weakSelf openFileAtPath:path]; };
    _connect.onOpenPanel = ^{ [weakSelf openDocument:nil]; };
    [_connect showWindow:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// A newly opened connection: one window, plus the tabs it had open last time.
- (MainWindowController *)openWindowWithConnection:(id<DBConnection>)connection tunnel:(SSHTunnel *)tunnel info:(NSDictionary *)info {
    if ([info[@"kind"] isEqual:@"sqlite"]) [ConnectionStore rememberFile:info moveToTop:YES]; // every way of opening a file
    // Already open in another window: a plain new window, without restoring (the tabs are there already).
    NSArray<NSArray *> *saved = [self controllersOf:info].count ? @[] : [ConnectionStore savedTabsFor:TBConnectionIdentity(info)];
    MainWindowController *controller = [self controllerWithConnection:connection tunnel:tunnel info:info];
    [controller showWindow:nil];
    [_connect.window orderOut:nil];
    if (!saved.count) return controller;
    // Tables that no longer exist are skipped: the list is read once, on the connection's queue, before any tab opens.
    dispatch_async(connection.queue, ^{
        NSMutableSet *existing = [NSMutableSet new];
        for (NSArray *t in [connection tables:NULL].rows) [existing addObject:@[t[0], t[1]]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *tabs = [NSMutableArray new];
            for (NSArray *tab in saved)
                if ([existing containsObject:@[tab[0], tab[1]]]) [tabs addObject:tab];
            if (!tabs.count || !controller.window.isVisible) return;
            [controller openTableSchema:tabs[0][0] name:tabs[0][1] tab:[tabs[0][2] integerValue]];
            MainWindowController *last = controller; // each tab after the previous one, keeping the saved order
            for (NSUInteger i = 1; i < tabs.count; i++)
                last = [self openTabFor:last schema:tabs[i][0] table:tabs[i][1] tab:[tabs[i][2] integerValue]];
            [controller.window makeKeyAndOrderFront:nil]; // the first tab, as before
        });
    });
    return controller;
}

- (MainWindowController *)controllerWithConnection:(id<DBConnection>)connection tunnel:(SSHTunnel *)tunnel info:(NSDictionary *)info {
    MainWindowController *controller = [[MainWindowController alloc] initWithConnection:connection tunnel:tunnel info:info];
    __weak AppDelegate *weakSelf = self;
    controller.onClose = ^(MainWindowController *c) { [weakSelf windowClosed:c]; };
    controller.onTabsChanged = ^(MainWindowController *c) { [weakSelf saveTabsOf:c.info]; };
    controller.onOpenInNewTab = ^(MainWindowController *c, NSString *schema, NSString *table) {
        [weakSelf openTabFor:c schema:schema table:table tab:0];
    };
    // Switching from the toolbar: the new window takes the old one's place and size. A tab only closes itself; the
    // new window is offset so the old connection's other tabs stay in sight instead of hiding behind it.
    controller.onReplace = ^(MainWindowController *old, id<DBConnection> connection, SSHTunnel *tunnel, NSDictionary *info) {
        MainWindowController *replacement = [weakSelf openWindowWithConnection:connection tunnel:tunnel info:info];
        NSRect frame = old.window.frame;
        if (old.window.tabbedWindows.count > 1) frame = NSOffsetRect(frame, 28, -28);
        [replacement.window setFrame:frame display:YES];
        [old.window close];
    };
    [_windows addObject:controller];
    return controller;
}

// A tab right after `source`'s, on the same connection (no new login or tunnel).
- (MainWindowController *)openTabFor:(MainWindowController *)source schema:(NSString *)schema table:(NSString *)table tab:(NSInteger)tab {
    MainWindowController *controller = [self controllerWithConnection:source.connection tunnel:source.tunnel info:source.info];
    [source.window addTabbedWindow:controller.window ordered:NSWindowAbove];
    [controller.window makeKeyAndOrderFront:nil];
    if (table) [controller openTableSchema:schema name:table tab:tab]; // no table: an empty tab to pick one in
    return controller;
}

// The windows of one connection, in tab order (tabs first, then any separate windows).
- (NSArray<MainWindowController *> *)controllersOf:(NSDictionary *)info {
    NSString *identity = TBConnectionIdentity(info);
    NSMutableArray *ordered = [NSMutableArray new];
    for (MainWindowController *c in _windows) {
        if (![TBConnectionIdentity(c.info) isEqual:identity] || [ordered containsObject:c]) continue;
        for (NSWindow *w in c.window.tabbedWindows ?: @[c.window])
            for (MainWindowController *other in _windows)
                if (other.window == w && ![ordered containsObject:other]) [ordered addObject:other];
    }
    return ordered;
}

- (void)saveTabsOf:(NSDictionary *)info {
    if (_terminating) return; // saved once, before the windows close one by one
    NSMutableArray *tabs = [NSMutableArray new];
    for (MainWindowController *c in [self controllersOf:info])
        if (c.openTable) [tabs addObject:c.openTable];
    if (tabs.count) [ConnectionStore saveTabs:tabs for:TBConnectionIdentity(info)];
}

// Closing one tab saves the remaining ones. Closing the whole window closes its tabs one after another in the same
// event, so the save waits for the next turn of the run loop: if no window of the connection is left by then, the
// list from before (all of them) stays and comes back next time. The connection closes with its last window.
- (void)windowClosed:(MainWindowController *)closed {
    [_windows removeObject:closed];
    NSDictionary *info = closed.info;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self controllersOf:info].count) [self saveTabsOf:info];
    });
    NSMutableArray *others = [NSMutableArray new];
    for (MainWindowController *c in _windows) [others addObject:c.connection];
    if (TBConnectionStillUsed(others, closed.connection)) return;
    [closed.tunnel stop];
    id<DBConnection> conn = closed.connection;
    dispatch_async(conn.queue, ^{ [conn close]; });
}

- (void)showConnections:(id)sender {
    [_connect showWindow:nil];
}

- (void)openDocument:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = L(@"Choose an SQLite database file.");
    panel.allowsMultipleSelection = YES;
    if ([panel runModal] != NSModalResponseOK) return;
    for (NSURL *url in panel.URLs) [self openFileAtPath:url.path];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls)
        if (url.isFileURL) [self openFileAtPath:url.path];
}

// Opens a window for the file, or shows why it couldn't.
- (void)openFileAtPath:(NSString *)path {
    NSDictionary *info = [ConnectionStore fileConnectionForPath:path];
    TBConnect(info, @"", ^(id<DBConnection> connection, SSHTunnel *tunnel, NSError *error) {
        if (!connection) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = [NSString stringWithFormat:L(@"Couldn't open %@"), path.lastPathComponent];
            alert.informativeText = error.localizedDescription ?: @"";
            [alert runModal];
            return;
        }
        [self openWindowWithConnection:connection tunnel:tunnel info:info];
    });
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
    for (MainWindowController *c in [_windows copy]) [self saveTabsOf:c.info];
    _terminating = YES;
    for (MainWindowController *c in [_windows copy]) [c.window close]; // closes connections and ssh tunnels
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
    [file addItemWithTitle:L(@"Open…") action:@selector(openDocument:) keyEquivalent:@"o"];
    [file addItemWithTitle:L(@"New Tab") action:@selector(newWindowForTab:) keyEquivalent:@"t"]; // the open table again
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

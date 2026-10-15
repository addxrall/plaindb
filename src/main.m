#import <Cocoa/Cocoa.h>
#import "ConnectWindowController.h"
#import "MainWindowController.h"
#import "SSHTunnel.h"

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    ConnectWindowController *_connect;
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

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (!visible) [self showConnections:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    for (MainWindowController *c in [_windows copy]) [c.window close]; // zamyka tunele ssh
}

- (NSMenu *)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [self submenu:@"Tabula" in:bar];
    [app addItemWithTitle:@"O programie Tabula" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Ukryj Tabulę" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:@"Zakończ Tabulę" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenu *file = [self submenu:@"Plik" in:bar];
    [file addItemWithTitle:@"Połączenia…" action:@selector(showConnections:) keyEquivalent:@"n"];
    [file addItemWithTitle:@"Zamknij okno" action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenu *edit = [self submenu:@"Edycja" in:bar];
    [edit addItemWithTitle:@"Cofnij" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Powtórz" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:NSMenuItem.separatorItem];
    [edit addItemWithTitle:@"Wytnij" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Kopiuj" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Wklej" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Zaznacz wszystko" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenu *query = [self submenu:@"Zapytanie" in:bar];
    [query addItemWithTitle:@"Uruchom / Odśwież" action:NSSelectorFromString(@"runQuery:") keyEquivalent:@"r"];

    NSMenu *window = [self submenu:@"Okno" in:bar];
    [window addItemWithTitle:@"Minimalizuj" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
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

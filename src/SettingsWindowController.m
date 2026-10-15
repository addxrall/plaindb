#import "SettingsWindowController.h"
#import "UI.h"

static NSString *const LanguagesKey = @"AppleLanguages";

// language code (nil = follow the system), label shown in its own language
static NSArray<NSArray *> *Languages(void) {
    return @[@[NSNull.null, L(@"System default")], @[@"en", @"English"], @[@"pl", @"Polski"]];
}

@implementation SettingsWindowController {
    NSPopUpButton *_language;
    NSTextField *_note;
    NSButton *_restart;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 150)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    window.releasedWhenClosed = NO;
    window.title = L(@"Settings");

    _language = [NSPopUpButton new];
    for (NSArray *l in Languages()) [_language addItemWithTitle:l[1]];
    NSString *current = [[NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier][LanguagesKey] firstObject];
    NSUInteger index = [Languages() indexOfObjectPassingTest:^BOOL(NSArray *l, NSUInteger i, BOOL *stop) { return [l[0] isEqual:current]; }];
    [_language selectItemAtIndex:index == NSNotFound ? 0 : index];
    _language.target = self;
    _language.action = @selector(languageChanged:);

    _note = TBLabel(L(@"Restart PlainDB to apply the new language."), 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _restart = TBButton(L(@"Restart Now"), self, @selector(restart:));
    _note.hidden = _restart.hidden = YES;

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[[NSTextField labelWithString:L(@"Language:")], _language],
        @[NSGridCell.emptyContentView, _note],
        @[NSGridCell.emptyContentView, _restart],
    ]];
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;

    NSView *root = [NSView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:root.topAnchor constant:24],
        [grid.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [root.widthAnchor constraintEqualToConstant:420],
        [root.heightAnchor constraintEqualToConstant:150],
    ]];
    window.contentView = root;
    [window center];
    return self;
}

- (void)languageChanged:(id)sender {
    id code = Languages()[_language.indexOfSelectedItem][0];
    if (code == NSNull.null) [NSUserDefaults.standardUserDefaults removeObjectForKey:LanguagesKey];
    else [NSUserDefaults.standardUserDefaults setObject:@[code] forKey:LanguagesKey];
    _note.hidden = _restart.hidden = NO;
}

- (void)restart:(id)sender {
    // A shell waits for this process to exit, then `open -n` starts a fresh copy.
    // Unsaved grid changes still get their prompt in applicationShouldTerminate.
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[@"-c", [NSString stringWithFormat:@"while kill -0 %d 2>/dev/null; do sleep 0.2; done; open -n \"$0\"",
                                                         NSProcessInfo.processInfo.processIdentifier],
                       NSBundle.mainBundle.bundlePath];
    [task launchAndReturnError:nil];
    [NSApp terminate:nil];
}

@end

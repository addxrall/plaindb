#import "ConnectWindowController.h"
#import "ConnectionStore.h"
#import "Connector.h"
#import "PGConnection.h"
#import "SSHTunnel.h"
#import "UI.h"

static NSString *const ModeKey = @"connectMode"; // 0 = Local, 1 = Saved
static const NSInteger TileColumns = 5;
static const CGFloat TitleBand = 38; // height of the transparent title bar area

// Production frame colours offered in the form: hex, name. Any other colour comes from the custom swatch.
static NSArray<NSArray<NSString *> *> *FrameColors(void) {
    return @[@[@"#e0342b", L(@"Red")], @[@"#f08c00", L(@"Orange")], @[@"#e6b800", L(@"Yellow")], @[@"#2ea043", L(@"Green")],
             @[@"#14a5b8", L(@"Teal")], @[@"#0a84ff", L(@"Blue")], @[@"#8b5cf6", L(@"Purple")], @[@"#e0418f", L(@"Pink")]];
}

static NSString *HexFromColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02lx%02lx%02lx", lround(c.redComponent * 255), lround(c.greenComponent * 255), lround(c.blueComponent * 255)];
}

// Round 16 pt colour swatch in a 23 pt frame (so swatches sit 7 pt apart); the selected one gets a
// ring 2 pt outside it, as in the design. The custom swatch is a colour wheel; its ring shows the chosen colour.
@interface SwatchButton : NSButton
@property (nonatomic, copy) NSString *hex;
@property (nonatomic) BOOL custom, none, selectedSwatch; // none: "no colour", a crossed-out circle
@end

@implementation SwatchButton
- (void)drawRect:(NSRect)rect {
    NSColor *color = [Theme colorFromHex:self.hex fallback:NSColor.systemRedColor];
    NSRect dot = NSInsetRect(self.bounds, (NSWidth(self.bounds) - 16) / 2, (NSHeight(self.bounds) - 16) / 2);
    if (self.selectedSwatch) {
        [color setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -2.75, -2.75)];
        ring.lineWidth = 1.5;
        [ring stroke];
    }
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:dot];
    if (self.none) {
        NSColor *ink = self.selectedSwatch ? NSColor.labelColor : NSColor.tertiaryLabelColor;
        [ink setStroke];
        NSBezierPath *outline = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, 0.75, 0.75)];
        outline.lineWidth = 1.5;
        [outline stroke];
        NSBezierPath *slash = [NSBezierPath bezierPath];
        [slash moveToPoint:NSMakePoint(NSMinX(dot) + 4, NSMinY(dot) + 4)];
        [slash lineToPoint:NSMakePoint(NSMaxX(dot) - 4, NSMaxY(dot) - 4)];
        slash.lineWidth = 1.5;
        [slash stroke];
        return;
    }
    if (self.custom) {
        NSArray *hues = @[@"#ff3b30", @"#ff9500", @"#ffcc00", @"#34c759", @"#00c7be", @"#0a84ff", @"#af52de", @"#ff2d55", @"#ff3b30"];
        NSMutableArray *colors = [NSMutableArray new];
        for (NSString *h in hues) [colors addObject:(__bridge id)[Theme colorFromHex:h fallback:NSColor.redColor].CGColor];
        CGGradientRef wheel = CGGradientCreateWithColors(CGColorSpaceCreateWithName(kCGColorSpaceSRGB), (__bridge CFArrayRef)colors, NULL);
        CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(ctx);
        [circle addClip];
        CGContextDrawConicGradient(ctx, wheel, CGPointMake(NSMidX(dot), NSMidY(dot)), M_PI_2);
        CGContextRestoreGState(ctx);
        CGGradientRelease(wheel);
    } else {
        [color setFill];
        [circle fill];
    }
    if (!self.selectedSwatch) { // hairline, like the design's inset .5px shadow
        [[NSColor colorWithWhite:0 alpha:0.2] setStroke];
        NSBezierPath *edge = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, 0.25, 0.25)];
        edge.lineWidth = 0.5;
        [edge stroke];
    }
}
@end

// key, label, placeholder
static NSArray<NSArray<NSString *> *> *FieldSpec(void) {
    return @[
        @[@"name", L(@"Name:"), L(@"e.g. Production – API")],
        @[@"host", L(@"Database host:"), @"localhost"],
        @[@"port", L(@"Port:"), @"5432"],
        @[@"user", L(@"User:"), @"postgres"],
        @[@"password", L(@"Password:"), @""],
        @[@"database", L(@"Database:"), @"postgres"],
        @[@"sshHost", L(@"SSH tunnel:"), L(@"user@server or alias")],
    ];
}

@implementation ConnectWindowController {
    NSMutableArray<NSMutableDictionary *> *_connections;
    NSInteger _selected;
    NSString *_loadedPassword, *_frameColor;
    BOOL _connecting, _colorPanelAttached;

    TBSwitcher *_tabs;
    NSLayoutConstraint *_modeCenter;
    // saved connections
    NSTableView *_list;
    NSDictionary<NSString *, NSTextField *> *_fields;
    NSButton *_production, *_connectButton;
    NSGridRow *_colorRow;
    NSArray<SwatchButton *> *_swatches;
    NSProgressIndicator *_spinner;
    NSImageView *_errorIcon;
    NSTextField *_statusLabel;
    // local databases
    NSView *_tilesView;
    NSArray<NSString *> *_localNames;
    NSProgressIndicator *_localSpinner;
    NSTextField *_localStatus;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 420)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    window.releasedWhenClosed = NO;
    window.title = L(@"Connections");
    window.titleVisibility = NSWindowTitleHidden;
    window.titlebarAppearsTransparent = YES;
    window.movableByWindowBackground = YES;
    _selected = -1;
    _connections = [ConnectionStore load];
    if (!_connections.count) [_connections addObject:[self newConnection]];
    [self buildUI];
    [window center];
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    return self;
}

- (NSMutableDictionary *)newConnection {
    return [@{@"id": NSUUID.UUID.UUIDString, @"name": L(@"New connection"), @"host": @"localhost", @"port": @"5432"} mutableCopy];
}

#pragma mark - UI

- (void)buildUI {
    _tabs = [[TBSwitcher alloc] initWithViews:@[[self buildLocalView], [self buildSavedView]]];
    NSInteger mode = MIN(MAX([NSUserDefaults.standardUserDefaults integerForKey:ModeKey], 0), 1);
    _tabs.selectedIndex = mode;
    NSSegmentedControl *modeSwitch = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Local"), L(@"Saved")]
                                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                             target:self
                                                                             action:@selector(switchMode:)];
    modeSwitch.selectedSegment = mode;
    modeSwitch.controlSize = NSControlSizeSmall;

    NSView *root = [NSView new];
    TBPin(_tabs, root, NSEdgeInsetsMake(0, 0, 0, 0));
    modeSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:modeSwitch];
    _modeCenter = [modeSwitch.centerXAnchor constraintEqualToAnchor:root.centerXAnchor];
    [NSLayoutConstraint activateConstraints:@[_modeCenter, [modeSwitch.centerYAnchor constraintEqualToAnchor:root.topAnchor constant:TitleBand / 2]]];
    [self centerModeSwitch];
    self.window.contentView = root;
}

// Over the whole window for Local, over the form (right of the sidebar) for Saved.
- (void)centerModeSwitch {
    _modeCenter.constant = _tabs.selectedIndex == 1 ? 103 : 0;
}

- (NSView *)buildSavedView {
    // left: list of saved connections
    _list = [NSTableView new];
    _list.headerView = nil;
    _list.rowHeight = 36;
    _list.intercellSpacing = NSMakeSize(0, 2);
    _list.backgroundColor = NSColor.clearColor;
    _list.style = NSTableViewStylePlain;
    _list.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.width = 206; // full sidebar width; the default 100 cut names short
    nameColumn.resizingMask = NSTableColumnAutoresizingMask;
    [_list addTableColumn:nameColumn];
    _list.dataSource = self;
    _list.delegate = self;
    _list.target = self;
    _list.doubleAction = @selector(connect:);
    NSScrollView *listScroll = [NSScrollView new];
    listScroll.documentView = _list;
    listScroll.hasVerticalScroller = YES;
    listScroll.autohidesScrollers = YES;
    listScroll.drawsBackground = NO;

    NSSegmentedControl *listButtons = [NSSegmentedControl segmentedControlWithImages:@[[NSImage imageNamed:NSImageNameAddTemplate],
                                                                                       [NSImage imageNamed:NSImageNameRemoveTemplate]]
                                                                        trackingMode:NSSegmentSwitchTrackingMomentary
                                                                              target:self
                                                                              action:@selector(listButtonClicked:)];
    listButtons.controlSize = NSControlSizeSmall;
    NSView *titleSpace = [NSView new];
    [titleSpace.heightAnchor constraintEqualToConstant:TitleBand].active = YES;
    NSStackView *sideColumn = TBColumn(@[titleSpace, listScroll, TBSeparator(), TBBar(@[listButtons], @[], 30)], listScroll);
    NSBox *side = TBPanel(Theme.side);
    TBPin(sideColumn, side.contentView, NSEdgeInsetsMake(0, 0, 0, 0));
    [side.widthAnchor constraintEqualToConstant:206].active = YES;

    // right: form
    NSMutableDictionary *fields = [NSMutableDictionary new];
    NSMutableDictionary *labels = [NSMutableDictionary new];
    for (NSArray *spec in FieldSpec()) {
        NSTextField *f = [spec[0] isEqual:@"password"] ? [NSSecureTextField new] : [NSTextField new];
        f.placeholderString = spec[2];
        fields[spec[0]] = f;
        labels[spec[0]] = [NSTextField labelWithString:spec[1]];
    }
    _fields = fields;
    [_fields[@"port"].widthAnchor constraintEqualToConstant:58].active = YES;
    NSStackView *hostRow = [NSStackView stackViewWithViews:@[_fields[@"host"], labels[@"port"], _fields[@"port"]]];
    hostRow.spacing = 10;
    NSTextField *sshHint = TBWrappingLabel(L(@"user@server or an alias from ~/.ssh/config. Empty: direct connection."), 11,
                                           NSColor.secondaryLabelColor);
    sshHint.preferredMaxLayoutWidth = 340;
    NSStackView *sshColumn = TBColumn(@[_fields[@"sshHost"], sshHint], nil);
    sshColumn.spacing = 4;
    _production = [NSButton checkboxWithTitle:L(@"Production: read-only, writes need confirmation") target:self action:@selector(productionToggled:)];

    NSMutableArray *swatches = [NSMutableArray new];
    NSArray *colors = [[@[@[@"", L(@"No color")]] arrayByAddingObjectsFromArray:FrameColors()] arrayByAddingObject:@[@"", L(@"Custom color")]];
    for (NSArray *c in colors) {
        SwatchButton *swatch = [SwatchButton new];
        swatch.hex = c[0];
        swatch.none = c == colors.firstObject;
        swatch.custom = c == colors.lastObject;
        swatch.toolTip = c[1];
        swatch.bordered = NO;
        swatch.target = self;
        swatch.action = swatch.custom ? @selector(customColorClicked:) : @selector(swatchClicked:);
        [NSLayoutConstraint activateConstraints:@[[swatch.widthAnchor constraintEqualToConstant:23], [swatch.heightAnchor constraintEqualToConstant:23]]];
        [swatches addObject:swatch];
    }
    _swatches = swatches;
    NSBox *divider = TBPanel(NSColor.separatorColor);
    [NSLayoutConstraint activateConstraints:@[[divider.widthAnchor constraintEqualToConstant:1], [divider.heightAnchor constraintEqualToConstant:14]]];
    NSStackView *swatchRow = [NSStackView stackViewWithViews:[[swatches subarrayWithRange:NSMakeRange(0, swatches.count - 1)]
                                                                 arrayByAddingObjectsFromArray:@[divider, swatches.lastObject]]];
    swatchRow.spacing = 0;
    [swatchRow setCustomSpacing:5.5 afterView:swatches[swatches.count - 2]]; // 7 pt gap + 2 pt margin around the divider
    [swatchRow setCustomSpacing:5.5 afterView:divider];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[labels[@"name"], _fields[@"name"]],
        @[labels[@"host"], hostRow],
        @[labels[@"user"], _fields[@"user"]],
        @[labels[@"password"], _fields[@"password"]],
        @[labels[@"database"], _fields[@"database"]],
        @[labels[@"sshHost"], sshColumn],
        @[NSGridCell.emptyContentView, _production],
        @[[NSTextField labelWithString:L(@"Window frame:")], swatchRow],
    ]];
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementFill; // fields take the remaining width
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    _colorRow = [grid rowAtIndex:7];
    [grid cellForView:swatchRow].yPlacement = NSGridCellPlacementCenter;
    [grid cellForView:swatchRow].xPlacement = NSGridCellPlacementLeading;
    [grid cellForView:_production].xPlacement = NSGridCellPlacementLeading;

    _spinner = TBSpinner(NSControlSizeSmall);
    _errorIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"exclamationmark.circle.fill" accessibilityDescription:nil]];
    _errorIcon.contentTintColor = Theme.red;
    _errorIcon.hidden = YES;
    _statusLabel = TBWrappingLabel(@"", 11.5, NSColor.secondaryLabelColor);
    _statusLabel.maximumNumberOfLines = 2;
    [_statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    _connectButton = TBButton(L(@"Connect"), self, @selector(connect:));
    _connectButton.keyEquivalent = @"\r";
    NSStackView *bottom = TBBar(@[_spinner, _errorIcon, _statusLabel], @[TBButton(L(@"Save"), self, @selector(save:)), _connectButton], 52);
    bottom.edgeInsets = NSEdgeInsetsMake(0, 22, 0, 20);

    NSView *formArea = [NSView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [formArea addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:formArea.topAnchor constant:4],
        [grid.leadingAnchor constraintEqualToAnchor:formArea.leadingAnchor constant:12],
        [grid.trailingAnchor constraintEqualToAnchor:formArea.trailingAnchor constant:-24],
    ]];
    NSView *titleSpace2 = [NSView new];
    [titleSpace2.heightAnchor constraintEqualToConstant:TitleBand].active = YES;
    NSStackView *right = TBColumn(@[titleSpace2, formArea, bottom], formArea);

    // explicit constraints: sidebar on the left at full height, form fills the rest
    NSView *saved = [NSView new];
    for (NSView *v in @[side, right]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [saved addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [side.topAnchor constraintEqualToAnchor:saved.topAnchor],
        [side.bottomAnchor constraintEqualToAnchor:saved.bottomAnchor],
        [side.leadingAnchor constraintEqualToAnchor:saved.leadingAnchor],
        [right.topAnchor constraintEqualToAnchor:saved.topAnchor],
        [right.bottomAnchor constraintEqualToAnchor:saved.bottomAnchor],
        [right.leadingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [right.trailingAnchor constraintEqualToAnchor:saved.trailingAnchor],
    ]];
    return saved;
}

- (NSView *)buildLocalView {
    NSTextField *title = TBLabel(L(@"Local Postgres server"), 13, NSFontWeightSemibold, NSColor.labelColor);
    _localStatus = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _localSpinner = TBSpinner(NSControlSizeSmall);
    NSButton *refresh = TBSymbolButton(@"arrow.clockwise", L(@"Refresh the database list"), self, @selector(reloadLocal:));
    NSStackView *header = TBBar(@[title, _localSpinner], @[_localStatus, refresh], 32);
    header.edgeInsets = NSEdgeInsetsMake(0, 20, 0, 20);

    _tilesView = [TBFlippedView new];
    _tilesView.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = _tilesView;
    [NSLayoutConstraint activateConstraints:@[
        [_tilesView.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_tilesView.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [_tilesView.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
    NSLayoutConstraint *emptyHeight = [_tilesView.heightAnchor constraintEqualToConstant:0];
    emptyHeight.priority = NSLayoutPriorityDefaultLow; // with no tiles; the tile grid's own height wins otherwise
    emptyHeight.active = YES;
    NSView *titleSpace = [NSView new];
    [titleSpace.heightAnchor constraintEqualToConstant:TitleBand].active = YES;
    NSStackView *view = TBColumn(@[titleSpace, header, scroll], scroll);
    view.edgeInsets = NSEdgeInsetsMake(0, 0, 16, 0);
    [view setCustomSpacing:10 afterView:header];
    return view;
}

// Right-click on a local database: its window frame colour (the tile icon shows it too).
- (NSMenu *)colorMenuForDatabase:(NSString *)database {
    NSMenu *menu = [NSMenu new];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:L(@"Window frame")]];
    NSString *current = [ConnectionStore localFrameColorFor:database];
    for (NSArray *c in [@[@[@"", L(@"No color")]] arrayByAddingObjectsFromArray:FrameColors()]) {
        NSMenuItem *item = [menu addItemWithTitle:c[1] action:@selector(setLocalColor:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @[database, c[0]];
        item.state = [c[0] isEqual:current] ? NSControlStateValueOn : NSControlStateValueOff;
        NSColor *color = [c[0] length] ? [Theme colorFromHex:c[0] fallback:NSColor.clearColor] : nil;
        item.image = [NSImage imageWithSize:NSMakeSize(12, 12) flipped:NO drawingHandler:^BOOL(NSRect r) {
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 1, 1)];
            if (color) {
                [color setFill];
                [dot fill];
            } else {
                [NSColor.tertiaryLabelColor setStroke];
                [dot stroke];
            }
            return YES;
        }];
    }
    return menu;
}

- (void)setLocalColor:(NSMenuItem *)sender {
    [ConnectionStore setLocalFrameColor:sender.representedObject[1] for:sender.representedObject[0]];
    [self showTiles:_localNames];
}

- (void)showTiles:(NSArray<NSString *> *)names {
    _localNames = names;
    for (NSView *v in [_tilesView.subviews copy]) [v removeFromSuperview];
    if (!names.count) return;

    NSImage *icon = [[NSImage imageWithSystemSymbolName:@"cylinder.fill" accessibilityDescription:nil]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightRegular]];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger i = 0; i < names.count; i += TileColumns) {
        NSMutableArray *row = [NSMutableArray new];
        for (NSUInteger j = i; j < i + TileColumns; j++) {
            if (j >= names.count) {
                [row addObject:NSGridCell.emptyContentView];
                continue;
            }
            NSButton *tile = [NSButton buttonWithTitle:names[j] image:icon target:self action:@selector(openLocal:)];
            tile.imagePosition = NSImageAbove;
            tile.bordered = NO;
            NSString *frame = [ConnectionStore localFrameColorFor:names[j]];
            tile.contentTintColor = frame.length ? [Theme colorFromHex:frame fallback:NSColor.controlAccentColor] : NSColor.controlAccentColor;
            tile.menu = [self colorMenuForDatabase:names[j]];
            tile.attributedTitle = [[NSAttributedString alloc] initWithString:names[j] attributes:@{
                NSForegroundColorAttributeName: NSColor.labelColor,
                NSFontAttributeName: [NSFont systemFontOfSize:12],
            }];
            tile.lineBreakMode = NSLineBreakByTruncatingMiddle;
            tile.toolTip = names[j];
            [tile.widthAnchor constraintEqualToConstant:104].active = YES;
            [tile.heightAnchor constraintEqualToConstant:72].active = YES;
            [row addObject:tile];
        }
        [rows addObject:row];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 10;
    grid.columnSpacing = 8;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [_tilesView addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:_tilesView.topAnchor],
        [grid.bottomAnchor constraintEqualToAnchor:_tilesView.bottomAnchor],
        [grid.centerXAnchor constraintEqualToAnchor:_tilesView.centerXAnchor],
    ]];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    if (_tabs.selectedIndex == 0) [self reloadLocal:nil];
}

#pragma mark - List

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _connections.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    TBRowView *view = [TBRowView new];
    view.selectionColor = Theme.sideSelection;
    view.selectionInset = 8;
    view.selectionRadius = 6;
    return view;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *c = _connections[row];
    BOOL production = [c[@"production"] boolValue], ssh = [c[@"sshHost"] length] > 0;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"connection" owner:nil];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"connection";
        NSImageView *icon = [NSImageView new];
        NSTextField *name = TBLabel(@"", 13, NSFontWeightMedium, NSColor.labelColor);
        NSTextField *sub = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
        sub.tag = 1;
        for (NSView *v in @[icon, name, sub]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:16],
            [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:16],
            [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:9],
            [name.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-16],
            [name.bottomAnchor constraintEqualToAnchor:cell.centerYAnchor constant:1],
            [sub.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
            [sub.trailingAnchor constraintEqualToAnchor:name.trailingAnchor],
            [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor],
        ]];
        cell.imageView = icon;
        cell.textField = name;
    }
    NSString *frame = [ConnectionStore frameColorFor:c];
    NSColor *tint = frame.length ? [Theme colorFromHex:frame fallback:Theme.red] : NSColor.secondaryLabelColor; // icon in the window's colour
    cell.imageView.image = [NSImage imageWithSystemSymbolName:ssh ? @"lock.shield" : @"cylinder" accessibilityDescription:nil];
    cell.imageView.contentTintColor = tint;
    cell.textField.stringValue = [c[@"name"] length] ? c[@"name"] : L(@"Untitled");
    cell.textField.textColor = production ? Theme.red : NSColor.labelColor;
    NSTextField *sub = [cell viewWithTag:1];
    sub.stringValue = ssh ? [NSString stringWithFormat:L(@"via %@"), c[@"sshHost"]]
                          : [NSString stringWithFormat:@"%@:%@", [c[@"host"] length] ? c[@"host"] : @"localhost", [c[@"port"] length] ? c[@"port"] : @"5432"];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_selected >= 0 && _selected < (NSInteger)_connections.count) [self storeFormAt:_selected];
    _selected = _list.selectedRow;
    [self fillForm];
}

- (void)fillForm {
    BOOL has = _selected >= 0;
    NSDictionary *c = has ? _connections[_selected] : @{};
    for (NSString *key in _fields) {
        _fields[key].stringValue = c[key] ?: @"";
        _fields[key].enabled = has;
    }
    _loadedPassword = has ? [ConnectionStore passwordFor:c[@"id"]] ?: @"" : @"";
    _fields[@"password"].stringValue = _loadedPassword;
    _production.state = [c[@"production"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    _production.enabled = _connectButton.enabled = has;
    _frameColor = has ? [ConnectionStore frameColorFor:c] : @"";
    if (_colorPanelAttached) { // an open colour panel must not recolour the next connection
        NSColorPanel.sharedColorPanel.target = nil;
        _colorPanelAttached = NO;
    }
    [self updateProductionRow];
    [self showStatus:@"" error:NO];
}

// Every connection can have a frame colour; production always has one, so "no colour" is hidden there.
- (void)updateProductionRow {
    BOOL production = _production.state == NSControlStateValueOn;
    if (production && !_frameColor.length) _frameColor = FrameColors()[0][0];
    BOOL preset = !_frameColor.length;
    for (NSArray *c in FrameColors()) preset |= [c[0] isEqual:_frameColor];
    for (SwatchButton *s in _swatches) {
        if (s.custom) s.hex = preset ? @"" : _frameColor;
        s.hidden = s.none && production;
        s.selectedSwatch = s.custom ? !preset : s.none ? !_frameColor.length : [s.hex isEqual:_frameColor];
        s.needsDisplay = YES;
    }
}

- (void)storeFormAt:(NSInteger)index {
    NSMutableDictionary *c = _connections[index];
    for (NSString *key in _fields) {
        if ([key isEqual:@"password"]) continue;
        c[key] = [_fields[key].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (![c[@"name"] length]) c[@"name"] = [c[@"host"] length] ? c[@"host"] : L(@"Untitled");
    c[@"production"] = @(_production.state == NSControlStateValueOn);
    c[@"frame"] = _frameColor;
    [c removeObjectForKey:@"color"]; // superseded by "frame"

    NSString *password = _fields[@"password"].stringValue;
    if (![password isEqual:_loadedPassword]) {
        [ConnectionStore setPassword:password for:c[@"id"]];
        _loadedPassword = password;
    }
    [ConnectionStore save:_connections];
    [_list reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (void)showStatus:(NSString *)text error:(BOOL)error {
    _statusLabel.stringValue = text;
    _statusLabel.textColor = error ? Theme.red : NSColor.secondaryLabelColor;
    _errorIcon.hidden = !error;
}

#pragma mark - Actions

- (void)productionToggled:(id)sender {
    [self updateProductionRow];
    if (_selected >= 0) [self storeFormAt:_selected];
}

- (void)swatchClicked:(SwatchButton *)sender {
    [self setFrameColor:sender.hex];
}

- (void)setFrameColor:(NSString *)hex {
    _frameColor = hex;
    [self updateProductionRow];
    if (_selected >= 0) [self storeFormAt:_selected];
}

// Custom swatch: the system colour panel, starting from the current colour.
- (void)customColorClicked:(id)sender {
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.showsAlpha = NO;
    panel.color = [Theme colorFromHex:_frameColor fallback:NSColor.systemOrangeColor];
    panel.target = self;
    panel.action = @selector(customColorChanged:);
    _colorPanelAttached = YES;
    [panel orderFront:nil];
}

- (void)customColorChanged:(NSColorPanel *)panel {
    if (_selected >= 0) [self setFrameColor:HexFromColor(panel.color)];
}

- (void)save:(id)sender {
    if (_selected >= 0) [self storeFormAt:_selected];
}

- (void)listButtonClicked:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) [self addConnection];
    else [self removeConnection];
}

- (void)addConnection {
    [_connections addObject:[self newConnection]];
    [ConnectionStore save:_connections];
    [_list reloadData];
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:_connections.count - 1] byExtendingSelection:NO];
    [self.window makeFirstResponder:_fields[@"name"]];
}

- (void)removeConnection {
    if (_selected < 0) return;
    NSInteger index = _selected;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:L(@"Remove the connection “%@”?"), _connections[index][@"name"]];
    alert.informativeText = L(@"This only removes the saved settings and the password in the Keychain. The database is not touched.");
    [alert addButtonWithTitle:L(@"Remove")];
    [alert addButtonWithTitle:L(@"Cancel")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [ConnectionStore setPassword:nil for:self->_connections[index][@"id"]];
        self->_selected = -1; // so the selection change doesn't store the form under the wrong index
        [self->_connections removeObjectAtIndex:index];
        [ConnectionStore save:self->_connections];
        [self->_list reloadData];
        [self fillForm];
    }];
}

- (void)switchMode:(NSSegmentedControl *)sender {
    _tabs.selectedIndex = sender.selectedSegment;
    [self centerModeSwitch];
    [NSUserDefaults.standardUserDefaults setInteger:sender.selectedSegment forKey:ModeKey];
    if (sender.selectedSegment == 0) [self reloadLocal:nil];
}

// Databases on the default local server: socket in /tmp, port 5432, OS user (like Postgres.app).
- (void)reloadLocal:(id)sender {
    [_localSpinner startAnimation:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PGConnection *pg = [[PGConnection alloc] initWithParams:@{@"dbname": @"postgres"} readOnly:YES];
        NSError *error = nil;
        DBResult *r = nil;
        if ([pg open:&error])
            r = [pg execute:@"SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
                     params:nil error:&error];
        [pg close];

        NSMutableArray *names = [NSMutableArray new];
        for (NSArray *row in r.rows) [names addObject:row[0]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_localSpinner stopAnimation:nil];
            [self showTiles:names];
            self->_localStatus.stringValue = r ? LN(@"%lu databases", names.count) : L(@"No server found on port 5432");
            self->_localStatus.toolTip = error.localizedDescription;
        });
    });
}

- (void)openLocal:(NSButton *)sender {
    if (_connecting) return;
    NSString *db = sender.title;
    NSDictionary *info = @{@"id": @"local", @"name": db, @"user": NSUserName(), @"database": db, @"frame": [ConnectionStore localFrameColorFor:db]};
    [_localSpinner startAnimation:nil];
    _localStatus.stringValue = [NSString stringWithFormat:L(@"Connecting to %@…"), db];
    [self connectWithInfo:info password:@"" done:^(NSError *error) {
        [self->_localSpinner stopAnimation:nil];
        self->_localStatus.stringValue = error ? error.localizedDescription : @"";
    }];
}

- (void)connect:(id)sender {
    if (_selected < 0 || _connecting) return;
    [self storeFormAt:_selected];
    NSDictionary *info = [_connections[_selected] copy];
    _connectButton.enabled = NO;
    [_spinner startAnimation:nil];
    NSString *host = [info[@"host"] length] ? info[@"host"] : @"localhost";
    [self showStatus:[info[@"sshHost"] length] ? [NSString stringWithFormat:L(@"Opening tunnel via %@…"), info[@"sshHost"]]
                                               : [NSString stringWithFormat:L(@"Connecting to %@…"), host]
               error:NO];
    [self connectWithInfo:info password:_fields[@"password"].stringValue done:^(NSError *error) {
        [self->_spinner stopAnimation:nil];
        self->_connectButton.enabled = YES;
        [self showStatus:error ? error.localizedDescription : @"" error:error != nil];
    }];
}

// Sets up the tunnel (if any) and the connection in the background. `done` runs on the main thread: nil = window opened.
- (void)connectWithInfo:(NSDictionary *)info password:(NSString *)password done:(void (^)(NSError *error))done {
    _connecting = YES;
    TBConnect(info, password, ^(id<DBConnection> connection, SSHTunnel *tunnel, NSError *error) {
        self->_connecting = NO;
        if (!connection) return done(error);
        if (self.onConnected) self.onConnected(connection, tunnel, info);
        done(nil);
    });
}

@end

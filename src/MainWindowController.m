#import "MainWindowController.h"
#import "GridView.h"
#import "JSONInspector.h"
#import "SQLText.h"
#import "SSHTunnel.h"
#import "UI.h"

static const NSInteger PageSize = 200;
static NSToolbarItemIdentifier const TabsItem = @"tabs";
static NSToolbarItemIdentifier const ProductionItem = @"production";

typedef DBResult *_Nullable (^Work)(NSError **error);
typedef NS_ENUM(NSInteger, Tab) { TabData, TabStructure, TabSQL, TabEmpty };
typedef NS_ENUM(NSInteger, DataState) { DataGrid, DataLoading, DataFailed };
typedef NS_ENUM(NSInteger, SQLState) { SQLIdle, SQLRunning, SQLDone, SQLFailed, SQLResult };

static NSView *Dot(NSColor *color, CGFloat size) {
    NSBox *dot = TBPanel(color);
    dot.cornerRadius = size / 2;
    [NSLayoutConstraint activateConstraints:@[[dot.widthAnchor constraintEqualToConstant:size], [dot.heightAnchor constraintEqualToConstant:size]]];
    return dot;
}

static NSButton *AccentButton(NSString *title, id target, SEL action) {
    NSButton *b = TBButton(title, target, action);
    b.bezelColor = NSColor.controlAccentColor;
    return b;
}

@interface MainWindowController () <NSToolbarDelegate, NSSearchFieldDelegate, NSMenuDelegate>
@end

static NSString *const PinsKey = @"pinnedTables"; // { "<connection id>/<database>": ["schema.table", …] }

@implementation MainWindowController {
    id<DBConnection> _conn;
    SSHTunnel *_tunnel;
    NSDictionary *_info;
    BOOL _production, _tunnelConnected;
    NSSplitViewController *_split;

    // JSON inspector on the right: which grid cell it shows
    JSONInspector *_jsonInspector;
    NSSplitViewItem *_inspectorItem;
    GridView *_inspectorGrid;
    NSInteger _inspectorRow, _inspectorColumn;

    // table list and current table
    NSArray<NSArray *> *_tables;
    NSArray *_sideRows; // NSString = section header, NSArray = [schema, name, kind]
    NSMutableArray<NSString *> *_pinned; // "schema.table", in the order they were pinned
    NSString *_schema, *_table, *_sortColumn;
    BOOL _sortAscending, _isView;
    NSInteger _offset;
    NSArray<NSString *> *_pkColumns, *_columnNames;
    NSSet<NSString *> *_defaultColumns;
    NSString *_searchTerm; // active ⌘F filter of the Data tab, nil when off
    NSView *_searchBar;
    NSSearchField *_searchField;
    NSTextField *_searchStatus;
    NSString *_tablesStatus, *_dataStatus, *_structureStatus, *_sqlStatus;

    NSSearchField *_filter;
    NSTableView *_sidebar;
    NSSegmentedControl *_tabSwitch;
    TBSwitcher *_tabs;

    // Data tab
    NSTextField *_tableLabel, *_pageLabel, *_readOnlyText, *_loadingLabel, *_errorTitle, *_errorMessage;
    NSView *_readOnlyBadge, *_readOnlyStrip;
    NSSegmentedControl *_rowButtons;
    NSButton *_prevButton, *_nextButton;
    TBSwitcher *_dataState;
    NSProgressIndicator *_dataSpinner;
    GridView *_dataGrid;

    // Structure tab
    NSTextField *_structureTitle, *_structureMeta;
    GridView *_columnsGrid, *_indexesGrid;
    NSLayoutConstraint *_indexesHeight;

    // SQL tab
    NSTextView *_sqlText;
    TBSwitcher *_sqlState;
    NSProgressIndicator *_sqlSpinner;
    NSTextField *_sqlDoneLabel, *_sqlErrorText;
    GridView *_sqlGrid;

    // bottom bars
    NSView *_pendingBar;
    NSTextField *_pendingLabel, *_pendingDetail, *_statusLabel, *_tunnelLabel;
    NSView *_tunnelDot;
    NSProgressIndicator *_tunnelSpinner;
}

- (instancetype)initWithConnection:(id<DBConnection>)connection tunnel:(SSHTunnel *)tunnel info:(NSDictionary *)info {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                                             NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    _conn = connection;
    _tunnel = tunnel;
    _info = info;
    _production = [info[@"production"] boolValue];
    _tunnelConnected = tunnel != nil;

    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.title = info[@"name"];
    NSString *target = [NSString stringWithFormat:@"%@@%@/%@", info[@"user"] ?: @"", [info[@"host"] length] ? info[@"host"] : @"localhost",
                                                  info[@"database"] ?: @""];
    window.subtitle = [info[@"sshHost"] length] ? [NSString stringWithFormat:L(@"%@ via %@"), target, info[@"sshHost"]] : target;
    window.toolbarStyle = NSWindowToolbarStyleUnified;

    [self buildUI];
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"main"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    toolbar.centeredItemIdentifiers = [NSSet setWithObject:TabsItem];
    window.toolbar = toolbar;
    if (_production) [self applyProductionFrame]; // after the toolbar: it decides the corner radius
    window.contentMinSize = NSMakeSize(760, 460);
    [window setContentSize:NSMakeSize(1100, 700)];
    [window center];

    __weak MainWindowController *weakSelf = self;
    _tunnel.onStatus = ^(BOOL connected) { [weakSelf setTunnelConnected:connected]; };
    [self setTunnelConnected:_tunnelConnected];
    [self showTab:TabData];
    [self loadTables];
    return self;
}

#pragma mark - UI

- (void)buildUI {
    _tabSwitch = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Data"), L(@"Structure"), @"SQL"]
                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                         target:self
                                                         action:@selector(tabChanged:)];

    NSViewController *sideController = [NSViewController new];
    sideController.view = [self buildSidebar];
    NSViewController *mainController = [NSViewController new];
    mainController.view = [self buildContent];

    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sideController];
    sideItem.minimumThickness = 190;
    sideItem.maximumThickness = 420;
    _split = [NSSplitViewController new];
    [_split addSplitViewItem:sideItem];
    [_split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:mainController]];

    _jsonInspector = [JSONInspector new];
    __weak MainWindowController *weakSelf = self;
    _jsonInspector.onApply = ^(NSString *json) { [weakSelf applyJSON:json]; };
    _jsonInspector.onClose = ^{ [weakSelf hideInspector]; };
    _inspectorItem = [NSSplitViewItem inspectorWithViewController:_jsonInspector];
    _inspectorItem.minimumThickness = 300;
    _inspectorItem.maximumThickness = 640;
    _inspectorItem.collapsed = YES;
    [_split addSplitViewItem:_inspectorItem];
    self.window.contentViewController = _split;

    for (GridView *grid in @[_dataGrid, _sqlGrid]) {
        __weak GridView *weakGrid = grid;
        grid.onOpenJSON = ^(NSInteger row, NSInteger column) { [weakSelf showJSONInGrid:weakGrid row:row column:column open:YES]; };
        grid.onSelectCell = ^(NSInteger row, NSInteger column) { [weakSelf showJSONInGrid:weakGrid row:row column:column open:NO]; };
    }
}

#pragma mark - JSON inspector

// open: from double-click / Enter. Otherwise (a click) the panel only follows the selection while it is open.
- (void)showJSONInGrid:(GridView *)grid row:(NSInteger)row column:(NSInteger)column open:(BOOL)open {
    if (!open && _inspectorItem.collapsed) return;
    id value = [grid valueAtRow:row column:column];
    if (!JSONIsValid(value)) return [_jsonInspector showPlaceholder];
    _inspectorGrid = grid;
    _inspectorRow = row;
    _inspectorColumn = column;
    NSString *subtitle = grid == _dataGrid ? [NSString stringWithFormat:L(@"%@ · row %ld"), [self displayName], (long)(grid.rowNumberOffset + row + 1)]
                                           : [NSString stringWithFormat:L(@"Query result · row %ld"), (long)row + 1];
    [_jsonInspector showJSON:value title:grid.result.columns[column] subtitle:subtitle
                    editable:grid.editable && ![grid isRowDeleted:row]];
    if (_inspectorItem.collapsed) _inspectorItem.animator.collapsed = NO;
}

- (void)applyJSON:(NSString *)json {
    [_inspectorGrid updateValue:json row:_inspectorRow column:_inspectorColumn];
}

- (void)hideInspector {
    _inspectorItem.animator.collapsed = YES;
    _inspectorGrid = nil;
}

// The grid's rows changed (new table, page, query): the inspector no longer points at a valid cell.
- (void)resetInspectorForGrid:(GridView *)grid {
    if (_inspectorGrid != grid) return;
    _inspectorGrid = nil;
    [_jsonInspector showPlaceholder];
}

- (NSView *)buildSidebar {
    _filter = [NSSearchField new];
    _filter.placeholderString = L(@"Filter");
    _filter.target = self;
    _filter.action = @selector(filterChanged:);
    _filter.controlSize = NSControlSizeSmall;

    _sidebar = [NSTableView new];
    _sidebar.style = NSTableViewStyleSourceList;
    _sidebar.headerView = nil;
    _sidebar.rowHeight = 24;
    _sidebar.floatsGroupRows = NO;
    _sidebar.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    [_sidebar addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"name"]];
    _sidebar.dataSource = self;
    _sidebar.delegate = self;
    _sidebar.menu = [NSMenu new];
    _sidebar.menu.delegate = self; // Pin / Unpin, titled for the clicked table
    _pinned = [[NSUserDefaults.standardUserDefaults dictionaryForKey:PinsKey][[self pinsKey]] mutableCopy] ?: [NSMutableArray new];
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _sidebar;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;

    NSView *side = [NSView new];
    for (NSView *v in @[_filter, scroll]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [side addSubview:v];
    }
    NSLayoutConstraint *width = [side.widthAnchor constraintEqualToConstant:224];
    width.priority = NSLayoutPriorityDefaultLow; // initial width only, the user can drag the divider
    [NSLayoutConstraint activateConstraints:@[
        width,
        [_filter.topAnchor constraintEqualToAnchor:side.safeAreaLayoutGuide.topAnchor constant:6],
        [_filter.leadingAnchor constraintEqualToAnchor:side.leadingAnchor constant:10],
        [_filter.trailingAnchor constraintEqualToAnchor:side.trailingAnchor constant:-10],
        [scroll.topAnchor constraintEqualToAnchor:_filter.bottomAnchor constant:6],
        [scroll.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:side.bottomAnchor],
    ]];
    return side;
}

- (NSView *)buildContent {
    NSView *empty = TBCenteredState(@[
        TBLabel(L(@"No table selected"), 15, NSFontWeightSemibold, NSColor.secondaryLabelColor),
        TBLabel(L(@"Choose a table or view from the list on the left."), 12, NSFontWeightRegular, NSColor.tertiaryLabelColor),
    ]);
    _tabs = [[TBSwitcher alloc] initWithViews:@[[self buildDataTab], [self buildStructureTab], [self buildSQLTab], empty]];

    // pending changes
    _pendingLabel = TBLabel(@"", 13, NSFontWeightSemibold, NSColor.labelColor);
    _pendingDetail = TBLabel(@"", 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSButton *save = AccentButton([NSString stringWithFormat:@"%@  ⌘S", L(@"Save")], self, @selector(saveChanges:));
    NSStackView *pendingRow = TBBar(@[Dot(Theme.changedDot, 8), _pendingLabel, _pendingDetail],
                                    @[TBButton(L(@"Discard"), self, @selector(discardChanges:)), save], 40);
    _pendingBar = TBPanel(Theme.head);
    TBPin(TBColumn(@[TBSeparator(), pendingRow], pendingRow), ((NSBox *)_pendingBar).contentView, NSEdgeInsetsMake(0, 0, 0, 0));
    _pendingBar.hidden = YES;

    // status bar
    _statusLabel = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _statusLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _tunnelLabel = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _tunnelSpinner = TBSpinner(NSControlSizeMini);
    _tunnelDot = Dot(Theme.green, 7);
    NSStackView *statusRow = TBBar(@[_statusLabel], @[_tunnelSpinner, _tunnelDot, _tunnelLabel], 24);
    statusRow.spacing = 6;
    NSBox *status = TBPanel(Theme.head);
    TBPin(TBColumn(@[TBSeparator(), statusRow], statusRow), status.contentView, NSEdgeInsetsMake(0, 0, 0, 0));

    NSStackView *column = TBColumn(@[_tabs, _pendingBar, status], _tabs);

    NSView *content = [NSView new];
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.topAnchor constraintEqualToAnchor:content.safeAreaLayoutGuide.topAnchor],
        [column.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [column.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    return content;
}

// Design: a 3 pt ring around the whole window (sidebar and toolbar included), above everything,
// following the window's rounded corners. The window's root view layer draws it, because a layer
// border is composited above all sublayers. AppKit doesn't publish the corner radius (16 pt with a
// unified toolbar), so it comes from the private _cornerRadius, with a fallback.
// ponytail: in full screen the ring keeps its rounded corners; fix in windowDidEnterFullScreen if it bothers.
- (void)applyProductionFrame {
    NSView *root = self.window.contentView.superview;
    BOOL known = [self.window respondsToSelector:NSSelectorFromString(@"_cornerRadius")];
    root.wantsLayer = YES;
    root.layer.cornerRadius = known ? [[self.window valueForKey:@"_cornerRadius"] doubleValue] : 10;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = 3;
    root.layer.borderColor = [self productionColor].CGColor;
}

- (NSColor *)productionColor {
    return [Theme colorFromHex:_info[@"color"] fallback:Theme.productionBanner];
}

// Right side of the title bar on production: "PRODUCTION" badge in the frame colour plus a short note.
- (NSView *)productionBadge {
    NSBox *badge = TBPanel([self productionColor]);
    badge.cornerRadius = 4;
    NSTextField *label = [NSTextField labelWithAttributedString:[[NSAttributedString alloc] initWithString:L(@"PRODUCTION") attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSKernAttributeName: @0.6,
    }]];
    TBPin(label, badge.contentView, NSEdgeInsetsMake(2, 7, 2, 7));
    [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *note = TBLabel(L(@"read-only, writes need confirmation"), 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *view = [NSStackView stackViewWithViews:@[badge, note]];
    view.spacing = 7;
    view.toolTip = L(@"Writes need confirmation");
    return view;
}

- (NSView *)buildDataTab {
    _tableLabel = TBLabel(@"", 13, NSFontWeightSemibold, NSColor.labelColor);
    _tableLabel.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _readOnlyBadge = TBBadge(L(@"read-only"), NSColor.secondaryLabelColor, Theme.fill);
    _readOnlyBadge.hidden = YES;
    _rowButtons = [NSSegmentedControl segmentedControlWithImages:@[[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:L(@"New row")],
                                                                   [NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:L(@"Delete row")]]
                                                    trackingMode:NSSegmentSwitchTrackingMomentary
                                                          target:self
                                                          action:@selector(rowButtonClicked:)];
    [_rowButtons setToolTip:L(@"New row") forSegment:0];
    [_rowButtons setToolTip:L(@"Delete or restore the selected rows (⌫)") forSegment:1];
    _prevButton = TBSymbolButton(@"chevron.left", L(@"Previous page"), self, @selector(previousPage:));
    _nextButton = TBSymbolButton(@"chevron.right", L(@"Next page"), self, @selector(nextPage:));
    _prevButton.bordered = _nextButton.bordered = NO;
    _pageLabel = TBLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _pageLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _pageLabel.alignment = NSTextAlignmentCenter;
    [_pageLabel.widthAnchor constraintGreaterThanOrEqualToConstant:92].active = YES;
    NSButton *refresh = TBSymbolButton(@"arrow.clockwise", L(@"Refresh (⌘R)"), self, @selector(refresh:));
    NSStackView *bar = TBBar(@[_tableLabel, _readOnlyBadge], @[_rowButtons, _prevButton, _pageLabel, _nextButton, refresh], 38);

    NSImageView *lock = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"lock.fill" accessibilityDescription:nil]];
    lock.contentTintColor = NSColor.tertiaryLabelColor;
    lock.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightRegular];
    _readOnlyText = TBLabel(@"", 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *stripRow = TBBar(@[lock, _readOnlyText], @[], 28);
    NSBox *strip = TBPanel(Theme.head);
    TBPin(TBColumn(@[stripRow, TBSeparator()], stripRow), strip.contentView, NSEdgeInsetsMake(0, 0, 0, 0));
    strip.hidden = YES;
    _readOnlyStrip = strip;

    _dataGrid = [GridView new];
    __weak MainWindowController *weakSelf = self;
    _dataGrid.onSort = ^(NSString *column, BOOL ascending) { [weakSelf sortBy:column ascending:ascending]; };
    _dataGrid.onChange = ^{ [weakSelf updateChanges]; };

    _dataSpinner = TBSpinner(NSControlSizeRegular);
    _loadingLabel = TBLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _errorTitle = TBLabel(@"", 14, NSFontWeightSemibold, NSColor.labelColor);
    _errorMessage = TBWrappingLabel(@"", 12, Theme.red);
    _errorMessage.font = [Theme mono:12];
    _errorMessage.alignment = NSTextAlignmentCenter;
    _dataState = [[TBSwitcher alloc] initWithViews:@[
        _dataGrid,
        TBCenteredState(@[_dataSpinner, _loadingLabel]),
        TBCenteredState(@[_errorTitle, _errorMessage, TBButton(L(@"Try again"), self, @selector(refresh:))]),
    ]];
    // ⌘F: search the whole table, all columns
    _searchField = [NSSearchField new];
    _searchField.placeholderString = L(@"Search all columns, Enter to search");
    _searchField.sendsWholeSearchString = YES; // one query per Enter, not per keystroke: it scans the whole table
    _searchField.target = self;
    _searchField.action = @selector(search:);
    _searchField.delegate = self;
    [_searchField.widthAnchor constraintGreaterThanOrEqualToConstant:320].active = YES;
    _searchStatus = TBLabel(@"", 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *searchRow = TBBar(@[_searchField, _searchStatus], @[TBButton(L(@"Done"), self, @selector(closeFind:))], 38);
    NSBox *searchBar = TBPanel(Theme.head);
    TBPin(TBColumn(@[searchRow, TBSeparator()], searchRow), searchBar.contentView, NSEdgeInsetsMake(0, 0, 0, 0));
    searchBar.hidden = YES;
    _searchBar = searchBar;

    return TBColumn(@[bar, TBSeparator(), searchBar, strip, _dataState], _dataState);
}

#pragma mark - Find

// ⌘F: the SQL editor gets the system find bar, the Data tab searches the whole table.
- (void)showFind:(id)sender {
    if (self.currentTab == TabSQL) {
        _sqlText.usesFindBar = YES;
        _sqlText.incrementalSearchingEnabled = YES;
        NSMenuItem *show = [NSMenuItem new];
        show.tag = NSTextFinderActionShowFindInterface;
        [self.window makeFirstResponder:_sqlText];
        return [_sqlText performTextFinderAction:show];
    }
    if (!_table) return;
    if (self.currentTab != TabData) [self showTab:TabData];
    _searchBar.hidden = NO;
    [self.window makeFirstResponder:_searchField];
}

- (void)search:(NSSearchField *)sender {
    NSString *term = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *active = term.length ? term : nil;
    if ((active == _searchTerm || [active isEqual:_searchTerm]) || ![self confirmDiscard]) return;
    _searchTerm = active;
    _offset = 0;
    [self loadDataShowingSpinner:YES];
}

- (void)closeFind:(id)sender {
    _searchBar.hidden = YES;
    _searchField.stringValue = @"";
    if (_searchTerm) [self search:_searchField];
    [self.window makeFirstResponder:_dataGrid.table];
}

// Esc in the search field closes the bar.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (control != _searchField || selector != @selector(cancelOperation:)) return NO;
    [self closeFind:nil];
    return YES;
}

- (NSView *)boxed:(NSView *)view {
    NSBox *box = TBPanel(NSColor.clearColor);
    box.cornerRadius = 8;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    TBPin(view, box.contentView, NSEdgeInsetsMake(1, 1, 1, 1));
    return box;
}

- (NSView *)buildStructureTab {
    _structureTitle = TBLabel(@"", 13, NSFontWeightSemibold, NSColor.labelColor);
    _structureTitle.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _structureMeta = TBLabel(@"", 12, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    NSStackView *header = TBBar(@[_structureTitle, _structureMeta], @[], 38);
    header.spacing = 10;

    _columnsGrid = [GridView new];
    _columnsGrid.showsRowNumbers = NO;
    _columnsGrid.nullText = L(@"none");
    _columnsGrid.columnColors = @{@1: Theme.sqlFunction, @4: NSColor.controlAccentColor};
    _indexesGrid = [GridView new];
    _indexesGrid.showsRowNumbers = NO;
    _indexesGrid.columnColors = @{@1: NSColor.secondaryLabelColor};
    NSView *columnsBox = [self boxed:_columnsGrid], *indexesBox = [self boxed:_indexesGrid];
    _indexesHeight = [indexesBox.heightAnchor constraintEqualToConstant:80];
    _indexesHeight.active = YES;

    NSTextField *columnsLabel = TBLabel(L(@"Columns"), 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    NSTextField *indexesLabel = TBLabel(L(@"Indexes"), 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    NSStackView *body = TBColumnInset(@[columnsLabel, columnsBox, indexesLabel, indexesBox], columnsBox, NSEdgeInsetsMake(18, 20, 24, 20));
    body.spacing = 8;
    [body setCustomSpacing:24 afterView:columnsBox];
    return TBColumn(@[header, TBSeparator(), body], body);
}

- (NSView *)buildSQLTab {
    NSButton *run = AccentButton([NSString stringWithFormat:@"%@  ⌘R", L(@"Run")], self, @selector(runQuery:));
    NSStackView *header = TBBar(@[TBLabel(L(@"Query"), 12, NSFontWeightRegular, NSColor.secondaryLabelColor)], @[run], 36);
    NSTextView *sqlText;
    NSScrollView *editor = SQLTextScrollView(&sqlText, YES, YES);
    _sqlText = sqlText;
    [editor.heightAnchor constraintEqualToConstant:214].active = YES;

    _sqlSpinner = TBSpinner(NSControlSizeRegular);
    _sqlDoneLabel = TBLabel(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _sqlDoneLabel.font = [Theme mono:12];
    _sqlErrorText = TBWrappingLabel(@"", 12, NSColor.labelColor);
    _sqlErrorText.font = [Theme mono:12];
    NSBox *errorBox = TBPanel(Theme.errorFill);
    errorBox.cornerRadius = 8;
    errorBox.borderWidth = 1;
    errorBox.borderColor = Theme.errorBorder;
    NSStackView *errorContent = TBColumnInset(@[TBLabel(L(@"Query error"), 12, NSFontWeightSemibold, Theme.red), _sqlErrorText], nil,
                                              NSEdgeInsetsMake(12, 14, 12, 14));
    errorContent.spacing = 8;
    TBPin(errorContent, errorBox.contentView, NSEdgeInsetsMake(0, 0, 0, 0));
    NSView *errorState = [NSView new];
    errorBox.translatesAutoresizingMaskIntoConstraints = NO;
    [errorState addSubview:errorBox];
    [NSLayoutConstraint activateConstraints:@[
        [errorBox.topAnchor constraintEqualToAnchor:errorState.topAnchor constant:16],
        [errorBox.leadingAnchor constraintEqualToAnchor:errorState.leadingAnchor constant:16],
        [errorBox.trailingAnchor constraintEqualToAnchor:errorState.trailingAnchor constant:-16],
        [errorBox.bottomAnchor constraintLessThanOrEqualToAnchor:errorState.bottomAnchor constant:-16],
    ]];

    _sqlGrid = [GridView new];
    _sqlState = [[TBSwitcher alloc] initWithViews:@[
        TBCenteredState(@[TBLabel(L(@"Results will appear here. Run a query: ⌘R"), 12, NSFontWeightRegular, NSColor.tertiaryLabelColor)]),
        TBCenteredState(@[_sqlSpinner, TBLabel(L(@"Running…"), 12, NSFontWeightRegular, NSColor.secondaryLabelColor)]),
        TBCenteredState(@[_sqlDoneLabel]),
        errorState,
        _sqlGrid,
    ]];
    return TBColumn(@[header, TBSeparator(), editor, TBSeparator(), _sqlState], _sqlState);
}

#pragma mark - Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    NSArray *items = @[NSToolbarSidebarTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, TabsItem, NSToolbarFlexibleSpaceItemIdentifier];
    return _production ? [items arrayByAddingObject:ProductionItem] : items;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    if ([identifier isEqual:TabsItem]) {
        item.view = _tabSwitch;
        item.label = L(@"View");
    } else if ([identifier isEqual:ProductionItem]) {
        item.view = [self productionBadge];
        item.label = L(@"PRODUCTION");
        item.bordered = NO;
    } else {
        return nil;
    }
    return item;
}

#pragma mark - Tabs and status

- (Tab)currentTab {
    return _tabSwitch.selectedSegment;
}

- (void)tabChanged:(id)sender {
    [self showTab:_tabSwitch.selectedSegment];
}

- (void)showTab:(Tab)tab {
    _tabSwitch.selectedSegment = tab;
    _tabs.selectedIndex = (tab != TabSQL && !_table) ? TabEmpty : tab;
    [self updateChanges];
    [self updateStatus];
}

- (void)updateStatus {
    NSString *text = !_table ? _tablesStatus : _dataStatus;
    if (self.currentTab == TabStructure && _table) text = _structureStatus;
    if (self.currentTab == TabSQL) text = _sqlStatus;
    _statusLabel.stringValue = text ?: @"";
}

- (void)setTunnelConnected:(BOOL)connected {
    _tunnelConnected = connected;
    BOOL reconnecting = _tunnel && !connected;
    reconnecting ? [_tunnelSpinner startAnimation:nil] : [_tunnelSpinner stopAnimation:nil];
    _tunnelDot.hidden = reconnecting;
    ((NSBox *)_tunnelDot).fillColor = _tunnel ? Theme.green : NSColor.tertiaryLabelColor;
    _tunnelLabel.stringValue = !_tunnel ? L(@"Direct connection") : connected ? L(@"SSH tunnel: connected") : L(@"SSH tunnel: dropped, reconnecting…");
    _tunnelLabel.textColor = reconnecting ? Theme.orange : NSColor.secondaryLabelColor;
}

- (NSString *)displayName {
    return [_schema isEqual:@"public"] ? _table : [NSString stringWithFormat:@"%@.%@", _schema, _table];
}

#pragma mark - Running queries

// Work runs on the connection's queue; `done` gets the result and the time it took on the main thread.
// Without `failed`, errors are shown as a sheet.
- (void)run:(Work)work done:(void (^)(DBResult *result, double ms))done failed:(nullable void (^)(NSError *error, double ms))failed {
    id<DBConnection> conn = _conn;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    dispatch_async(conn.queue, ^{
        NSError *error = nil;
        DBResult *result = work(&error);
        double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) done(result, ms);
            else if (failed) failed(error, ms);
            else [self showError:error];
        });
    });
}

- (void)showError:(NSError *)error {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = L(@"Error");
    alert.informativeText = error.localizedDescription ?: L(@"Unknown error");
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Tables and data

- (void)loadTables {
    id<DBConnection> conn = _conn;
    [self run:^DBResult *(NSError **e) { return [conn tables:e]; } done:^(DBResult *r, double ms) {
        self->_tables = r.rows;
        NSUInteger views = [r.rows filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF[2] == 'view'"]].count;
        self->_tablesStatus = [NSString stringWithFormat:@"%@ · %@", LN(@"%lu tables", r.rows.count - views), LN(@"%lu views", views)];
        [self filterChanged:nil];
        [self updateStatus];
    } failed:nil];
}

- (void)filterChanged:(id)sender {
    NSString *f = _filter.stringValue;
    NSMutableArray *pinned = [NSMutableArray new], *tables = [NSMutableArray new], *views = [NSMutableArray new];
    for (NSArray *t in _tables) {
        if (f.length && ![t[1] localizedCaseInsensitiveContainsString:f]) continue;
        if ([_pinned containsObject:[self pinName:t]]) [pinned addObject:t];
        else [[t[2] isEqual:@"view"] ? views : tables addObject:t];
    }
    [pinned sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { // pin order
        return [@([self->_pinned indexOfObject:[self pinName:a]]) compare:@([self->_pinned indexOfObject:[self pinName:b]])];
    }];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *section in @[@[L(@"Pinned"), pinned], @[L(@"Tables"), tables], @[L(@"Views"), views]]) {
        if (![section[1] count]) continue;
        [rows addObject:section[0]];
        [rows addObjectsFromArray:section[1]];
    }
    _sideRows = rows;
    [_sidebar reloadData];
    [self reselectCurrentTable];
}

#pragma mark - Pinned tables

// Pins are kept per connection and database.
- (NSString *)pinsKey {
    return [NSString stringWithFormat:@"%@/%@", _info[@"id"] ?: @"", _info[@"database"] ?: @""];
}

- (NSString *)pinName:(NSArray *)table {
    return [NSString stringWithFormat:@"%@.%@", table[0], table[1]];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = _sidebar.clickedRow;
    if (row < 0 || ![_sideRows[row] isKindOfClass:NSArray.class]) return;
    BOOL pinned = [_pinned containsObject:[self pinName:_sideRows[row]]];
    NSMenuItem *item = [menu addItemWithTitle:pinned ? L(@"Unpin") : L(@"Pin") action:@selector(togglePin:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = _sideRows[row];
}

- (void)togglePin:(NSMenuItem *)sender {
    NSString *name = [self pinName:sender.representedObject];
    if ([_pinned containsObject:name]) [_pinned removeObject:name];
    else [_pinned addObject:name];
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:PinsKey] mutableCopy] ?: [NSMutableDictionary new];
    all[[self pinsKey]] = _pinned.count ? [_pinned copy] : nil;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:PinsKey];
    [self filterChanged:nil];
}

// After the list is rebuilt, keep the open table selected (without reloading it).
- (void)reselectCurrentTable {
    if (!_table) return;
    NSUInteger row = [_sideRows indexOfObjectPassingTest:^BOOL(id item, NSUInteger i, BOOL *stop) {
        return [item isKindOfClass:NSArray.class] && [item[0] isEqual:self->_schema] && [item[1] isEqual:self->_table];
    }];
    if (row != NSNotFound) [_sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)loadDataShowingSpinner:(BOOL)spinner {
    if (!_table) return;
    NSMutableString *sql = [NSMutableString stringWithFormat:@"SELECT * FROM %@.%@", DBQuoteIdent(_schema), DBQuoteIdent(_table)];
    NSString *term = _columnNames.count ? _searchTerm : nil;
    if (term) [sql appendFormat:@" WHERE %@", [_conn searchConditionForColumns:_columnNames]];
    if (_sortColumn) [sql appendFormat:@" ORDER BY %@ %@", DBQuoteIdent(_sortColumn), _sortAscending ? @"ASC" : @"DESC"];
    [sql appendFormat:@" LIMIT %ld OFFSET %ld", (long)PageSize, (long)_offset];
    NSArray *params = term ? @[DBLikePattern(term)] : nil;
    if (spinner) {
        _loadingLabel.stringValue = [NSString stringWithFormat:L(@"Loading %@…"), [self displayName]];
        [_dataSpinner startAnimation:nil];
        _dataState.selectedIndex = DataLoading;
        _dataStatus = L(@"Loading…");
        [self updateStatus];
    }

    id<DBConnection> conn = _conn;
    NSInteger offset = _offset;
    [self run:^DBResult *(NSError **e) {
        if (!term) return [conn execute:sql params:nil error:e];
        // ponytail: a search scans every column of the whole table; capped so a big production table can't hang the window
        [conn execute:@"SET statement_timeout = 15000" params:nil error:NULL];
        DBResult *r = [conn execute:sql params:params error:e];
        [conn execute:@"RESET statement_timeout" params:nil error:NULL];
        return r;
    } done:^(DBResult *r, double ms) {
        [self->_dataSpinner stopAnimation:nil];
        self->_dataGrid.rowNumberOffset = offset;
        self->_dataGrid.result = r;
        self->_dataGrid.highlight = term;
        self->_searchStatus.stringValue = !term ? @""
            : r.rows.count == PageSize ? [NSString stringWithFormat:L(@"%ld+ matching rows, see the next pages"), (long)PageSize]
                                       : LN(@"%lu matching rows", offset + r.rows.count);
        [self resetInspectorForGrid:self->_dataGrid];
        self->_dataState.selectedIndex = DataGrid;
        [self applyEditability];
        [self updateChanges];
        self->_pageLabel.stringValue = r.rows.count ? [NSString stringWithFormat:@"%ld–%ld", (long)offset + 1, (long)(offset + r.rows.count)]
                                                    : L(@"no rows");
        self->_prevButton.enabled = offset > 0;
        self->_nextButton.enabled = r.rows.count == PageSize;
        self->_dataStatus = [NSString stringWithFormat:@"%@ · %.0f ms", LN(@"%lu rows", r.rows.count), ms];
        [self updateStatus];
    } failed:^(NSError *error, double ms) {
        [self->_dataSpinner stopAnimation:nil];
        BOOL timedOut = term && [error.userInfo[@"sqlstate"] isEqual:@"57014"];
        self->_errorTitle.stringValue = timedOut ? L(@"The search took too long")
                                                 : [NSString stringWithFormat:L(@"Couldn't load %@"), [self displayName]];
        self->_errorMessage.stringValue = timedOut ? L(@"It was stopped after 15 s. Try a more specific term.") : error.localizedDescription ?: @"";
        self->_dataState.selectedIndex = DataFailed;
        self->_dataStatus = L(@"Loading failed");
        [self updateStatus];
    }];
}

- (void)loadStructure {
    id<DBConnection> conn = _conn;
    NSString *schema = _schema, *table = _table;
    _structureTitle.stringValue = [self displayName];
    // Columns arrive before the data (same serial queue), so applyEditability already knows the primary key.
    [self run:^DBResult *(NSError **e) { return [conn columnsInSchema:schema table:table error:e]; } done:^(DBResult *r, double ms) {
        NSMutableArray *pk = [NSMutableArray new], *rows = [NSMutableArray new], *names = [NSMutableArray new];
        NSMutableSet *defaults = [NSMutableSet new];
        for (NSArray *col in r.rows) { // [column, type, null, default, pk]
            [names addObject:col[0]];
            if ([col[4] isEqual:@"PK"]) [pk addObject:col[0]];
            if (col[3] != NSNull.null) [defaults addObject:col[0]];
            [rows addObject:@[col[0], col[1], [col[2] length] ? @"✓" : @"", col[3], col[4]]];
        }
        self->_pkColumns = pk;
        self->_defaultColumns = defaults;
        self->_columnNames = names;
        DBResult *shown = [DBResult new];
        shown.columns = @[L(@"Name"), L(@"Type"), @"NOT NULL", L(@"Default"), @"PK"];
        shown.rows = rows;
        self->_columnsGrid.result = shown;
        self->_structureMeta.stringValue = LN(@"%lu columns", rows.count);
    } failed:nil];
    [self run:^DBResult *(NSError **e) { return [conn indexesInSchema:schema table:table error:e]; } done:^(DBResult *r, double ms) {
        DBResult *shown = [DBResult new];
        shown.columns = @[L(@"Name"), L(@"Definition")];
        shown.rows = r.rows;
        self->_indexesGrid.result = shown;
        self->_indexesHeight.constant = MIN(MAX(r.rows.count, 1), 6) * 24 + 30;
        self->_structureMeta.stringValue = [NSString stringWithFormat:@"%@ · %@", self->_structureMeta.stringValue, LN(@"%lu indexes", r.rows.count)];
        self->_structureStatus = self->_structureMeta.stringValue;
        [self updateStatus];
    } failed:nil];
}

- (void)sortBy:(NSString *)column ascending:(BOOL)ascending {
    if (![self confirmDiscard]) return;
    _sortColumn = column;
    _sortAscending = ascending;
    _offset = 0;
    [self loadDataShowingSpinner:NO];
}

- (void)previousPage:(id)sender {
    if (![self confirmDiscard]) return;
    _offset = MAX(0, _offset - PageSize);
    [self loadDataShowingSpinner:NO];
}

- (void)nextPage:(id)sender {
    if (![self confirmDiscard]) return;
    _offset += PageSize;
    [self loadDataShowingSpinner:NO];
}

- (void)refresh:(id)sender {
    if (!_table) return [self loadTables];
    if ([self confirmDiscard]) [self loadDataShowingSpinner:NO];
}

#pragma mark - Editing

// Only tables with a primary key are editable: only then does UPDATE/DELETE hit exactly one row.
- (void)applyEditability {
    BOOL editable = !_isView && _pkColumns.count > 0;
    _dataGrid.editable = editable;
    _rowButtons.enabled = editable;
    _readOnlyBadge.hidden = _readOnlyStrip.hidden = editable;
    _readOnlyText.stringValue = _isView ? L(@"View: data is read-only.")
                                        : [NSString stringWithFormat:L(@"Read-only: table %@ has no primary key, so a row can't be identified unambiguously."),
                                                                     [self displayName]];
    NSMutableIndexSet *defaults = [NSMutableIndexSet new];
    [_dataGrid.result.columns enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        if ([self->_defaultColumns containsObject:name]) [defaults addIndex:i];
    }];
    _dataGrid.defaultColumns = defaults;
}

- (void)updateChanges {
    NSUInteger n = _dataGrid.changeCount;
    _pendingBar.hidden = n == 0 || self.currentTab != TabData;
    _pendingLabel.stringValue = LN(@"%lu changes", n);
    NSMutableArray *parts = [NSMutableArray new];
    if (_dataGrid.editedCellCount) [parts addObject:LN(@"%lu edits", _dataGrid.editedCellCount)];
    if (_dataGrid.insertedRows.count) [parts addObject:LN(@"%lu new rows", _dataGrid.insertedRows.count)];
    if (_dataGrid.deletedRows.count) [parts addObject:LN(@"%lu deleted", _dataGrid.deletedRows.count)];
    _pendingDetail.stringValue = [parts componentsJoinedByString:@", "];
}

- (void)rowButtonClicked:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) [_dataGrid addRow];
    else [_dataGrid deleteSelectedRows];
}

- (void)discardChanges:(id)sender {
    [_dataGrid discardChanges];
}

// Asks whether to discard unsaved changes. YES = OK to continue.
- (BOOL)confirmDiscard {
    NSUInteger n = _dataGrid.changeCount;
    if (!n) return YES;
    NSAlert *alert = [NSAlert new];
    alert.messageText = L(@"You have unsaved changes");
    alert.informativeText = [NSString stringWithFormat:L(@"%@. Discard them?"), LN(@"%lu changes", n)];
    [alert addButtonWithTitle:L(@"Cancel")];
    [alert addButtonWithTitle:L(@"Discard Changes")].hasDestructiveAction = YES;
    if ([alert runModal] != NSAlertSecondButtonReturn) return NO;
    [_dataGrid discardChanges];
    return YES;
}

- (void)saveChanges:(id)sender {
    if (!_dataGrid.changeCount) return;
    [self.window makeFirstResponder:_dataGrid.table]; // ends cell editing, if any
    dispatch_async(dispatch_get_main_queue(), ^{ // the edit is stored asynchronously
        NSArray *statements = DBChangeStatements(self->_schema, self->_table, self->_dataGrid.result, self->_pkColumns,
                                                 self->_dataGrid.edits, self->_dataGrid.deletedRows, self->_dataGrid.insertedRows);
        if (!statements.count) return;
        if (!self->_production) return [self executeChanges:statements];
        NSMutableArray *preview = [NSMutableArray arrayWithObject:@"BEGIN;"];
        for (NSArray *s in statements) [preview addObject:[DBInlineParams(s[0], s[1]) stringByAppendingString:@";"]];
        [preview addObject:@"COMMIT;"];
        [self confirmProduction:[preview componentsJoinedByString:@"\n"] statements:statements.count then:^{ [self executeChanges:statements]; }];
    });
}

// Everything in one transaction. Each UPDATE/DELETE must hit exactly 1 row, otherwise ROLLBACK.
- (void)executeChanges:(NSArray<NSArray *> *)statements {
    id<DBConnection> conn = _conn;
    [self run:^DBResult *(NSError **e) {
        if (![conn execute:@"BEGIN READ WRITE" params:nil error:e]) return nil;
        NSInteger total = 0;
        for (NSArray *s in statements) {
            DBResult *r = [conn execute:s[0] params:s[1] error:e];
            if (r && [s[2] boolValue] && r.affected != 1) {
                if (e) *e = DBError([NSString stringWithFormat:@"%@\n\n%@", L(@"A row changed or disappeared in the meantime, nothing was saved. Refresh the data and try again."),
                                                              DBInlineParams(s[0], s[1])], nil);
                r = nil;
            }
            if (!r) {
                [conn execute:@"ROLLBACK" params:nil error:NULL];
                return nil;
            }
            total += r.affected;
        }
        DBResult *commit = [conn execute:@"COMMIT" params:nil error:e];
        commit.affected = total;
        return commit;
    } done:^(DBResult *r, double ms) {
        [self->_dataGrid discardChanges];
        [self loadDataShowingSpinner:NO];
    } failed:nil];
}

- (void)confirmProduction:(NSString *)sql statements:(NSUInteger)count then:(void (^)(void))action {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = L(@"This changes data on production");
    NSString *check = L(@"Check the SQL before running it; this can't be undone.");
    alert.informativeText = count ? [NSString stringWithFormat:L(@"%@ · %@ in one transaction. %@"), _info[@"name"], LN(@"%lu statements", count), check]
                                  : [NSString stringWithFormat:@"%@ · %@", _info[@"name"], check];
    NSTextView *preview;
    NSScrollView *scroll = SQLTextScrollView(&preview, NO, NO);
    preview.string = sql;
    SQLHighlight(preview.textStorage);
    NSUInteger lines = [sql componentsSeparatedByString:@"\n"].count;
    scroll.frame = NSMakeRect(0, 0, 500, MIN(220, lines * 18 + 24));
    scroll.borderType = NSLineBorder;
    alert.accessoryView = scroll;
    NSButton *execute = [alert addButtonWithTitle:L(@"Execute")];
    NSButton *cancel = [alert addButtonWithTitle:L(@"Cancel")];
    execute.hasDestructiveAction = YES;
    execute.keyEquivalent = @""; // Enter must cancel, not execute
    cancel.keyEquivalent = @"\r";
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) action();
    }];
}

#pragma mark - SQL

// ⌘R: runs the query in the SQL tab, refreshes elsewhere.
- (void)runQuery:(id)sender {
    if (self.currentTab != TabSQL) return [self refresh:sender];
    NSRange sel = _sqlText.selectedRange;
    NSString *sql = sel.length ? [_sqlText.string substringWithRange:sel] : _sqlText.string;
    sql = [sql stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (sql.length) [self runSQL:sql confirmed:NO];
}

// On production the session is READ ONLY, so a write fails with 25006.
// Then we ask, and after confirmation run the same SQL inside BEGIN READ WRITE … COMMIT.
- (void)runSQL:(NSString *)sql confirmed:(BOOL)confirmed {
    [_sqlSpinner startAnimation:nil];
    _sqlState.selectedIndex = SQLRunning;
    _sqlStatus = L(@"Running…");
    [self updateStatus];

    id<DBConnection> conn = _conn;
    [self run:^DBResult *(NSError **e) {
        if (!confirmed) return [conn execute:sql params:nil error:e];
        if (![conn execute:@"BEGIN READ WRITE" params:nil error:e]) return nil;
        DBResult *r = [conn execute:sql params:nil error:e];
        if (r && [conn execute:@"COMMIT" params:nil error:e]) return r;
        [conn execute:@"ROLLBACK" params:nil error:NULL];
        return nil;
    } done:^(DBResult *r, double ms) {
        [self->_sqlSpinner stopAnimation:nil];
        if (r.columns.count) {
            self->_sqlGrid.result = r;
            [self resetInspectorForGrid:self->_sqlGrid];
            self->_sqlState.selectedIndex = SQLResult;
            self->_sqlStatus = [NSString stringWithFormat:@"%@ · %.0f ms", LN(@"%lu rows", r.rows.count), ms];
        } else {
            self->_sqlDoneLabel.stringValue = [NSString stringWithFormat:@"%@ · %@", L(@"Query executed"), LN(@"%lu rows", MAX(r.affected, 0))];
            self->_sqlState.selectedIndex = SQLDone;
            self->_sqlStatus = [NSString stringWithFormat:@"%.0f ms", ms];
        }
        [self updateStatus];
    } failed:^(NSError *error, double ms) {
        [self->_sqlSpinner stopAnimation:nil];
        if (self->_production && !confirmed && [error.userInfo[@"sqlstate"] isEqual:@"25006"]) {
            self->_sqlState.selectedIndex = SQLIdle;
            self->_sqlStatus = @"";
            [self updateStatus];
            return [self confirmProduction:sql statements:0 then:^{ [self runSQL:sql confirmed:YES]; }];
        }
        self->_sqlErrorText.stringValue = error.localizedDescription ?: L(@"Unknown error");
        self->_sqlState.selectedIndex = SQLFailed;
        self->_sqlStatus = [NSString stringWithFormat:@"%@ · %.0f ms", L(@"Query error"), ms];
        [self updateStatus];
    }];
}

#pragma mark - Table list

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _sideRows.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return [_sideRows[row] isKindOfClass:NSString.class];
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return ![self tableView:tableView isGroupRow:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    id item = _sideRows[row];
    if ([item isKindOfClass:NSString.class]) {
        TBCellView *cell = TBCell(tableView, @"section", NO);
        cell.textField.stringValue = item;
        cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        cell.textField.textColor = NSColor.tertiaryLabelColor;
        return cell;
    }
    NSArray *t = item;
    BOOL isView = [t[2] isEqual:@"view"];
    TBCellView *cell = TBCell(tableView, @"table", YES);
    NSMutableAttributedString *name = [NSMutableAttributedString new];
    if (![t[0] isEqual:@"public"] && ![t[0] isEqual:@"main"])
        [name appendAttributedString:[[NSAttributedString alloc] initWithString:[t[0] stringByAppendingString:@"."]
                                                                     attributes:@{NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}]];
    [name appendAttributedString:[[NSAttributedString alloc] initWithString:t[1] attributes:@{NSForegroundColorAttributeName: NSColor.labelColor}]];
    [name addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:13] range:NSMakeRange(0, name.length)];
    cell.textField.attributedStringValue = name;
    cell.imageView.image = [NSImage imageWithSystemSymbolName:isView ? @"rectangle.dashed" : @"tablecells" accessibilityDescription:nil];
    cell.imageView.contentTintColor = isView ? NSColor.secondaryLabelColor : NSColor.controlAccentColor;
    return cell;
}

- (BOOL)selectionShouldChangeInTableView:(NSTableView *)tableView {
    return [self confirmDiscard];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _sidebar.selectedRow;
    if (row < 0 || ![_sideRows[row] isKindOfClass:NSArray.class]) return;
    NSArray *t = _sideRows[row];
    if ([t[0] isEqual:_schema] && [t[1] isEqual:_table]) return; // same table, e.g. re-selected after pinning
    _schema = t[0];
    _table = t[1];
    _isView = [t[2] isEqual:@"view"];
    _pkColumns = _columnNames = nil; // read-only until the structure is loaded
    _searchTerm = nil;                 // a search belongs to one table
    _searchField.stringValue = @"";
    _searchBar.hidden = YES;
    _offset = 0;
    _sortColumn = nil;
    [_dataGrid resetSort];
    _tableLabel.stringValue = [self displayName];
    [self showTab:self.currentTab == TabSQL ? TabData : self.currentTab];
    [self loadStructure];
    [self loadDataShowingSpinner:YES];
}

#pragma mark - Window

- (BOOL)windowShouldClose:(NSWindow *)sender {
    return [self confirmDiscard];
}

- (void)windowWillClose:(NSNotification *)notification {
    [_tunnel stop];
    id<DBConnection> conn = _conn;
    dispatch_async(conn.queue, ^{ [conn close]; });
    if (self.onClose) self.onClose(self);
}

@end

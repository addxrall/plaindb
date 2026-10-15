#import "MainWindowController.h"
#import "GridView.h"
#import "SSHTunnel.h"

static const NSInteger PageSize = 200;

typedef DBResult *_Nullable (^Work)(NSError **error);

static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

static NSButton *SymbolButton(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] target:target action:action];
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.toolTip = tip;
    return b;
}

static NSStackView *Bar(NSArray<NSView *> *leading, NSArray<NSView *> *trailing) {
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(6, 10, 6, 10);
    [s setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    for (NSView *v in leading) [s addView:v inGravity:NSStackViewGravityLeading];
    for (NSView *v in trailing) [s addView:v inGravity:NSStackViewGravityTrailing];
    return s;
}

// Pionowy stos na pełną szerokość. `grow` dostaje całą wolną wysokość.
static NSStackView *Column(NSArray<NSView *> *views, NSView *grow) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.distribution = NSStackViewDistributionFill;
    s.spacing = 0;
    for (NSView *v in views) [v.widthAnchor constraintEqualToAnchor:s.widthAnchor].active = YES;
    [grow setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    return s;
}

static NSTextView *CodeTextView(NSScrollView *scroll, BOOL editable) {
    NSTextView *t = scroll.documentView;
    t.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
    t.richText = NO;
    t.editable = editable;
    t.textContainerInset = NSMakeSize(6, 8);
    t.automaticQuoteSubstitutionEnabled = NO;
    t.automaticDashSubstitutionEnabled = NO;
    t.automaticTextReplacementEnabled = NO;
    t.automaticSpellingCorrectionEnabled = NO;
    t.continuousSpellCheckingEnabled = NO;
    return t;
}

@implementation MainWindowController {
    id<DBConnection> _conn;
    SSHTunnel *_tunnel;
    BOOL _production;
    double _lastMs;

    NSArray<NSArray *> *_tables, *_visible;
    NSString *_schema, *_table, *_sortColumn;
    BOOL _sortAscending;
    NSInteger _offset;

    NSSearchField *_filter;
    NSTableView *_sidebar;
    NSTabView *_tabs;
    NSTabViewItem *_dataItem, *_sqlItem;
    NSTextField *_tableLabel, *_pageLabel, *_statusLabel, *_tunnelLabel;
    NSButton *_prevButton, *_nextButton;
    GridView *_dataGrid, *_columnsGrid, *_sqlGrid;
    NSTextView *_indexesText, *_sqlText;
}

- (instancetype)initWithConnection:(id<DBConnection>)connection tunnel:(SSHTunnel *)tunnel info:(NSDictionary *)info {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 700)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    _conn = connection;
    _tunnel = tunnel;
    _production = [info[@"production"] boolValue];

    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.title = info[@"name"];
    window.contentMinSize = NSMakeSize(720, 420);
    NSString *target = [NSString stringWithFormat:@"%@@%@/%@", info[@"user"] ?: @"", [info[@"host"] length] ? info[@"host"] : @"localhost",
                                                  info[@"database"] ?: @""];
    window.subtitle = [info[@"sshHost"] length] ? [NSString stringWithFormat:@"%@ przez %@", target, info[@"sshHost"]] : target;

    [self buildUIWithName:info[@"name"]];
    [window center];

    __weak MainWindowController *weakSelf = self;
    _tunnel.onStatus = ^(NSString *status) { [weakSelf setTunnelStatus:status]; };
    [self loadTables];
    return self;
}

#pragma mark - UI

- (void)buildUIWithName:(NSString *)name {
    // lista tabel
    _filter = [NSSearchField new];
    _filter.placeholderString = @"Filtruj tabele";
    _filter.target = self;
    _filter.action = @selector(filterChanged:);
    _sidebar = [NSTableView new];
    _sidebar.style = NSTableViewStyleSourceList;
    _sidebar.headerView = nil;
    _sidebar.rowHeight = 24;
    _sidebar.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    [_sidebar addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"name"]];
    _sidebar.dataSource = self;
    _sidebar.delegate = self;
    NSScrollView *sideScroll = [NSScrollView new];
    sideScroll.documentView = _sidebar;
    sideScroll.hasVerticalScroller = YES;
    sideScroll.drawsBackground = NO;

    NSView *side = [NSView new];
    for (NSView *v in @[_filter, sideScroll]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [side addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [_filter.topAnchor constraintEqualToAnchor:side.topAnchor constant:8],
        [_filter.leadingAnchor constraintEqualToAnchor:side.leadingAnchor constant:8],
        [_filter.trailingAnchor constraintEqualToAnchor:side.trailingAnchor constant:-8],
        [sideScroll.topAnchor constraintEqualToAnchor:_filter.bottomAnchor constant:6],
        [sideScroll.leadingAnchor constraintEqualToAnchor:side.leadingAnchor],
        [sideScroll.trailingAnchor constraintEqualToAnchor:side.trailingAnchor],
        [sideScroll.bottomAnchor constraintEqualToAnchor:side.bottomAnchor],
        [side.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    ]];

    // zakładka Dane
    _tableLabel = Label(@"Wybierz tabelę z listy", 13, NSFontWeightSemibold, NSColor.labelColor);
    _pageLabel = Label(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _pageLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _prevButton = SymbolButton(@"chevron.left", @"Poprzednia strona", self, @selector(previousPage:));
    _nextButton = SymbolButton(@"chevron.right", @"Następna strona", self, @selector(nextPage:));
    _prevButton.enabled = _nextButton.enabled = NO;
    NSButton *refresh = SymbolButton(@"arrow.clockwise", @"Odśwież (⌘R)", self, @selector(refresh:));
    _dataGrid = [GridView new];
    __weak MainWindowController *weakSelf = self;
    _dataGrid.onSort = ^(NSString *column, BOOL ascending) { [weakSelf sortBy:column ascending:ascending]; };
    _dataItem = [self addTab:@"Dane" view:Column(@[Bar(@[_tableLabel], @[_prevButton, _pageLabel, _nextButton, refresh]), _dataGrid], _dataGrid)];

    // zakładka Struktura
    _columnsGrid = [GridView new];
    NSScrollView *indexesScroll = [NSTextView scrollableTextView];
    _indexesText = CodeTextView(indexesScroll, NO);
    [indexesScroll.heightAnchor constraintEqualToConstant:120].active = YES;
    NSTextField *indexesLabel = Label(@"Indeksy", 12, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    [self addTab:@"Struktura" view:Column(@[_columnsGrid, Bar(@[indexesLabel], @[]), indexesScroll], _columnsGrid)];

    // zakładka SQL
    NSScrollView *editorScroll = [NSTextView scrollableTextView];
    _sqlText = CodeTextView(editorScroll, YES);
    [editorScroll.heightAnchor constraintEqualToConstant:160].active = YES;
    NSButton *run = [NSButton buttonWithTitle:@"Uruchom" target:self action:@selector(runQuery:)];
    NSTextField *hint = Label(@"⌘R · zaznaczony fragment uruchamia tylko jego", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _sqlGrid = [GridView new];
    _sqlItem = [self addTab:@"SQL" view:Column(@[Bar(@[run, hint], @[]), editorScroll, _sqlGrid], _sqlGrid)];

    // pasek statusu
    _statusLabel = Label(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _tunnelLabel = Label(_tunnel ? @"Tunel SSH: połączony" : @"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *status = Bar(@[_statusLabel], @[_tunnelLabel]);
    status.edgeInsets = NSEdgeInsetsMake(3, 10, 4, 10);

    NSSplitView *split = [NSSplitView new];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    [split addArrangedSubview:side];
    [split addArrangedSubview:_tabs];
    [split setHoldingPriority:NSLayoutPriorityDefaultLow + 10 forSubviewAtIndex:0];

    NSMutableArray *rows = [NSMutableArray new];
    if (_production) [rows addObject:[self productionBanner:name]];
    [rows addObjectsFromArray:@[split, status]];
    self.window.contentView = Column(rows, split);
    [self.window layoutIfNeeded];
    [split setPosition:230 ofDividerAtIndex:0];
}

- (NSTabViewItem *)addTab:(NSString *)label view:(NSView *)view {
    if (!_tabs) _tabs = [NSTabView new];
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:label];
    item.label = label;
    item.view = view;
    [_tabs addTabViewItem:item];
    return item;
}

- (NSView *)productionBanner:(NSString *)name {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0;
    box.cornerRadius = 0;
    box.fillColor = NSColor.systemRedColor;
    box.contentViewMargins = NSZeroSize;
    NSTextField *text = Label([NSString stringWithFormat:@"PRODUKCJA · %@ · tylko odczyt, zapis wymaga potwierdzenia", name],
                              11, NSFontWeightSemibold, NSColor.whiteColor);
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [box.heightAnchor constraintEqualToConstant:24],
        [text.centerXAnchor constraintEqualToAnchor:box.contentView.centerXAnchor],
        [text.centerYAnchor constraintEqualToAnchor:box.contentView.centerYAnchor],
    ]];
    return box;
}

#pragma mark - Wykonywanie zapytań

// Praca idzie na kolejkę połączenia; `done` dostaje wynik na głównym wątku.
// Bez `failed` błąd pokazuje się jako arkusz.
- (void)run:(Work)work done:(void (^)(DBResult *result))done failed:(nullable void (^)(NSError *error))failed {
    id<DBConnection> conn = _conn;
    _statusLabel.stringValue = @"Wykonuję…";
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    dispatch_async(conn.queue, ^{
        NSError *error = nil;
        DBResult *result = work(&error);
        double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lastMs = ms;
            if (result) {
                self->_statusLabel.stringValue = [self summary:result];
                done(result);
            } else {
                self->_statusLabel.stringValue = @"Błąd";
                failed ? failed(error) : [self showError:error];
            }
        });
    });
}

- (void)run:(Work)work done:(void (^)(DBResult *result))done {
    [self run:work done:done failed:nil];
}

- (NSString *)summary:(DBResult *)r {
    NSString *what = r.columns.count ? [NSString stringWithFormat:@"%lu wierszy", (unsigned long)r.rows.count]
                                     : [NSString stringWithFormat:@"zmienione wiersze: %ld", (long)MAX(r.affected, 0)];
    return [NSString stringWithFormat:@"%@ · %.0f ms", what, _lastMs];
}

- (void)showError:(NSError *)error {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Błąd";
    alert.informativeText = error.localizedDescription ?: @"Nieznany błąd";
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Tabele i dane

- (void)loadTables {
    id<DBConnection> conn = _conn;
    [self run:^DBResult *(NSError **e) { return [conn tables:e]; } done:^(DBResult *r) {
        self->_tables = r.rows;
        [self filterChanged:nil];
    }];
}

- (void)filterChanged:(id)sender {
    NSString *f = _filter.stringValue;
    _visible = !f.length ? _tables : [_tables filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *t, id b) {
        return [t[1] localizedCaseInsensitiveContainsString:f];
    }]];
    [_sidebar reloadData];
}

- (void)loadData {
    if (!_table) return;
    NSMutableString *sql = [NSMutableString stringWithFormat:@"SELECT * FROM %@.%@", DBQuoteIdent(_schema), DBQuoteIdent(_table)];
    if (_sortColumn) [sql appendFormat:@" ORDER BY %@ %@", DBQuoteIdent(_sortColumn), _sortAscending ? @"ASC" : @"DESC"];
    [sql appendFormat:@" LIMIT %ld OFFSET %ld", (long)PageSize, (long)_offset];

    id<DBConnection> conn = _conn;
    NSInteger offset = _offset;
    [self run:^DBResult *(NSError **e) { return [conn execute:sql params:nil error:e]; } done:^(DBResult *r) {
        self->_dataGrid.result = r;
        self->_pageLabel.stringValue = r.rows.count ? [NSString stringWithFormat:@"%ld–%ld", (long)offset + 1, (long)(offset + r.rows.count)]
                                                    : @"brak wierszy";
        self->_prevButton.enabled = offset > 0;
        self->_nextButton.enabled = r.rows.count == PageSize;
    }];
}

- (void)loadStructure {
    id<DBConnection> conn = _conn;
    NSString *schema = _schema, *table = _table;
    [self run:^DBResult *(NSError **e) { return [conn columnsInSchema:schema table:table error:e]; } done:^(DBResult *r) {
        self->_columnsGrid.result = r;
    }];
    [self run:^DBResult *(NSError **e) { return [conn indexesInSchema:schema table:table error:e]; } done:^(DBResult *r) {
        NSMutableArray *defs = [NSMutableArray new];
        for (NSArray *row in r.rows) [defs addObject:row[0]];
        self->_indexesText.string = defs.count ? [defs componentsJoinedByString:@"\n"] : @"Brak indeksów.";
    }];
}

- (void)sortBy:(NSString *)column ascending:(BOOL)ascending {
    _sortColumn = column;
    _sortAscending = ascending;
    _offset = 0;
    [self loadData];
}

- (void)previousPage:(id)sender {
    _offset = MAX(0, _offset - PageSize);
    [self loadData];
}

- (void)nextPage:(id)sender {
    _offset += PageSize;
    [self loadData];
}

- (void)refresh:(id)sender {
    if (_table) [self loadData];
    else [self loadTables];
}

#pragma mark - SQL

// ⌘R: w zakładce SQL uruchamia zapytanie, w pozostałych odświeża.
- (void)runQuery:(id)sender {
    if (_tabs.selectedTabViewItem != _sqlItem) return [self refresh:sender];
    NSRange sel = _sqlText.selectedRange;
    NSString *sql = sel.length ? [_sqlText.string substringWithRange:sel] : _sqlText.string;
    sql = [sql stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (sql.length) [self runSQL:sql confirmed:NO];
}

// Na produkcji sesja jest READ ONLY, więc zapis kończy się błędem 25006.
// Wtedy pytamy i po potwierdzeniu wykonujemy to samo w BEGIN READ WRITE … COMMIT.
- (void)runSQL:(NSString *)sql confirmed:(BOOL)confirmed {
    id<DBConnection> conn = _conn;
    [self run:^DBResult *(NSError **e) {
        if (!confirmed) return [conn execute:sql params:nil error:e];
        if (![conn execute:@"BEGIN READ WRITE" params:nil error:e]) return nil;
        DBResult *r = [conn execute:sql params:nil error:e];
        if (r && [conn execute:@"COMMIT" params:nil error:e]) return r;
        [conn execute:@"ROLLBACK" params:nil error:NULL];
        return nil;
    } done:^(DBResult *r) {
        self->_sqlGrid.result = r;
    } failed:^(NSError *error) {
        if (self->_production && !confirmed && [error.userInfo[@"sqlstate"] isEqual:@"25006"]) [self confirmWrite:sql];
        else [self showError:error];
    }];
}

- (void)confirmWrite:(NSString *)sql {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"To zapytanie zmienia dane na produkcji";
    alert.informativeText = sql.length > 1500 ? [[sql substringToIndex:1500] stringByAppendingString:@"…"] : sql;
    NSButton *execute = [alert addButtonWithTitle:@"Wykonaj"];
    NSButton *cancel = [alert addButtonWithTitle:@"Anuluj"];
    execute.keyEquivalent = @""; // Enter ma anulować, nie wykonywać
    cancel.keyEquivalent = @"\r";
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [self runSQL:sql confirmed:YES];
    }];
}

#pragma mark - Lista tabel

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _visible.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSArray *t = _visible[row];
    NSTableCellView *cell = TBCell(tableView, @"table", YES);
    BOOL defaultSchema = [t[0] isEqual:@"public"] || [t[0] isEqual:@"main"];
    cell.textField.stringValue = defaultSchema ? t[1] : [NSString stringWithFormat:@"%@.%@", t[0], t[1]];
    cell.imageView.image = [NSImage imageWithSystemSymbolName:[t[2] isEqual:@"view"] ? @"eye" : @"tablecells" accessibilityDescription:nil];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = _sidebar.selectedRow;
    if (row < 0) return;
    NSArray *t = _visible[row];
    _schema = t[0];
    _table = t[1];
    _offset = 0;
    _sortColumn = nil;
    [_dataGrid resetSort];
    _tableLabel.stringValue = [_schema isEqual:@"public"] ? _table : [NSString stringWithFormat:@"%@.%@", _schema, _table];
    if (_tabs.selectedTabViewItem == _sqlItem) [_tabs selectTabViewItem:_dataItem];
    [self loadStructure];
    [self loadData];
}

#pragma mark - Okno

- (void)setTunnelStatus:(NSString *)status {
    _tunnelLabel.stringValue = status;
}

- (void)windowWillClose:(NSNotification *)notification {
    [_tunnel stop];
    id<DBConnection> conn = _conn;
    dispatch_async(conn.queue, ^{ [conn close]; });
    if (self.onClose) self.onClose(self);
}

@end

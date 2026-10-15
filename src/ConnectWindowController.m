#import "ConnectWindowController.h"
#import "ConnectionStore.h"
#import "GridView.h"
#import "PGConnection.h"
#import "SSHTunnel.h"

// klucz, etykieta, placeholder
static NSArray<NSArray<NSString *> *> *FieldSpec(void) {
    return @[
        @[@"name", @"Nazwa", @"np. Produkcja – API"],
        @[@"host", @"Host bazy", @"localhost"],
        @[@"port", @"Port", @"5432"],
        @[@"user", @"Użytkownik", @"postgres"],
        @[@"password", @"Hasło", @""],
        @[@"database", @"Baza danych", @"postgres"],
        @[@"sshHost", @"Tunel SSH", @"user@serwer albo alias z ~/.ssh/config"],
    ];
}

@implementation ConnectWindowController {
    NSMutableArray<NSMutableDictionary *> *_connections;
    NSInteger _selected;
    NSString *_loadedPassword;

    NSTableView *_list;
    NSDictionary<NSString *, NSTextField *> *_fields;
    NSButton *_production, *_connectButton;
    NSProgressIndicator *_spinner;
    NSTextField *_errorLabel;
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 380)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    if (!(self = [super initWithWindow:window])) return nil;
    window.releasedWhenClosed = NO;
    window.title = @"Połączenia";
    _selected = -1;
    _connections = [ConnectionStore load];
    if (!_connections.count) [_connections addObject:[self newConnection]];
    [self buildUI];
    [window center];
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    return self;
}

- (NSMutableDictionary *)newConnection {
    return [@{@"id": NSUUID.UUID.UUIDString, @"name": @"Nowe połączenie", @"port": @"5432"} mutableCopy];
}

#pragma mark - UI

- (void)buildUI {
    _list = [NSTableView new];
    _list.style = NSTableViewStyleSourceList;
    _list.headerView = nil;
    _list.rowHeight = 24;
    _list.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    [_list addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"name"]];
    _list.dataSource = self;
    _list.delegate = self;
    _list.target = self;
    _list.doubleAction = @selector(connect:);
    NSScrollView *listScroll = [NSScrollView new];
    listScroll.documentView = _list;
    listScroll.hasVerticalScroller = YES;
    listScroll.borderType = NSBezelBorder;

    NSButton *add = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameAddTemplate] target:self action:@selector(addConnection:)];
    NSButton *remove = [NSButton buttonWithImage:[NSImage imageNamed:NSImageNameRemoveTemplate] target:self action:@selector(removeConnection:)];
    add.bezelStyle = remove.bezelStyle = NSBezelStyleSmallSquare;
    NSStackView *listButtons = [NSStackView stackViewWithViews:@[add, remove]];
    listButtons.spacing = 0;

    NSStackView *left = [NSStackView stackViewWithViews:@[listScroll, listButtons]];
    left.orientation = NSUserInterfaceLayoutOrientationVertical;
    left.alignment = NSLayoutAttributeLeading;
    left.spacing = 0;
    [NSLayoutConstraint activateConstraints:@[
        [listScroll.widthAnchor constraintEqualToConstant:190],
        [listScroll.heightAnchor constraintEqualToConstant:300],
    ]];

    NSMutableDictionary *fields = [NSMutableDictionary new];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSArray *spec in FieldSpec()) {
        NSTextField *f = [spec[0] isEqual:@"password"] ? [NSSecureTextField new] : [NSTextField new];
        f.placeholderString = spec[2];
        [f.widthAnchor constraintEqualToConstant:300].active = YES;
        fields[spec[0]] = f;
        [rows addObject:@[[NSTextField labelWithString:spec[1]], f]];
    }
    _fields = fields;
    NSTextField *sshHint = [NSTextField wrappingLabelWithString:@"Puste = połączenie bezpośrednie. Z tunelem host bazy jest widziany z serwera SSH (zwykle localhost). Wymaga klucza SSH, hasła SSH nie obsługujemy."];
    sshHint.font = [NSFont systemFontOfSize:11];
    sshHint.textColor = NSColor.secondaryLabelColor;
    [sshHint.widthAnchor constraintEqualToConstant:300].active = YES;
    _production = [NSButton checkboxWithTitle:@"Produkcja: tylko odczyt, zapis po potwierdzeniu" target:nil action:nil];
    [rows addObject:@[NSGridCell.emptyContentView, sshHint]];
    [rows addObject:@[NSGridCell.emptyContentView, _production]];

    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;

    _errorLabel = [NSTextField wrappingLabelWithString:@""];
    _errorLabel.textColor = NSColor.systemRedColor;
    _errorLabel.selectable = YES;
    [_errorLabel.widthAnchor constraintEqualToConstant:390].active = YES;

    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    NSButton *save = [NSButton buttonWithTitle:@"Zapisz" target:self action:@selector(save:)];
    _connectButton = [NSButton buttonWithTitle:@"Połącz" target:self action:@selector(connect:)];
    _connectButton.keyEquivalent = @"\r";
    NSStackView *buttons = [NSStackView new];
    [buttons addView:_spinner inGravity:NSStackViewGravityLeading];
    [buttons addView:save inGravity:NSStackViewGravityTrailing];
    [buttons addView:_connectButton inGravity:NSStackViewGravityTrailing];

    NSStackView *right = [NSStackView stackViewWithViews:@[grid, _errorLabel, buttons]];
    right.orientation = NSUserInterfaceLayoutOrientationVertical;
    right.alignment = NSLayoutAttributeLeading;
    right.spacing = 12;
    [buttons.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;

    NSStackView *root = [NSStackView stackViewWithViews:@[left, right]];
    root.alignment = NSLayoutAttributeTop;
    root.spacing = 20;
    root.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    self.window.contentView = root;
    [self.window setContentSize:root.fittingSize];
}

#pragma mark - Lista

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _connections.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *c = _connections[row];
    BOOL production = [c[@"production"] boolValue];
    NSTableCellView *cell = TBCell(tableView, @"connection", YES);
    cell.textField.stringValue = c[@"name"];
    cell.imageView.image = [NSImage imageWithSystemSymbolName:[c[@"sshHost"] length] ? @"lock.shield" : @"cylinder" accessibilityDescription:nil];
    cell.imageView.contentTintColor = production ? NSColor.systemRedColor : nil;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_selected >= 0) [self storeFormAt:_selected];
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
    _errorLabel.stringValue = @"";
}

- (void)storeFormAt:(NSInteger)index {
    NSMutableDictionary *c = _connections[index];
    for (NSString *key in _fields) {
        if ([key isEqual:@"password"]) continue;
        c[key] = [_fields[key].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (![c[@"name"] length]) c[@"name"] = [c[@"host"] length] ? c[@"host"] : @"Bez nazwy";
    c[@"production"] = @(_production.state == NSControlStateValueOn);

    NSString *password = _fields[@"password"].stringValue;
    if (![password isEqual:_loadedPassword]) {
        [ConnectionStore setPassword:password for:c[@"id"]];
        _loadedPassword = password;
    }
    [ConnectionStore save:_connections];
    [_list reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:index] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

#pragma mark - Akcje

- (void)save:(id)sender {
    if (_selected >= 0) [self storeFormAt:_selected];
}

- (void)addConnection:(id)sender {
    [_connections addObject:[self newConnection]];
    [ConnectionStore save:_connections];
    [_list reloadData];
    [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:_connections.count - 1] byExtendingSelection:NO];
    [self.window makeFirstResponder:_fields[@"name"]];
}

- (void)removeConnection:(id)sender {
    if (_selected < 0) return;
    NSInteger index = _selected;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Usunąć połączenie „%@”?", _connections[index][@"name"]];
    alert.informativeText = @"Usuwa tylko zapisaną konfigurację i hasło z Keychain. Baza zostaje bez zmian.";
    [alert addButtonWithTitle:@"Usuń"];
    [alert addButtonWithTitle:@"Anuluj"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [ConnectionStore setPassword:nil for:self->_connections[index][@"id"]];
        self->_selected = -1; // żeby zmiana zaznaczenia nie zapisała formularza pod zły indeks
        [self->_connections removeObjectAtIndex:index];
        [ConnectionStore save:self->_connections];
        [self->_list reloadData];
        [self fillForm];
    }];
}

- (void)connect:(id)sender {
    if (_selected < 0 || !_connectButton.enabled) return;
    [self storeFormAt:_selected];
    NSDictionary *info = [_connections[_selected] copy];
    NSString *password = _fields[@"password"].stringValue;
    _connectButton.enabled = NO;
    _errorLabel.stringValue = @"";
    [_spinner startAnimation:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *host = info[@"host"], *port = [info[@"port"] length] ? info[@"port"] : @"5432";
        SSHTunnel *tunnel = nil;
        if ([info[@"sshHost"] length]) {
            tunnel = [[SSHTunnel alloc] initWithSSHHost:info[@"sshHost"] remoteHost:host.length ? host : @"localhost" remotePort:port];
            if (![tunnel start:&error]) tunnel = nil;
            host = @"127.0.0.1";
            port = @(tunnel.localPort).stringValue;
        }

        PGConnection *conn = nil;
        if (!error) {
            NSMutableDictionary *params = [@{@"port": port} mutableCopy];
            if (host.length) params[@"host"] = host; // pusty host = lokalny socket
            if ([info[@"user"] length]) params[@"user"] = info[@"user"];
            if (password.length) params[@"password"] = password;
            if ([info[@"database"] length]) params[@"dbname"] = info[@"database"];
            conn = [[PGConnection alloc] initWithParams:params readOnly:[info[@"production"] boolValue]];
            if (![conn open:&error]) {
                conn = nil;
                [tunnel stop];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_spinner stopAnimation:nil];
            self->_connectButton.enabled = YES;
            if (!conn) {
                self->_errorLabel.stringValue = error.localizedDescription ?: @"Nie udało się połączyć.";
                return;
            }
            if (self.onConnected) self.onConnected(conn, tunnel, info);
        });
    });
}

@end

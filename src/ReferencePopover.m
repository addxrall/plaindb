#import "ReferencePopover.h"
#import "UI.h"

static NSString *Shown(id value) {
    if (![value isKindOfClass:NSString.class]) return @"NULL";
    NSString *s = [value stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
    return s.length > 300 ? [[s substringToIndex:300] stringByAppendingString:@"…"] : s;
}

#pragma mark - Preview

@implementation ReferencePreview {
    NSString *_title, *_subtitle;
    DBResult *_result;
}

- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle result:(DBResult *)result {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _title = title;
        _subtitle = subtitle;
        _result = result;
    }
    return self;
}

- (void)loadView {
    NSTextField *title = TBLabel(_title, 13, NSFontWeightSemibold, NSColor.labelColor);
    title.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    NSTextField *subtitle = TBLabel(_subtitle, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);

    NSView *body;
    NSArray *row = _result.rows.firstObject;
    if (!row) {
        body = TBCenteredState(@[TBLabel(L(@"The referenced row doesn't exist."), 12, NSFontWeightRegular, NSColor.secondaryLabelColor)]);
    } else {
        // Design: names right-aligned in their own (content-wide) column, values take the rest.
        NSMutableArray *lines = [NSMutableArray new];
        [_result.columns enumerateObjectsUsingBlock:^(NSString *column, NSUInteger i, BOOL *stop) {
            NSTextField *name = TBLabel(column, 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
            [name setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
            [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
            NSTextField *value = TBLabel(Shown(row[i]), 12, NSFontWeightRegular, row[i] == NSNull.null ? NSColor.tertiaryLabelColor : NSColor.labelColor);
            value.font = [Theme mono:12];
            value.selectable = YES;
            value.toolTip = [row[i] isKindOfClass:NSString.class] ? row[i] : nil;
            [value setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
            [lines addObject:@[name, value]];
        }];
        NSGridView *grid = [NSGridView gridViewWithViews:lines];
        grid.rowSpacing = 6;
        grid.columnSpacing = 12;
        [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
        grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
        NSScrollView *scroll = [NSScrollView new];
        scroll.drawsBackground = NO;
        scroll.hasVerticalScroller = YES;
        scroll.autohidesScrollers = YES;
        NSView *document = [TBFlippedView new];
        TBPin(grid, document, NSEdgeInsetsMake(10, 14, 10, 14));
        document.translatesAutoresizingMaskIntoConstraints = NO;
        scroll.documentView = document;
        [NSLayoutConstraint activateConstraints:@[
            [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
            [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
            [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        ]];
        body = scroll;
    }

    NSButton *open = TBButton(L(@"Open Table"), self, @selector(openTable:));
    NSStackView *header = TBColumnInset(@[title, subtitle], nil, NSEdgeInsetsMake(12, 14, 8, 14));
    header.spacing = 1;
    NSStackView *view = TBColumn(@[header, TBSeparator(), body, TBSeparator(), TBBar(@[], @[open], 40)], body);
    [view.widthAnchor constraintEqualToConstant:400].active = YES;
    [view.heightAnchor constraintEqualToConstant:276].active = YES;
    self.view = view;
}

- (void)openTable:(id)sender {
    if (self.onOpenTable) self.onOpenTable();
}

@end

#pragma mark - Picker

// The chosen row stays accent blue with white text while typing in the search field (a plain table
// would grey its selection out, as it isn't the first responder).
@interface AccentRowView : NSTableRowView
@end

@implementation AccentRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [NSColor.controlAccentColor setFill];
    NSRectFill(self.bounds);
}
@end

@interface ReferencePicker () <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation ReferencePicker {
    NSString *_column, *_table, *_keyColumn;
    DBResult *_result;
    NSSearchField *_search;
    NSTableView *_list;
    NSTextField *_status;
}

- (instancetype)initWithColumn:(NSString *)column table:(NSString *)table keyColumn:(NSString *)keyColumn {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _column = column;
        _table = table;
        _keyColumn = keyColumn;
    }
    return self;
}

- (void)loadView {
    NSFont *bold = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], *plain = [NSFont systemFontOfSize:13];
    NSMutableAttributedString *heading = [[NSMutableAttributedString alloc] initWithString:_column attributes:@{NSFontAttributeName: bold}];
    [heading appendAttributedString:[[NSAttributedString alloc] initWithString:@" → " attributes:@{
        NSFontAttributeName: plain, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor}]];
    [heading appendAttributedString:[[NSAttributedString alloc] initWithString:_table attributes:@{NSFontAttributeName: bold}]];
    NSTextField *title = TBLabel(@"", 13, NSFontWeightSemibold, NSColor.labelColor);
    title.attributedStringValue = heading;
    _search = [NSSearchField new];
    _search.placeholderString = L(@"Search in any column");
    _search.target = self;
    _search.action = @selector(searchChanged:);
    _search.delegate = self;

    _list = [NSTableView new];
    _list.headerView = nil;
    _list.style = NSTableViewStylePlain;
    _list.rowHeight = 36;
    _list.usesAlternatingRowBackgroundColors = YES;
    [_list addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"row"]];
    _list.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    _list.dataSource = self;
    _list.delegate = self;
    _list.target = self;
    _list.doubleAction = @selector(pick:);
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _list;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    _status = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSButton *null = TBButton(L(@"Set NULL"), self, @selector(pickNull:));
    NSButton *choose = TBButton(L(@"Choose"), self, @selector(pick:));
    choose.keyEquivalent = @"\r"; // the accent button; Enter in the search field also picks (see below)

    NSStackView *top = TBColumnInset(@[title, _search], nil, NSEdgeInsetsMake(12, 14, 10, 14));
    top.spacing = 8;
    NSStackView *view = TBColumn(@[top, TBSeparator(), scroll, TBSeparator(), TBBar(@[_status], @[null, choose], 40)], scroll);
    [view.widthAnchor constraintEqualToConstant:440].active = YES;
    [view.heightAnchor constraintEqualToConstant:330].active = YES;
    self.view = view;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [AccentRowView new];
}

// White text on the selected row: its colours depend on the selection, so changed rows are rebuilt.
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [_list reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _list.numberOfRows)] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window makeFirstResponder:_search];
    _status.stringValue = L(@"Loading…");
    if (self.onSearch) self.onSearch(@"");
}

- (void)searchChanged:(id)sender {
    _status.stringValue = L(@"Searching…");
    if (self.onSearch) self.onSearch([_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
}

- (void)showResult:(DBResult *)result error:(NSError *)error {
    _result = result;
    [_list reloadData];
    if (result.rows.count) [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    _status.stringValue = error ? (error.localizedDescription ?: @"") : result.rows.count ? LN(@"%lu rows", result.rows.count) : L(@"Nothing found");
    _status.textColor = error ? Theme.red : NSColor.secondaryLabelColor;
}

// ↑ ↓ move through the results while typing, Enter picks.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    NSInteger row = _list.selectedRow, count = _list.numberOfRows;
    if (selector == @selector(moveDown:) || selector == @selector(moveUp:)) {
        if (!count) return YES;
        row = MAX(0, MIN(count - 1, row + (selector == @selector(moveDown:) ? 1 : -1)));
        [_list selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [_list scrollRowToVisible:row];
        return YES;
    }
    if (selector == @selector(insertNewline:)) {
        [self pick:nil];
        return YES;
    }
    return NO;
}

- (void)pick:(id)sender {
    NSInteger row = _list.selectedRow;
    NSUInteger key = [_result.columns indexOfObject:_keyColumn];
    if (row < 0 || key == NSNotFound) return;
    if (self.onPick) self.onPick(_result.rows[row][key]);
}

- (void)pickNull:(id)sender {
    if (self.onPick) self.onPick(NSNull.null);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _result.rows.count;
}

// Two lines: the key value, then a few other non-empty values to recognise the row by.
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"row" owner:nil];
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"row";
        NSTextField *key = TBLabel(@"", 12, NSFontWeightSemibold, NSColor.labelColor);
        key.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
        NSTextField *rest = TBLabel(@"", 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor);
        rest.tag = 1;
        for (NSView *v in @[key, rest]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [key.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:12],
            [key.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [key.bottomAnchor constraintEqualToAnchor:cell.centerYAnchor constant:1],
            [rest.leadingAnchor constraintEqualToAnchor:key.leadingAnchor],
            [rest.trailingAnchor constraintEqualToAnchor:key.trailingAnchor],
            [rest.topAnchor constraintEqualToAnchor:key.bottomAnchor],
        ]];
        cell.textField = key;
    }
    NSArray *values = _result.rows[row];
    NSUInteger keyIndex = [_result.columns indexOfObject:_keyColumn];
    NSMutableArray *others = [NSMutableArray new];
    [values enumerateObjectsUsingBlock:^(id v, NSUInteger i, BOOL *stop) {
        if (i == keyIndex || ![v isKindOfClass:NSString.class] || ![v length]) return;
        NSString *s = [v stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [others addObject:s.length > 40 ? [[s substringToIndex:40] stringByAppendingString:@"…"] : s];
        if (others.count == 4) *stop = YES;
    }];
    BOOL selected = [tableView isRowSelected:row];
    cell.textField.stringValue = keyIndex == NSNotFound ? @"" : Shown(values[keyIndex]);
    cell.textField.textColor = selected ? NSColor.whiteColor : NSColor.labelColor;
    NSTextField *rest = [cell viewWithTag:1];
    rest.stringValue = [others componentsJoinedByString:@" · "];
    rest.textColor = selected ? [NSColor colorWithWhite:1 alpha:0.85] : NSColor.secondaryLabelColor;
    return cell;
}

@end

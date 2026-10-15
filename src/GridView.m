#import "GridView.h"

NSTableCellView *TBCell(NSTableView *table, NSString *identifier, BOOL withImage) {
    NSTableCellView *cell = [table makeViewWithIdentifier:identifier owner:nil];
    if (cell) return cell;
    cell = [NSTableCellView new];
    cell.identifier = identifier;

    NSTextField *field = [NSTextField labelWithString:@""];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:field];
    cell.textField = field;

    NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
    CGFloat inset = 4;
    if (withImage) {
        NSImageView *image = [NSImageView new];
        image.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:image];
        cell.imageView = image;
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:16],
        ]];
        leading = image.trailingAnchor;
        inset = 6;
    }
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:leading constant:inset],
        [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

@implementation GridView {
    BOOL _ignoreSortChange;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _table = [NSTableView new];
        _table.style = NSTableViewStylePlain;
        _table.usesAlternatingRowBackgroundColors = YES;
        _table.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
        _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
        _table.allowsMultipleSelection = YES;
        _table.rowHeight = 22;
        _table.dataSource = self;
        _table.delegate = self;
        self.documentView = _table;
        self.hasVerticalScroller = YES;
        self.hasHorizontalScroller = YES;
        self.autohidesScrollers = YES;
    }
    return self;
}

- (void)setResult:(DBResult *)result {
    _result = result;
    _ignoreSortChange = YES;
    while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];

    NSArray *sample = [result.rows subarrayWithRange:NSMakeRange(0, MIN(result.rows.count, 50))];
    [result.columns enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@(i).stringValue];
        col.title = name;
        NSUInteger chars = name.length;
        for (NSArray *row in sample) {
            id v = row[i];
            if (v != NSNull.null) chars = MAX(chars, [v length]);
        }
        col.width = MIN(MAX(chars * 7 + 20, 60), 320);
        if (self.onSort) col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:name ascending:YES];
        [self.table addTableColumn:col];
    }];
    [_table reloadData];
    _ignoreSortChange = NO;
}

- (void)resetSort {
    _ignoreSortChange = YES;
    _table.sortDescriptors = @[];
    _ignoreSortChange = NO;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _result.rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    static NSFont *regular, *italic;
    if (!regular) {
        regular = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        italic = [NSFontManager.sharedFontManager convertFont:regular toHaveTrait:NSItalicFontMask];
    }
    NSTableCellView *cell = TBCell(tableView, @"cell", NO);
    id value = _result.rows[row][column.identifier.integerValue];
    if (value == NSNull.null) {
        cell.textField.stringValue = @"NULL";
        cell.textField.font = italic;
        cell.textField.textColor = NSColor.tertiaryLabelColor;
    } else {
        NSString *s = value;
        if (s.length > 500) s = [s substringToIndex:500];
        cell.textField.stringValue = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
        cell.textField.font = regular;
        cell.textField.textColor = NSColor.labelColor;
    }
    return cell;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSSortDescriptor *sort = tableView.sortDescriptors.firstObject;
    if (_ignoreSortChange || !sort || !_onSort) return;
    _onSort(sort.key, sort.ascending);
}

@end

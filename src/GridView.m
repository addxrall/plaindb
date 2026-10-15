#import "GridView.h"
#import "DatePicker.h"
#import "ImageValue.h"
#import "JSONInspector.h"
#import "UI.h"

static NSString *const RowNumberColumn = @"#";

// Grid cell that draws its fill, one line of text and the focus ring itself.
// No NSTextField and no constraints: with hundreds of visible cells, a text field per cell
// (its own layer, backing store and layout) made scrolling miss frames. Rows draw their
// cells into one layer (see rowViewForRow).
@interface GridCellView : NSView
@property (nonatomic, copy) NSAttributedString *text;
@property (nonatomic, strong, nullable) NSColor *fill;
@property (nonatomic) BOOL ring;
@property (nonatomic, strong, nullable) NSImage *badge; // at the trailing edge: ↗ foreign key, 🖼 image
@property (nonatomic, strong, nullable) NSImage *icon;  // at the leading edge: boolean checkbox
@end

static const CGFloat IconWidth = 22; // clickable area of the checkbox

static const CGFloat BadgeWidth = 20; // clickable area of the badge

// Empty checkbox for false, in a quiet grey.
static NSImage *Checkbox(void) {
    static NSImage *image;
    if (!image) {
        NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightRegular]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.tertiaryLabelColor]];
        image = [[NSImage imageWithSystemSymbolName:@"square" accessibilityDescription:nil] imageWithSymbolConfiguration:config];
    }
    return image;
}

// Accent-coloured SF Symbol for cell badges, made once.
static NSImage *Badge(NSString *symbol) {
    static NSMutableDictionary<NSString *, NSImage *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    if (!cache[symbol]) {
        NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.controlAccentColor]];
        cache[symbol] = [[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] imageWithSymbolConfiguration:config];
    }
    return cache[symbol];
}

@implementation GridCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}


- (void)setText:(NSAttributedString *)text { _text = [text copy]; self.needsDisplay = YES; }
- (void)setFill:(NSColor *)fill { _fill = fill; self.needsDisplay = YES; }
- (void)setRing:(BOOL)ring { _ring = ring; self.needsDisplay = YES; }
- (void)setBadge:(NSImage *)badge { _badge = badge; self.needsDisplay = YES; }
- (void)setIcon:(NSImage *)icon { _icon = icon; self.needsDisplay = YES; }

- (void)drawRect:(NSRect)rect {
    // AppKit redraws a whole row (all columns, ~6000 pt wide) when the grid scrolls sideways.
    // Cells off screen skip their drawing; GridView redraws cells as their columns scroll into view.
    // (self.visibleRect isn't reliable here: during that row redraw it isn't clipped by the scroll view.)
    NSScrollView *scroll = self.enclosingScrollView;
    if (!NSIntersectsRect([self convertRect:self.bounds toView:scroll.documentView], scroll.documentVisibleRect)) return;
    if (_fill) {
        [_fill setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
    NSAttributedString *text = _text;
    NSDictionary *attrs = text.length ? [text attributesAtIndex:0 effectiveRange:NULL] : @{};
    NSFont *font = attrs[NSFontAttributeName];
    CGFloat left = _icon ? IconWidth : 8;
    CGFloat width = NSWidth(self.bounds) - left - 8 - (_badge ? BadgeWidth - 4 : 0), line = ceil(font.ascender - font.descender + font.leading);
    if (_icon) {
        NSSize s = _icon.size;
        NSRect r = NSMakeRect(6 + (14 - s.width) / 2, (NSHeight(self.bounds) - s.height) / 2, s.width, s.height);
        [_icon drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    if (_badge) {
        NSSize s = _badge.size;
        NSRect r = NSMakeRect(NSWidth(self.bounds) - BadgeWidth + (BadgeWidth - s.width) / 2, (NSHeight(self.bounds) - s.height) / 2, s.width, s.height);
        [_badge drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    // Cells use monospaced fonts, so the cut for the ellipsis is plain arithmetic. Letting the
    // typesetter truncate (NSStringDrawingTruncatesLastVisibleLine) took most of the drawing time.
    static NSMutableDictionary<NSFont *, NSNumber *> *charWidths;
    if (!charWidths) charWidths = [NSMutableDictionary new];
    if (font && !charWidths[font]) charWidths[font] = @([@"0" sizeWithAttributes:@{NSFontAttributeName: font}].width);
    NSUInteger fits = font ? (NSUInteger)MAX(floor((width + 0.5) / charWidths[font].doubleValue), 1) : text.length;
    if (text.length > fits) {
        NSRange keep = [text.string rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, fits - 1)];
        NSMutableAttributedString *cut = [[text attributedSubstringFromRange:keep] mutableCopy];
        [cut appendAttributedString:[[NSAttributedString alloc] initWithString:@"…" attributes:attrs]];
        text = cut;
    }
    [text drawWithRect:NSMakeRect(left, floor((NSHeight(self.bounds) - line) / 2), width, line) options:NSStringDrawingUsesLineFragmentOrigin];
    if (_ring) {
        [NSColor.controlAccentColor setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 1, 1)];
        path.lineWidth = 2;
        [path stroke];
    }
}

- (BOOL)isFlipped {
    return YES;
}

// VoiceOver reads the value like a label.
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityStaticTextRole;
}
- (NSString *)accessibilityValue {
    return _text.string;
}
@end

// Slim, always visible scroll bar in the design's style: 11 pt track in the header colour with a
// hairline towards the content, and a 7 pt rounded knob.
@interface ThinScroller : NSScroller
@end

@implementation ThinScroller
+ (BOOL)isCompatibleWithOverlayScrollers {
    return NO;
}

+ (CGFloat)scrollerWidthForControlSize:(NSControlSize)size scrollerStyle:(NSScrollerStyle)style {
    return 11;
}

- (BOOL)horizontal {
    return NSWidth(self.bounds) > NSHeight(self.bounds);
}

- (void)drawKnobSlotInRect:(NSRect)slot highlight:(BOOL)flag {
    [Theme.head setFill];
    NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    NSRectFill(self.horizontal ? NSMakeRect(0, 0, NSWidth(self.bounds), 1) : NSMakeRect(0, 0, 1, NSHeight(self.bounds)));
}

- (void)drawKnob {
    NSRect knob = [self rectForPart:NSScrollerKnob];
    knob = self.horizontal ? NSInsetRect(knob, 2, (NSHeight(knob) - 7) / 2) : NSInsetRect(knob, (NSWidth(knob) - 7) / 2, 2);
    knob = NSOffsetRect(knob, self.horizontal ? 0 : 0.5, self.horizontal ? 0.5 : 0); // centre in the track beside the hairline
    [NSColor.tertiaryLabelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:knob xRadius:3.5 yRadius:3.5] fill];
}
@end

@implementation GridView {
    BOOL _ignoreSortChange;
    NSIndexSet *_numericColumns;
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSNumber *, id> *> *_edits;
    NSMutableIndexSet *_deleted;
    NSMutableArray<NSMutableDictionary<NSNumber *, id> *> *_inserted;
    NSInteger _editRow, _editColumn, _selectedColumn, _ringRow;
    NSString *_editOriginal;
    NSTextField *_editor; // only while a cell is being edited
    NSIndexSet *_visibleColumns;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _edits = [NSMutableDictionary new];
        _deleted = [NSMutableIndexSet new];
        _inserted = [NSMutableArray new];
        _defaultColumns = [NSIndexSet new];
        _numericColumns = [NSIndexSet new];
        _referenceColumns = [NSIndexSet new];
        _columnKinds = @{};
        _columnColors = @{};
        _nullText = @"NULL";
        _showsRowNumbers = YES;
        _editRow = _ringRow = -1;

        _table = [NSTableView new];
        _table.style = NSTableViewStylePlain;
        _table.usesAlternatingRowBackgroundColors = YES;
        _table.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
        _table.gridColor = Theme.grid;
        _table.intercellSpacing = NSMakeSize(0, 0);
        _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
        _table.allowsMultipleSelection = YES;
        _table.rowHeight = 24;
        _table.dataSource = self;
        _table.delegate = self;
        _table.target = self;
        _table.action = @selector(clicked:);
        _table.doubleAction = @selector(doubleClicked:);
        _table.menu = [self buildMenu];
        self.documentView = _table;
        self.verticalScroller = [ThinScroller new];
        self.horizontalScroller = [ThinScroller new];
        self.hasVerticalScroller = YES;
        self.hasHorizontalScroller = YES;
        self.autohidesScrollers = YES; // hidden only when there is nothing to scroll
        self.scrollerStyle = NSScrollerStyleLegacy;
        self.borderType = NSNoBorder;
        _visibleColumns = [NSIndexSet new];
        self.contentView.postsBoundsChangedNotifications = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrolled:)
                                                   name:NSViewBoundsDidChangeNotification object:self.contentView];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Cells skip drawing while off screen, so cells in columns that just scrolled into view are redrawn here.
- (void)scrolled:(NSNotification *)notification {
    NSIndexSet *visible = [_table columnIndexesInRect:_table.visibleRect];
    NSMutableIndexSet *entered = [visible mutableCopy];
    [entered removeIndexes:_visibleColumns];
    _visibleColumns = visible;
    if (!entered.count) return;
    NSRange rows = [_table rowsInRect:_table.visibleRect];
    [entered enumerateIndexesUsingBlock:^(NSUInteger col, BOOL *stop) {
        for (NSUInteger row = rows.location; row < NSMaxRange(rows); row++)
            [self.table viewAtColumn:col row:row makeIfNecessary:NO].needsDisplay = YES;
    }];
}

// Always classic, visible scroll bars: wide tables need a horizontal bar you can see and grab,
// even when the system shows overlay scroll bars only while scrolling. AppKit resets the style
// whenever the system preference changes, so it is pinned here.
- (void)setScrollerStyle:(NSScrollerStyle)style {
    [super setScrollerStyle:NSScrollerStyleLegacy];
}

- (NSMenu *)buildMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:L(@"Set NULL") action:@selector(setNull:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:L(@"Copy") action:@selector(copyValue:) keyEquivalent:@"c"].target = self;
    [menu addItemWithTitle:L(@"Show Referenced Row") action:@selector(openReference:) keyEquivalent:@""].target = self;
    return menu;
}

#pragma mark - Columns

// Table column index → result column index (-1 for the row number column), and back.
- (NSInteger)dataColumn:(NSInteger)tableColumn {
    return tableColumn - (_showsRowNumbers ? 1 : 0);
}

- (NSInteger)tableColumn:(NSInteger)dataColumn {
    return dataColumn + (_showsRowNumbers ? 1 : 0);
}

- (NSTableColumn *)newColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)width numeric:(BOOL)numeric {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:identifier];
    col.title = title;
    col.width = width;
    col.headerCell.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    col.headerCell.textColor = NSColor.secondaryLabelColor;
    col.headerCell.alignment = numeric ? NSTextAlignmentRight : NSTextAlignmentLeft;
    return col;
}

#pragma mark - Result

- (void)setResult:(DBResult *)result {
    // Empty the grid first: addTableColumn builds cells for visible rows right away,
    // so old rows must not reach into the new, shorter result.
    _result = nil;
    [self clearChanges];
    [_table reloadData];
    _ignoreSortChange = YES;
    while (_table.tableColumns.count) [_table removeTableColumn:_table.tableColumns.lastObject];

    static NSRegularExpression *number;
    if (!number) number = [NSRegularExpression regularExpressionWithPattern:@"^-?\\d+(\\.\\d+)?$" options:0 error:nil];
    NSArray *sample = [result.rows subarrayWithRange:NSMakeRange(0, MIN(result.rows.count, 50))];
    NSMutableIndexSet *numeric = [NSMutableIndexSet new];

    if (_showsRowNumbers && result) [_table addTableColumn:[self newColumn:RowNumberColumn title:@"" width:44 numeric:YES]];
    [result.columns enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSUInteger chars = name.length, numbers = 0, values = 0;
        for (NSArray *row in sample) {
            id v = row[i];
            if (v == NSNull.null) continue;
            values++;
            chars = MAX(chars, [v length]);
            if ([number firstMatchInString:v options:0 range:NSMakeRange(0, [v length])]) numbers++;
        }
        BOOL isNumeric = values > 0 && numbers == values;
        if (isNumeric) [numeric addIndex:i];
        CGFloat charWidth = [@"0" sizeWithAttributes:@{NSFontAttributeName: [Theme mono:12]}].width; // cells are monospaced
        NSTableColumn *col = [self newColumn:@(i).stringValue title:name width:MIN(MAX(ceil(chars * charWidth) + 18, 60), 320) numeric:isNumeric];
        if (self.onSort) col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:name ascending:YES];
        [self.table addTableColumn:col];
    }];
    _numericColumns = numeric;
    _result = result;
    [_table reloadData];
    _ignoreSortChange = NO;
}

- (void)setHighlight:(NSString *)highlight {
    _highlight = [highlight copy];
    [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _table.numberOfRows)]
                      columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _table.numberOfColumns)]];
}

- (void)resetSort {
    _ignoreSortChange = YES;
    _table.sortDescriptors = @[];
    _ignoreSortChange = NO;
}

#pragma mark - Changes

- (NSDictionary *)edits {
    return [_edits copy];
}

- (NSIndexSet *)deletedRows {
    return [_deleted copy];
}

- (NSArray *)insertedRows {
    return [_inserted copy];
}

- (NSUInteger)changeCount {
    NSMutableIndexSet *rows = [_deleted mutableCopy];
    for (NSNumber *row in _edits) [rows addIndex:row.unsignedIntegerValue];
    return rows.count + _inserted.count;
}

- (NSUInteger)editedCellCount {
    NSUInteger n = 0;
    for (NSNumber *row in _edits)
        if (![_deleted containsIndex:row.unsignedIntegerValue]) n += _edits[row].count;
    return n;
}

- (void)clearChanges {
    [_edits removeAllObjects];
    [_deleted removeAllIndexes];
    [_inserted removeAllObjects];
    _editRow = _ringRow = -1;
}

- (void)discardChanges {
    [self clearChanges];
    [_table reloadData];
    [self changed];
}

- (void)changed {
    if (_onChange) _onChange();
}

- (BOOL)isInserted:(NSInteger)row {
    return row >= (NSInteger)_result.rows.count;
}

// Current cell value. nil = unset column of a new row (DEFAULT).
- (id)valueAtRow:(NSInteger)row column:(NSInteger)col {
    if ([self isInserted:row]) return _inserted[row - _result.rows.count][@(col)];
    return _edits[@(row)][@(col)] ?: _result.rows[row][col];
}

- (void)setValue:(id)value row:(NSInteger)row column:(NSInteger)col {
    if ([self isInserted:row]) {
        _inserted[row - _result.rows.count][@(col)] = value;
    } else {
        NSMutableDictionary *rowEdits = _edits[@(row)] ?: [NSMutableDictionary new];
        if ([_result.rows[row][col] isEqual:value]) [rowEdits removeObjectForKey:@(col)];
        else rowEdits[@(col)] = value;
        _edits[@(row)] = rowEdits.count ? rowEdits : nil;
    }
    [self reloadRow:row];
    [self changed];
}

- (void)updateValue:(id)value row:(NSInteger)row column:(NSInteger)col {
    if (_editable && row >= 0 && row < _table.numberOfRows && ![_deleted containsIndex:row]) [self setValue:value row:row column:col];
}

- (BOOL)isRowDeleted:(NSInteger)row {
    return [_deleted containsIndex:row];
}

- (void)reloadRow:(NSInteger)row {
    if (row >= 0 && row < _table.numberOfRows)
        [_table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                          columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _table.numberOfColumns)]];
}

- (void)addRow {
    if (!_editable || !_result) return;
    [_inserted addObject:[NSMutableDictionary new]];
    [_table reloadData];
    NSInteger row = _table.numberOfRows - 1;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    [_table scrollRowToVisible:row];
    [self changed];
}

- (void)deleteSelectedRows {
    NSIndexSet *selected = _table.selectedRowIndexes;
    if (!_editable || !selected.count) return;
    NSUInteger existing = _result.rows.count;
    NSMutableIndexSet *rows = [NSMutableIndexSet new], *newRows = [NSMutableIndexSet new];
    [selected enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if (row >= existing) [newRows addIndex:row - existing];
        else [rows addIndex:row];
    }];
    if (rows.count && [_deleted containsIndexes:rows]) [_deleted removeIndexes:rows];
    else [_deleted addIndexes:rows];
    [_inserted removeObjectsAtIndexes:newRows]; // a new row just disappears
    [_table reloadData]; // clears the selection, but a second ⌫ must restore the same rows
    [_table selectRowIndexes:rows byExtendingSelection:NO];
    [self changed];
}

#pragma mark - Selection and cell editing

- (void)clicked:(id)sender {
    NSInteger row = _table.clickedRow, col = [self dataColumn:_table.clickedColumn];
    if (col >= 0) _selectedColumn = col;
    [self updateRing];
    if (col < 0 || row < 0) return;
    // a click on the ↗ of a foreign key value
    NSRect cell = [self cellRectForRow:row column:col];
    NSPoint click = [_table convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
    if (click.x < NSMinX(cell) + IconWidth && [self isBoolAtColumn:col] && _editable && ![_deleted containsIndex:row])
        return [self toggleRow:row column:col]; // on the checkbox
    if (click.x >= NSMaxX(cell) - BadgeWidth) { // on the badge
        if ([self hasReferenceAtRow:row column:col] && _onOpenReference) return _onOpenReference(row, col, cell);
        if (_onOpenImage && ImageValueDetected([self valueAtRow:row column:col])) return _onOpenImage(row, col, cell);
    }
    if (_onSelectCell) _onSelectCell(row, col);
}

// Boolean columns show "☑ false", wider than the t / f the width was estimated from.
- (void)setColumnKinds:(NSDictionary<NSNumber *, NSString *> *)kinds {
    _columnKinds = [kinds copy];
    [kinds enumerateKeysAndObjectsUsingBlock:^(NSNumber *col, NSString *kind, BOOL *stop) {
        NSInteger index = [self tableColumn:col.integerValue];
        if ([kind isEqual:TBKindBool] && index < (NSInteger)self.table.tableColumns.count)
            self.table.tableColumns[index].width = MAX(self.table.tableColumns[index].width, 84);
    }];
    [_table reloadData];
}

- (BOOL)isBoolAtColumn:(NSInteger)col {
    return [_columnKinds[@(col)] isEqual:TBKindBool];
}

// true → false → true; NULL (or unset) → true. Set NULL is in the context menu.
- (void)toggleRow:(NSInteger)row column:(NSInteger)col {
    id value = [self valueAtRow:row column:col];
    [self setValue:[value isEqual:@"t"] ? @"f" : @"t" row:row column:col];
}

- (NSRect)cellRectForRow:(NSInteger)row column:(NSInteger)col {
    return [_table frameOfCellAtColumn:[self tableColumn:col] row:row];
}

- (BOOL)hasReferenceAtRow:(NSInteger)row column:(NSInteger)col {
    return [_referenceColumns containsIndex:col] && [[self valueAtRow:row column:col] isKindOfClass:NSString.class];
}

// Double-click / Enter: foreign keys get the picker, JSON goes to the inspector, anything else is edited in place.
- (void)activateRow:(NSInteger)row column:(NSInteger)col {
    if (row < 0 || col < 0 || row >= _table.numberOfRows || col >= (NSInteger)_result.columns.count) return;
    if (_onPickReference && _editable && [_referenceColumns containsIndex:col] && ![_deleted containsIndex:row])
        return _onPickReference(row, col, [self cellRectForRow:row column:col]);
    NSString *kind = _columnKinds[@(col)];
    if (kind && _editable && ![_deleted containsIndex:row]) {
        if ([kind isEqual:TBKindBool]) return [self toggleRow:row column:col];
        if (_onPickDate) return _onPickDate(row, col, [self cellRectForRow:row column:col], kind);
    }
    if (_onOpenImage && ImageValueDetected([self valueAtRow:row column:col])) // raw image bytes aren't for editing by hand
        return _onOpenImage(row, col, [self cellRectForRow:row column:col]);
    if (_onOpenJSON && JSONIsValid([self valueAtRow:row column:col])) return _onOpenJSON(row, col);
    [self beginEditingRow:row column:col];
}

- (void)openReference:(id)sender {
    NSInteger row = _table.clickedRow, col = [self dataColumn:_table.clickedColumn];
    if (_onOpenReference) _onOpenReference(row, col, [self cellRectForRow:row column:col]);
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateRing];
}

// The selected cell gets an accent ring (single row selection in an editable grid).
- (void)updateRing {
    NSInteger old = _ringRow;
    _ringRow = _editable && _table.numberOfSelectedRows == 1 ? _table.selectedRow : -1;
    [self reloadRow:old];
    if (_ringRow != old) [self reloadRow:_ringRow];
}

- (void)doubleClicked:(id)sender {
    [self activateRow:_table.clickedRow column:[self dataColumn:_table.clickedColumn]];
}

- (void)beginEditingRow:(NSInteger)row column:(NSInteger)col {
    if (!_editable || row < 0 || col < 0 || row >= _table.numberOfRows || col >= (NSInteger)_result.columns.count) return;
    if ([_deleted containsIndex:row]) return;
    [_table scrollRowToVisible:row];
    [_table scrollColumnToVisible:[self tableColumn:col]];
    id value = [self valueAtRow:row column:col];
    _editOriginal = [value isKindOfClass:NSString.class] ? value : @"";
    _editRow = row;
    _editColumn = col;
    _selectedColumn = col;
    [self updateRing];

    // A text field exists only while editing, laid over the cell (whose ring stays visible around it).
    [_editor removeFromSuperview];
    _editor = [NSTextField new];
    _editor.frame = NSInsetRect([_table frameOfCellAtColumn:[self tableColumn:col] row:row], 3, 3);
    _editor.bezeled = NO;
    _editor.bordered = NO;
    _editor.focusRingType = NSFocusRingTypeNone;
    _editor.drawsBackground = YES;
    _editor.backgroundColor = NSColor.textBackgroundColor;
    _editor.font = [Theme mono:12];
    _editor.alignment = [_numericColumns containsIndex:col] ? NSTextAlignmentRight : NSTextAlignmentLeft;
    _editor.stringValue = _editOriginal;
    _editor.delegate = self;
    [_table addSubview:_editor];
    [self.window makeFirstResponder:_editor];
}

- (void)endEditor {
    [_editor removeFromSuperview];
    _editor = nil;
    [self.window makeFirstResponder:_table];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSInteger row = _editRow, col = _editColumn;
    if (row < 0) return;
    _editRow = -1;
    NSString *value = _editor.stringValue;
    BOOL changed = ![value isEqual:_editOriginal];
    // after editing has ended, not in the middle of it
    dispatch_async(dispatch_get_main_queue(), ^{
        [self endEditor];
        if (changed) [self setValue:value row:row column:col];
    });
}

// Esc cancels editing without changing the value.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector != @selector(cancelOperation:)) return NO;
    _editRow = -1;
    [control abortEditing];
    [self endEditor];
    return YES;
}

// ⌫ deletes the selected rows, Enter edits the selected cell.
- (void)keyDown:(NSEvent *)event {
    unsigned short key = event.keyCode;
    if (_editable && (key == 51 || key == 117)) [self deleteSelectedRows];
    else if ((key == 36 || key == 76) && _table.selectedRow >= 0) [self activateRow:_table.selectedRow column:_selectedColumn];
    else [super keyDown:event];
}

#pragma mark - Menu and pasteboard

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    BOOL onCell = _table.clickedRow >= 0 && [self dataColumn:_table.clickedColumn] >= 0;
    if (item.action == @selector(copyValue:)) return onCell;
    if (item.action == @selector(openReference:)) {
        item.hidden = ![_referenceColumns containsIndex:[self dataColumn:_table.clickedColumn]];
        return onCell && _onOpenReference && [self hasReferenceAtRow:_table.clickedRow column:[self dataColumn:_table.clickedColumn]];
    }
    if (item.action == @selector(setNull:)) return _editable && onCell && ![_deleted containsIndex:_table.clickedRow];
    if (item.action == @selector(copy:)) return _table.selectedRowIndexes.count > 0;
    return YES;
}

- (NSString *)textAtRow:(NSInteger)row column:(NSInteger)col {
    id v = [self valueAtRow:row column:col];
    return [v isKindOfClass:NSString.class] ? v : @"";
}

- (void)copyValue:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[self textAtRow:_table.clickedRow column:[self dataColumn:_table.clickedColumn]]
                                      forType:NSPasteboardTypeString];
}

// ⌘C: selected rows as tab-separated text, ready to paste into a spreadsheet.
- (void)copy:(id)sender {
    NSMutableArray *lines = [NSMutableArray new];
    NSUInteger columns = _result.columns.count;
    [_table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        NSMutableArray *cells = [NSMutableArray new];
        for (NSUInteger c = 0; c < columns; c++) [cells addObject:[self textAtRow:row column:c]];
        [lines addObject:[cells componentsJoinedByString:@"\t"]];
    }];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:[lines componentsJoinedByString:@"\n"] forType:NSPasteboardTypeString];
}

- (void)setNull:(id)sender {
    [self setValue:NSNull.null row:_table.clickedRow column:[self dataColumn:_table.clickedColumn]];
}

#pragma mark - Table view

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _result.rows.count + _inserted.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    TBRowView *view = [tableView makeViewWithIdentifier:@"row" owner:nil];
    if (view) return view;
    view = [TBRowView new];
    view.identifier = @"row";
    return view;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    static NSFont *regular, *italic, *small;
    static NSParagraphStyle *left, *right;
    if (!regular) {
        regular = [Theme mono:12];
        italic = [NSFontManager.sharedFontManager convertFont:regular toHaveTrait:NSItalicFontMask];
        small = [Theme mono:10.5];
        NSMutableParagraphStyle *l = [NSMutableParagraphStyle new], *r = [NSMutableParagraphStyle new];
        l.lineBreakMode = r.lineBreakMode = NSLineBreakByClipping; // GridCellView adds the ellipsis itself
        r.alignment = NSTextAlignmentRight;
        left = l;
        right = r;
    }
    BOOL inserted = [self isInserted:row];
    BOOL deleted = !inserted && [_deleted containsIndex:row];
    NSColor *rowFill = deleted ? Theme.deleted : inserted ? Theme.added : nil;
    GridCellView *cell = [tableView makeViewWithIdentifier:@"cell" owner:nil];
    if (!cell) {
        cell = [GridCellView new];
        cell.identifier = @"cell";
    }

    if ([column.identifier isEqual:RowNumberColumn]) {
        NSString *number = inserted ? @"+" : @(row + 1 + _rowNumberOffset).stringValue;
        cell.text = [[NSAttributedString alloc] initWithString:number attributes:@{
            NSFontAttributeName: small, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor, NSParagraphStyleAttributeName: right,
        }];
        cell.fill = rowFill;
        cell.ring = NO;
        cell.badge = cell.icon = nil;
        return cell;
    }

    NSInteger col = column.identifier.integerValue;
    BOOL edited = !inserted && _edits[@(row)][@(col)] != nil;
    id value = [self valueAtRow:row column:col];
    BOOL isDefault = !value && [_defaultColumns containsIndex:col];
    BOOL placeholder = ![value isKindOfClass:NSString.class];

    BOOL isBool = [self isBoolAtColumn:col] && !placeholder;
    NSString *text;
    if (isDefault) text = @"DEFAULT";
    else if (placeholder) text = _nullText;
    else if (isBool) text = [value isEqual:@"t"] ? @"true" : @"false"; // Postgres prints t / f
    else {
        // Only what fits in the column (monospace: ~7.2 pt per character) gets laid out.
        NSUInteger fits = (NSUInteger)(column.width / 7) + 2;
        text = [value length] > fits ? [value substringToIndex:fits] : value;
        text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
    }
    NSMutableDictionary *attrs = [@{
        NSFontAttributeName: isDefault ? small : placeholder ? italic : regular,
        NSForegroundColorAttributeName: placeholder ? NSColor.tertiaryLabelColor : (_columnColors[@(col)] ?: NSColor.labelColor),
        NSParagraphStyleAttributeName: [_numericColumns containsIndex:col] ? right : left,
    } mutableCopy];
    if (deleted) attrs[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    NSMutableAttributedString *shown = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs];
    if (_highlight.length && !placeholder) { // same matching as the search: anywhere, ignoring case
        NSRange search = NSMakeRange(0, text.length), found;
        while ((found = [text rangeOfString:_highlight options:NSCaseInsensitiveSearch range:search]).location != NSNotFound) {
            [shown addAttributes:@{NSBackgroundColorAttributeName: NSColor.findHighlightColor, NSForegroundColorAttributeName: NSColor.blackColor}
                           range:found];
            search = NSMakeRange(NSMaxRange(found), text.length - NSMaxRange(found));
        }
    }
    cell.text = shown;
    cell.fill = rowFill ?: (edited ? Theme.changed : nil);
    cell.ring = row == _ringRow && col == _selectedColumn && !deleted;
    cell.icon = isBool ? ([value isEqual:@"t"] ? Badge(@"checkmark.square.fill") : Checkbox()) : nil;
    cell.badge = placeholder ? nil
               : [_referenceColumns containsIndex:col] ? Badge(@"arrow.up.right")
               : _onOpenImage && ImageValueDetected(value) ? Badge(@"photo") : nil;
    return cell;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSSortDescriptor *sort = tableView.sortDescriptors.firstObject;
    if (_ignoreSortChange || !sort || !_onSort) return;
    _onSort(sort.key, sort.ascending);
}

@end

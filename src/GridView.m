#import "GridView.h"
#import "DatePicker.h"
#import "FileRefs.h"
#import "ImageValue.h"
#import "JSONInspector.h"
#import "UI.h"

static NSString *const RowNumberColumn = @"#";

// Grid cell that draws its fill, one line of text and the focus ring itself.
// No NSTextField and no constraints: with hundreds of visible cells, a text field per cell
// (its own layer, backing store and layout) made scrolling miss frames. Rows draw their
// cells into one layer (see rowViewForRow).
typedef NS_ENUM(NSInteger, CellBadge) { CellBadgeNone, CellBadgeReference, CellBadgeImage };
typedef NS_ENUM(NSInteger, CellCheckbox) { CellCheckboxNone, CellCheckboxOff, CellCheckboxOn };

@interface GridCellView : NSView
@property (nonatomic, copy) NSAttributedString *text;
@property (nonatomic, strong, nullable) NSColor *fill;
@property (nonatomic) BOOL ring;
@property (nonatomic) CellBadge badge;          // right after the text: ↗ foreign key, 🖼 image
@property (nonatomic) CellCheckbox checkbox;    // before the text, for booleans
@property (nonatomic, readonly) NSRect badgeRect; // where the badge was last drawn, for clicks
@end

static const CGFloat CheckboxEnd = 27; // the checkbox and its gap: text starts here (8 + 13 + 6)
static const CGFloat BadgeSize = 15, BadgeGap = 6;

static BOOL IsTrue(id value) {
    return [value isKindOfClass:NSString.class] && [@[@"t", @"true", @"1"] containsObject:[value lowercaseString]];
}

static BOOL IsDark(NSView *view) {
    return [view.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}

// Design: 15 pt rounded square in a light accent tint, with the glyph in the accent colour.
static void DrawBadge(CellBadge badge, NSRect r, BOOL dark) {
    [[NSColor.controlAccentColor colorWithAlphaComponent:dark ? 0.2 : 0.1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:4 yRadius:4] fill];
    [NSColor.controlAccentColor set];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineCapStyle = NSLineCapStyleRound;
    p.lineJoinStyle = NSLineJoinStyleRound;
    if (badge == CellBadgeReference) { // ↗ in a 7 × 7 box
        NSPoint o = NSMakePoint(NSMinX(r) + 4, NSMinY(r) + 4);
        [p moveToPoint:NSMakePoint(o.x + 1.2, o.y + 5.8)];
        [p lineToPoint:NSMakePoint(o.x + 5.6, o.y + 1.4)];
        [p moveToPoint:NSMakePoint(o.x + 2.4, o.y + 1.2)];
        [p lineToPoint:NSMakePoint(o.x + 5.8, o.y + 1.2)];
        [p lineToPoint:NSMakePoint(o.x + 5.8, o.y + 4.6)];
        p.lineWidth = 1.3;
        [p stroke];
    } else { // picture: frame, hills and a sun in a 10 × 8 box
        NSPoint o = NSMakePoint(NSMinX(r) + 2.5, NSMinY(r) + 3.5);
        NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(o.x + 0.6, o.y + 0.6, 8.8, 6.8) xRadius:1.2 yRadius:1.2];
        frame.lineWidth = 1.1;
        [frame stroke];
        [p moveToPoint:NSMakePoint(o.x + 1.6, o.y + 6.4)];
        [p lineToPoint:NSMakePoint(o.x + 4, o.y + 3.8)];
        [p lineToPoint:NSMakePoint(o.x + 5.6, o.y + 5.3)];
        [p lineToPoint:NSMakePoint(o.x + 6.8, o.y + 4.2)];
        [p lineToPoint:NSMakePoint(o.x + 8.4, o.y + 6.4)];
        p.lineWidth = 1;
        [p stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(o.x + 6.1, o.y + 1.6, 1.6, 1.6)] fill];
    }
}

// Design: 13 pt box, accent with a white tick when on, a white (dark: grey) box with a thin border when off.
static void DrawCheckbox(BOOL on, NSRect r, BOOL dark) {
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:r xRadius:3.5 yRadius:3.5];
    if (on) {
        [NSColor.controlAccentColor setFill];
        [box fill];
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(NSMinX(r) + 3.3, NSMinY(r) + 6.7)];
        [tick lineToPoint:NSMakePoint(NSMinX(r) + 5.5, NSMinY(r) + 8.8)];
        [tick lineToPoint:NSMakePoint(NSMinX(r) + 9.8, NSMinY(r) + 3.9)];
        tick.lineWidth = 1.6;
        tick.lineCapStyle = NSLineCapStyleRound;
        tick.lineJoinStyle = NSLineJoinStyleRound;
        [NSColor.whiteColor setStroke];
        [tick stroke];
        return;
    }
    [(dark ? [NSColor colorWithSRGBRed:0x3a / 255.0 green:0x3a / 255.0 blue:0x3d / 255.0 alpha:1] : NSColor.whiteColor) setFill];
    [box fill];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:3 yRadius:3];
    border.lineWidth = 1;
    [(dark ? [NSColor colorWithWhite:1 alpha:0.22] : [NSColor colorWithWhite:0 alpha:0.28]) setStroke];
    [border stroke];
}

@implementation GridCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    return self;
}


- (void)setText:(NSAttributedString *)text { _text = [text copy]; self.needsDisplay = YES; }
- (void)setFill:(NSColor *)fill { _fill = fill; self.needsDisplay = YES; }
- (void)setRing:(BOOL)ring { _ring = ring; self.needsDisplay = YES; }
- (void)setBadge:(CellBadge)badge { _badge = badge; self.needsDisplay = YES; }
- (void)setCheckbox:(CellCheckbox)checkbox { _checkbox = checkbox; self.needsDisplay = YES; }

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
    BOOL dark = IsDark(self);
    NSAttributedString *text = _text;
    NSDictionary *attrs = text.length ? [text attributesAtIndex:0 effectiveRange:NULL] : @{};
    NSFont *font = attrs[NSFontAttributeName];
    CGFloat height = NSHeight(self.bounds), left = _checkbox ? CheckboxEnd : 8;
    CGFloat width = NSWidth(self.bounds) - left - 8 - (_badge ? BadgeSize + BadgeGap : 0), line = ceil(font.ascender - font.descender + font.leading);
    if (_checkbox) DrawCheckbox(_checkbox == CellCheckboxOn, NSMakeRect(8, floor((height - 13) / 2), 13, 13), dark);
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
    [text drawWithRect:NSMakeRect(left, floor((height - line) / 2), width, line) options:NSStringDrawingUsesLineFragmentOrigin];
    _badgeRect = NSZeroRect;
    if (_badge) { // right after the text; after right-aligned (numeric) text that is the right edge
        NSParagraphStyle *style = attrs[NSParagraphStyleAttributeName];
        CGFloat textWidth = font ? MIN(text.length * charWidths[font].doubleValue, width) : width;
        CGFloat x = style.alignment == NSTextAlignmentRight ? NSWidth(self.bounds) - 8 - BadgeSize : left + textWidth + BadgeGap;
        _badgeRect = NSMakeRect(x, floor((height - BadgeSize) / 2), BadgeSize, BadgeSize);
        DrawBadge(_badge, _badgeRect, dark);
    }
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
        _booleanTrue = @"t";
        _booleanFalse = @"f";
        _defaultColumns = [NSIndexSet new];
        _numericColumns = [NSIndexSet new];
        _referenceColumns = [NSIndexSet new];
        _fileColumns = [NSIndexSet new];
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
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"" action:@selector(deleteClickedRows:) keyEquivalent:@""].target = self; // titled in validateMenuItem
    return menu;
}

// Right-click "Delete Row": the clicked row, or the whole selection when the click is inside it.
- (NSIndexSet *)rowsForClickedRow:(NSInteger)row {
    return [_table.selectedRowIndexes containsIndex:row] ? _table.selectedRowIndexes : [NSIndexSet indexSetWithIndex:row];
}

// Like ⌫: deletes those rows, or restores them when all of them are already marked as deleted.
- (void)toggleDeletionFromRow:(NSInteger)row {
    if (row < 0 || row >= _table.numberOfRows) return;
    [_table selectRowIndexes:[self rowsForClickedRow:row] byExtendingSelection:NO];
    [self deleteSelectedRows];
}

- (void)deleteClickedRows:(id)sender {
    [self toggleDeletionFromRow:_table.clickedRow];
}

- (NSString *)deleteTitleForRow:(NSInteger)row {
    NSIndexSet *rows = [self rowsForClickedRow:row];
    NSIndexSet *existing = [rows indexesPassingTest:^BOOL(NSUInteger i, BOOL *stop) { return i < self->_result.rows.count; }];
    BOOL restore = existing.count && [_deleted containsIndexes:existing];
    return restore ? LN(@"Restore %lu rows", rows.count) : LN(@"Delete %lu rows", rows.count);
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
    [self redrawAllCells];
}

- (void)setHighlightedValues:(NSDictionary<NSNumber *, NSSet<NSString *> *> *)values {
    if (values == _highlightedValues || [values isEqual:_highlightedValues]) return;
    _highlightedValues = [values copy];
    [self redrawAllCells];
}

- (void)redrawAllCells {
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
    // a click on the checkbox of a boolean, or on the ↗ / 🖼 badge
    NSRect cell = [self cellRectForRow:row column:col];
    NSPoint click = [_table convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
    if (click.x < NSMinX(cell) + CheckboxEnd - 2 && [self isBoolAtColumn:col] && _editable && ![_deleted containsIndex:row])
        return [self toggleRow:row column:col];
    GridCellView *view = [_table viewAtColumn:[self tableColumn:col] row:row makeIfNecessary:NO];
    NSRect badge = NSInsetRect(view.badgeRect, -3, -4); // a little slack around the 15 pt badge
    if (view.badge && NSPointInRect([view convertPoint:click fromView:_table], badge)) {
        if ([self hasReferenceAtRow:row column:col] && _onOpenReference) return _onOpenReference(row, col, cell);
        if ([self hasFileValue:[self valueAtRow:row column:col] column:col]) return _onOpenFile(row, col, cell);
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
            self.table.tableColumns[index].width = MAX(self.table.tableColumns[index].width, 72);
    }];
    [_table reloadData];
}

- (BOOL)isBoolAtColumn:(NSInteger)col {
    return [_columnKinds[@(col)] isEqual:TBKindBool];
}

// true → false → true; NULL (or unset) → true. Set NULL is in the context menu.
- (void)toggleRow:(NSInteger)row column:(NSInteger)col {
    id value = [self valueAtRow:row column:col];
    [self setValue:IsTrue(value) ? _booleanFalse : _booleanTrue row:row column:col];
}

- (NSRect)cellRectForRow:(NSInteger)row column:(NSInteger)col {
    return [_table frameOfCellAtColumn:[self tableColumn:col] row:row];
}

- (void)setFileColumns:(NSIndexSet *)fileColumns {
    _fileColumns = [fileColumns copy];
    [_table reloadData];
}

- (void)setDetectsFileKeys:(BOOL)detectsFileKeys {
    _detectsFileKeys = detectsFileKeys;
    [_table reloadData];
}

- (BOOL)hasFileValue:(id)value column:(NSInteger)col {
    if (!_onOpenFile || ![value isKindOfClass:NSString.class] || ![value length]) return NO;
    if ([_fileColumns containsIndex:col]) return ![value isEqual:@"[]"]; // a multi file field without files
    return _detectsFileKeys && FileKeysInValue(value).count > 0;
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
        // a value that isn't a date (e.g. Unix seconds in an SQLite DATETIME column) is edited as text
        id value = [self valueAtRow:row column:col];
        BOOL parses = ![value isKindOfClass:NSString.class] || TBDateFromValue(value, kind) != nil;
        if (_onPickDate && parses) return _onPickDate(row, col, [self cellRectForRow:row column:col], kind);
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
    if (item.action == @selector(deleteClickedRows:)) {
        item.hidden = !_editable;
        [item.menu itemAtIndex:[item.menu indexOfItem:item] - 1].hidden = !_editable; // its separator
        if (_table.clickedRow >= 0) item.title = [self deleteTitleForRow:_table.clickedRow];
        return _editable && _table.clickedRow >= 0;
    }
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
        cell.badge = CellBadgeNone;
        cell.checkbox = CellCheckboxNone;
        return cell;
    }

    NSInteger col = column.identifier.integerValue;
    BOOL edited = !inserted && _edits[@(row)][@(col)] != nil;
    id value = [self valueAtRow:row column:col];
    BOOL isDefault = !value && [_defaultColumns containsIndex:col];
    BOOL placeholder = ![value isKindOfClass:NSString.class];

    BOOL isBool = [self isBoolAtColumn:col] && !isDefault; // NULL gets an empty box too
    NSString *text;
    if (isDefault) text = @"DEFAULT";
    else if (placeholder) text = _nullText;
    else if (isBool) text = IsTrue(value) ? @"true" : @"false"; // Postgres prints t / f, SQLite 1 / 0
    else {
        // Only what fits in the column (monospace: ~7.2 pt per character) gets laid out.
        NSUInteger fits = (NSUInteger)(column.width / 7) + 2;
        text = [value length] > fits ? [value substringToIndex:fits] : value;
        text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" ⏎ "];
    }
    NSMutableDictionary *attrs = [@{
        NSFontAttributeName: isDefault ? small : placeholder ? italic : regular,
        NSForegroundColorAttributeName: placeholder ? NSColor.tertiaryLabelColor
                                        : (_columnColors[@(col)] ?: isBool ? NSColor.secondaryLabelColor : NSColor.labelColor),
        NSParagraphStyleAttributeName: [_numericColumns containsIndex:col] ? right : left,
    } mutableCopy];
    if (deleted) attrs[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
    NSMutableAttributedString *shown = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs];
    if (!placeholder && [_highlightedValues[@(col)] containsObject:value]) // matched through the row this key points to
        [shown addAttribute:NSBackgroundColorAttributeName value:Theme.findHighlight range:NSMakeRange(0, text.length)];
    else if (_highlight.length && !placeholder) { // same matching as the search: anywhere, ignoring case
        NSRange search = NSMakeRange(0, text.length), found;
        while ((found = [text rangeOfString:_highlight options:NSCaseInsensitiveSearch range:search]).location != NSNotFound) {
            [shown addAttribute:NSBackgroundColorAttributeName value:Theme.findHighlight range:found];
            search = NSMakeRange(NSMaxRange(found), text.length - NSMaxRange(found));
        }
    }
    cell.text = shown;
    cell.fill = rowFill ?: (edited ? Theme.changed : nil);
    cell.ring = row == _ringRow && col == _selectedColumn && !deleted;
    cell.checkbox = !isBool ? CellCheckboxNone : IsTrue(value) ? CellCheckboxOn : CellCheckboxOff;
    cell.badge = placeholder ? CellBadgeNone
               : [_referenceColumns containsIndex:col] ? CellBadgeReference
               : [self hasFileValue:value column:col] || (_onOpenImage && ImageValueDetected(value)) ? CellBadgeImage : CellBadgeNone;
    return cell;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    NSSortDescriptor *sort = tableView.sortDescriptors.firstObject;
    if (_ignoreSortChange || !sort || !_onSort) return;
    _onSort(sort.key, sort.ascending);
}

@end

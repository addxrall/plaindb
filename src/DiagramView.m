#import "DiagramView.h"
#import "UI.h"

static const CGFloat Margin = 24; // as SchemaLayout's

static BOOL IsDefaultSchema(NSString *schema) {
    return [schema isEqual:@"public"] || [schema isEqual:@"main"];
}

@implementation DiagramView {
    SchemaTable *_dragged;
    NSPoint _grab;    // where in the dragged box the mouse went down
    BOOL _didDrag;
    NSString *_menuColumn; // the column row the box menu was opened on
    BOOL _panning;
    NSPoint _panStart, _panOrigin; // where the pan began, in window coordinates, and the clip view's origin then
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)setGraph:(SchemaGraph *)graph {
    _graph = graph;
    _selected = nil;
    [self fitToContent];
    self.needsDisplay = YES;
}

- (void)setSelected:(SchemaTable *)selected {
    _selected = selected;
    self.needsDisplay = YES;
}

- (NSRect)contentRect {
    NSRect content = NSZeroRect;
    for (SchemaTable *t in _graph.tables) content = NSUnionRect(content, t.frame);
    return NSIsEmptyRect(content) ? NSZeroRect : NSMakeRect(0, 0, NSMaxX(content) + Margin, NSMaxY(content) + Margin);
}

- (void)fitToContent {
    NSRect content = self.contentRect;
    NSScrollView *scroll = self.enclosingScrollView;
    NSSize visible = scroll ? scroll.contentView.bounds.size : NSZeroSize; // in the view's coordinates, so zoom-aware
    [self setFrameSize:NSMakeSize(MAX(NSWidth(content), visible.width), MAX(NSHeight(content), visible.height))];
}

// Zooming out or a bigger window shows more of the document: the view grows to fill it (so clicks there still
// reach it), and shrinks back to the boxes when zooming in again.
- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    NSScrollView *scroll = self.enclosingScrollView;
    if (!scroll) return;
    scroll.contentView.postsFrameChangedNotifications = YES;
    for (NSArray *n in @[@[NSScrollViewDidEndLiveMagnifyNotification, scroll], @[NSViewFrameDidChangeNotification, scroll.contentView]])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scrollViewChanged:) name:n[0] object:n[1]];
}

- (void)scrollViewChanged:(NSNotification *)notification {
    [self fitToContent];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Drawing

// Middle of a column's row in a box (the "+ N more" row for columns past the cap, the header if missing).
static CGFloat RowY(SchemaTable *t, NSString *column) {
    NSUInteger i = [t.columns indexOfObjectPassingTest:^BOOL(NSArray *c, NSUInteger idx, BOOL *stop) { return [c[0] isEqual:column]; }];
    if (i == NSNotFound) return NSMinY(t.frame) + SchemaHeaderHeight / 2;
    return NSMinY(t.frame) + SchemaHeaderHeight + (MIN(i, SchemaMaxRows) + 0.5) * SchemaRowHeight;
}

- (void)drawEdge:(SchemaEdge *)e {
    BOOL lit = _selected && (e.from == _selected || e.to == _selected);
    NSRect from = e.from.frame, to = e.to.frame;
    CGFloat y1 = RowY(e.from, e.column), y2 = RowY(e.to, e.referencedColumn);
    NSPoint start, end;
    CGFloat out1, out2; // which way the curve leaves the start and enters the end (-1 left, +1 right)
    if (NSMinX(from) >= NSMaxX(to)) { // the usual case: the referenced table stands to the left
        start = NSMakePoint(NSMinX(from), y1), end = NSMakePoint(NSMaxX(to), y2), out1 = -1, out2 = 1;
    } else if (NSMaxX(from) <= NSMinX(to)) {
        start = NSMakePoint(NSMaxX(from), y1), end = NSMakePoint(NSMinX(to), y2), out1 = 1, out2 = -1;
    } else { // same column (or itself): a loop on the right
        start = NSMakePoint(NSMaxX(from), y1), end = NSMakePoint(NSMaxX(to), y2), out1 = 1, out2 = 1;
    }
    CGFloat pull = MAX(40, fabs(end.x - start.x) / 2);
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:start];
    [path curveToPoint:end controlPoint1:NSMakePoint(start.x + out1 * pull, start.y) controlPoint2:NSMakePoint(end.x + out2 * pull, end.y)];
    path.lineWidth = lit ? 2 : 1.2;
    if (e.many) { // several references in one column (a PocketBase multi relation)
        CGFloat dash[] = {5, 4};
        [path setLineDash:dash count:2 phase:0];
    }
    NSColor *color = lit ? NSColor.controlAccentColor : Theme.text3;
    [color setStroke];
    [path stroke];
    // a dot at the key column, an arrow head at the referenced table
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(start.x - 3, start.y - 3, 6, 6)] fill];
    NSBezierPath *head = [NSBezierPath bezierPath];
    [head moveToPoint:end];
    [head lineToPoint:NSMakePoint(end.x + out2 * 8, end.y - 4.5)];
    [head lineToPoint:NSMakePoint(end.x + out2 * 8, end.y + 4.5)];
    [head closePath];
    [head fill];
}

- (void)drawTable:(SchemaTable *)t {
    NSRect box = t.frame;
    BOOL selected = t == _selected;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:box xRadius:8 yRadius:8];
    [Theme.box setFill];
    [outline fill];

    // header
    NSRect header = NSMakeRect(NSMinX(box), NSMinY(box), NSWidth(box), SchemaHeaderHeight);
    [NSGraphicsContext saveGraphicsState];
    [outline addClip];
    [Theme.head setFill];
    NSRectFill(header);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(NSMinX(box), NSMaxY(header) - 1, NSWidth(box), 1));
    [NSGraphicsContext restoreGraphicsState];
    NSMutableAttributedString *title = [NSMutableAttributedString new];
    if (!IsDefaultSchema(t.schema))
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[t.schema stringByAppendingString:@"."] attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightRegular], NSForegroundColorAttributeName: Theme.text3}]];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:t.name attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor}]];
    [title drawWithRect:NSMakeRect(NSMinX(box) + 10, NSMinY(box) + 7, NSWidth(box) - 20, 17)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];

    // rows: key / arrow glyph, name, type
    static NSDictionary *nameAttrs, *typeAttrs, *moreAttrs, *pkAttrs, *fkAttrs;
    if (!nameAttrs) {
        NSMutableParagraphStyle *right = [NSMutableParagraphStyle new];
        right.alignment = NSTextAlignmentRight;
        right.lineBreakMode = NSLineBreakByTruncatingTail;
        nameAttrs = @{NSFontAttributeName: [Theme mono:11.5], NSForegroundColorAttributeName: NSColor.labelColor};
        typeAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:10.5], NSForegroundColorAttributeName: Theme.text3,
                      NSParagraphStyleAttributeName: right};
        moreAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: Theme.text3};
        pkAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold], NSForegroundColorAttributeName: Theme.orange};
        fkAttrs = @{NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.controlAccentColor};
    }
    NSUInteger shown = MIN(t.columns.count, SchemaMaxRows);
    for (NSUInteger i = 0; i < shown; i++) {
        NSArray *c = t.columns[i];
        CGFloat y = NSMinY(box) + SchemaHeaderHeight + i * SchemaRowHeight + 3;
        BOOL pk = [c[2] isEqual:@"PK"], fk = [t.foreignKeyColumns containsObject:c[0]];
        if (pk || fk) [(pk ? @"PK" : @"FK") drawAtPoint:NSMakePoint(NSMinX(box) + 8, y + 2) withAttributes:pk ? pkAttrs : fkAttrs];
        [c[0] drawWithRect:NSMakeRect(NSMinX(box) + 30, y, 112, 15) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                attributes:nameAttrs];
        [c[1] drawWithRect:NSMakeRect(NSMinX(box) + 146, y + 1, NSWidth(box) - 156, 15)
                   options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:typeAttrs];
    }
    if (t.columns.count > SchemaMaxRows)
        [[NSString stringWithFormat:L(@"+ %lu more"), (unsigned long)(t.columns.count - SchemaMaxRows)]
            drawAtPoint:NSMakePoint(NSMinX(box) + 30, NSMinY(box) + SchemaHeaderHeight + SchemaMaxRows * SchemaRowHeight + 3) withAttributes:moreAttrs];

    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, selected ? 1 : 0.5, selected ? 1 : 0.5) xRadius:8 yRadius:8];
    border.lineWidth = selected ? 2 : 1;
    [(selected ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke];
    [border stroke];
}

- (void)drawRect:(NSRect)dirty {
    [Theme.editor setFill];
    NSRectFill(dirty);
    for (SchemaEdge *e in _graph.edges)
        if (e.from && e.to) [self drawEdge:e];
    for (SchemaTable *t in _graph.tables)
        if (NSIntersectsRect(t.frame, dirty) && t != _selected) [self drawTable:t];
    if (_selected) [self drawTable:_selected]; // on top
}

#pragma mark - Mouse

- (SchemaTable *)tableAt:(NSPoint)p {
    if (_selected && NSPointInRect(p, _selected.frame)) return _selected;
    for (SchemaTable *t in _graph.tables.reverseObjectEnumerator)
        if (NSPointInRect(p, t.frame)) return t;
    return nil;
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    SchemaTable *hit = [self tableAt:p];
    if (event.clickCount == 2 && hit) {
        if (self.onShowNeighbours) self.onShowNeighbours(hit);
        return;
    }
    self.selected = hit;
    if (self.onSelect) self.onSelect(hit);
    if (!hit) return [self beginPan:event];
    _dragged = hit;
    _grab = NSMakePoint(p.x - NSMinX(hit.frame), p.y - NSMinY(hit.frame));
    _didDrag = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    if (_panning) return [self panTo:event];
    if (!_dragged) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect frame = _dragged.frame;
    frame.origin = NSMakePoint(MAX(0, p.x - _grab.x), MAX(0, p.y - _grab.y));
    _dragged.frame = frame;
    _didDrag = YES;
    [self fitToContent];
    [self autoscroll:event];
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)event {
    if (_panning) return [self endPan:event];
    if (_dragged && _didDrag && self.onMoved) self.onMoved(_dragged);
    _dragged = nil;
}

#pragma mark - Panning

// The empty background (left button) or anything (middle button) can be grabbed to move the view.
- (void)otherMouseDown:(NSEvent *)event {
    if (event.buttonNumber == 2) [self beginPan:event];
    else [super otherMouseDown:event];
}

- (void)otherMouseDragged:(NSEvent *)event {
    if (_panning) [self panTo:event];
    else [super otherMouseDragged:event];
}

- (void)otherMouseUp:(NSEvent *)event {
    if (_panning) [self endPan:event];
    else [super otherMouseUp:event];
}

- (void)beginPan:(NSEvent *)event {
    _panning = YES;
    _panStart = event.locationInWindow;
    _panOrigin = self.enclosingScrollView.contentView.bounds.origin;
    [NSCursor.closedHandCursor set];
}

- (void)panTo:(NSEvent *)event {
    NSScrollView *scroll = self.enclosingScrollView;
    NSClipView *clip = scroll.contentView;
    NSPoint p = event.locationInWindow;
    CGFloat zoom = scroll.magnification;
    // the document follows the mouse; the view is flipped, window coordinates aren't
    NSRect bounds = clip.bounds;
    bounds.origin = NSMakePoint(_panOrigin.x - (p.x - _panStart.x) / zoom, _panOrigin.y + (p.y - _panStart.y) / zoom);
    [clip scrollToPoint:[clip constrainBoundsRect:bounds].origin];
    [scroll reflectScrolledClipView:clip];
}

- (void)endPan:(NSEvent *)event {
    _panning = NO;
    [self updateCursor:event];
}

// An open hand over the background says it can be grabbed.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                       options:NSTrackingMouseMoved | NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                         owner:self userInfo:nil]];
}

- (void)cursorUpdate:(NSEvent *)event {
    [self updateCursor:event];
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateCursor:event];
}

- (void)updateCursor:(NSEvent *)event {
    if (_panning) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [([self tableAt:p] ? NSCursor.arrowCursor : NSCursor.openHandCursor) set];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    SchemaTable *hit = [self tableAt:p];
    if (!hit) return nil;
    self.selected = hit;
    if (self.onSelect) self.onSelect(hit);
    // the column row under the click, for "Add Foreign Key…"
    NSInteger row = (NSInteger)floor((p.y - NSMinY(hit.frame) - SchemaHeaderHeight) / SchemaRowHeight);
    _menuColumn = row >= 0 && row < (NSInteger)MIN(hit.columns.count, SchemaMaxRows) ? hit.columns[row][0] : nil;
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    for (NSArray *item in @[@[L(@"Open Table"), @"openSelected:"], @[L(@"Open in New Tab"), @"openSelectedInNewTab:"],
                            @[L(@"Show Neighbours"), @"showSelectedNeighbours:"]])
        [menu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:@""].target = self;
    if (self.onAddColumn) {
        [menu addItem:NSMenuItem.separatorItem];
        for (NSArray *item in @[@[L(@"Add Column…"), @"addColumn:", self.addColumnBlockedReason ?: @""],
                                @[L(@"Add Foreign Key…"), @"addForeignKey:", self.addForeignKeyBlockedReason ?: @""]]) {
            NSMenuItem *m = [menu addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:@""];
            m.target = self;
            m.enabled = ![item[2] length];
            m.toolTip = [item[2] length] ? item[2] : nil;
        }
    }
    return menu;
}

- (void)addColumn:(id)sender {
    if (_selected && self.onAddColumn) self.onAddColumn(_selected);
}

- (void)addForeignKey:(id)sender {
    if (_selected && self.onAddForeignKey) self.onAddForeignKey(_selected, _menuColumn);
}

- (void)openSelected:(id)sender {
    if (_selected && self.onOpen) self.onOpen(_selected);
}

- (void)openSelectedInNewTab:(id)sender {
    if (_selected && self.onOpenInNewTab) self.onOpenInNewTab(_selected);
}

- (void)showSelectedNeighbours:(id)sender {
    if (_selected && self.onShowNeighbours) self.onShowNeighbours(_selected);
}

#pragma mark - Zoom

// ⌘+ / ⌘= zoom in, ⌘− zoom out, ⌘0 fit everything; pinching works through the scroll view.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSScrollView *scroll = self.enclosingScrollView;
    if (!(event.modifierFlags & NSEventModifierFlagCommand) || !scroll || self.window.firstResponder != self) return [super performKeyEquivalent:event];
    NSString *key = event.charactersIgnoringModifiers;
    if ([key isEqual:@"+"] || [key isEqual:@"="]) scroll.magnification = MIN(scroll.magnification * 1.25, scroll.maxMagnification);
    else if ([key isEqual:@"-"]) scroll.magnification = MAX(scroll.magnification / 1.25, scroll.minMagnification);
    else if ([key isEqual:@"0"]) {
        NSRect content = NSZeroRect;
        for (SchemaTable *t in _graph.tables) content = NSUnionRect(content, t.frame);
        if (!NSIsEmptyRect(content)) [scroll magnifyToFitRect:NSInsetRect(content, -Margin, -Margin)];
    } else return [super performKeyEquivalent:event];
    [self fitToContent];
    return YES;
}

// ⌘ + mouse wheel zooms around the cursor; without ⌘ the wheel scrolls as usual.
- (void)scrollWheel:(NSEvent *)event {
    NSScrollView *scroll = self.enclosingScrollView;
    if (!(event.modifierFlags & NSEventModifierFlagCommand) || !scroll) return [super scrollWheel:event];
    // a wheel notch is about one line; a trackpad reports points
    CGFloat factor = event.hasPreciseScrollingDeltas ? pow(1.005, event.scrollingDeltaY) : pow(1.1, event.deltaY);
    CGFloat zoom = MIN(MAX(scroll.magnification * factor, scroll.minMagnification), scroll.maxMagnification);
    [scroll setMagnification:zoom centeredAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    [self fitToContent];
}

@end

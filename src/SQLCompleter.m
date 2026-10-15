#import "SQLCompleter.h"
#import "SQLCompletion.h"
#import "UI.h"

static const CGFloat RowHeight = 22, ListWidth = 340;
static const NSUInteger VisibleRows = 9;

// Accent selection that stays blue although the text view, not the list, has the focus.
@interface CompletionRowView : NSTableRowView
@end

@implementation CompletionRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [NSColor.controlAccentColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1) xRadius:4 yRadius:4] fill];
}
@end

@interface SQLCompleter () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SQLCompleter {
    __weak NSTextView *_textView;
    NSPanel *_panel;
    NSTableView *_list;
    NSArray<SQLSuggestion *> *_items;
    NSInteger _chosen; // kept here: a table in a window that isn't on screen yet drops its selection
    NSRange _replace;  // the word being completed
    BOOL _inserting;
    id _monitor;
}

- (instancetype)initWithTextView:(NSTextView *)textView {
    if ((self = [super init])) {
        _textView = textView;
        textView.delegate = self;
        __weak SQLCompleter *weakSelf = self;
        // ⌃Space opens the list, as in most editors
        _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            SQLCompleter *strongSelf = weakSelf;
            NSTextView *view = strongSelf ? strongSelf->_textView : nil;
            BOOL ctrlSpace = (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagControl && event.keyCode == 49;
            if (!ctrlSpace || !view || view.window.firstResponder != view) return event;
            [strongSelf show];
            return nil;
        }];
    }
    return self;
}

- (void)dealloc {
    if (_monitor) [NSEvent removeMonitor:_monitor];
    [_panel close];
}

- (BOOL)isShown {
    return _panel.isVisible;
}

#pragma mark - List window

- (void)buildPanel {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, ListWidth, RowHeight * VisibleRows)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered defer:YES];
    _panel.hasShadow = YES;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.opaque = NO;
    _panel.releasedWhenClosed = NO;
    NSVisualEffectView *background = [NSVisualEffectView new];
    background.material = NSVisualEffectMaterialMenu;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 8;
    background.layer.masksToBounds = YES;
    _list = [NSTableView new];
    _list.headerView = nil;
    _list.rowHeight = RowHeight;
    _list.intercellSpacing = NSMakeSize(0, 0);
    _list.backgroundColor = NSColor.clearColor;
    _list.style = NSTableViewStylePlain;
    _list.refusesFirstResponder = YES;
    [_list addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"item"]];
    _list.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    _list.dataSource = self;
    _list.delegate = self;
    _list.target = self;
    _list.doubleAction = @selector(accept);
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = _list;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    TBPin(scroll, background, NSEdgeInsetsMake(4, 0, 4, 0));
    _panel.contentView = background;
}

- (void)show {
    [self updateShowingEmpty:YES];
}

- (void)hide {
    if (_panel.isVisible) [_textView.window removeChildWindow:_panel];
    [_panel orderOut:nil];
}

// Recomputes the list for the cursor; `force` also shows it with no word typed (⌃Space).
- (void)updateShowingEmpty:(BOOL)force {
    NSTextView *view = _textView;
    if (!view || view.selectedRange.length) return [self hide];
    NSUInteger cursor = view.selectedRange.location;
    NSRange replace;
    NSArray *items = SQLSuggestionsAt(view.string, cursor, _schema, force, &replace);
    if (!items.count) return [self hide];
    _items = items;
    _chosen = 0;
    _replace = replace;
    if (!_panel) [self buildPanel];
    [_list reloadData];
    [_list scrollRowToVisible:0];
    // under the start of the word, flipped above it near the bottom of the screen
    NSRect word = [view firstRectForCharacterRange:NSMakeRange(replace.location, 0) actualRange:NULL];
    CGFloat height = RowHeight * MIN(items.count, VisibleRows) + 8;
    NSRect frame = NSMakeRect(NSMinX(word) - 6, NSMinY(word) - height - 2, ListWidth, height);
    NSRect screen = view.window.screen.visibleFrame;
    if (NSMinY(frame) < NSMinY(screen)) frame.origin.y = NSMaxY(word) + 2;
    [_panel setFrame:frame display:YES];
    if (!_panel.isVisible) [view.window addChildWindow:_panel ordered:NSWindowAbove];
}

- (void)accept {
    NSInteger row = _chosen;
    NSTextView *view = _textView;
    if (row < 0 || row >= (NSInteger)_items.count || !view) return [self hide];
    NSString *text = _items[row].text;
    BOOL call = [text hasSuffix:@"("];
    _inserting = YES;
    [view insertText:call ? [text stringByAppendingString:@")"] : text replacementRange:_replace];
    if (call) view.selectedRange = NSMakeRange(view.selectedRange.location - 1, 0); // between the parentheses
    _inserting = NO;
    [self hide];
}

#pragma mark - Text view delegate

- (void)textDidChange:(NSNotification *)notification {
    if (_inserting) return;
    NSTextView *view = _textView;
    NSUInteger cursor = view.selectedRange.location;
    unichar typed = cursor > 0 && cursor <= view.string.length ? [view.string characterAtIndex:cursor - 1] : 0;
    BOOL word = typed == '.' || typed == '_' || [NSCharacterSet.alphanumericCharacterSet characterIsMember:typed];
    if (word || self.isShown) [self updateShowingEmpty:NO];
}

// Moving the cursor away from the word closes the list.
- (void)textViewDidChangeSelection:(NSNotification *)notification {
    if (!self.isShown || _inserting) return;
    NSRange sel = _textView.selectedRange;
    if (sel.length || sel.location < _replace.location || sel.location > NSMaxRange(_replace) + 1) [self hide];
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (!self.isShown) {
        if (selector == @selector(complete:)) { [self show]; return YES; } // Esc / ⌥Esc
        return NO;
    }
    NSInteger count = _items.count;
    if (selector == @selector(moveDown:) || selector == @selector(moveUp:)) {
        [self choose:MAX(0, MIN(count - 1, _chosen + (selector == @selector(moveDown:) ? 1 : -1)))];
        return YES;
    }
    if (selector == @selector(insertNewline:) || selector == @selector(insertTab:)) { [self accept]; return YES; }
    if (selector == @selector(cancelOperation:) || selector == @selector(complete:)) { [self hide]; return YES; }
    return NO;
}

#pragma mark - List

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _items.count;
}

- (void)choose:(NSInteger)row {
    NSInteger previous = _chosen;
    _chosen = row;
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSetWithIndex:row];
    if (previous >= 0 && previous < (NSInteger)_items.count) [rows addIndex:previous];
    [_list reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    [_list scrollRowToVisible:row];
}

// A click picks a row; a double-click inserts it.
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    [self choose:row];
    return NO;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    CompletionRowView *view = [CompletionRowView new];
    view.selected = row == _chosen;
    return view;
}

// kind badge · name · detail (type and table, dimmed, right)
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    SQLSuggestion *s = _items[row];
    BOOL selected = row == _chosen;
    [tableView rowViewAtRow:row makeIfNecessary:NO].selected = selected;
    NSArray *badges = @[@[@"C", NSColor.controlAccentColor], @[@"T", Theme.green], @[@"ƒ", Theme.sqlFunction], @[@"K", Theme.sqlKeyword]];
    NSTextField *badge = TBLabel(badges[s.kind][0], 10, NSFontWeightBold, selected ? NSColor.whiteColor : badges[s.kind][1]);
    badge.alignment = NSTextAlignmentCenter;
    NSTextField *name = TBLabel(s.text, 12, NSFontWeightRegular, selected ? NSColor.whiteColor : NSColor.labelColor);
    name.font = [Theme mono:12];
    NSTextField *detail = TBLabel(s.detail, 11, NSFontWeightRegular, selected ? [NSColor colorWithWhite:1 alpha:0.8] : NSColor.tertiaryLabelColor);
    detail.alignment = NSTextAlignmentRight;
    NSView *cell = [NSView new];
    for (NSView *v in @[badge, name, detail]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:v];
    }
    [detail setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [badge.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:10],
        [badge.widthAnchor constraintEqualToConstant:14],
        [name.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:8],
        [detail.leadingAnchor constraintGreaterThanOrEqualToAnchor:name.trailingAnchor constant:10],
        [detail.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
        [badge.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [name.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [detail.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

@end

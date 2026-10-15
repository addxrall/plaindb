#import "JSONInspector.h"
#import "DBConnection.h"
#import "SQLText.h"
#import "UI.h"

@implementation JSONNode
@end

#pragma mark - Parsing and formatting

static BOOL IsSpace(unichar c) {
    return c == ' ' || c == '\n' || c == '\r' || c == '\t';
}

BOOL JSONIsValid(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *s = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!([s hasPrefix:@"{"] || [s hasPrefix:@"["])) return NO;
    return [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] != nil;
}

typedef struct {
    const unichar *s;
    NSUInteger n, i;
} Cursor;

static void SkipSpace(Cursor *c) {
    while (c->i < c->n && IsSpace(c->s[c->i])) c->i++;
}

// At an opening quote. Unescaping is left to NSJSONSerialization, which knows all the escapes.
static NSString *ParseString(Cursor *c) {
    NSUInteger start = c->i++;
    while (c->i < c->n) {
        unichar ch = c->s[c->i];
        if (ch == '\\') c->i += 2;
        else if (ch == '"') {
            c->i++;
            NSString *raw = [NSString stringWithCharacters:c->s + start length:c->i - start];
            id value = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding]
                                                       options:NSJSONReadingFragmentsAllowed error:nil];
            return [value isKindOfClass:NSString.class] ? value : nil;
        } else c->i++;
    }
    return nil;
}

static JSONNode *ParseValue(Cursor *c, int depth) {
    SkipSpace(c);
    if (c->i >= c->n || depth > 256) return nil;
    JSONNode *node = [JSONNode new];
    node.children = [NSMutableArray new];
    unichar ch = c->s[c->i];
    if (ch == '{' || ch == '[') {
        BOOL object = ch == '{';
        unichar close = object ? '}' : ']';
        node.kind = object ? @"object" : @"array";
        c->i++;
        SkipSpace(c);
        if (c->i < c->n && c->s[c->i] == close) {
            c->i++;
            return node;
        }
        while (YES) {
            NSString *key = nil;
            if (object) {
                SkipSpace(c);
                if (c->i >= c->n || c->s[c->i] != '"' || !(key = ParseString(c))) return nil;
                SkipSpace(c);
                if (c->i >= c->n || c->s[c->i] != ':') return nil;
                c->i++;
            }
            JSONNode *child = ParseValue(c, depth + 1);
            if (!child) return nil;
            child.key = key;
            child.index = node.children.count;
            [node.children addObject:child];
            SkipSpace(c);
            if (c->i >= c->n) return nil;
            unichar next = c->s[c->i++];
            if (next == close) return node;
            if (next != ',') return nil;
        }
    }
    if (ch == '"') {
        NSString *s = ParseString(c);
        if (!s) return nil;
        node.kind = @"string";
        node.text = s;
        return node;
    }
    NSUInteger start = c->i;
    while (c->i < c->n && c->s[c->i] < 128 && (isalnum(c->s[c->i]) || strchr("+-.", c->s[c->i]))) c->i++;
    NSString *word = [NSString stringWithCharacters:c->s + start length:c->i - start];
    if ([word isEqual:@"true"] || [word isEqual:@"false"]) node.kind = @"bool";
    else if ([word isEqual:@"null"]) node.kind = @"null";
    else if (word.length && [[NSScanner scannerWithString:word] scanDouble:NULL]) node.kind = @"number";
    else return nil;
    node.text = word;
    return node;
}

JSONNode *JSONParse(NSString *text) {
    NSUInteger n = text.length;
    unichar *buffer = malloc(MAX(n, 1) * sizeof(unichar));
    [text getCharacters:buffer range:NSMakeRange(0, n)];
    Cursor c = {buffer, n, 0};
    JSONNode *root = ParseValue(&c, 0);
    SkipSpace(&c);
    free(buffer);
    return c.i == n ? root : nil;
}

// Walks the text and calls `token` for every character outside whitespace, with string contents passed through.
static NSString *Reformat(NSString *text, BOOL pretty) {
    NSUInteger n = text.length;
    unichar *s = malloc(MAX(n, 1) * sizeof(unichar));
    [text getCharacters:s range:NSMakeRange(0, n)];
    CFMutableStringRef out = CFStringCreateMutable(NULL, 0);
    NSInteger indent = 0;
    BOOL inString = NO, escape = NO;
    void (^put)(unichar) = ^(unichar ch) { CFStringAppendCharacters(out, &ch, 1); };
    void (^newline)(NSInteger) = ^(NSInteger level) {
        put('\n');
        for (NSInteger k = 0; k < level * 2; k++) put(' ');
    };
    for (NSUInteger i = 0; i < n; i++) {
        unichar ch = s[i];
        if (inString) {
            put(ch);
            if (escape) escape = NO;
            else if (ch == '\\') escape = YES;
            else if (ch == '"') inString = NO;
            continue;
        }
        if (IsSpace(ch)) continue;
        if (ch == '"') inString = YES;
        if (!pretty) {
            put(ch);
            continue;
        }
        if (ch == '{' || ch == '[') {
            put(ch);
            NSUInteger j = i + 1;
            while (j < n && IsSpace(s[j])) j++;
            if (j < n && (s[j] == '}' || s[j] == ']')) { // empty container stays on one line
                put(s[j]);
                i = j;
            } else newline(++indent);
        } else if (ch == '}' || ch == ']') {
            newline(--indent);
            put(ch);
        } else if (ch == ',') {
            put(ch);
            newline(indent);
        } else if (ch == ':') {
            put(':');
            put(' ');
        } else put(ch);
    }
    free(s);
    return CFBridgingRelease(out);
}

NSString *JSONPretty(NSString *text) {
    return Reformat(text, YES);
}

NSString *JSONMinify(NSString *text) {
    return Reformat(text, NO);
}

#pragma mark - Highlighting

static void JSONHighlight(NSTextStorage *storage) {
    static NSRegularExpression *tokens;
    if (!tokens)
        tokens = [NSRegularExpression regularExpressionWithPattern:@"(\"(?:[^\"\\\\]|\\\\.)*\")(\\s*:)?|(-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b)|\\b(true|false|null)\\b"
                                                           options:0 error:nil];
    NSString *text = storage.string;
    NSRange all = NSMakeRange(0, text.length);
    static NSMutableParagraphStyle *lines;
    if (!lines) {
        lines = [NSMutableParagraphStyle new];
        lines.minimumLineHeight = lines.maximumLineHeight = 18;
    }
    [storage beginEditing];
    [storage addAttribute:NSForegroundColorAttributeName value:NSColor.labelColor range:all];
    [storage addAttribute:NSParagraphStyleAttributeName value:lines range:all];
    [tokens enumerateMatchesInString:text options:0 range:all usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if ([m rangeAtIndex:1].location != NSNotFound) {
            BOOL key = [m rangeAtIndex:2].location != NSNotFound;
            [storage addAttribute:NSForegroundColorAttributeName value:key ? Theme.sqlFunction : Theme.sqlString range:[m rangeAtIndex:1]];
        } else if ([m rangeAtIndex:3].location != NSNotFound) {
            [storage addAttribute:NSForegroundColorAttributeName value:Theme.sqlNumber range:m.range];
        } else {
            [storage addAttribute:NSForegroundColorAttributeName value:Theme.sqlKeyword range:m.range];
        }
    }];
    [storage endEditing];
}

@interface JSONHighlighter : NSObject <NSTextStorageDelegate>
@end

@implementation JSONHighlighter
- (void)textStorage:(NSTextStorage *)storage didProcessEditing:(NSTextStorageEditActions)actions range:(NSRange)range changeInLength:(NSInteger)delta {
    if (!(actions & NSTextStorageEditedCharacters)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ JSONHighlight(storage); });
}
@end

#pragma mark - Inspector

@interface JSONInspector () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation JSONInspector {
    JSONNode *_root;
    NSString *_original; // minified, to tell whether the text changed
    BOOL _editable;
    JSONHighlighter *_highlighter;

    NSTextField *_title, *_subtitle, *_status;
    NSSegmentedControl *_mode;
    TBSwitcher *_pages;
    NSOutlineView *_outline;
    NSTextView *_text;
    NSButton *_format, *_apply;
}

- (void)loadView {
    _title = TBLabel(@"", 13, NSFontWeightSemibold, NSColor.labelColor);
    _title.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightSemibold];
    _subtitle = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    for (NSTextField *label in @[_title, _subtitle]) // full text unless the panel really is too narrow
        [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titles = TBColumn(@[_title, _subtitle], nil);
    titles.spacing = 1;
    NSButton *close = TBSymbolButton(@"xmark", L(@"Close"), self, @selector(close:));
    close.bordered = NO;
    NSStackView *header = TBBar(@[titles], @[close], 46);

    _mode = [NSSegmentedControl segmentedControlWithLabels:@[L(@"Tree"), L(@"Text")]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeChanged:)];
    _mode.selectedSegment = 0;
    _mode.controlSize = NSControlSizeSmall;
    NSStackView *modeBar = TBBar(@[_mode], @[], 34);

    _outline = [NSOutlineView new];
    _outline.headerView = nil;
    _outline.style = NSTableViewStylePlain;
    _outline.rowHeight = 20;
    _outline.indentationPerLevel = 14;
    _outline.usesAlternatingRowBackgroundColors = YES;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"node"];
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    _outline.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    _outline.dataSource = self;
    _outline.delegate = self;
    NSScrollView *outlineScroll = [NSScrollView new];
    outlineScroll.documentView = _outline;
    outlineScroll.hasVerticalScroller = YES;
    outlineScroll.autohidesScrollers = YES;

    // design: no line numbers, 10 × 12 pt padding, 18 pt lines, a hairline above
    NSTextView *text;
    NSScrollView *textScroll = SQLTextScrollView(&text, YES, NO);
    _text = text;
    _text.font = [Theme mono:12];
    _text.textContainerInset = NSMakeSize(12 - _text.textContainer.lineFragmentPadding, 10); // line height: JSONHighlight
    _highlighter = [JSONHighlighter new];
    _text.textStorage.delegate = _highlighter; // JSON colours instead of SQL ones
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(textChanged:) name:NSTextDidChangeNotification object:_text];

    NSView *placeholder = TBCenteredState(@[
        [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"curlybraces" accessibilityDescription:nil]],
        TBLabel(L(@"Double-click a cell with JSON to see it here."), 12, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]);
    _pages = [[TBSwitcher alloc] initWithViews:@[outlineScroll, TBColumn(@[TBSeparator(), textScroll], textScroll), placeholder]];

    _status = TBLabel(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    _format = TBButton(L(@"Format"), self, @selector(format:));
    _apply = TBButton(L(@"Apply"), self, @selector(apply:));
    _apply.bezelColor = NSColor.controlAccentColor;
    NSStackView *footer = TBBar(@[_status], @[_format, _apply], 44);

    NSStackView *root = TBColumn(@[header, TBSeparator(), modeBar, _pages, TBSeparator(), footer], _pages);
    NSView *view = [NSView new];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor],
        [root.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [root.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        [view.widthAnchor constraintGreaterThanOrEqualToConstant:300],
    ]];
    self.view = view;
    [self showPlaceholder];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)showPlaceholder {
    [self view];
    _root = nil;
    _title.stringValue = L(@"JSON");
    _subtitle.stringValue = @"";
    _status.stringValue = @"";
    _mode.enabled = _format.enabled = _apply.enabled = NO;
    _pages.selectedIndex = 2;
}

- (void)showJSON:(NSString *)json title:(NSString *)title subtitle:(NSString *)subtitle editable:(BOOL)editable {
    [self view];
    _title.stringValue = title;
    _subtitle.stringValue = subtitle;
    _editable = editable;
    _original = JSONMinify(json);
    _root = JSONParse(json);
    [_outline reloadData];
    for (JSONNode *child in _root.children) [_outline expandItem:child]; // first level open
    _text.string = JSONPretty(json);
    JSONHighlight(_text.textStorage);
    _text.editable = editable;
    _mode.enabled = YES;
    _apply.hidden = _format.hidden = !editable;
    _format.enabled = YES;
    [self modeChanged:nil];
    [self validate];
}

#pragma mark - Actions

- (void)modeChanged:(id)sender {
    if (_mode.selectedSegment == 0 && !JSONIsValid(_text.string)) _mode.selectedSegment = 1; // no tree for broken JSON
    if (_mode.selectedSegment == 0) {
        _root = JSONParse(_text.string);
        [_outline reloadData];
        for (JSONNode *child in _root.children) [_outline expandItem:child];
    }
    _pages.selectedIndex = _mode.selectedSegment;
}

- (void)textChanged:(NSNotification *)notification {
    [self validate];
}

- (void)validate {
    NSError *error = nil;
    NSString *text = _text.string;
    BOOL valid = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error] && JSONIsValid(text);
    NSString *detail = error.userInfo[NSDebugDescriptionErrorKey] ?: error.localizedDescription;
    _status.stringValue = valid ? [@"✓ " stringByAppendingString:L(@"Valid JSON")]
                                : [NSString stringWithFormat:L(@"Invalid JSON: %@"), detail ?: @""];
    _status.textColor = valid ? Theme.green : Theme.red;
    _status.toolTip = valid ? nil : detail;
    _apply.enabled = _editable && valid && ![JSONMinify(text) isEqual:_original];
    _format.enabled = valid;
}

- (void)format:(id)sender {
    _text.string = JSONPretty(_text.string);
    JSONHighlight(_text.textStorage);
    [self validate];
}

- (void)apply:(id)sender {
    if (!_apply.enabled) return;
    _original = JSONMinify(_text.string);
    if (self.onApply) self.onApply(_original);
    [self validate];
}

- (void)close:(id)sender {
    if (self.onClose) self.onClose();
}

#pragma mark - Tree

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(JSONNode *)item {
    return (item ?: _root).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(JSONNode *)item {
    return (item ?: _root).children[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(JSONNode *)item {
    return item.children.count > 0;
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)column item:(JSONNode *)item {
    static NSFont *font, *bold;
    if (!font) {
        font = [Theme mono:12];
        bold = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    }
    NSMutableAttributedString *line = [NSMutableAttributedString new];
    void (^add)(NSString *, NSColor *, NSFont *) = ^(NSString *s, NSColor *color, NSFont *f) {
        [line appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: color}]];
    };
    if (item.key) add(item.key, NSColor.labelColor, bold);
    else add([NSString stringWithFormat:@"[%ld]", (long)item.index], NSColor.tertiaryLabelColor, font);
    add(@": ", NSColor.tertiaryLabelColor, font);
    if ([item.kind isEqual:@"object"]) add([NSString stringWithFormat:@"{%lu}", (unsigned long)item.children.count], NSColor.tertiaryLabelColor, font);
    else if ([item.kind isEqual:@"array"]) add([NSString stringWithFormat:@"[%lu]", (unsigned long)item.children.count], NSColor.tertiaryLabelColor, font);
    else if ([item.kind isEqual:@"string"]) add([NSString stringWithFormat:@"\"%@\"", [item.text stringByReplacingOccurrencesOfString:@"\n" withString:@"⏎"]], Theme.sqlString, font);
    else if ([item.kind isEqual:@"number"]) add(item.text, Theme.sqlNumber, font);
    else add(item.text, Theme.sqlKeyword, font);

    TBCellView *cell = TBCell(outlineView, @"node", NO);
    cell.textField.attributedStringValue = line;
    cell.textField.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textField.toolTip = [item.kind isEqual:@"string"] ? item.text : nil;
    return cell;
}

@end

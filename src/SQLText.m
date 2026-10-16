#import "SQLText.h"
#import "UI.h"

void SQLHighlight(NSTextStorage *storage) {
    static NSRegularExpression *tokens;
    static NSSet *keywords, *functions;
    if (!tokens) {
        tokens = [NSRegularExpression regularExpressionWithPattern:@"(--[^\\n]*)|('(?:[^']|'')*'?)|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_][A-Za-z0-9_]*)"
                                                           options:0 error:nil];
        keywords = [NSSet setWithArray:[@"select from where join on as and or not group by order desc asc limit offset update set "
                                         "delete insert into values begin commit rollback inner left right outer full cross having "
                                         "distinct is null default case when then else end returning true false with union all in "
                                         "like ilike between exists create table alter drop index primary key references"
                                         componentsSeparatedByString:@" "]];
        functions = [NSSet setWithArray:[@"count sum avg min max now coalesce lower upper length concat" componentsSeparatedByString:@" "]];
    }
    NSString *text = storage.string;
    NSRange all = NSMakeRange(0, text.length);
    [storage beginEditing];
    [storage addAttribute:NSForegroundColorAttributeName value:NSColor.labelColor range:all];
    [tokens enumerateMatchesInString:text options:0 range:all usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        NSColor *color = nil;
        if ([m rangeAtIndex:1].location != NSNotFound) color = Theme.sqlComment;
        else if ([m rangeAtIndex:2].location != NSNotFound) color = Theme.sqlString;
        else if ([m rangeAtIndex:3].location != NSNotFound) color = Theme.sqlNumber;
        else {
            NSString *word = [text substringWithRange:m.range].lowercaseString;
            color = [keywords containsObject:word] ? Theme.sqlKeyword : [functions containsObject:word] ? Theme.sqlFunction : nil;
        }
        if (color) [storage addAttribute:NSForegroundColorAttributeName value:color range:m.range];
    }];
    [storage endEditing];
}

@interface SQLHighlighter : NSObject <NSTextStorageDelegate>
@end

@implementation SQLHighlighter
- (void)textStorage:(NSTextStorage *)storage didProcessEditing:(NSTextStorageEditActions)actions range:(NSRange)range changeInLength:(NSInteger)delta {
    if (!(actions & NSTextStorageEditedCharacters)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ SQLHighlight(storage); }); // not while the storage is still processing
}
@end

// Gutter with line numbers next to the editor.
@interface LineNumberRuler : NSRulerView
@end

@implementation LineNumberRuler
- (void)drawHashMarksAndLabelsInRect:(NSRect)rect {
    NSTextView *textView = (NSTextView *)self.clientView;
    NSLayoutManager *layout = textView.layoutManager;
    NSString *text = textView.string;
    NSDictionary *attrs = @{NSFontAttributeName: [Theme mono:11], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor};
    CGFloat offset = [self convertPoint:NSZeroPoint fromView:textView].y + textView.textContainerInset.height;
    NSRange visible = [layout glyphRangeForBoundingRect:textView.visibleRect inTextContainer:textView.textContainer];

    NSUInteger line = 1;
    for (NSUInteger i = 0, start = [layout characterIndexForGlyphAtIndex:visible.location]; i < start; i++)
        if ([text characterAtIndex:i] == '\n') line++;

    NSUInteger glyph = visible.location;
    while (glyph < NSMaxRange(visible)) {
        NSRange lineRange = [text lineRangeForRange:NSMakeRange([layout characterIndexForGlyphAtIndex:glyph], 0)];
        NSRange glyphs = [layout glyphRangeForCharacterRange:lineRange actualCharacterRange:NULL];
        NSRect r = [layout lineFragmentRectForGlyphAtIndex:glyph effectiveRange:NULL];
        NSString *label = @(line).stringValue;
        NSSize size = [label sizeWithAttributes:attrs];
        [label drawAtPoint:NSMakePoint(self.ruleThickness - size.width - 8, offset + NSMinY(r) + (NSHeight(r) - size.height) / 2) withAttributes:attrs];
        line++;
        glyph = NSMaxRange(glyphs);
    }
    if (!text.length || [text hasSuffix:@"\n"]) { // empty last line
        NSRect r = layout.extraLineFragmentRect;
        NSString *label = @(line).stringValue;
        NSSize size = [label sizeWithAttributes:attrs];
        if (!NSIsEmptyRect(r))
            [label drawAtPoint:NSMakePoint(self.ruleThickness - size.width - 8, offset + NSMinY(r) + (NSHeight(r) - size.height) / 2) withAttributes:attrs];
    }
}
@end

// Copy and cut put the selection on the clipboard for this Mac only (see TBCopyLocally); drags and Services, which
// use other pasteboards, work as usual.
@interface LocalCopyTextView : NSTextView
@end

@implementation LocalCopyTextView
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray<NSPasteboardType> *)types {
    if (pasteboard != NSPasteboard.generalPasteboard) return [super writeSelectionToPasteboard:pasteboard types:types];
    NSMutableString *text = [NSMutableString new];
    for (NSValue *range in self.selectedRanges) [text appendString:[self.string substringWithRange:range.rangeValue]];
    TBCopyLocally(pasteboard, text, nil);
    return YES;
}
@end

NSScrollView *SQLTextScrollView(NSTextView **textView, BOOL editable, BOOL lineNumbers) {
    static SQLHighlighter *highlighter;
    if (!highlighter) highlighter = [SQLHighlighter new];

    NSScrollView *scroll = [LocalCopyTextView scrollableTextView];
    NSTextView *t = scroll.documentView;
    NSCAssert([t isKindOfClass:LocalCopyTextView.class], @"scrollableTextView makes a text view of the receiving class");
    t.font = [Theme mono:12.5];
    t.richText = NO;
    t.editable = editable;
    t.textContainerInset = NSMakeSize(8, 10);
    t.backgroundColor = Theme.editor;
    t.automaticQuoteSubstitutionEnabled = NO;
    t.automaticDashSubstitutionEnabled = NO;
    t.automaticTextReplacementEnabled = NO;
    t.automaticSpellingCorrectionEnabled = NO;
    t.continuousSpellCheckingEnabled = NO;
    t.textStorage.delegate = highlighter;
    if (lineNumbers) {
        LineNumberRuler *ruler = [[LineNumberRuler alloc] initWithScrollView:scroll orientation:NSVerticalRuler];
        ruler.clientView = t;
        ruler.ruleThickness = 38;
        ruler.clipsToBounds = YES; // otherwise its edge line is drawn past the scroll view (views don't clip by default)
        scroll.verticalRulerView = ruler;
        scroll.hasVerticalRuler = YES;
        scroll.rulersVisible = YES;
        __weak LineNumberRuler *weakRuler = ruler;
        [NSNotificationCenter.defaultCenter addObserverForName:NSTextDidChangeNotification object:t queue:nil
                                                    usingBlock:^(NSNotification *n) { weakRuler.needsDisplay = YES; }];
    }
    *textView = t;
    return scroll;
}

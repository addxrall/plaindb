#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// Colour tokens from the PlainDB design, each with a light and a dark variant.
@interface Theme : NSObject
@property (class, readonly) NSColor *head, *side, *fill, *rowSelection, *sideSelection, *grid;
@property (class, readonly) NSColor *changed, *changedDot, *added, *deleted;
@property (class, readonly) NSColor *red, *green, *orange, *productionBanner, *errorFill, *errorBorder, *editor;
@property (class, readonly) NSColor *sqlKeyword, *sqlString, *sqlNumber, *sqlFunction, *sqlComment;
+ (NSFont *)mono:(CGFloat)size;
+ (NSColor *)colorFromHex:(nullable NSString *)hex fallback:(NSColor *)fallback;
@end

NSTextField *TBLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
NSTextField *TBWrappingLabel(NSString *text, CGFloat size, NSColor *color);
NSButton *TBButton(NSString *title, id target, SEL action);
NSButton *TBSymbolButton(NSString *symbol, NSString *tip, id target, SEL action);
// Plain view filled with a (dynamic) colour.
NSBox *TBPanel(NSColor *fill);
NSBox *TBSeparator(void);
// Rounded pill with text, e.g. "read-only" or "PK".
NSView *TBBadge(NSString *text, NSColor *textColor, NSColor *fill);
// Shows exactly one of `views` at a time. All pages are pinned to the edges with constraints
// (an NSTabView keeps the size its pages had when created, so pages ended up misplaced).
@interface TBSwitcher : NSView
- (instancetype)initWithViews:(NSArray<NSView *> *)views;
@property (nonatomic) NSInteger selectedIndex;
@end
// Vertical stack where every view is full width (minus the side insets); `grow` takes the remaining height.
NSStackView *TBColumn(NSArray<NSView *> *views, NSView *_Nullable grow);
NSStackView *TBColumnInset(NSArray<NSView *> *views, NSView *_Nullable grow, NSEdgeInsets insets);
// Horizontal bar: views pinned to the leading and trailing edges.
NSStackView *TBBar(NSArray<NSView *> *leading, NSArray<NSView *> *trailing, CGFloat height);
void TBPin(NSView *view, NSView *container, NSEdgeInsets insets);
// Centered message, e.g. an empty or loading state.
NSView *TBCenteredState(NSArray<NSView *> *views);
NSProgressIndicator *TBSpinner(NSControlSize size);

// Row with a custom (light) selection colour, so cell text keeps its normal colour.
@interface TBRowView : NSTableRowView
@property (nonatomic, strong, nullable) NSColor *selectionColor;
@property (nonatomic) CGFloat selectionInset, selectionRadius; // rounded selection, e.g. in lists
@end

// Cell with a fill and an optional focus ring, redrawn correctly when light/dark mode changes.
@interface TBCellView : NSTableCellView
@property (nonatomic, strong, nullable) NSColor *fill;
@property (nonatomic) BOOL ring;
@end

// Reusable cell with a text field (and optionally an icon), vertically centered.
TBCellView *TBCell(NSTableView *table, NSString *identifier, BOOL withImage);

NS_ASSUME_NONNULL_END

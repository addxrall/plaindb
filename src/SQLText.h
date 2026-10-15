#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Colours SQL keywords, functions, strings, numbers and comments (same rules as the design).
void SQLHighlight(NSTextStorage *storage);

// Scrollable monospace text view for SQL: no smart quotes, live highlighting,
// optional line number gutter. The text view is returned through `textView`.
NSScrollView *SQLTextScrollView(NSTextView *_Nullable *_Nonnull textView, BOOL editable, BOOL lineNumbers);

NS_ASSUME_NONNULL_END

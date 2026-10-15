#import <Cocoa/Cocoa.h>
#import "SchemaGraph.h"

NS_ASSUME_NONNULL_BEGIN

// Completion list for the SQL editor: becomes the text view's delegate, shows SQLSuggestions under the cursor while
// typing (or on ⌃Space / Esc), ↑↓ to choose, Tab or Enter to insert, Esc to close.
@interface SQLCompleter : NSObject <NSTextViewDelegate>
- (instancetype)initWithTextView:(NSTextView *)textView;
@property (nonatomic, strong, nullable) SchemaGraph *schema;
@property (nonatomic, readonly, getter=isShown) BOOL shown;
- (void)show; // for the current word, also with nothing typed yet
- (void)hide;
@end

NS_ASSUME_NONNULL_END

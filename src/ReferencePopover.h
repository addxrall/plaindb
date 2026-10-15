#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// Popover content showing the row a foreign key points to, field by field.
@interface ReferencePreview : NSViewController
@property (nonatomic, copy, nullable) void (^onOpenTable)(void);
// `result` holds the referenced row (or no rows when it doesn't exist).
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle result:(DBResult *)result;
@end

// Popover content for choosing the row a foreign key should point to: search the referenced table, pick a row,
// and its key value goes into the cell.
@interface ReferencePicker : NSViewController
@property (nonatomic, copy, nullable) void (^onSearch)(NSString *term); // "" = first rows; answer with showResult:
@property (nonatomic, copy, nullable) void (^onPick)(id value);         // the key value as NSString, or NSNull
- (instancetype)initWithTitle:(NSString *)title keyColumn:(NSString *)keyColumn;
- (void)showResult:(nullable DBResult *)result error:(nullable NSError *)error;
@end

NS_ASSUME_NONNULL_END

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A parsed JSON value that keeps the original key order (NSJSONSerialization doesn't).
@interface JSONNode : NSObject
@property (nonatomic, copy, nullable) NSString *key; // nil for array items and the root
@property (nonatomic) NSInteger index;               // position in the parent array
@property (nonatomic, copy) NSString *kind;          // object, array, string, number, bool, null
@property (nonatomic, copy) NSString *text;          // scalar value, strings unescaped
@property (nonatomic, strong) NSMutableArray<JSONNode *> *children;
@end

// YES for a string holding a JSON object or array (what the inspector opens).
BOOL JSONIsValid(id _Nullable value);
// nil when the text isn't valid JSON.
JSONNode *_Nullable JSONParse(NSString *text);
// Re-indent / strip whitespace outside strings. Key order and string contents stay as they are.
NSString *JSONPretty(NSString *text);
NSString *JSONMinify(NSString *text);

// Side panel (inspector) showing one JSON cell as a tree or as editable, highlighted text.
@interface JSONInspector : NSViewController
@property (nonatomic, copy, nullable) void (^onApply)(NSString *json); // minified
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (void)showJSON:(NSString *)json title:(NSString *)title subtitle:(NSString *)subtitle editable:(BOOL)editable;
- (void)showPlaceholder;
@end

NS_ASSUME_NONNULL_END

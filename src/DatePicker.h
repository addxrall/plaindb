#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Column kinds the grid edits with a dedicated control. "date", "time" and "timestamp" have no time zone and are
// handled in UTC so they round-trip unchanged; "timestamptz" is shown in the local zone and written with its offset.
typedef NSString *TBValueKind NS_TYPED_ENUM;
extern TBValueKind const TBKindBool, TBKindDate, TBKindTime, TBKindTimestamp, TBKindTimestampTZ;

// Postgres type name (format_type) → kind, or nil for everything edited as text.
TBValueKind _Nullable TBKindForType(NSString *type);

// Postgres text output ↔ NSDate for a date/time kind. Fractional seconds are dropped.
NSDate *_Nullable TBDateFromValue(NSString *value, TBValueKind kind);
NSString *TBValueFromDate(NSDate *date, TBValueKind kind);

// Popover with a calendar and/or clock for one date/time value.
@interface DatePickerPopover : NSViewController
@property (nonatomic, copy, nullable) void (^onPick)(id value); // NSString in Postgres format, or NSNull
- (instancetype)initWithTitle:(NSString *)title value:(id)value kind:(TBValueKind)kind;
@end

NS_ASSUME_NONNULL_END

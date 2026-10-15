#import "DatePicker.h"
#import "DBConnection.h"
#import "UI.h"

TBValueKind const TBKindBool = @"bool", TBKindDate = @"date", TBKindTime = @"time", TBKindTimestamp = @"timestamp",
                  TBKindTimestampTZ = @"timestamptz";

TBValueKind TBKindForType(NSString *type) {
    if ([type isEqual:@"boolean"]) return TBKindBool;
    if ([type isEqual:@"date"]) return TBKindDate;
    if ([type hasPrefix:@"timestamp"]) return [type hasSuffix:@"with time zone"] && ![type hasSuffix:@"without time zone"] ? TBKindTimestampTZ : TBKindTimestamp;
    if ([type hasPrefix:@"time"] && ![type hasSuffix:@"with time zone"]) return TBKindTime;
    return nil;
}

static NSTimeZone *ZoneFor(TBValueKind kind) {
    return kind == TBKindTimestampTZ ? NSTimeZone.localTimeZone : [NSTimeZone timeZoneForSecondsFromGMT:0];
}

static NSDateFormatter *Formatter(NSString *format, NSTimeZone *zone) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    f.timeZone = zone;
    f.dateFormat = format;
    return f;
}

NSDate *TBDateFromValue(NSString *value, TBValueKind kind) {
    static NSRegularExpression *fraction;
    if (!fraction) fraction = [NSRegularExpression regularExpressionWithPattern:@"\\.\\d+" options:0 error:nil];
    NSString *s = [fraction stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
    NSArray *formats = kind == TBKindDate ? @[@"yyyy-MM-dd"]
                     : kind == TBKindTime ? @[@"HH:mm:ss", @"HH:mm"]
                     : kind == TBKindTimestampTZ ? @[@"yyyy-MM-dd HH:mm:ssXXXXX", @"yyyy-MM-dd HH:mm:ssX"]
                                               : @[@"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd HH:mm"];
    for (NSString *format in formats) {
        NSDate *date = [Formatter(format, ZoneFor(kind)) dateFromString:s];
        if (date) return date;
    }
    return nil;
}

NSString *TBValueFromDate(NSDate *date, TBValueKind kind) {
    NSString *format = kind == TBKindDate ? @"yyyy-MM-dd" : kind == TBKindTime ? @"HH:mm:ss"
                     : kind == TBKindTimestampTZ ? @"yyyy-MM-dd HH:mm:ssxxx" : @"yyyy-MM-dd HH:mm:ss";
    return [Formatter(format, ZoneFor(kind)) stringFromDate:date];
}

@implementation DatePickerPopover {
    NSString *_title;
    id _value;
    TBValueKind _kind;
    NSDatePicker *_calendar, *_field;
}

- (instancetype)initWithTitle:(NSString *)title value:(id)value kind:(TBValueKind)kind {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _title = title;
        _value = value;
        _kind = kind;
    }
    return self;
}

- (void)loadView {
    BOOL hasDate = _kind != TBKindTime, hasTime = _kind != TBKindDate;
    NSDatePickerElementFlags elements = (hasDate ? NSDatePickerElementFlagYearMonthDay : 0) | (hasTime ? NSDatePickerElementFlagHourMinuteSecond : 0);
    NSDate *initial = [_value isKindOfClass:NSString.class] ? TBDateFromValue(_value, _kind) : nil;
    if (!initial) initial = NSDate.date;

    // graphical calendar (dates) or clock (time only), plus a precise text field kept in sync
    _calendar = [NSDatePicker new];
    _calendar.datePickerStyle = NSDatePickerStyleClockAndCalendar;
    _calendar.datePickerElements = hasDate ? NSDatePickerElementFlagYearMonthDay : NSDatePickerElementFlagHourMinuteSecond;
    _field = [NSDatePicker new];
    _field.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    _field.datePickerElements = elements;
    for (NSDatePicker *p in @[_calendar, _field]) {
        p.timeZone = ZoneFor(_kind);
        p.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        p.dateValue = initial;
        p.target = self;
        p.action = @selector(changed:);
    }

    NSTextField *title = TBLabel(_title, 13, NSFontWeightSemibold, NSColor.labelColor);
    NSString *zone = _kind == TBKindTimestampTZ ? [NSString stringWithFormat:L(@"Your time zone: %@"), NSTimeZone.localTimeZone.name] : @"";
    NSTextField *note = TBLabel(zone, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSButton *now = TBButton(hasTime ? L(@"Now") : L(@"Today"), self, @selector(now:));
    NSButton *null = TBButton(L(@"Set NULL"), self, @selector(setNull:));
    NSButton *set = TBButton(L(@"Set"), self, @selector(set:));
    set.bezelColor = NSColor.controlAccentColor;
    set.keyEquivalent = @"\r";

    NSStackView *content = [NSStackView stackViewWithViews:@[title, _calendar, _field, note]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeCenterX;
    content.spacing = 10;
    content.edgeInsets = NSEdgeInsetsMake(14, 16, 12, 16);
    note.hidden = !zone.length;
    NSStackView *view = TBColumn(@[content, TBSeparator(), TBBar(@[now], @[null, set], 42)], content);
    [view.widthAnchor constraintGreaterThanOrEqualToConstant:300].active = YES;
    self.view = view;
}

- (void)changed:(NSDatePicker *)sender {
    NSDatePicker *other = sender == _calendar ? _field : _calendar;
    other.dateValue = sender.dateValue;
}

- (void)now:(id)sender {
    _calendar.dateValue = _field.dateValue = NSDate.date;
}

- (void)setNull:(id)sender {
    if (self.onPick) self.onPick(NSNull.null);
}

- (void)set:(id)sender {
    if (self.onPick) self.onPick(TBValueFromDate(_field.dateValue, _kind));
}

@end

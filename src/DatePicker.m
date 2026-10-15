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

// Month calendar drawn as in the design (NSDatePicker's graphical style can't be styled):
// month and ‹ ● › on top, weekday initials, 6 weeks of days; the chosen day in accent, today in accent text.
@interface CalendarView : NSView
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, copy) void (^onChange)(NSDate *date);
- (instancetype)initWithTimeZone:(NSTimeZone *)zone;
@end

@implementation CalendarView {
    NSCalendar *_calendar;
    NSDateComponents *_shown; // year and month on screen
}

static const CGFloat CalWidth = 226, CalPad = 8, CalHeader = 22, CalWeekdays = 16, CalRow = 22;

- (instancetype)initWithTimeZone:(NSTimeZone *)zone {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        _calendar.timeZone = zone;
        _calendar.firstWeekday = NSCalendar.currentCalendar.firstWeekday;
        [NSLayoutConstraint activateConstraints:@[[self.widthAnchor constraintEqualToConstant:CalWidth],
                                                  [self.heightAnchor constraintEqualToConstant:CalPad + CalHeader + CalWeekdays + 6 * CalRow + 6]]];
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setDate:(NSDate *)date {
    _date = date;
    _shown = [_calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:date];
    self.needsDisplay = YES;
}

- (NSDate *)firstShownDay {
    NSDateComponents *first = [_shown copy];
    first.day = 1;
    NSDate *start = [_calendar dateFromComponents:first];
    NSInteger lead = ([_calendar component:NSCalendarUnitWeekday fromDate:start] - _calendar.firstWeekday + 7) % 7;
    return [_calendar dateByAddingUnit:NSCalendarUnitDay value:-lead toDate:start options:0];
}

- (CGFloat)column {
    return (CalWidth - 2 * CalPad) / 7;
}

// ‹ ● › at the right of the header, 16 pt each, 4 pt apart
- (NSRect)buttonRect:(NSInteger)i {
    return NSMakeRect(CalWidth - CalPad - 2 - 16 * (3 - i) - 4 * (2 - i), CalPad + 1, 16, 16);
}

- (void)drawRect:(NSRect)rect {
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:6 yRadius:6];
    [NSColor.textBackgroundColor setFill];
    [box fill];
    [NSColor.separatorColor setStroke];
    [box stroke];

    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en"];
    NSDateFormatter *month = [NSDateFormatter new];
    month.locale = locale;
    month.calendar = _calendar;
    month.timeZone = _calendar.timeZone;
    [month setLocalizedDateFormatFromTemplate:@"LLLLy"];
    NSDateComponents *first = [_shown copy];
    first.day = 1;
    [[month stringFromDate:[_calendar dateFromComponents:first]] drawAtPoint:NSMakePoint(CalPad + 2, CalPad + 1) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor}];
    NSDictionary *arrow = @{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    for (NSInteger i = 0; i < 3; i += 2) {
        NSString *s = i ? @"›" : @"‹";
        NSRect r = [self buttonRect:i];
        NSSize size = [s sizeWithAttributes:arrow];
        [s drawAtPoint:NSMakePoint(NSMidX(r) - size.width / 2, NSMidY(r) - size.height / 2) withAttributes:arrow];
    }
    NSRect dot = [self buttonRect:1];
    [NSColor.secondaryLabelColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(dot) - 3, NSMidY(dot) - 3, 6, 6)] fill];

    CGFloat column = [self column], top = CalPad + CalHeader;
    NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
    center.alignment = NSTextAlignmentCenter;
    NSArray *initials = [L(@"Su Mo Tu We Th Fr Sa") componentsSeparatedByString:@" "];
    for (NSInteger i = 0; i < 7; i++)
        [initials[(i + _calendar.firstWeekday - 1) % 7] drawInRect:NSMakeRect(CalPad + i * column, top, column, CalWeekdays) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:10.5], NSForegroundColorAttributeName: NSColor.tertiaryLabelColor,
            NSParagraphStyleAttributeName: center}];

    NSDate *day = [self firstShownDay];
    for (NSInteger i = 0; i < 42; i++) {
        BOOL inMonth = [_calendar component:NSCalendarUnitMonth fromDate:day] == _shown.month;
        BOOL chosen = [_calendar isDate:day inSameDayAsDate:_date], today = [_calendar isDate:day inSameDayAsDate:NSDate.date];
        NSRect cell = NSMakeRect(CalPad + (i % 7) * column, top + CalWeekdays + (i / 7) * CalRow, column, CalRow);
        NSRect chip = NSMakeRect(NSMidX(cell) - 12, NSMidY(cell) - 10, 24, 20);
        if (chosen) {
            [NSColor.controlAccentColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:5 yRadius:5] fill];
        }
        NSColor *color = chosen ? NSColor.whiteColor : today ? NSColor.controlAccentColor : inMonth ? NSColor.labelColor : NSColor.tertiaryLabelColor;
        NSFont *font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:chosen || today ? NSFontWeightSemibold : NSFontWeightRegular];
        NSString *text = @([_calendar component:NSCalendarUnitDay fromDate:day]).stringValue;
        CGFloat height = ceil(font.ascender - font.descender);
        [text drawInRect:NSMakeRect(NSMinX(chip), NSMidY(chip) - height / 2, NSWidth(chip), height) withAttributes:@{
            NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: center}];
        day = [_calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    for (NSInteger i = 0; i < 3; i++) {
        if (!NSPointInRect(p, NSInsetRect([self buttonRect:i], -2, -3))) continue;
        NSDate *first = [_calendar dateFromComponents:_shown];
        NSDate *target = i == 1 ? NSDate.date : [_calendar dateByAddingUnit:NSCalendarUnitMonth value:i ? 1 : -1 toDate:first options:0];
        _shown = [_calendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:target];
        self.needsDisplay = YES;
        return;
    }
    CGFloat top = CalPad + CalHeader + CalWeekdays;
    if (p.y < top || p.x < CalPad || p.x >= CalWidth - CalPad) return;
    NSInteger index = (NSInteger)((p.y - top) / CalRow) * 7 + (NSInteger)((p.x - CalPad) / [self column]);
    if (index < 0 || index >= 42) return;
    // the chosen day, keeping the time of day
    NSDate *day = [_calendar dateByAddingUnit:NSCalendarUnitDay value:index toDate:[self firstShownDay] options:0];
    NSDateComponents *c = [_calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:day];
    NSDateComponents *time = [_calendar components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:_date];
    c.hour = time.hour;
    c.minute = time.minute;
    c.second = time.second;
    self.date = [_calendar dateFromComponents:c];
    if (self.onChange) self.onChange(self.date);
}
@end

@interface DatePickerPopover ()
- (void)setFieldDate:(NSDate *)date;
@end

@implementation DatePickerPopover {
    NSString *_title;
    id _value;
    TBValueKind _kind;
    CalendarView *_calendar;
    NSDatePicker *_field;
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

    // calendar (not for a time of day) plus a precise text field kept in sync
    _calendar = [[CalendarView alloc] initWithTimeZone:ZoneFor(_kind)];
    _calendar.date = initial;
    __weak DatePickerPopover *weakSelf = self;
    _calendar.onChange = ^(NSDate *date) { [weakSelf setFieldDate:date]; };
    _calendar.hidden = !hasDate;
    _field = [NSDatePicker new];
    _field.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    _field.datePickerElements = elements;
    _field.timeZone = ZoneFor(_kind);
    _field.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    _field.locale = [NSLocale localeWithLocaleIdentifier:@"sv_SE"]; // shows 2026-10-03 10:20:29, as Postgres writes it
    _field.font = [Theme mono:12];
    _field.dateValue = initial;
    _field.target = self;
    _field.action = @selector(changed:);

    NSTextField *title = TBLabel(_title, 13, NSFontWeightSemibold, NSColor.labelColor);
    NSString *zone = _kind == TBKindTimestampTZ ? [NSString stringWithFormat:L(@"Your time zone: %@"), NSTimeZone.localTimeZone.name] : @"";
    NSTextField *note = TBLabel(zone, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSButton *now = TBButton(hasTime ? L(@"Now") : L(@"Today"), self, @selector(now:));
    NSButton *null = TBButton(L(@"Set NULL"), self, @selector(setNull:));
    NSButton *set = TBButton(L(@"Set"), self, @selector(set:));
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

- (void)setFieldDate:(NSDate *)date {
    _field.dateValue = date;
}

- (void)changed:(NSDatePicker *)sender {
    _calendar.date = sender.dateValue;
}

- (void)now:(id)sender {
    _calendar.date = _field.dateValue = NSDate.date;
}

- (void)setNull:(id)sender {
    if (self.onPick) self.onPick(NSNull.null);
}

- (void)set:(id)sender {
    if (self.onPick) self.onPick(TBValueFromDate(_field.dateValue, _kind));
}

@end

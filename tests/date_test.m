// Postgres date/time text ↔ NSDate: values round-trip unchanged (minus fractional seconds).
#import "DatePicker.h"
#import <assert.h>

static BOOL RoundTrip(NSString *value, TBValueKind kind, NSString *expected) {
    NSDate *date = TBDateFromValue(value, kind);
    return date && [TBValueFromDate(date, kind) isEqual:expected];
}

int main(void) {
    @autoreleasepool {
        assert(TBKindForType(@"boolean") == TBKindBool);
        assert(TBKindForType(@"date") == TBKindDate);
        assert(TBKindForType(@"timestamp without time zone") == TBKindTimestamp);
        assert(TBKindForType(@"timestamp(3) without time zone") == TBKindTimestamp);
        assert(TBKindForType(@"timestamp with time zone") == TBKindTimestampTZ);
        assert(TBKindForType(@"time without time zone") == TBKindTime);
        assert(!TBKindForType(@"time with time zone") && !TBKindForType(@"text") && !TBKindForType(@"interval"));
        // SQLite declared types
        assert(TBKindForType(@"BOOLEAN") == TBKindBool && TBKindForType(@"bool") == TBKindBool);
        assert(TBKindForType(@"DATE") == TBKindDate && TBKindForType(@"DATETIME") == TBKindTimestamp && TBKindForType(@"TIMESTAMP") == TBKindTimestamp);
        assert(!TBKindForType(@"INTEGER") && !TBKindForType(@"TEXT"));

        assert(RoundTrip(@"2025-04-04", TBKindDate, @"2025-04-04"));
        assert(RoundTrip(@"23:59:01", TBKindTime, @"23:59:01"));
        // no time zone: exactly what was stored, also across a DST change
        assert(RoundTrip(@"2025-03-30 02:30:00", TBKindTimestamp, @"2025-03-30 02:30:00"));
        assert(RoundTrip(@"2025-04-04 12:34:56.789123", TBKindTimestamp, @"2025-04-04 12:34:56"));
        // with a time zone: the same instant, written with the local offset
        NSDate *instant = TBDateFromValue(@"2025-04-04 12:34:56+02", TBKindTimestampTZ);
        assert([instant isEqual:TBDateFromValue(@"2025-04-04 10:34:56+00", TBKindTimestampTZ)]);
        assert([instant isEqual:TBDateFromValue(@"2025-04-04 16:04:56.5+05:30", TBKindTimestampTZ)]);
        assert([TBDateFromValue(TBValueFromDate(instant, TBKindTimestampTZ), TBKindTimestampTZ) isEqual:instant]);
        assert(!TBDateFromValue(@"not a date", TBKindDate));
        puts("date_test: OK");
    }
    return 0;
}

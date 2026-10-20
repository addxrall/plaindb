// Postgres date/time text ↔ Date: values round-trip unchanged (minus fractional seconds).
@testable import PlainDBKit
import AppKit

@main enum DateTest {
    static func roundTrip(_ value: String, _ kind: ValueKind, _ expected: String) -> Bool {
        guard let date = kind.date(from: value) else { return false }
        return kind.value(from: date) == expected
    }

    @MainActor static func main() {
        check(ValueKind(type: "boolean") == .bool)
        check(ValueKind(type: "date") == .date)
        check(ValueKind(type: "timestamp without time zone") == .timestamp)
        check(ValueKind(type: "timestamp(3) without time zone") == .timestamp)
        check(ValueKind(type: "timestamp with time zone") == .timestampTZ)
        check(ValueKind(type: "time without time zone") == .time)
        check(ValueKind(type: "time with time zone") == nil && ValueKind(type: "text") == nil && ValueKind(type: "interval") == nil)
        // SQLite declared types
        check(ValueKind(type: "BOOLEAN") == .bool && ValueKind(type: "bool") == .bool)
        check(ValueKind(type: "DATE") == .date && ValueKind(type: "DATETIME") == .timestamp && ValueKind(type: "TIMESTAMP") == .timestamp)
        check(ValueKind(type: "INTEGER") == nil && ValueKind(type: "TEXT") == nil)
        // the raw values are what the grid hands to onPickDate's callers
        check(ValueKind.timestampTZ.rawValue == "timestamptz" && ValueKind.bool.rawValue == "bool")

        check(roundTrip("2025-04-04", .date, "2025-04-04"))
        check(roundTrip("23:59:01", .time, "23:59:01"))
        // no time zone: exactly what was stored, also across a DST change
        check(roundTrip("2025-03-30 02:30:00", .timestamp, "2025-03-30 02:30:00"))
        check(roundTrip("2025-04-04 12:34:56.789123", .timestamp, "2025-04-04 12:34:56"))
        check(roundTrip("2025-04-04 12:34", .timestamp, "2025-04-04 12:34:00"))
        // with a time zone: the same instant, written with the local offset
        let instant = ValueKind.timestampTZ.date(from: "2025-04-04 12:34:56+02")
        check(instant != nil && instant == ValueKind.timestampTZ.date(from: "2025-04-04 10:34:56+00"))
        check(instant == ValueKind.timestampTZ.date(from: "2025-04-04 16:04:56.5+05:30"))
        check(ValueKind.timestampTZ.date(from: ValueKind.timestampTZ.value(from: instant!)) == instant)
        check(ValueKind.date.date(from: "not a date") == nil)

        // the popover builds, and Set / Set NULL hand back Postgres text / NULL
        var picked: [DBValue] = []
        let picker = DatePickerPopover(title: "created_at", value: "2025-04-04 12:34:56", kind: .timestamp)
        picker.onPick = { picked.append($0) }
        _ = picker.view
        func press(_ title: String) {
            func find(_ view: NSView) -> NSButton? {
                if let b = view as? NSButton, b.title == title { return b }
                return view.subviews.lazy.compactMap(find).first
            }
            find(picker.view)?.performClick(nil)
        }
        press(L("Set"))
        press(L("Set NULL"))
        check(picked == ["2025-04-04 12:34:56", .null])
        print("date_test: OK")
    }
}

import AppKit

// Column kinds the grid edits with a dedicated control. "date", "time" and "timestamp" have no time zone and are
// handled in UTC so they round-trip unchanged; "timestamptz" is shown in the local zone and written with its offset.
enum ValueKind: String, Sendable {
    case bool, date, time, timestamp, timestampTZ = "timestamptz"

    // Postgres type name (format_type) → kind, or nil for everything edited as text.
    init?(type: String) {
        let type = type.lowercased() // SQLite declared types are whatever the schema says, often upper case
        if type == "boolean" || type == "bool" { self = .bool }
        else if type == "date" { self = .date }
        else if type == "datetime" { self = .timestamp }
        else if type.hasPrefix("timestamp") {
            self = type.hasSuffix("with time zone") && !type.hasSuffix("without time zone") ? .timestampTZ : .timestamp
        } else if type.hasPrefix("time") && !type.hasSuffix("with time zone") { self = .time }
        else { return nil }
    }

    var timeZone: TimeZone { self == .timestampTZ ? .current : TimeZone(secondsFromGMT: 0)! }

    private func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }

    // Postgres text output → Date. Fractional seconds are dropped.
    func date(from value: String) -> Date? {
        let s = value.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        let formats = switch self {
        case .date: ["yyyy-MM-dd"]
        case .time: ["HH:mm:ss", "HH:mm"]
        case .timestampTZ: ["yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssX"]
        default: ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]
        }
        for format in formats {
            if let date = formatter(format).date(from: s) { return date }
        }
        return nil
    }

    // Date → Postgres text.
    func value(from date: Date) -> String {
        let format = switch self {
        case .date: "yyyy-MM-dd"
        case .time: "HH:mm:ss"
        case .timestampTZ: "yyyy-MM-dd HH:mm:ssxxx"
        default: "yyyy-MM-dd HH:mm:ss"
        }
        return formatter(format).string(from: date)
    }
}

// Month calendar drawn by hand: NSDatePicker's graphical style can't be styled.
private final class CalendarView: NSView {
    static let width: CGFloat = 226, pad: CGFloat = 8, header: CGFloat = 22, weekdays: CGFloat = 16, row: CGFloat = 22

    var onChange: ((Date) -> Void)?
    var date = Date() {
        didSet {
            shown = calendar.dateComponents([.year, .month], from: date)
            needsDisplay = true
        }
    }
    private var calendar = Calendar(identifier: .gregorian)
    private var shown = DateComponents() // year and month on screen

    init(timeZone: TimeZone) {
        super.init(frame: .zero)
        calendar.timeZone = timeZone
        calendar.firstWeekday = Calendar.current.firstWeekday
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.pad + Self.header + Self.weekdays + 6 * Self.row + 6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var firstShownDay: Date {
        var first = shown
        first.day = 1
        let start = calendar.date(from: first)!
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -lead, to: start)!
    }

    private var columnWidth: CGFloat { (Self.width - 2 * Self.pad) / 7 }

    // ‹ ● › at the right of the header
    private func buttonRect(_ i: Int) -> NSRect {
        NSRect(x: Self.width - Self.pad - 2 - 16 * CGFloat(3 - i) - 4 * CGFloat(2 - i), y: Self.pad + 1, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        Theme.box.setFill()
        box.fill()
        Theme.boxB.setStroke()
        box.stroke()

        let month = DateFormatter()
        month.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        month.calendar = calendar
        month.timeZone = calendar.timeZone
        month.setLocalizedDateFormatFromTemplate("LLLLy")
        var first = shown
        first.day = 1
        month.string(from: calendar.date(from: first)!).draw(at: NSPoint(x: Self.pad + 2, y: Self.pad + 1),
                                                             withAttributes: [.font: Theme.font(12, .semibold), .foregroundColor: Theme.t1])
        let arrow: [NSAttributedString.Key: Any] = [.font: Theme.font(13), .foregroundColor: Theme.t2]
        for i in [0, 2] {
            let s = i == 0 ? "‹" : "›", r = buttonRect(i), size = s.size(withAttributes: arrow)
            s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: arrow)
        }
        let dot = buttonRect(1)
        Theme.t2.setFill()
        NSBezierPath(ovalIn: NSRect(x: dot.midX - 3, y: dot.midY - 3, width: 6, height: 6)).fill()

        let top = Self.pad + Self.header
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let initials = L("Su Mo Tu We Th Fr Sa").components(separatedBy: " ")
        for i in 0..<7 where initials.count == 7 {
            initials[(i + calendar.firstWeekday - 1) % 7].draw(
                in: NSRect(x: Self.pad + CGFloat(i) * columnWidth, y: top, width: columnWidth, height: Self.weekdays),
                withAttributes: [.font: Theme.font(10.5), .foregroundColor: Theme.t3, .paragraphStyle: center])
        }

        var day = firstShownDay
        for i in 0..<42 {
            let inMonth = calendar.component(.month, from: day) == shown.month
            let chosen = calendar.isDate(day, inSameDayAs: date), today = calendar.isDate(day, inSameDayAs: Date())
            let cell = NSRect(x: Self.pad + CGFloat(i % 7) * columnWidth, y: top + Self.weekdays + CGFloat(i / 7) * Self.row,
                              width: columnWidth, height: Self.row)
            let chip = NSRect(x: cell.midX - 12, y: cell.midY - 10, width: 24, height: 20)
            if chosen {
                Theme.acc.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            }
            let color = chosen ? Theme.accT : today ? Theme.acc : inMonth ? Theme.t1 : Theme.t3
            let font = Theme.mono(11.5, chosen || today ? .semibold : .regular)
            let height = ceil(font.ascender - font.descender)
            String(calendar.component(.day, from: day)).draw(
                in: NSRect(x: chip.minX, y: chip.midY - height / 2, width: chip.width, height: height),
                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: center])
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for i in 0..<3 where buttonRect(i).insetBy(dx: -2, dy: -3).contains(p) {
            let first = calendar.date(from: shown)!
            let target = i == 1 ? Date() : calendar.date(byAdding: .month, value: i == 2 ? 1 : -1, to: first)!
            shown = calendar.dateComponents([.year, .month], from: target)
            needsDisplay = true
            return
        }
        let top = Self.pad + Self.header + Self.weekdays
        guard p.y >= top, p.x >= Self.pad, p.x < Self.width - Self.pad else { return }
        let index = Int((p.y - top) / Self.row) * 7 + Int((p.x - Self.pad) / columnWidth)
        guard index >= 0, index < 42 else { return }
        // the chosen day, keeping the time of day
        let day = calendar.date(byAdding: .day, value: index, to: firstShownDay)!
        var c = calendar.dateComponents([.year, .month, .day], from: day)
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        (c.hour, c.minute, c.second) = (time.hour, time.minute, time.second)
        date = calendar.date(from: c)!
        onChange?(date)
    }
}

// Popover with a calendar and/or clock for one date/time value.
final class DatePickerPopover: NSViewController {
    // The value in Postgres format, or .null.
    var onPick: ((DBValue) -> Void)?
    private let titleText: String
    private let value: DBValue
    private let kind: ValueKind
    private var calendar: CalendarView!
    private let field = NSDatePicker()

    init(title: String, value: DBValue, kind: ValueKind) {
        (titleText, self.value, self.kind) = (title, value, kind)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hasDate = kind != .time, hasTime = kind != .date
        let initial = value.string.flatMap { kind.date(from: $0) } ?? Date()

        // calendar (not for a time of day) plus a precise text field kept in sync
        calendar = CalendarView(timeZone: kind.timeZone)
        calendar.date = initial
        calendar.onChange = { [weak self] date in self?.field.dateValue = date }
        calendar.isHidden = !hasDate
        field.datePickerStyle = .textFieldAndStepper
        field.datePickerElements = [hasDate ? .yearMonthDay : [], hasTime ? .hourMinuteSecond : []]
        field.timeZone = kind.timeZone
        field.calendar = Calendar(identifier: .gregorian)
        field.locale = Locale(identifier: "sv_SE") // shows 2026-10-03 10:20:29, as Postgres writes it
        field.font = Theme.mono(12)
        field.textColor = Theme.t1
        field.dateValue = initial
        field.target = self
        field.action = #selector(changed(_:))

        let title = label(titleText, 13, .semibold)
        let zone = kind == .timestampTZ ? String(format: L("Your time zone: %@"), TimeZone.current.identifier) : ""
        let note = label(zone, 11, .regular, Theme.t2)
        note.isHidden = zone.isEmpty
        let now = PillButton(hasTime ? L("Now") : L("Today"), target: self, action: #selector(setNow(_:)))
        let null = PillButton(L("Set NULL"), target: self, action: #selector(setNull(_:)))
        let set = PillButton(L("Set"), style: .accent, target: self, action: #selector(set(_:)))
        set.keyEquivalent = "\r"

        let content = NSStackView(views: [title, calendar, field, note])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        let view = column([content, separator(), bar([now], [null, set], height: 42, left: 12, right: 12)], grow: content)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        self.view = view
    }

    @objc private func changed(_ sender: NSDatePicker) {
        calendar.date = sender.dateValue
    }

    @objc private func setNow(_ sender: Any?) {
        let now = Date()
        field.dateValue = now
        calendar.date = now
    }

    @objc private func setNull(_ sender: Any?) {
        onPick?(.null)
    }

    @objc private func set(_ sender: Any?) {
        onPick?(.text(kind.value(from: field.dateValue)))
    }
}

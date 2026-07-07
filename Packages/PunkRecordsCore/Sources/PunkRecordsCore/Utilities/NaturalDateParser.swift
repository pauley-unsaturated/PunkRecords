import Foundation

/// The outcome of parsing a natural-language date: the resolved instant plus
/// whether the input pinned a time-of-day (so the inspector knows to render
/// `yyyy-MM-dd` vs `yyyy-MM-dd HH:mm`).
public struct ParsedDate: Equatable, Sendable {
    public let date: Date
    public let hasTime: Bool

    public init(date: Date, hasTime: Bool) {
        self.date = date
        self.hasTime = hasTime
    }

    /// The stored/display string for this date under `calendar`. Date-only when
    /// no time was given, else with `HH:mm`. Uses `en_US_POSIX` so the format is
    /// stable regardless of the user's locale.
    public func canonicalString(calendar: Calendar = NaturalDateParser.defaultCalendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = hasTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Resolves natural-language date input to a concrete ``ParsedDate``.
///
/// Layered so that everything the tests assert is deterministic under an
/// injected `now`:
/// 1. **Relative offsets** — `+1w`, `+3d`, `-2m`, `+1y` (grammar not covered by
///    NSDataDetector, implemented here).
/// 2. **Relative keywords** — `today`, `tomorrow`, `tonight`, `yesterday`,
///    weekday names (`monday`, `next friday`), each with an optional
///    `… at <time>` suffix.
/// 3. **NSDataDetector** — absolute dates (`July 10 2026`, `2026-07-10`) as a
///    fallback. These don't depend on `now`, so they stay reproducible.
public enum NaturalDateParser {
    /// A Gregorian, UTC calendar — the default reference frame for parsing and
    /// formatting so results are timezone-stable. Callers may inject their own.
    public static var defaultCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// Parse `input` relative to `now`. Returns `nil` for unrecognized text.
    public static func parse(
        _ input: String,
        now: Date = Date(),
        calendar: Calendar = NaturalDateParser.defaultCalendar
    ) -> ParsedDate? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if let date = relativeOffset(lowered, now: now, calendar: calendar) {
            return ParsedDate(date: date, hasTime: false)
        }
        if let parsed = keywordDate(lowered, now: now, calendar: calendar) {
            return parsed
        }
        return detectorDate(trimmed)
    }

    // MARK: - Relative offsets (+1w, +3d, -2m, +1y)

    private static let offsetRegex = try? NSRegularExpression(
        pattern: #"^([+-])(\d+)\s*([dwmy])$"#,
        options: [.caseInsensitive]
    )

    private static func relativeOffset(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let regex = offsetRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let signRange = Range(match.range(at: 1), in: text),
              let numberRange = Range(match.range(at: 2), in: text),
              let unitRange = Range(match.range(at: 3), in: text),
              let magnitude = Int(text[numberRange]) else { return nil }

        let amount = text[signRange] == "-" ? -magnitude : magnitude
        let component: Calendar.Component
        switch text[unitRange].lowercased() {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        let base = calendar.startOfDay(for: now)
        return calendar.date(byAdding: component, value: amount, to: base)
    }

    // MARK: - Relative keywords

    private static func keywordDate(_ text: String, now: Date, calendar: Calendar) -> ParsedDate? {
        // Split off an optional "… at <time>" suffix.
        var dayPart = text
        var timePart: String?
        if let atRange = text.range(of: " at ") {
            dayPart = String(text[..<atRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            timePart = String(text[atRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        guard let day = relativeDay(dayPart, now: now, calendar: calendar) else { return nil }

        guard let timePart, let time = parseTime(timePart) else {
            return ParsedDate(date: day, hasTime: false)
        }
        let dated = calendar.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: day
        ) ?? day
        return ParsedDate(date: dated, hasTime: true)
    }

    /// Resolve a bare day phrase to that day's start (00:00).
    private static func relativeDay(_ text: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch text {
        case "today", "tonight":
            return today
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: today)
        default:
            break
        }
        // "next monday" / "this friday" / "monday" → the nearest strictly-future
        // occurrence of that weekday.
        let cleaned = text
            .replacingOccurrences(of: "next ", with: "")
            .replacingOccurrences(of: "this ", with: "")
            .replacingOccurrences(of: "coming ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let weekday = Self.weekdays[cleaned] else { return nil }
        let current = calendar.component(.weekday, from: today)
        var delta = weekday - current
        if delta <= 0 { delta += 7 }        // always land on a future weekday
        return calendar.date(byAdding: .day, value: delta, to: today)
    }

    /// Gregorian weekday numbers (Sunday = 1 … Saturday = 7).
    private static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7
    ]

    // MARK: - Time parsing (3, 3pm, 3:30, 15:00)

    private static let timeRegex = try? NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#,
        options: [.caseInsensitive]
    )

    private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        guard let regex = timeRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let hourRange = Range(match.range(at: 1), in: text),
              var hour = Int(text[hourRange]) else { return nil }

        var minute = 0
        if let minuteRange = Range(match.range(at: 2), in: text), let value = Int(text[minuteRange]) {
            minute = value
        }
        if let meridiemRange = Range(match.range(at: 3), in: text) {
            switch text[meridiemRange].lowercased() {
            case "pm" where hour < 12: hour += 12
            case "am" where hour == 12: hour = 0
            default: break
            }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    // MARK: - NSDataDetector fallback (absolute dates)

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    private static func detectorDate(_ text: String) -> ParsedDate? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let date = match.date else { return nil }
        return ParsedDate(date: date, hasTime: false)
    }
}

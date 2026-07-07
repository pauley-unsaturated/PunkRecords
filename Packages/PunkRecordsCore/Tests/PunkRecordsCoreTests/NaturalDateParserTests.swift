import Foundation
import Testing
@testable import PunkRecordsCore

@Suite("NaturalDateParser Tests")
struct NaturalDateParserTests {
    /// A fixed UTC Gregorian calendar and reference date so every relative
    /// result is deterministic. 2026-07-07 is a Tuesday.
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 0, _ mm: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm))!
    }

    private var now: Date { date(2026, 7, 7) }

    private func parse(_ input: String) -> ParsedDate? {
        NaturalDateParser.parse(input, now: now, calendar: calendar)
    }

    // MARK: - Relative offsets

    @Test("+1w advances one week")
    func plusOneWeek() {
        let result = parse("+1w")
        #expect(result?.date == date(2026, 7, 14))
        #expect(result?.hasTime == false)
    }

    @Test("Day, month, year offsets with signs")
    func offsets() {
        #expect(parse("+3d")?.date == date(2026, 7, 10))
        #expect(parse("-2m")?.date == date(2026, 5, 7))
        #expect(parse("+1y")?.date == date(2027, 7, 7))
        #expect(parse("-5d")?.date == date(2026, 7, 2))
    }

    // MARK: - Keywords

    @Test("today / tomorrow / yesterday")
    func dayKeywords() {
        #expect(parse("today")?.date == date(2026, 7, 7))
        #expect(parse("tomorrow")?.date == date(2026, 7, 8))
        #expect(parse("yesterday")?.date == date(2026, 7, 6))
        #expect(parse("Tomorrow")?.date == date(2026, 7, 8))   // case-insensitive
    }

    @Test("next Monday lands on the nearest future Monday")
    func nextMonday() {
        // 2026-07-07 is Tuesday, so the next Monday is 2026-07-13.
        #expect(parse("next Monday")?.date == date(2026, 7, 13))
        #expect(parse("monday")?.date == date(2026, 7, 13))
        #expect(calendar.component(.weekday, from: parse("next Monday")!.date) == 2)
    }

    @Test("A weekday later in the same week resolves within the week")
    func sameWeekWeekday() {
        // Tuesday → the coming Friday is 2026-07-10.
        #expect(parse("friday")?.date == date(2026, 7, 10))
    }

    // MARK: - Time suffix

    @Test("tomorrow at 3pm sets an afternoon time")
    func tomorrowAtTime() {
        let result = parse("tomorrow at 3pm")
        #expect(result?.date == date(2026, 7, 8, 15, 0))
        #expect(result?.hasTime == true)
    }

    @Test("24-hour and minute times parse")
    func explicitTimes() {
        #expect(parse("tomorrow at 15:30")?.date == date(2026, 7, 8, 15, 30))
        #expect(parse("today at 9am")?.date == date(2026, 7, 7, 9, 0))
        let bare = parse("tomorrow at 3")
        #expect(bare?.hasTime == true)
        #expect(calendar.component(.hour, from: bare!.date) == 3)
    }

    // MARK: - Absolute fallback + formatting

    @Test("Absolute dates fall through to NSDataDetector")
    func absoluteFallback() {
        #expect(parse("July 10, 2026") != nil)
    }

    @Test("Unrecognized input returns nil")
    func unrecognized() {
        #expect(parse("") == nil)
        #expect(parse("not a date at all") == nil)
        #expect(parse("+9z") == nil)
    }

    @Test("Canonical string drops time unless one was given")
    func canonicalFormatting() {
        #expect(ParsedDate(date: date(2026, 7, 10), hasTime: false).canonicalString(calendar: calendar) == "2026-07-10")
        #expect(ParsedDate(date: date(2026, 7, 10, 15, 30), hasTime: true).canonicalString(calendar: calendar) == "2026-07-10 15:30")
        // The parser's own output formats back to a stable string.
        #expect(parse("+1w")?.canonicalString(calendar: calendar) == "2026-07-14")
    }
}

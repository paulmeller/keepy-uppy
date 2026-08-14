import XCTest
@testable import KeepyUppy

final class TriggerScheduleTests: XCTestCase {
    /// A fixed zone, so a run in Sydney and a run in CI agree. `Calendar.current`
    /// is the shipping default; pinning it here is what makes the boundary cases
    /// below mean anything.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    private func schedule(_ days: UInt8, _ start: Int, _ end: Int) -> TriggerSchedule {
        TriggerSchedule(dayMask: days, startMinute: start, endMinute: end)
    }

    private let nineToSix = (9 * 60, 18 * 60)

    // MARK: - The ordinary case

    func testWeekdayWindowMatchesInsideAndNotOutside() {
        let s = schedule(TriggerSchedule.weekdays, nineToSix.0, nineToSix.1)
        // 2026-08-12 is a Wednesday.
        XCTAssertTrue(s.includes(date("2026-08-12 09:00"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-12 13:30"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-12 08:59"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-12 18:00"), calendar: calendar))
    }

    /// The window is half-open: it opens *on* the start minute and closes
    /// *before* the end minute. Pinned because an off-by-one here is a session
    /// that starts a minute late every day, which nobody would report as a bug.
    func testTheWindowIsHalfOpen() {
        let s = schedule(TriggerSchedule.everyDay, 600, 660)
        XCTAssertTrue(s.includes(date("2026-08-12 10:00"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-12 10:59"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-12 11:00"), calendar: calendar))
    }

    func testAWeekdayRuleIsSilentAtTheWeekend() {
        let s = schedule(TriggerSchedule.weekdays, nineToSix.0, nineToSix.1)
        // 2026-08-15 is a Saturday, 2026-08-16 a Sunday.
        XCTAssertFalse(s.includes(date("2026-08-15 13:00"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-16 13:00"), calendar: calendar))
    }

    func testWeekendMaskIsSaturdayAndSunday() {
        let s = schedule(TriggerSchedule.weekends, nineToSix.0, nineToSix.1)
        XCTAssertTrue(s.includes(date("2026-08-15 13:00"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-16 13:00"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-14 13:00"), calendar: calendar))
    }

    // MARK: - Crossing midnight

    /// The case the day mask is easy to get wrong: a Friday-night rule must run
    /// into Saturday morning **without Saturday being ticked**.
    func testAnOvernightWindowBelongsToTheDayItOpensOn() {
        let fridayOnly: UInt8 = 1 << 5  // Friday
        let s = schedule(fridayOnly, 22 * 60, 6 * 60)
        // 2026-08-14 is a Friday.
        XCTAssertTrue(s.includes(date("2026-08-14 22:00"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-14 23:59"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-15 00:30"), calendar: calendar), "Saturday small hours")
        XCTAssertTrue(s.includes(date("2026-08-15 05:59"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-15 06:00"), calendar: calendar), "window closed")
    }

    /// …and the mirror of it: the same rule must NOT open on Saturday evening
    /// just because Saturday saw the tail of it that morning.
    func testAnOvernightWindowDoesNotReopenOnTheFollowingEvening() {
        let fridayOnly: UInt8 = 1 << 5
        let s = schedule(fridayOnly, 22 * 60, 6 * 60)
        XCTAssertFalse(s.includes(date("2026-08-15 22:30"), calendar: calendar))
    }

    /// Sunday's tail lands on Monday, which is the wrap in the modulo.
    func testAnOvernightWindowWrapsFromSundayToMonday() {
        let sundayOnly: UInt8 = 1 << 0
        let s = schedule(sundayOnly, 23 * 60, 60)
        // 2026-08-16 is a Sunday; 2026-08-17 the Monday after.
        XCTAssertTrue(s.includes(date("2026-08-16 23:30"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-08-17 00:30"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-17 01:00"), calendar: calendar))
    }

    // MARK: - Daylight saving

    /// The reason the comparison is on wall-clock components. Sydney springs
    /// forward on 2026-10-04: 02:00 becomes 03:00. A 09:00–18:00 rule must still
    /// be 09:00–18:00 that day, not 08:00–17:00.
    func testAWindowKeepsItsWallClockAcrossASpringForward() {
        let s = schedule(TriggerSchedule.everyDay, nineToSix.0, nineToSix.1)
        XCTAssertFalse(s.includes(date("2026-10-04 08:30"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-10-04 09:30"), calendar: calendar))
        XCTAssertTrue(s.includes(date("2026-10-04 17:30"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-10-04 18:30"), calendar: calendar))
    }

    /// The autumn side, where an hour happens twice. Both 02:30s are inside a
    /// window that covers 02:30, and neither is inside one that does not.
    func testAWindowKeepsItsWallClockAcrossAFallBack() {
        let s = schedule(TriggerSchedule.everyDay, 2 * 60, 3 * 60)
        // Sydney falls back on 2026-04-05.
        XCTAssertTrue(s.includes(date("2026-04-05 02:30"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-04-05 03:30"), calendar: calendar))
    }

    // MARK: - Windows that can never match

    /// **The dangerous one.** An unguarded overnight comparison reads
    /// `start == end` as "every minute of the day", which is a Mac held awake
    /// forever by a rule its owner thought was blank.
    func testAZeroLengthWindowNeverMatchesRatherThanAlwaysMatching() {
        let s = schedule(TriggerSchedule.everyDay, 9 * 60, 9 * 60)
        XCTAssertFalse(s.includes(date("2026-08-12 09:00"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-12 03:00"), calendar: calendar))
        XCTAssertFalse(s.includes(date("2026-08-12 21:00"), calendar: calendar))
    }

    func testAScheduleWithNoDaysNeverMatches() {
        let s = schedule(0, nineToSix.0, nineToSix.1)
        XCTAssertFalse(s.includes(date("2026-08-12 13:00"), calendar: calendar))
    }

    func testProblemNamesBothWaysAScheduleCanBeUseless() {
        XCTAssertNotNil(TriggerSchedule.problem(dayMask: 0, startMinute: 540, endMinute: 1080))
        XCTAssertNotNil(TriggerSchedule.problem(dayMask: TriggerSchedule.everyDay,
                                                startMinute: 540, endMinute: 540))
        XCTAssertNil(TriggerSchedule.problem(dayMask: TriggerSchedule.weekdays,
                                             startMinute: 540, endMinute: 1080))
        // An overnight window is legitimate and must not be reported as a problem.
        XCTAssertNil(TriggerSchedule.problem(dayMask: TriggerSchedule.everyDay,
                                             startMinute: 22 * 60, endMinute: 6 * 60))
    }

    // MARK: - Encoding

    func testEncodingRoundTrips() throws {
        let s = schedule(TriggerSchedule.weekdays, 9 * 60, 18 * 60)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(TriggerSchedule.self, from: data), s)
    }

    /// The days encode as **one number**, which is the whole reason `dayMask`
    /// is not a `Set<Weekday>`: a set is written as an array, and no encoder
    /// promises the order of one, so an otherwise-untouched rule would rewrite
    /// itself differently on some launches.
    ///
    /// Note what this does *not* claim. Whole-struct byte stability is not the
    /// property being bought here and is not available by default —
    /// `JSONEncoder` does not order a struct's keys unless asked
    /// (`.sortedKeys`), so two encodes of one value can differ byte-for-byte
    /// while both decode identically. The day set's *own* representation is
    /// what had to be pinned, and a scalar pins it.
    func testTheDaySetEncodesAsASingleStableNumber() throws {
        let s = schedule(TriggerSchedule.weekdays, 9 * 60, 18 * 60)
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(s)) as? [String: Any]
        XCTAssertEqual(object?["dayMask"] as? Int, Int(TriggerSchedule.weekdays))

        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        XCTAssertEqual(try sorted.encode(s), try sorted.encode(s))
    }

    func testWeekdayMaskCoversMondayToFridayOnly() {
        let s = schedule(TriggerSchedule.weekdays, 0, TriggerSchedule.minutesPerDay - 1)
        XCTAssertFalse(s.includesDay(0), "Sunday")
        for day in 1...5 { XCTAssertTrue(s.includesDay(day), "weekday \(day)") }
        XCTAssertFalse(s.includesDay(6), "Saturday")
    }
}

extension TriggerScheduleTests {
    // MARK: - Parsing the CLI value

    func testParsingTheThreeDayShorthands() {
        XCTAssertEqual(TriggerSchedule(text: "weekdays 09:00-18:00")?.dayMask, TriggerSchedule.weekdays)
        XCTAssertEqual(TriggerSchedule(text: "weekends 10:00-16:00")?.dayMask, TriggerSchedule.weekends)
        XCTAssertEqual(TriggerSchedule(text: "daily 00:00-23:59")?.dayMask, TriggerSchedule.everyDay)
        XCTAssertEqual(TriggerSchedule(text: "everyday 00:00-23:59")?.dayMask, TriggerSchedule.everyDay)
    }

    func testParsingAnExplicitDayList() {
        let s = TriggerSchedule(text: "mon,wed,fri 22:00-06:00")
        XCTAssertEqual(s?.dayMask, (1 << 1) | (1 << 3) | (1 << 5))
        XCTAssertEqual(s?.startMinute, 22 * 60)
        XCTAssertEqual(s?.endMinute, 6 * 60)
    }

    func testParsingIsCaseInsensitive() {
        XCTAssertEqual(TriggerSchedule(text: "WeekDays 09:00-18:00"),
                       TriggerSchedule(text: "weekdays 09:00-18:00"))
    }

    func testParsingRejectsWhatCanNeverBeAWindow() {
        // A day that does not exist, and a typo for one that does.
        XCTAssertNil(TriggerSchedule(text: "funday 09:00-18:00"))
        XCTAssertNil(TriggerSchedule(text: "mon,tues 09:00-18:00"))
        // Zero length — the same value `problem(...)` refuses at the keyboard.
        XCTAssertNil(TriggerSchedule(text: "weekdays 09:00-09:00"))
        // 24:00 reads as end-of-day and is not a time a `Calendar` can produce.
        XCTAssertNil(TriggerSchedule(text: "weekdays 09:00-24:00"))
        XCTAssertNil(TriggerSchedule(text: "weekdays 09:60-18:00"))
        // Shape errors: no window, no days, no space.
        XCTAssertNil(TriggerSchedule(text: "weekdays"))
        XCTAssertNil(TriggerSchedule(text: "09:00-18:00"))
        XCTAssertNil(TriggerSchedule(text: "weekdays09:00-18:00"))
        XCTAssertNil(TriggerSchedule(text: ""))
    }

    func testAParsedScheduleMatchesTheSameWindowAsAHandBuiltOne() {
        XCTAssertEqual(TriggerSchedule(text: "weekdays 09:00-18:00"),
                       schedule(TriggerSchedule.weekdays, 9 * 60, 18 * 60))
    }
}

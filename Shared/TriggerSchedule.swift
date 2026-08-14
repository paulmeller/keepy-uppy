import Foundation

/// A recurring wall-clock window — "weekdays, 09:00 until 18:00".
///
/// Pure, and told the time rather than reading it, for the reason every engine
/// in `Shared/` is: a window that spans a year is tested in a millisecond, and
/// the tests that matter here are the ones about *when* — midnight, the last
/// minute before the window opens, the Sunday of a Friday-night rule — which
/// are unreachable if the type reads its own clock.
struct TriggerSchedule: Codable, Equatable, CustomStringConvertible {
    /// Bit 0 is Sunday … bit 6 is Saturday, matching `Calendar`'s 1-based
    /// `weekday` less one.
    ///
    /// A bitmask rather than a `Set<Weekday>` because a set encodes as an array
    /// whose element order no encoder promises. A preserved rule that re-encodes
    /// its days in a different order on every launch is a file that churns for
    /// no reason and a diff nobody can read — and this file's neighbours already
    /// refuse to leave encoded values "at the mercy of whatever the encoder
    /// does".
    var dayMask: UInt8
    /// Minutes since local midnight, `0..<1440`.
    var startMinute: Int
    /// Minutes since local midnight, `0..<1440`. May be *less* than
    /// `startMinute`, which is how a window crosses midnight.
    var endMinute: Int

    static let minutesPerDay = 1440

    /// Monday to Friday — the mask behind the "weekdays" preset.
    static let weekdays: UInt8 = 0b0111110
    /// Saturday and Sunday.
    static let weekends: UInt8 = 0b1000001
    static let everyDay: UInt8 = 0b1111111
}

extension TriggerSchedule {
    /// So that interpolating a schedule anywhere prints a window rather than
    /// its fields.
    ///
    /// `keepy-uppy sessions` interpolates `SessionKind` directly, which is fine
    /// for a case carrying a name or a number and became
    /// `whileOnSchedule(keepy_uppy.TriggerSchedule(dayMask: 65, startMinute:
    /// 360, endMinute: 1380))` the moment a case carried a struct. Conforming
    /// here fixes that line and every future one, rather than teaching one
    /// print statement about one case.
    var description: String { describe() }

    func includesDay(_ dayIndex: Int) -> Bool {
        guard (0..<7).contains(dayIndex) else { return false }
        return dayMask & (1 << UInt8(dayIndex)) != 0
    }

    /// Whether `date`, read in `calendar`'s time zone, falls inside the window.
    ///
    /// **Wall clock, deliberately, which is what makes daylight saving a
    /// non-event.** The comparison is on the hour and minute a person would
    /// read off the wall, so a 09:00–18:00 rule is 09:00–18:00 on both sides of
    /// a clock change. Storing an absolute offset instead would silently shift
    /// the window by an hour twice a year, on a machine nobody was watching —
    /// which is the whole failure mode of a scheduled trigger.
    func includes(_ date: Date, calendar: Calendar = .current) -> Bool {
        // A window with no width can never match, and is refused at the
        // keyboard by `problem(...)`. This is the belt to those braces — and it
        // must not be read as "always", which is what an unguarded
        // `minutes >= start || minutes < end` would do to it: a Mac held awake
        // forever by a rule the user thought was empty.
        guard startMinute != endMinute else { return false }
        guard dayMask != 0 else { return false }

        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour,
              let minute = parts.minute else { return false }
        let minutes = hour * 60 + minute
        let today = weekday - 1
        let yesterday = (today + 6) % 7

        if startMinute < endMinute {
            return includesDay(today) && minutes >= startMinute && minutes < endMinute
        }

        // Crosses midnight, and **the window belongs to the day it opens on**.
        // A "Friday, 22:00–06:00" rule runs into Saturday morning without
        // Saturday being ticked, because that is what a person means by Friday
        // night. Keying the tail to the day it *ends* on would make the same
        // rule need two days ticked to express one night, and would start a
        // second window at 00:00 Friday that nobody asked for.
        return (includesDay(today) && minutes >= startMinute)
            || (includesDay(yesterday) && minutes < endMinute)
    }

    /// "weekdays, 9:00 am to 6:00 pm" — the schedule as a person would say it.
    ///
    /// The time is formatted for the reader's locale (a 24-hour Mac gets
    /// "18:00"), but the *day* names are the calendar's short symbols rather
    /// than anything hand-written, so a non-English Mac does not get an English
    /// "Mon". `weekdays`/`weekends`/`every day` are named rather than listed
    /// because "Mon, Tue, Wed, Thu, Fri" in a menu row is noise where one word
    /// will do.
    func describe(calendar: Calendar = .current,
                  locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0,
                                                        locale: locale) ?? "HH:mm"

        func clock(_ minute: Int) -> String {
            var parts = DateComponents()
            parts.year = 2000; parts.month = 1; parts.day = 1
            parts.hour = minute / 60; parts.minute = minute % 60
            guard let date = calendar.date(from: parts) else {
                return String(format: "%02d:%02d", minute / 60, minute % 60)
            }
            return formatter.string(from: date)
        }

        let days: String
        switch dayMask {
        case TriggerSchedule.everyDay: days = "Every day"
        case TriggerSchedule.weekdays: days = "Weekdays"
        case TriggerSchedule.weekends: days = "Weekends"
        default:
            let symbols = calendar.shortWeekdaySymbols
            days = (0..<7).filter(includesDay).map { symbols[$0] }.joined(separator: ", ")
        }
        return "\(days), \(clock(startMinute)) to \(clock(endMinute))"
    }

    /// Parses `"weekdays 09:00-18:00"`, `"mon,wed,fri 22:00-06:00"`,
    /// `"daily 00:00-23:59"`. Nil when the text is not that.
    ///
    /// **The day names are English, and only English** — unlike `describe()`,
    /// which localises them. A flag in a script is not read by a person in
    /// their own language; it is typed once, committed, and run on machines
    /// whose locale nobody checked. `USBDeviceID(text:)` makes the same trade
    /// for the same reason.
    init?(text: String) {
        let parts = text.lowercased().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }

        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var mask: UInt8 = 0
        switch parts[0] {
        case "weekdays": mask = TriggerSchedule.weekdays
        case "weekends": mask = TriggerSchedule.weekends
        case "daily", "everyday": mask = TriggerSchedule.everyDay
        default:
            for token in parts[0].split(separator: ",") {
                guard let index = names.firstIndex(of: String(token)) else { return nil }
                mask |= (1 << UInt8(index))
            }
        }
        guard mask != 0 else { return nil }

        let window = parts[1].split(separator: "-")
        guard window.count == 2,
              let start = TriggerSchedule.parseClock(String(window[0])),
              let end = TriggerSchedule.parseClock(String(window[1])),
              start != end
        else { return nil }

        self.init(dayMask: mask, startMinute: start, endMinute: end)
    }

    /// `"09:00"` to `540`. Rejects anything that is not two numbers in range —
    /// including `"24:00"`, which reads as a legitimate end-of-day and is not:
    /// the last minute of a day is `23:59`, and accepting `24:00` would store a
    /// minute count no `Calendar` component can ever equal.
    private static func parseClock(_ text: String) -> Int? {
        let bits = text.split(separator: ":")
        guard bits.count == 2, let hour = Int(bits[0]), let minute = Int(bits[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Why this schedule can never match anything, or `nil` if it can.
    ///
    /// The sibling of `TriggerRule.subnetProblem` and `usbDeviceProblem`, and it
    /// exists for their two reasons: the rule has one statement, and that
    /// statement is testable without a UI.
    static func problem(dayMask: UInt8, startMinute: Int, endMinute: Int) -> String? {
        if dayMask == 0 {
            return "Pick at least one day — a schedule with no days can never fire."
        }
        if startMinute == endMinute {
            return "Start and end are the same time, so the window has no length. "
                + "For a whole day, use 00:00 to 23:59."
        }
        return nil
    }
}

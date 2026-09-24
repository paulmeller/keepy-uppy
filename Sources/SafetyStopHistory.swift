import Foundation

/// The per-user, durable answer to "why did it turn off?".
///
/// ## Why this exists at all, next to `SafetyStopLog`
///
/// The daemon already records every guard stop — but it forgets after five
/// minutes, and `Shared/SafetyStopLog.swift` argues at length for why that
/// bound must stay small: it is a *root* process, its log holds other accounts'
/// session ids, and the size of that memory must not be reachable from a user
/// setting. All of that is right, and none of it is going to change.
///
/// What it leaves behind is a user who was asleep, in a meeting, or simply
/// looking the other way when a guard fired, and for whom the machine's
/// behaviour is therefore indistinguishable from random. Before this type, the
/// only way to be told was a notification: transient, easy to miss, off by
/// default, and — on a Mac whose `usernotificationsd` is unwell — never
/// delivered at all. One missed banner and the reason was gone for good.
///
/// So the durable copy lives **here**, in the per-user app, and holds only this
/// user's own stops. That split is the same one the rest of the codebase makes:
/// the daemon keeps the minimum it needs to enforce, and anything that is
/// merely *about* a user is kept by the per-user process that serves them.
///
/// ## Bounds
///
/// Ten entries, and no age bound at all. The daemon's limits protect a root
/// process's memory and other accounts' privacy; neither concern applies to a
/// user's own list of their own stops, and an age bound here would recreate
/// exactly the failure this type exists to fix — an explanation that expires
/// before the user thinks to look for it. Ten is enough to show a pattern
/// ("this is the third thermal stop today") and small enough that the
/// preference it is written to stays trivial.
struct SafetyStopHistory: Equatable, Codable {
    static let maxEntries = 10

    /// Oldest first, so the newest is `last` and eviction is `removeFirst` —
    /// the same ordering convention, for the same readability reason, as
    /// `SafetyStopLog.entries`.
    private(set) var entries: [SafetyStopRecord] = []

    init() {}

    var mostRecent: SafetyStopRecord? { entries.last }

    /// How far the user has been caught up, as a timestamp rather than an id.
    ///
    /// **Optional, and it must stay optional**: it was added after the type was
    /// already being persisted, and a synthesised `init(from:)` decodes a
    /// missing key for an `Optional` rather than throwing. A non-optional here
    /// would have made every history saved before this existed undecodable —
    /// which `SafetyStopHistoryStore.load` would have quietly turned into "you
    /// have never had a stop", erasing exactly what this type is for.
    private var acknowledgedThrough: Date?

    /// The stop the menu should be showing, or nil when the user has already
    /// been told.
    ///
    /// Compared by time rather than by id so that dismissing catches up on
    /// everything at or before it, and a stop that arrives afterwards speaks
    /// up on its own.
    var unacknowledged: SafetyStopRecord? {
        guard let latest = mostRecent else { return nil }
        guard let seen = acknowledgedThrough else { return latest }
        return latest.endedAt > seen ? latest : nil
    }

    /// Marks everything currently recorded as seen. **Keeps the entries**: the
    /// menu line is a notice, while Settings is the record, and dismissing a
    /// notice is not asking for the record to be destroyed.
    mutating func acknowledge() {
        acknowledgedThrough = mostRecent?.endedAt
    }

    /// Absorbs what the daemon just reported, keeping only this user's stops
    /// and only ones not already known.
    ///
    /// **The dedupe is load-bearing, not hygiene.** The daemon keeps a record
    /// for five minutes and the app re-reads that log on every stop transition,
    /// so the same stop genuinely is offered more than once. A history that
    /// appended blindly would show one episode as several, which is worse than
    /// showing nothing: it invents a pattern.
    ///
    /// `ownerUID` is filtered here rather than trusted from the reply, exactly
    /// as `attributedStopEvent` does — the daemon's reply is unfiltered by
    /// design, and every consumer applies its own filter on the way in.
    mutating func record(_ records: [SafetyStopRecord], ownerUID: UInt32) {
        let known = Set(entries.map(\.sessionID))
        let new = records.filter { $0.ownerUID == ownerUID && !known.contains($0.sessionID) }
        guard !new.isEmpty else { return }

        entries.append(contentsOf: new.sorted { $0.endedAt < $1.endedAt })
        let excess = entries.count - Self.maxEntries
        if excess > 0 { entries.removeFirst(excess) }
    }
}

// MARK: - The words

/// The one phrase naming each guard, shared by the notification and every
/// surface that explains a stop afterwards.
///
/// Named once because the alternative is two vocabularies for one event: a user
/// who saw "the battery was running out" in a banner and later reads something
/// else in the menu has been given every reason to think there were two
/// incidents. `SafetyStopHistoryTests` asserts the notification title still
/// contains this phrase, so the two cannot drift apart silently.
func safetyStopReasonPhrase(_ reason: SafetyReason) -> String {
    switch reason {
    case .thermal: return "this Mac was too hot"
    case .lowBattery: return "the battery was running out"
    case .maxDuration: return "the time limit was reached"
    }
}

/// How long ago something happened, in the plainest words that are still true.
///
/// Deliberately not `RelativeDateTimeFormatter`: it is locale- and
/// style-dependent ("10 min. ago", "10 minutes ago"), which makes the sentence
/// it appears in untestable without asserting on the formatter's current mood.
/// A stop explanation is read once, in a menu, and does not need more precision
/// than this.
func agoText(_ interval: TimeInterval) -> String {
    let seconds = Int(max(0, interval))
    func plural(_ n: Int, _ unit: String) -> String {
        "\(n) \(unit)\(n == 1 ? "" : "s") ago"
    }
    switch seconds {
    case ..<60: return "just now"
    case ..<3_600: return plural(seconds / 60, "minute")
    case ..<86_400: return plural(seconds / 3_600, "hour")
    default: return plural(seconds / 86_400, "day")
    }
}

/// The sentence a surface shows for one past stop.
func safetyStopSummary(_ record: SafetyStopRecord, now: Date) -> String {
    let when = agoText(now.timeIntervalSince(record.endedAt))
    return "Stopped \(when): \(safetyStopReasonPhrase(record.reason))"
}

// MARK: - Where it is kept

/// Persistence, shaped exactly like `SafetyConfigStore` so there is one way to
/// read a preference in this codebase rather than two.
///
/// Deliberately **not** in `Shared/`, unlike that one. `Shared/` compiles into
/// the root daemon and the CLI as well as the app, and neither has any business
/// with a user's list of their own stops — the daemon has its own five-minute
/// log and reads nothing back. Keeping this in `Sources/` means the app is the
/// only process that can see it, which is what "per-user" should mean.
enum SafetyStopHistoryStore {
    private static let key = "safetyStopHistory"

    /// The storage key, for the test that writes deliberate rubbish to it. A
    /// test that hardcoded the string would still pass after the key was
    /// renamed, while silently testing nothing.
    static var keyForTesting: String { key }

    private static var defaults: UserDefaults { PreferencesSuite.defaults }

    /// Empty — never a crash and never a fabricated entry — when there is
    /// nothing readable there. An explanation is a convenience; failing to load
    /// one must cost the user the explanation and nothing else.
    static func load() -> SafetyStopHistory {
        guard let data = defaults.data(forKey: key),
              let history = try? JSONDecoder().decode(SafetyStopHistory.self, from: data)
        else { return SafetyStopHistory() }
        return history
    }

    static func save(_ history: SafetyStopHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: key)
    }
}

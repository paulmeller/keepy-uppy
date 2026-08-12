import Foundation

// MARK: - The record

/// One session ended by a safety guard, and why. The only thing in this
/// project that carries a `SafetyReason` outside the daemon.
///
/// One record per ended session rather than one per episode: a safety stop is
/// `.stopAll`, so a single episode ends every live session — including other
/// users' — and a client that must filter to its own uid needs the uid on each
/// record. That filter is applied on the way *in* everywhere else it exists
/// (`SessionCompletionTracker`, `SessionNotificationTracker`) for a reason that
/// was found the hard way, and this type is what makes it possible here.
///
/// `sessionID` is what makes the record *attributable* rather than merely
/// recent. The app matches records against the exact ids it just watched
/// disappear, so a five-minute-old thermal stop cannot be attached to a lease
/// that expired by itself a minute ago — which is the fabrication this whole
/// feature exists to avoid, one layer up.
///
/// **No member has a default, and none may gain one** — `Session`,
/// `PowerRequest` and `SessionNotificationPreferences` all carry the same
/// prohibition and the same scar tissue: three of `Session.init`'s parameters
/// had defaults and all three were silently substituted at a call site that
/// forgot to pass one.
struct SafetyStopRecord: Codable, Equatable {
    let sessionID: UUID
    let ownerUID: UInt32
    let reason: SafetyReason
    let endedAt: Date

    init(sessionID: UUID, ownerUID: UInt32, reason: SafetyReason, endedAt: Date) {
        self.sessionID = sessionID
        self.ownerUID = ownerUID
        self.reason = reason
        self.endedAt = endedAt
    }
}

// MARK: - The log

/// The daemon's bounded memory of guard-ended sessions.
///
/// Pure, and in `Shared/`, for `SessionTable.desiredPowerPlan`'s reason
/// exactly: `Helper/` is not reachable from the test target, so the part that
/// can be pure is. What stays in `Helper/DaemonRuntime.swift` is one call in
/// the `.stopAll` arm and one accessor, both confined to that type's serial
/// queue like every other piece of runtime state.
///
/// ## The safety arm is the only writer, and that is the whole value
///
/// Ordinary endings — expiry, a manual stop, a condition ending, the agent
/// disappearing, a client disconnecting — are **not** recorded here. A record
/// in this log *means* a guard fired; a log that also held expiries would need
/// a discriminator on every record and would be a different feature (and the
/// client reading it would have to decide, again, which endings are worth a
/// sentence — a decision that already exists in exactly one place).
///
/// ## Bounded on both axes, and why each number is what it is
///
/// **Count — `maxRecords`.** One episode is a single `.stopAll`, so it can end
/// up to `SessionAdmission.maxSessionsGlobal` sessions at once, and an
/// unbounded buffer inside a root daemon is precisely the class of problem the
/// session caps themselves exist for: every scan over it is O(n) on the same
/// serial queue as the 5s safety timer and every XPC call. The bound is
/// therefore *derived from* that cap rather than written as a literal, so the
/// two cannot drift apart.
///
/// It is exactly one maximal episode and no more, deliberately:
/// * **Smaller** would let one episode evict its own oldest records, and since
///   `.stopAll` ends *every* user's sessions, the records evicted would be
///   whichever uid the table happened to enumerate first — a client filtering
///   to its own uid would find its reason missing for no reason it could ever
///   discover, on a Mac with two people logged in and not on a Mac with one.
/// * **Larger** buys nothing: nothing outside the daemon can use a record from
///   an episode two episodes ago (see the age bound), so the extra capacity
///   would only widen how long another account's session ids and uids sit in a
///   root process's memory.
///
/// **Age — `maxAge`.** A reason attached to an ending observed much later is a
/// reason for the *wrong* ending. Five minutes:
/// * **Much shorter** (say 10s) and the feature silently degrades to the
///   reason-free copy in exactly the case it was built for. The app's own
///   numbers bound how late it can legitimately observe an ending: a 3s poll,
///   a 5s per-call timeout, and a 3s reconnect delay — so roughly 11s for one
///   bad cycle, and a daemon restart costs a further reconnect plus the
///   deliberate no-baseline-on-the-first-snapshot tick.
/// * **Much longer** (say a day) and the daemon is holding facts about ended
///   sessions long after any client could honestly use one. The app's tracker
///   forgets its baseline on disconnect and announces nothing at all after a
///   relaunch, so a record that outlives the app's own memory can never be
///   attached to anything; it is dead weight in a root process, and every extra
///   minute is another minute of another account's session ids being readable.
///
/// Five minutes also happens to be `SafetyConfig.default.cooldown` — the period
/// a fired guard keeps triggers suppressed, i.e. how long the machine is still
/// considered to be in that episode. That is the right *order of magnitude*
/// argument, and it is why the number is not smaller. It is deliberately **not
/// written as** `SafetyConfig.cooldown`: that value is a user setting, and a
/// user editing their safety preferences must not be able to move how much
/// memory a root daemon holds, nor how long another account's session ids
/// survive in it.
///
/// Neither bound is a correctness mechanism for attribution — the app matches
/// on `sessionID` — so a wrong choice in either direction costs availability of
/// an explanation, never a wrong explanation.
struct SafetyStopLog {
    /// One maximal episode. Derived, never a literal — see the type comment.
    static let maxRecords = SessionAdmission.maxSessionsGlobal
    static let maxAge: TimeInterval = 300

    /// Oldest first. Insertion order is the eviction order, so "drop the oldest"
    /// is `removeFirst` rather than a sort, and a reader can see that the two
    /// agree.
    private var entries: [SafetyStopRecord] = []

    init() {}

    /// Appends an episode's records and applies both bounds.
    ///
    /// Takes an array rather than one record because that is the shape the only
    /// writer has: `sessions.apply(.stopAll, now:)` hands back every session it
    /// ended, and one episode's records must land together or the count bound
    /// could evict half of an episode that was still being written.
    mutating func record(_ records: [SafetyStopRecord], now: Date) {
        entries.append(contentsOf: records)
        prune(asOf: now)
    }

    /// Every record still inside both bounds, oldest first.
    ///
    /// **`asOf:` rather than the `since:` a caller chooses**, deliberately. A
    /// window supplied by the caller is a second opinion about what "recent"
    /// means, and two callers holding different opinions is how the daemon and
    /// the client come to disagree about the same question — the failure
    /// `bundleVersionText` exists to prevent one file over. This takes only the
    /// clock and applies the one bound the type owns.
    ///
    /// It is a *read* that reports the bound without applying it to storage, so
    /// that a daemon which never fires another guard still stops reporting aged
    /// records rather than reporting them until the next episode prunes them.
    func records(asOf now: Date) -> [SafetyStopRecord] {
        entries.filter { !Self.isExpired($0, asOf: now) }
    }

    /// How many records are being held, expired ones included — the memory
    /// bound, as opposed to what `records(asOf:)` is willing to report. Only
    /// the tests care, and they care because "the bound is real" is otherwise
    /// unobservable from outside.
    var storedCount: Int { entries.count }

    private mutating func prune(asOf now: Date) {
        entries.removeAll { Self.isExpired($0, asOf: now) }
        // The excess is computed into a local first: `entries.removeFirst(
        // entries.count - maxRecords)` reads and mutates `entries` in one
        // expression, which is an exclusivity violation rather than a style
        // preference.
        let excess = entries.count - Self.maxRecords
        if excess > 0 { entries.removeFirst(excess) }
    }

    /// `static`, and not an instance method, for the same exclusivity reason
    /// the local above exists: `entries.removeAll { isExpired(…) }` mutates
    /// `entries` while the predicate borrows `self`, which the compiler refuses
    /// outright.
    private static func isExpired(_ record: SafetyStopRecord, asOf now: Date) -> Bool {
        now.timeIntervalSince(record.endedAt) > maxAge
    }
}

import XCTest
@testable import KeepyUppy

/// The per-user memory of guard stops, and the sentence it produces.
///
/// This exists because the daemon's own `SafetyStopLog` deliberately forgets
/// after five minutes — it is a root process holding other accounts' session
/// ids, and `Shared/SafetyStopLog.swift` argues at length for why that bound
/// must stay small and must not be reachable from a user setting. A user who
/// was asleep, in a meeting, or simply looking elsewhere when a guard fired
/// still deserves an answer, so the durable copy lives here: in the per-user
/// app, holding only this user's own stops.
final class SafetyStopHistoryTests: XCTestCase {
    private let me: UInt32 = 501
    private let someoneElse: UInt32 = 502

    private func record(_ reason: SafetyReason,
                        uid: UInt32,
                        at endedAt: Date,
                        id: UUID = UUID()) -> SafetyStopRecord {
        SafetyStopRecord(sessionID: id, ownerUID: uid, reason: reason, endedAt: endedAt)
    }

    func testRecordingAGuardStopMakesItTheMostRecent() {
        var history = SafetyStopHistory()
        let stop = record(.lowBattery, uid: me, at: Date(timeIntervalSince1970: 100))

        history.record([stop], ownerUID: me)

        XCTAssertEqual(history.mostRecent, stop)
    }

    func testAStopBelongingToAnotherUserIsIgnored() {
        var history = SafetyStopHistory()

        history.record([record(.thermal, uid: someoneElse, at: Date())], ownerUID: me)

        XCTAssertNil(history.mostRecent,
                     "another account's stop is not this user's to be told about")
    }

    func testTheSameSessionIsNeverRecordedTwice() {
        var history = SafetyStopHistory()
        let id = UUID()
        let stop = record(.thermal, uid: me, at: Date(timeIntervalSince1970: 100), id: id)

        // The notifier re-reads the daemon's log on every stop transition, and
        // that log keeps a record for five minutes — so the same stop really is
        // offered more than once, and a history that appended blindly would
        // show one episode as several.
        history.record([stop], ownerUID: me)
        history.record([stop], ownerUID: me)

        XCTAssertEqual(history.entries.count, 1)
    }

    func testTheOldestIsEvictedBeyondTheBound() {
        var history = SafetyStopHistory()
        let overBy = 3
        for i in 0..<(SafetyStopHistory.maxEntries + overBy) {
            history.record([record(.maxDuration, uid: me, at: Date(timeIntervalSince1970: Double(i)))],
                           ownerUID: me)
        }

        XCTAssertEqual(history.entries.count, SafetyStopHistory.maxEntries)
        XCTAssertEqual(history.entries.first?.endedAt,
                       Date(timeIntervalSince1970: Double(overBy)),
                       "the oldest should have gone, not the newest")
    }

    func testEntriesAreOldestFirstSoTheMostRecentIsLast() {
        var history = SafetyStopHistory()
        let first = record(.thermal, uid: me, at: Date(timeIntervalSince1970: 10))
        let second = record(.lowBattery, uid: me, at: Date(timeIntervalSince1970: 20))

        history.record([first], ownerUID: me)
        history.record([second], ownerUID: me)

        XCTAssertEqual(history.entries, [first, second])
        XCTAssertEqual(history.mostRecent, second)
    }

    // MARK: - Dismissal

    func testTheMostRecentStopIsUnacknowledgedUntilItIsAcknowledged() {
        var history = SafetyStopHistory()
        let stop = record(.thermal, uid: me, at: Date(timeIntervalSince1970: 100))
        history.record([stop], ownerUID: me)

        XCTAssertEqual(history.unacknowledged, stop)

        history.acknowledge()

        XCTAssertNil(history.unacknowledged, "a dismissed stop stops nagging from the menu")
    }

    func testAcknowledgingKeepsTheStopInTheHistory() {
        var history = SafetyStopHistory()
        let stop = record(.lowBattery, uid: me, at: Date(timeIntervalSince1970: 100))
        history.record([stop], ownerUID: me)

        history.acknowledge()

        XCTAssertEqual(history.entries, [stop],
                       "dismissing the menu line must not erase the record Settings shows")
    }

    func testANewerStopIsUnacknowledgedEvenAfterAnEarlierOneWasDismissed() {
        var history = SafetyStopHistory()
        history.record([record(.thermal, uid: me, at: Date(timeIntervalSince1970: 100))], ownerUID: me)
        history.acknowledge()

        let newer = record(.lowBattery, uid: me, at: Date(timeIntervalSince1970: 200))
        history.record([newer], ownerUID: me)

        XCTAssertEqual(history.unacknowledged, newer,
                       "dismissing one stop must not silence the next one")
    }

    // MARK: - The sentence

    func testTheSummaryNamesTheGuardAndWhenItFired() {
        let now = Date(timeIntervalSince1970: 1_000)
        let stop = record(.lowBattery, uid: me, at: now.addingTimeInterval(-600))

        let summary = safetyStopSummary(stop, now: now)

        XCTAssertTrue(summary.contains("battery"), "got: \(summary)")
        XCTAssertTrue(summary.contains("10 minutes ago"), "got: \(summary)")
    }

    func testEveryReasonHasItsOwnPhrase() {
        let phrases = SafetyReason.allCases.map(safetyStopReasonPhrase)

        XCTAssertEqual(Set(phrases).count, SafetyReason.allCases.count,
                       "two guards sharing a sentence is a user who cannot tell them apart")
    }

    /// The menu line and the notification must not be two vocabularies for the
    /// same event: a user who saw the banner and later opens the menu should
    /// read the same words, not a second wording that invites the question of
    /// whether it is a second incident.
    func testThePhraseIsTheOneTheNotificationWouldHaveUsed() {
        for reason in SafetyReason.allCases {
            let copy = sessionNotificationCopy(for: sessionNotificationEvent(for: reason))
            XCTAssertTrue(copy.title.contains(safetyStopReasonPhrase(reason)),
                          "\(reason): notification says “\(copy.title)”, "
                            + "menu would say “\(safetyStopReasonPhrase(reason))”")
        }
    }
}

/// Persistence for the history above.
///
/// Mirrors `SafetyConfigStoreTests`, including its `setUp`: that test learned
/// the hard way that clearing `PreferencesSuite.name` in this process clears
/// the *shipping* domain, so the guard is asserted rather than assumed.
final class SafetyStopHistoryStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        XCTAssertTrue(PreferencesSuite.removeAllValuesForTesting(),
                      "refused to clear the suite — it is the shipping one")
    }

    func testLoadWithNothingSavedReturnsAnEmptyHistory() {
        XCTAssertNil(SafetyStopHistoryStore.load().mostRecent)
    }

    func testSaveThenLoadRoundTrips() {
        var history = SafetyStopHistory()
        let stop = SafetyStopRecord(sessionID: UUID(),
                                    ownerUID: 501,
                                    reason: .thermal,
                                    endedAt: Date(timeIntervalSince1970: 42))
        history.record([stop], ownerUID: 501)

        SafetyStopHistoryStore.save(history)

        XCTAssertEqual(SafetyStopHistoryStore.load().mostRecent, stop)
    }

    /// An explanation is a convenience, never a correctness mechanism, so
    /// unreadable storage must degrade to "nothing to tell you" rather than
    /// take the app down on launch.
    func testUnreadableStorageReadsAsEmpty() {
        PreferencesSuite.defaults.set(Data([0x00, 0x01]), forKey: SafetyStopHistoryStore.keyForTesting)

        XCTAssertNil(SafetyStopHistoryStore.load().mostRecent)
    }
}

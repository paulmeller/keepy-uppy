import XCTest
@testable import KeepyUppy

final class SessionCompletionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Same fallback-domain reasoning as TriggerRuleTests.setUp() — this
        // test host is the app process itself, so `.standard` is where
        // `SessionCompletionStore` actually lands.
        UserDefaults.standard.removePersistentDomain(forName: PreferencesSuite.name)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(id: UUID = UUID()) -> Session {
        Session(id: id, kind: .indefinite, owner: ClientID(rawValue: "x"),
               persistence: .detached, origin: .manual, startedAt: t0)
    }

    // MARK: - sessionsEndedSince

    func testNoChangeReportsNothingEnded() {
        let a = session()
        XCTAssertTrue(sessionsEndedSince(previous: [a], current: [a]).isEmpty)
    }

    func testDisappearedSessionIsReportedEnded() {
        let a = session()
        let b = session()
        let ended = sessionsEndedSince(previous: [a, b], current: [b])
        XCTAssertEqual(ended.map(\.id), [a.id])
    }

    func testMultipleDisappearedSessionsAreAllReported() {
        let a = session()
        let b = session()
        let ended = sessionsEndedSince(previous: [a, b], current: [])
        XCTAssertEqual(Set(ended.map(\.id)), Set([a.id, b.id]))
    }

    func testStillPresentSessionIsNeverReported() {
        let a = session()
        XCTAssertTrue(sessionsEndedSince(previous: [a], current: [a, session()]).isEmpty)
    }

    func testNewlyAppearedSessionIsNeverReportedAsEnded() {
        let ended = sessionsEndedSince(previous: [], current: [session()])
        XCTAssertTrue(ended.isEmpty)
    }

    // MARK: - SessionCompletionStore

    func testDefaultConfigHasNothingConfigured() {
        let config = SessionCompletionStore.load()
        XCTAssertNil(config.scriptPath)
        XCTAssertNil(config.webhookURL)
    }

    func testStoreSaveThenLoadRoundTrips() {
        let config = SessionCompletionConfig(scriptPath: "/usr/local/bin/notify.sh",
                                             webhookURL: "https://example.com/hook")
        SessionCompletionStore.save(config)
        XCTAssertEqual(SessionCompletionStore.load(), config)
    }

    func testStoreRoundTripsWithOnlyOneFieldSet() {
        let config = SessionCompletionConfig(scriptPath: nil, webhookURL: "https://example.com/hook")
        SessionCompletionStore.save(config)
        XCTAssertEqual(SessionCompletionStore.load(), config)
    }
}

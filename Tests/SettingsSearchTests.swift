import XCTest
@testable import KeepyUppy

final class SettingsSearchTests: XCTestCase {
    func testABlankQueryFindsNothingRatherThanEverything() {
        XCTAssertTrue(searchSettings("").isEmpty)
        XCTAssertTrue(searchSettings("   ").isEmpty)
    }

    /// The whole reason `keywords` exists: people search for the problem, not
    /// for the label. None of these words appear in the title they must find.
    func testTheProblemFindsTheControlThatSolvesIt() {
        func tabFor(_ query: String) -> SettingsTab? { searchSettings(query).first?.tab }
        XCTAssertEqual(tabFor("hot"), .safety, "an overheating Mac")
        XCTAssertEqual(tabFor("throttle"), .safety)
        XCTAssertEqual(tabFor("clamshell"), .display, "lid-closed behaviour")
        XCTAssertEqual(tabFor("spin down"), .display, "external drives")
        XCTAssertEqual(tabFor("hotkey"), .advanced)
        XCTAssertEqual(tabFor("usr local bin"), .advanced)
        XCTAssertEqual(tabFor("weekdays"), .triggers, "the scheduled trigger")
        XCTAssertEqual(tabFor("root"), .general, "why it wants a daemon")
    }

    func testMatchingIsCaseAndDiacriticInsensitiveAndOnSubstrings() {
        XCTAssertFalse(searchSettings("THERM").isEmpty)
        XCTAssertFalse(searchSettings("therm").isEmpty, "a half-typed word still matches")
        XCTAssertEqual(searchSettings("Battery").first?.tab, .safety)
    }

    /// A title match beats a keyword match, so typing an exact label puts that
    /// label first rather than burying it under something that merely mentions
    /// it.
    func testTitleMatchesSortAboveKeywordMatches() {
        let results = searchSettings("battery")
        XCTAssertEqual(results.first?.title, "Battery")
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        XCTAssertTrue(searchSettings("xyzzy").isEmpty)
    }

    /// Catches a whole tab dropping out of the index — the failure worth
    /// automating, since the index itself is hand-maintained and a missing
    /// *entry* is invisible while a missing *tab* means a pane nobody can find.
    func testEveryTabIsReachableFromSearch() {
        let covered = Set(settingsIndex.map(\.tab))
        XCTAssertEqual(covered, Set(SettingsTab.allCases),
                       "a tab has no searchable settings: \(Set(SettingsTab.allCases).subtracting(covered))")
    }

    func testEveryIndexEntryHasKeywordsAndATitle() {
        for entry in settingsIndex {
            XCTAssertFalse(entry.title.isEmpty)
            XCTAssertFalse(entry.keywords.isEmpty, "\(entry.title) can only be found by its own label")
        }
    }
}

final class MenuBarIconStyleTests: XCTestCase {
    /// **Every style must draw two different glyphs.** The menu bar's one job
    /// is to answer "is this Mac being held awake" without being clicked, and a
    /// style whose active and idle symbols matched would silently delete that
    /// answer for anyone who picked it.
    func testEveryStyleDistinguishesActiveFromIdle() {
        for style in MenuBarIconStyle.allCases {
            XCTAssertNotEqual(style.symbol(active: true), style.symbol(active: false),
                              "\(style) looks the same whether or not the Mac is awake")
            XCTAssertFalse(style.symbol(active: true).isEmpty)
            XCTAssertFalse(style.label.isEmpty)
        }
    }

    /// An unknown stored value falls back rather than drawing nothing — an
    /// unresolvable SF Symbol renders as an invisible menu bar item, which is
    /// indistinguishable from the app having crashed.
    func testAnUnknownStoredStyleFallsBack() {
        XCTAssertEqual(MenuBarIconStylePreference.style(rawValue: "hologram"),
                       MenuBarIconStylePreference.fallback)
        XCTAssertEqual(MenuBarIconStylePreference.style(rawValue: ""),
                       MenuBarIconStylePreference.fallback)
        XCTAssertEqual(MenuBarIconStylePreference.style(rawValue: "sun"), .sun)
    }

    func testTheDefaultIsStillTheBalloon() {
        XCTAssertEqual(MenuBarIconStylePreference.fallback, .balloon)
        XCTAssertEqual(MenuBarIconStylePreference.style(
            rawValue: MenuBarIconStylePreference.defaultRawValue), .balloon)
    }
}

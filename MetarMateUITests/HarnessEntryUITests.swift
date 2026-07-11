import XCTest

// Regression guard for the METAR Injection harness ENTRY gesture. The original 5-second long-press on
// the nav-bar header could never fire — iOS's system gesture gate owns the top screen edge ("System
// gesture gate timed out"). The fix moved entry to FIVE taps on a content-area chip
// (accessibilityIdentifier "harnessEntryChip"). This test proves those 5 taps open the harness.
//
// The chip is gated on TestHarnessGate.isAvailable (sandbox receipt), so it is ABSENT on a build whose
// receipt isn't "sandboxReceipt" — including some simulators, which report "receipt". On those the test
// SKIPS (honestly) rather than failing; the gate is deliberately NOT loosened to make it pass. Run on a
// Debug device or a sandbox-receipt simulator to exercise the guard for real.
final class HarnessEntryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFiveTapChipOpensHarness() throws {
        let app = XCUIApplication()
        app.launch()

        // Favorites tab (survives the splash screen via the wait).
        let favorites = app.tabBars.buttons["Favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 15), "Favorites tab never appeared")
        favorites.tap()

        let chip = app.descendants(matching: .any).matching(identifier: "harnessEntryChip").firstMatch
        guard chip.waitForExistence(timeout: 5) else {
            throw XCTSkip("harnessEntryChip absent — TestHarnessGate is closed on this build (receiptName != \"sandboxReceipt\"). Run on a Debug device or sandbox-receipt simulator to exercise this guard.")
        }

        // Five taps — the deliberately-not-accidental entry gesture.
        for _ in 0..<5 { chip.tap() }

        XCTAssertTrue(app.navigationBars["METAR Injection"].waitForExistence(timeout: 5),
                      "Five taps on the entry chip did not open the METAR Injection harness")
    }
}

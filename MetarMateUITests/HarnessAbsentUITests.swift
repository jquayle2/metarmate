import XCTest

// App Store guard for the METAR Injection harness (audit #21). The harness and its entry chip are
// compiled only into Debug and TestFlight builds (`#if DEBUG || TESTFLIGHT`). This test proves the
// effect, not the construction: in a Release build without TESTFLIGHT the Favorites screen has no
// "harnessEntryChip" at all.
//
// The app is launched with -UITestForceHarnessGate, which opens the harness's runtime receipt gate
// in the simulator. So the only thing that can keep the chip off screen in Release is the code
// being absent. The UI-test bundle is built with the same configuration as the app, so the same
// conditions tell the test which build it is looking at:
//   • Debug / TestFlight: the chip must be PRESENT (positive control: the argument and the query work).
//   • Release:            the chip must be ABSENT.
// Run it against Release explicitly. ENABLE_TESTABILITY=YES only lets the unit-test target link;
// it doesn't change the #if conditions:
//   xcodebuild test -scheme MetarMate -configuration Release ENABLE_TESTABILITY=YES -destination "platform=iOS Simulator,name=iPhone 17" -only-testing:MetarMateUITests/HarnessAbsentUITests
final class HarnessAbsentUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHarnessChipOnlyInDebugAndTestFlightBuilds() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-UITestForceHarnessGate")
        app.launch()

        let favorites = app.tabBars.buttons["Favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 15), "Favorites tab never appeared")
        favorites.tap()

        let chip = app.descendants(matching: .any).matching(identifier: "harnessEntryChip").firstMatch
        #if DEBUG || TESTFLIGHT
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "harnessEntryChip missing in a Debug/TestFlight build with the gate forced open")
        #else
        XCTAssertFalse(chip.waitForExistence(timeout: 5), "harnessEntryChip is present in a Release build without TESTFLIGHT")
        #endif
    }
}

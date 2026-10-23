import XCTest

// The version line at the bottom of Customize Layout says "· TestFlight" in TestFlight builds, so a
// tester build is never mistaken for the App Store one (Jeff, Oct 23). Customize Layout is Pro, so
// in gated builds (Debug, Release) this test checks the paywall opens instead. The UI-test bundle
// is built with the app's configuration, so TESTFLIGHT here matches the app. Run per configuration:
//   xcodebuild test -scheme MetarMate -configuration TestFlight ENABLE_TESTABILITY=YES -destination "platform=iOS Simulator,name=iPhone 17" -only-testing:MetarMateUITests/VersionLineUITests
final class VersionLineUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testVersionLineNamesTestFlightOnlyInTestFlightBuilds() throws {
        let app = XCUIApplication()
        app.launch()

        // Open any airport's detail screen via Search, then Customize Layout.
        let search = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Search tab never appeared")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("KLAS")
        let result = app.staticTexts["KLAS"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "KLAS not found in search")
        result.tap()

        let customize = app.buttons["slider.horizontal.3"].firstMatch
        XCTAssertTrue(customize.waitForExistence(timeout: 10), "Customize Layout button missing")
        sleep(2)   // entitlements finish loading; until then the UI treats the user as Pro
        customize.tap()
        #if !TESTFLIGHT
        // Customize Layout is Pro, and gating is on outside TestFlight: the paywall opens instead.
        // The marker itself is compile-time (FeatureFlagsTests checks BuildChannel.isTestFlight).
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "proPaywall").firstMatch.waitForExistence(timeout: 5),
                      "gated build: Customize Layout didn't open the paywall")
        return
        #endif

        let line = app.staticTexts["versionLine"].firstMatch
        if !line.waitForExistence(timeout: 3) {
            app.swipeUp(); app.swipeUp(); app.swipeUp()
        }
        XCTAssertTrue(line.waitForExistence(timeout: 5), "version line missing")
        XCTAssertTrue(line.label.hasPrefix("Version "), "unexpected version line: \(line.label)")
        XCTAssertTrue(line.label.hasSuffix(" · TestFlight"), "TestFlight build without the marker: \(line.label)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "versionLine"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

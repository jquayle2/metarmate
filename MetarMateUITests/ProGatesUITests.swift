import XCTest

// A3 step 3: each Pro gate's effect in the running app. The UI-test bundle is built with the app's
// configuration, so TESTFLIGHT here matches the app's switch:
//   • Debug / Release (gating on, and no StoreKit purchase in a test run): a Pro entry point opens
//     the paywall.
//   • TestFlight (gating off): the same entry point opens the feature.
// Free features never open the paywall in any build.
//   xcodebuild test -scheme MetarMate -configuration TestFlight ENABLE_TESTABILITY=YES -destination "platform=iOS Simulator,name=iPhone 17 A3" -only-testing:MetarMateUITests/ProGatesUITests
final class ProGatesUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var gated: Bool {
        #if TESTFLIGHT
        return false
        #else
        return true
        #endif
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Alerts"].firstMatch.waitForExistence(timeout: 15))
        sleep(2)   // entitlements finish loading; until then the UI treats the user as Pro
        return app
    }

    @MainActor
    private func paywall(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "proPaywall").firstMatch
    }

    @MainActor
    private func openProfiles(_ app: XCUIApplication) {
        app.tabBars.buttons["Alerts"].firstMatch.tap()
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Minimums:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "profile switcher missing")
        menu.tap()
        let manage = app.buttons["Manage Profiles…"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        XCTAssertTrue(app.navigationBars["Minimums Profiles"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNewCustomProfileIsPro() throws {
        let app = launch()
        openProfiles(app)
        app.buttons["newProfileButton"].firstMatch.tap()
        if gated {
            XCTAssertTrue(paywall(app).waitForExistence(timeout: 5), "gated build: + didn't open the paywall")
        } else {
            XCTAssertTrue(app.navigationBars["New Profile"].waitForExistence(timeout: 5), "TestFlight build: + didn't open New Profile")
            XCTAssertFalse(paywall(app).exists)
        }
    }

    @MainActor
    func testNewWatchIsPro() throws {
        let app = launch()
        app.tabBars.buttons["Alerts"].firstMatch.tap()
        let add = app.buttons["addWatchButton"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        if gated {
            XCTAssertTrue(paywall(app).waitForExistence(timeout: 5), "gated build: + didn't open the paywall")
        } else {
            XCTAssertTrue(app.navigationBars["Add Airport"].waitForExistence(timeout: 5), "TestFlight build: + didn't open Add Airport")
            XCTAssertFalse(paywall(app).exists)
        }
    }

    @MainActor
    func testStarterOpensReadOnlyForEveryone() throws {
        let app = launch()
        openProfiles(app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'VFR day'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["VFR day"].waitForExistence(timeout: 5), "starter editor didn't open")
        XCTAssertFalse(paywall(app).exists, "a starter must never open the paywall")
        XCTAssertTrue(app.staticTexts["Built-in starters can't be changed. Clone one to make your own."].exists)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.exists)
        XCTAssertFalse(field.isEnabled, "starter values must be read-only")
    }
}

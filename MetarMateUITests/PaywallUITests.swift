import XCTest

// A3 step 4: the Pro paywall as a free user sees it in a gated build. The price must come from
// StoreKit (the scheme's MetarMateProducts.storekit: $5.99), and Restore Purchases and Redeem Code
// must be on screen. Skipped in TestFlight builds, where no gate opens the paywall.
final class PaywallUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if TESTFLIGHT
        throw XCTSkip("TestFlight builds have gating off; no gate opens the paywall")
        #endif
    }

    @MainActor
    func testProPaywallShowsStoreKitPriceRestoreAndRedeem() throws {
        let app = XCUIApplication()
        app.launch()
        let alerts = app.tabBars.buttons["Alerts"].firstMatch
        XCTAssertTrue(alerts.waitForExistence(timeout: 15))
        sleep(2)   // entitlements finish loading; until then the UI treats the user as Pro
        alerts.tap()
        let menu = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Minimums:'")).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Manage Profiles…"].firstMatch.tap()
        app.buttons["newProfileButton"].firstMatch.tap()

        let buy = app.buttons["buyProButton"].firstMatch
        XCTAssertTrue(buy.waitForExistence(timeout: 10), "Buy button never appeared (products didn't load)")
        XCTAssertEqual(buy.label, "Buy Pro · $5.99")
        for title in ["Home and lock screen widgets", "Unlimited custom minimums profiles", "Minimums alerts",
                      "Siri and Shortcuts", "Custom detail layout", "One purchase. Yours to keep.",
                      "Shared with your family through Family Sharing."] {
            XCTAssertTrue(app.staticTexts[title].exists, "missing: \(title)")
        }
        let paywall = app.descendants(matching: .any).matching(identifier: "proPaywall").firstMatch
        XCTAssertFalse(paywall.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Apple Watch'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["restorePurchasesButton"].exists)
        XCTAssertTrue(app.buttons["redeemCodeButton"].exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "pro-paywall"
        shot.lifetime = .keepAlways
        add(shot)

        // Restore with no purchase: the screen stays and says nothing was found.
        app.buttons["restorePurchasesButton"].tap()
        let notFound = app.staticTexts["No MetarMate Pro purchase was found for this Apple Account."]
        XCTAssertTrue(notFound.waitForExistence(timeout: 15), "restore with no purchase gave no message")
        XCTAssertTrue(buy.exists)
    }
}

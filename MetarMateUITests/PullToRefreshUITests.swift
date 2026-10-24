import XCTest

// Pull-to-refresh on Nearest with a real pull gesture. The app runs against its UI-test network stub
// (METARMATE_UITEST_NET, DEBUG only): each served METAR batch has its own wind speed (180@5, 180@6,
// …), so a pull that reaches the network changes the row's wind and one answered by a cache doesn't.
// Regressions guarded:
// - a pull was answered by the 5-min METAR cache instead of the network;
// - the pull cancelled itself on the load's first view update, leaving every row on "Retrying…".
// Needs a simulator location near airports (Features > Location); without one the tests skip.
final class PullToRefreshUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func launch(network: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["METARMATE_UITEST_NET"] = network
        app.launch()
        let nearest = app.tabBars.buttons["Nearest"].firstMatch
        XCTAssertTrue(nearest.waitForExistence(timeout: 15), "Nearest tab never appeared")
        nearest.tap()
        guard app.staticTexts["KVGT"].waitForExistence(timeout: 20) else {
            throw XCTSkip("No KVGT row: set the simulator location to North Las Vegas (36.2107, -115.1945)")
        }
        return app
    }

    @MainActor
    func pull(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor
    func text(_ app: XCUIApplication, containing s: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
    }

    /// Online: the pull reaches the network (the row's wind changes) and finishes.
    @MainActor
    func testPullReachesTheNetworkAndFinishes() throws {
        let app = try launch(network: "online")
        // The row's label is "KVGT, 0.1 nm, ›, North Las Vegas, CLR · 10+SM · 180@5".
        let kvgt = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'KVGT,' AND label CONTAINS '180@'")).firstMatch
        XCTAssertTrue(kvgt.waitForExistence(timeout: 15), "first load never showed the served METAR")
        let before = kvgt.label
        pull(app)
        let changed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'KVGT,' AND label CONTAINS '180@' AND label != %@", before)).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 10),
                      "the pull didn't reach the network (rows still show \(before))")
        XCTAssertFalse(text(app, containing: "Retrying").exists, "a row is still retrying after the pull")
    }

    /// Network off at launch, rows end at "Couldn't reach weather service"; network back, a pull
    /// loads them and none is left on "Retrying…".
    @MainActor
    func testOfflineLaunchThenPullOnceOnlineLoads() throws {
        let backOnline = Date().addingTimeInterval(40)   // first load + 3 retries take ~22 s
        let app = try launch(network: "offline-until:\(Int(backOnline.timeIntervalSince1970))")
        XCTAssertTrue(text(app, containing: "Couldn't reach weather service").waitForExistence(timeout: 34),
                      "offline rows never reached the failed state")
        let remaining = backOnline.timeIntervalSinceNow + 1
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }   // the stub is online again
        pull(app)
        XCTAssertTrue(text(app, containing: "180@").waitForExistence(timeout: 10), "the pull never loaded the rows")
        let retrying = text(app, containing: "Retrying")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: retrying)
        wait(for: [gone], timeout: 10)
        XCTAssertFalse(text(app, containing: "Couldn't reach weather service").exists, "a row is still failed after the pull")
    }
}

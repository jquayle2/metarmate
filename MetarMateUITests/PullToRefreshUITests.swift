import XCTest

// Pull-to-refresh on Nearest and the weather detail screen with a real pull gesture. The app runs against its UI-test network stub
// (METARMATE_UITEST_NET, DEBUG only): each served METAR batch has its own wind speed (180@5, 180@6,
// …), so a pull that reaches the network changes the row's wind and one answered by a cache doesn't.
// Regressions guarded:
// - a pull was answered by the 5-min METAR cache instead of the network;
// - the pull cancelled itself on the load's first view update, leaving every row on "Retrying…".
// The Nearest tests need a simulator location near airports (Features > Location); without one they
// skip. The detail tests open KVGT from Search and need no location.
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

    // MARK: - Weather detail

    @MainActor
    func openDetail(network: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["METARMATE_UITEST_NET"] = network
        app.launch()
        let search = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), "Search tab never appeared")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        if field.buttons["Clear text"].exists { field.buttons["Clear text"].tap() }
        field.typeText("KVGT")
        let cell = app.buttons.containing(NSPredicate(format: "label CONTAINS 'KVGT'")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no KVGT search result"); cell.tap()
        return app
    }

    /// The detail shows the raw report ("METAR KVGT 241551Z 18005KT …"); the stub's wind changes per batch.
    @MainActor
    func rawReport(_ app: XCUIApplication, otherThan before: String? = nil) -> XCUIElement {
        let format = before == nil ? "label CONTAINS 'KVGT 241551Z 180'" : "label CONTAINS 'KVGT 241551Z 180' AND label != %@"
        let args: [Any] = before.map { [$0] } ?? []
        return app.descendants(matching: .any).matching(NSPredicate(format: format, argumentArray: args)).firstMatch
    }

    /// Online: a pull on the detail reaches the network (the raw report's wind changes).
    @MainActor
    func testDetailPullReachesTheNetwork() throws {
        let app = openDetail(network: "online")
        let report = rawReport(app)
        XCTAssertTrue(report.waitForExistence(timeout: 15), "the detail never showed the served METAR")
        let before = report.label
        pull(app)
        XCTAssertTrue(rawReport(app, otherThan: before).waitForExistence(timeout: 10),
                      "the detail pull didn't reach the network (still \(before))")
        XCTAssertFalse(text(app, containing: "Failed to load weather").exists)
    }

    /// Offline when the detail opens: it ends at "Failed to load weather". Network back, a pull loads it.
    @MainActor
    func testDetailOfflineThenPullOnceOnlineLoads() throws {
        let backOnline = Date().addingTimeInterval(45)   // the detail's load + 3 retries take ~22 s
        let app = openDetail(network: "offline-until:\(Int(backOnline.timeIntervalSince1970))")
        XCTAssertTrue(text(app, containing: "Failed to load weather").waitForExistence(timeout: 40),
                      "the offline detail never reached the failed state")
        let remaining = backOnline.timeIntervalSinceNow + 1
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }   // the stub is online again
        pull(app)
        XCTAssertTrue(rawReport(app).waitForExistence(timeout: 10), "the pull never loaded the detail")
        XCTAssertFalse(text(app, containing: "Failed to load weather").exists, "the detail still shows the failure")
    }
}

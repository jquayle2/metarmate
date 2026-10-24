import Testing
import Foundation
@testable import MetarMate

// Integration seam: A3 pauses a lapsed user's watches; the verdict branch gave rows the shared
// GO/NO-GO badge. A paused row shows "Paused" and nothing from the last check, even when a display
// from before the lapse is still in memory (Jeff, Oct 24: paused overrides the other row lines).
@MainActor
struct PausedWatchRowTests {

    let now = Date()

    var vfrDay: MinimumsProfile { MinimumsProfile.builtInStarters().first { $0.builtInKey == "vfrDay" }! }

    /// A current VFR METAR that's GO against VFR day.
    var goDisplay: AlertPipeline.WatchDisplay {
        let c = AlertConditions(windDirection: 300, windSpeed: 6, windGust: nil, ceilingFeet: nil,
                                visibilitySM: 10, flightCategory: .vfr, source: .metar,
                                timestamp: now.addingTimeInterval(-600))
        let v = GoNoGoEvaluator.evaluate(vfrDay, c, previousSide: nil, icao: "KZZZ", now: now)
        return AlertPipeline.WatchDisplay(conditions: c, verdict: v, profile: GoNoGoEvaluator.snapshot(of: vfrDay))
    }

    @Test func activeRowShowsTheVerdict() throws {
        let row = WatchRow(watch: AirportWatch(icao: "KZZZ"), display: goDisplay, airport: nil)
        let shown = try #require(row.shown)
        #expect(shown.tone == .go)
        #expect(row.conditions != nil)
    }

    @Test func pausedRowDropsTheLeftoverVerdictAndWeather() {
        let row = WatchRow(watch: AirportWatch(icao: "KZZZ"), display: goDisplay, airport: nil, paused: true)
        #expect(row.current == nil)
        #expect(row.shown == nil)        // no GO/NO-GO badge, no verdict detail line
        #expect(row.conditions == nil)   // no conditions line, category badge or freshness line
    }
}

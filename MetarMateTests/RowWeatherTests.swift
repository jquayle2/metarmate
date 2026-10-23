import Testing
import Foundation
@testable import MetarMate

// List rows: a stale last-good reading never shows its category as current; loading, no product
// and a failure with nothing cached show no reading.
@MainActor
struct RowWeatherTests {

    static let obs = 1_792_770_660   // Oct 23, 2026 15:51Z
    static var obsDate: Date { Date(timeIntervalSince1970: TimeInterval(obs)) }
    static func metar() throws -> Metar { try FetchOutcomeTests.metar("KVGT", obsTime: obs) }

    @Test func loadedMetarShowsWhileCurrent() throws {
        let row = RowWeather.loaded(.metar(try Self.metar()))
        #expect(row.displayMetar(at: Self.obsDate.addingTimeInterval(30 * 60)) != nil)
    }

    /// Last good reading kept through a failure: shown while it's within 75 min of observation…
    @Test func failedKeepsLastGoodReadingWhileCurrent() throws {
        let row = RowWeather.failed(last: .metar(try Self.metar()))
        #expect(row.displayMetar(at: Self.obsDate.addingTimeInterval(75 * 60))?.stationId == "KVGT")
    }

    /// …and withheld once it's over 75 min old, so its flight-category color can't read as current.
    /// Age is from the observation time, not when it was fetched.
    @Test func staleLastReadingIsNotShownAsCurrent() throws {
        let row = RowWeather.retrying(last: .metar(try Self.metar()))
        #expect(row.displayMetar(at: Self.obsDate.addingTimeInterval(76 * 60)) == nil)
        #expect(row.reading?.metar != nil)   // still known, for the row's age/dim rendering
    }

    @Test func loadingNoProductAndEmptyFailureShowNothing() {
        let now = Self.obsDate
        #expect(RowWeather.loading.displayMetar(at: now) == nil)
        #expect(RowWeather.noProduct.displayMetar(at: now) == nil)
        #expect(RowWeather.failed(last: nil).displayMetar(at: now) == nil)
        #expect(RowWeather.loading.reading == nil)
    }
}

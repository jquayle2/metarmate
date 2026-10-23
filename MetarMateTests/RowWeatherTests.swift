import Testing
import Foundation
import CoreLocation
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

    // MARK: - Nearest reload on a move

    /// Nearest reloads after a 2 nm move, not on every GPS refinement.
    @Test func nearestReloadsOnlyAfterTwoNauticalMiles() {
        let kigm = CLLocation(latitude: 35.2595, longitude: -113.9380)
        let oneNmNorth = CLLocation(latitude: 35.2595 + 1.0 / 60, longitude: -113.9380)
        let threeNmNorth = CLLocation(latitude: 35.2595 + 3.0 / 60, longitude: -113.9380)
        #expect(!AirportViewModel.movedEnoughToReload(from: kigm, to: oneNmNorth))
        #expect(AirportViewModel.movedEnoughToReload(from: kigm, to: threeNmNorth))
        #expect(AirportViewModel.movedEnoughToReload(from: nil, to: kigm))     // never loaded
        #expect(!AirportViewModel.movedEnoughToReload(from: kigm, to: nil))    // no fix
    }

    @Test func loadingNoProductAndEmptyFailureShowNothing() {
        let now = Self.obsDate
        #expect(RowWeather.loading.displayMetar(at: now) == nil)
        #expect(RowWeather.noProduct.displayMetar(at: now) == nil)
        #expect(RowWeather.failed(last: nil).displayMetar(at: now) == nil)
        #expect(RowWeather.loading.reading == nil)
    }
}

import Testing
import Foundation
import CoreLocation
@testable import MetarMate

// List rows: what AirportRowView shows for each RowWeather state. A reading reads as current
// (category rail) only when loaded and within 75 min of observation; stale, retrying and failed rows
// never show a category color; loading is "—", no METAR is "No current METAR".
@MainActor
struct RowWeatherTests {

    static let obs = 1_792_770_660   // Oct 23, 2026 15:51Z
    static var obsDate: Date { Date(timeIntervalSince1970: TimeInterval(obs)) }
    static func metar() throws -> Metar { try FetchOutcomeTests.metar("KVGT", obsTime: obs) }   // VFR
    static let kvgt = Airport(icao: "KVGT", iata: "VGT", name: "North Las Vegas", latitude: 36.2, longitude: -115.2, elevation: 2205)

    static func display(_ state: RowWeather, minutesAfterObs: Double) -> AirportRowView.StateDisplay {
        AirportRowView.StateDisplay(state, airport: kvgt, at: obsDate.addingTimeInterval(minutesAfterObs * 60))
    }

    @Test func loadedCurrentMetarShowsItsCategory() throws {
        let d = Self.display(.loaded(.metar(try Self.metar())), minutesAfterObs: 30)
        #expect(d.isCurrent)
        #expect(d.railColor == Brand.vfrGreen)
        #expect(d.ageSuffix.isEmpty)
    }

    /// Age is from the observation time, not when it was fetched: at 76 min a loaded METAR is stale
    /// — dimmed, neutral rail, its age shown.
    @Test func staleLoadedMetarIsNeutralWithAge() throws {
        let d = Self.display(.loaded(.metar(try Self.metar())), minutesAfterObs: 76)
        #expect(!d.isCurrent)
        #expect(d.railColor == Brand.slate)
        #expect(d.ageSuffix == " · 1 h 16 min old")
        #expect(d.metar != nil)
    }

    @Test func loadedMetarAt75MinutesIsStillCurrent() throws {
        #expect(Self.display(.loaded(.metar(try Self.metar())), minutesAfterObs: 75).isCurrent)
    }

    /// A reading kept through a failure is never shown as current, even when it's recent.
    @Test func failedRowKeepsLastReadingDimmedWithRetry() throws {
        let d = Self.display(.failed(last: .metar(try Self.metar())), minutesAfterObs: 20)
        #expect(!d.isCurrent)
        #expect(d.railColor == Brand.slate)
        #expect(d.showRetry)
        #expect(d.ageSuffix == " · 20 min old")
    }

    @Test func retryingRowKeepsLastReadingDimmedWithoutRetryButton() throws {
        let d = Self.display(.retrying(last: .metar(try Self.metar())), minutesAfterObs: 20)
        #expect(!d.isCurrent)
        #expect(d.note == "Retrying…")
        #expect(!d.showRetry)
    }

    @Test func statesWithoutAReadingAreNeutralText() {
        let loading = Self.display(.loading, minutesAfterObs: 0)
        #expect(loading.note == "—")
        #expect(loading.railColor == Brand.slate)
        #expect(Self.display(.noProduct, minutesAfterObs: 0).note == "No current METAR")
        #expect(Self.display(.retrying(last: nil), minutesAfterObs: 0).note == "Retrying…")
        let failed = Self.display(.failed(last: nil), minutesAfterObs: 0)
        #expect(failed.note == "Couldn't reach weather service")
        #expect(failed.showRetry)
        #expect(failed.railColor == Brand.slate)
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
}

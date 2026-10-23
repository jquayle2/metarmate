import Testing
import Foundation
@testable import MetarMate

// The two detail-screen report-age limits, from observation time: red age text over 60 min (an early
// "next report is late" warning, no color change) and no category color over 75 min (D#4).
@MainActor
struct ReportAgeLimitsTests {

    static func metar(minutesOld: Double, now: Date = Date()) throws -> Metar {
        try FetchOutcomeTests.metar("KVGT", obsTime: Int(now.addingTimeInterval(-minutesOld * 60).timeIntervalSince1970))
    }

    @Test func limitsAreNamedInOnePlace() {
        #expect(WidgetWeatherSnapshot.oldReportWarningMinutes == 60)
        #expect(WidgetWeatherSnapshot.noCurrentAfterMinutes == 75)
    }

    @Test func redAgeTextOver60Minutes() throws {
        #expect(!(try Self.metar(minutesOld: 59)).isOld)
        #expect(try Self.metar(minutesOld: 61).isOld)
    }

    @Test func categoryColorWithheldOver75Minutes() throws {
        let now = Date(timeIntervalSince1970: 1_792_770_660)
        #expect(!(try Self.metar(minutesOld: 75, now: now)).isNoCurrent(at: now))
        #expect(try Self.metar(minutesOld: 76, now: now).isNoCurrent(at: now))
    }

    /// Between 60 and 75 min the age text is red but the report is still current (category shown).
    @Test func sixtyToSeventyFiveIsWarnedButCurrent() throws {
        let m = try Self.metar(minutesOld: 70)
        #expect(m.isOld)
        #expect(!m.isNoCurrent(at: Date()))
    }
}

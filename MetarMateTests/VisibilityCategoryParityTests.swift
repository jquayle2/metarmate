import Testing
import Foundation
@testable import MetarMate

// Flight-category parity for the Visibility-enum change (commit 10). Written FIRST against the
// current Double-backed calculateFlightCategory, exercised through the public TafParser.parse path
// (the function itself is private). After Metar/TafForecast.visibility become a `Visibility` enum,
// THIS TEST IS UNCHANGED and must stay green: the flight category for every real visibility must be
// provably identical before and after. The only new behavior is `.unknown` -> `.unknown` category
// (empty visib, no ceiling) — that assertion is new, not a changed one.
struct VisibilityCategoryParityTests {

    // Parse a single-period TAF with the given raw `visib` JSON literal and NO ceiling, so the
    // visibility axis alone drives the flight category. Returns the computed category.
    private func category(visibJSON: String) throws -> FlightCategory {
        let json = #"{"icaoId":"KZZZ","issueTime":"2026-07-09T22:00:00.000Z","validTimeFrom":1783634400,"validTimeTo":1783728000,"rawTAF":"vis parity probe","fcsts":[{"timeFrom":1783634400,"timeTo":1783648800,"wdir":200,"wspd":6,"visib":\#(visibJSON),"clouds":[]}]}"#
        let raw = try JSONDecoder().decode(RawTaf.self, from: Data(json.utf8))
        let taf = try TafParser.parse(raw: raw)
        return try #require(taf.forecasts.first).flightCategory
    }

    @Test func exactVisibilitiesYieldStableCategory() throws {
        #expect(try category(visibJSON: "0.25") == .lifr)
        #expect(try category(visibJSON: "0.5")  == .lifr)
        #expect(try category(visibJSON: "0.75") == .lifr)
        #expect(try category(visibJSON: "1")    == .ifr)
        #expect(try category(visibJSON: "2")    == .ifr)
        #expect(try category(visibJSON: "3")    == .mvfr)
        #expect(try category(visibJSON: "5")    == .mvfr)   // 5 SM is MVFR (<= 5), not VFR
        #expect(try category(visibJSON: "6")    == .vfr)
        #expect(try category(visibJSON: "10")   == .vfr)
    }

    @Test func greaterThanVisibilitiesYieldSameCategoryAsExact() throws {
        // P6SM / "6+" / P10SM must land on the same category the bare 6.0 / 10.0 gave (VFR).
        #expect(try category(visibJSON: #""6+""#)  == .vfr)
        #expect(try category(visibJSON: #""P6SM""#) == .vfr)
        #expect(try category(visibJSON: #""10+""#)  == .vfr)
    }

    @Test func unknownVisibilityYieldsUnknownCategory() throws {
        // NEW behavior (not a changed assertion): empty visib + no ceiling -> .unknown, never a
        // fabricated VFR.
        #expect(try category(visibJSON: #""""#) == .unknown)
    }

    // Both sides of every category threshold — locks the exact boundary behavior so the enum swap
    // can't shift a boundary by a hair. (F9 was a `< 5` vs `<= 5` boundary bug.)
    @Test func boundaryVisibilitiesLockThresholds() throws {
        // LIFR / IFR edge: `< 1`
        #expect(try category(visibJSON: "0.99") == .lifr)
        #expect(try category(visibJSON: "1.0")  == .ifr)
        #expect(try category(visibJSON: "1.01") == .ifr)
        // IFR / MVFR edge: `< 3`
        #expect(try category(visibJSON: "2.99") == .ifr)
        #expect(try category(visibJSON: "3.0")  == .mvfr)
        #expect(try category(visibJSON: "3.01") == .mvfr)
        // MVFR / VFR edge: `<= 5` (the F9 fix boundary — 5.0 is MVFR, 5.01 is VFR)
        #expect(try category(visibJSON: "4.99") == .mvfr)
        #expect(try category(visibJSON: "5.0")  == .mvfr)
        #expect(try category(visibJSON: "5.01") == .vfr)
    }
}

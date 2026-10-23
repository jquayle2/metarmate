import Testing
import Foundation
@testable import MetarMate

// Fetch outcomes: only a confirmed no-product may trigger a fallback; a failure retries and never
// falls back; cancellation is not an outcome.
@MainActor
struct FetchOutcomeTests {

    static func metar(_ station: String, obsTime: Int) throws -> Metar {
        let json = #"{"icaoId":"\#(station)","obsTime":\#(obsTime),"rawOb":"METAR \#(station) 231551Z 20008KT 10SM CLR 19/13 A2996","temp":19,"dewp":13,"altim":1014.6,"wdir":200,"wspd":8,"visib":"10+","clouds":[],"fltCat":"VFR"}"#
        return try MetarParser.parse(raw: JSONDecoder().decode(RawMetar.self, from: Data(json.utf8)))
    }

    // MARK: - Classification

    @Test func noContentAndEmptyAreNoProduct() {
        #expect(FetchErrorKind(WeatherError.noContent) == .noProduct)
        #expect(FetchErrorKind(WeatherError.noData) == .noProduct)
    }

    @Test func rateLimitAndServerErrorsAreTransient() {
        #expect(FetchErrorKind(WeatherError.httpStatus(429)) == .transient)
        #expect(FetchErrorKind(WeatherError.httpStatus(503)) == .transient)
        #expect(FetchErrorKind(URLError(.timedOut)) == .transient)
        #expect(FetchErrorKind(URLError(.notConnectedToInternet)) == .transient)
        #expect(FetchErrorKind(URLError(.networkConnectionLost)) == .transient)
    }

    @Test func otherClientErrorsFailWithoutRetry() {
        #expect(FetchErrorKind(WeatherError.httpStatus(400)) == .failed)
        #expect(FetchErrorKind(WeatherError.httpStatus(404)) == .failed)
        #expect(FetchErrorKind(WeatherError.parseError("x")) == .failed)
    }

    /// URLError -999 from a .task torn down on a tab switch is cancellation, not a failure.
    @Test func urlCancelledIsCancellation() {
        #expect(FetchErrorKind(URLError(.cancelled)) == .cancelled)
        #expect(FetchErrorKind(CancellationError()) == .cancelled)
    }

    @Test func failureCarriesTransience() {
        #expect(FetchFailure(WeatherError.httpStatus(429), retryAfter: 30).isTransient)
        #expect(!FetchFailure(WeatherError.httpStatus(400)).isTransient)
    }

    @Test func logWordsMatchTheClass() {
        #expect(FetchLog.classify(WeatherError.noContent) == "noProduct(204)")
        #expect(FetchLog.classify(WeatherError.httpStatus(429)) == "transient(http 429)")
        #expect(FetchLog.classify(URLError(.cancelled)) == "cancelled")
        #expect(FetchLog.classify(FetchFailure(URLError(.timedOut))) == "transient(urlerr -1001)")
    }

    // MARK: - Retry policy

    @Test func threeRetriesThenStop() {
        #expect(RetryPolicy.foreground.delay(beforeRetry: 0, retryAfter: nil) == 2)
        #expect(RetryPolicy.foreground.delay(beforeRetry: 1, retryAfter: nil) == 5)
        #expect(RetryPolicy.foreground.delay(beforeRetry: 2, retryAfter: nil) == 15)
        #expect(RetryPolicy.foreground.delay(beforeRetry: 3, retryAfter: nil) == nil)
    }

    @Test func retryAfterIsHonoredAndCapped() {
        #expect(RetryPolicy.foreground.delay(beforeRetry: 0, retryAfter: 10) == 10)
        #expect(RetryPolicy.foreground.delay(beforeRetry: 2, retryAfter: 1) == 15)
        #expect(RetryPolicy.foreground.delay(beforeRetry: 0, retryAfter: 3600) == 60)
    }

    @Test func runStopsOnNoProductWithoutRetrying() async throws {
        var calls = 0
        let outcome: FetchOutcome<Int> = try await RetryPolicy.foreground.run("test") { calls += 1; return .noProduct }
        #expect(outcome.isNoProduct)
        #expect(calls == 1)
    }

    @Test func runDoesNotRetryNonTransientFailure() async throws {
        var calls = 0
        let outcome: FetchOutcome<Int> = try await RetryPolicy.foreground.run("test") {
            calls += 1; return .failed(FetchFailure(WeatherError.httpStatus(400)))
        }
        if case .failed = outcome {} else { Issue.record("expected failed") }
        #expect(calls == 1)
    }

    // MARK: - No-product memory

    @Test func noProductIsRememberedTenMinutes() {
        var memory = NoProductMemory()
        let t0 = Date(timeIntervalSince1970: 1_792_770_660)
        memory.remember("KA20", at: t0)
        #expect(memory.contains("KA20", at: t0.addingTimeInterval(599)))
        #expect(!memory.contains("KA20", at: t0.addingTimeInterval(600)))
        #expect(!memory.contains("KIGM", at: t0))
    }

    @Test func forgetDropsAStation() {
        var memory = NoProductMemory()
        let t0 = Date()
        memory.remember("KA20", at: t0)
        memory.forget("KA20")
        #expect(!memory.contains("KA20", at: t0))
    }

    // MARK: - Batch outcomes

    @Test func batchStationMissingFromA200IsNoProduct() throws {
        let kigm = try Self.metar("KIGM", obsTime: 1_792_770_660)
        let outcomes = MetarBatch.outcomes(requested: ["KIGM", "KA20"], parsed: [kigm], unparseable: [])
        #expect(outcomes["KIGM"]?.value?.stationId == "KIGM")
        #expect(outcomes["KA20"]?.isNoProduct == true)
    }

    /// NOAA returned obs for the station that didn't parse: we don't know what they say, so it's a
    /// failure (never "no product", never a fallback).
    @Test func batchUnparseableStationIsFailedNotNoProduct() {
        let outcomes = MetarBatch.outcomes(requested: ["KVGT"], parsed: [], unparseable: ["KVGT"])
        guard case .failed(let failure) = outcomes["KVGT"] else { Issue.record("expected failed"); return }
        #expect(!failure.isTransient)
    }

    @Test func batchKeepsTheNewestObservation() throws {
        let older = try Self.metar("KVGT", obsTime: 1_792_767_060)
        let newer = try Self.metar("KVGT", obsTime: 1_792_770_660)
        let outcomes = MetarBatch.outcomes(requested: ["KVGT"], parsed: [older, newer], unparseable: [])
        #expect(outcomes["KVGT"]?.value?.observationTime == newer.observationTime)
    }

    // MARK: - Nearby TAF

    /// Only a confirmed no-product borrows a nearby TAF; a failed own-TAF request never does.
    @Test func ownTafFailureNeverBorrows() {
        let failed = NearbyTaf.outcome(of: FetchOutcome<Taf>.failed(FetchFailure(URLError(.timedOut))))
        #expect(!NearbyTaf.needsBorrow(failed, at: Date()))
        let none = NearbyTaf.outcome(of: FetchOutcome<Taf>.noProduct)
        #expect(NearbyTaf.needsBorrow(none, at: Date()))
    }
}

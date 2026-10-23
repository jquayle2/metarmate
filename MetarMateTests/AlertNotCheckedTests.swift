import Testing
import Foundation
@testable import MetarMate

// Alerts when the METAR request fails after retries: the watch is not checked (no notification, side
// untouched). The previous reading's verdict shows only while the last good check is within 75 min;
// after that the row is neutral and unevaluated, so a stale GO never looks current.
@MainActor
struct AlertNotCheckedTests {

    static let now = Date(timeIntervalSince1970: 1_792_770_660)

    static func metar() throws -> Metar {
        try FetchOutcomeTests.metar("KVGT", obsTime: Int(now.timeIntervalSince1970) - 20 * 60)
    }

    @Test func previousReadingKeptWhileLastGoodCheckWithin75Minutes() throws {
        let c = AlertPipeline.conditionsAfterFailure(lastMetar: try Self.metar(),
                                                     lastGoodCheck: Self.now.addingTimeInterval(-75 * 60), at: Self.now)
        #expect(c != nil)
    }

    @Test func previousVerdictDroppedOnceLastGoodCheckIsOver75Minutes() throws {
        let c = AlertPipeline.conditionsAfterFailure(lastMetar: try Self.metar(),
                                                     lastGoodCheck: Self.now.addingTimeInterval(-76 * 60), at: Self.now)
        #expect(c == nil)
    }

    @Test func nothingToKeepWithoutALastGoodCheck() throws {
        #expect(AlertPipeline.conditionsAfterFailure(lastMetar: try Self.metar(), lastGoodCheck: nil, at: Self.now) == nil)
        #expect(AlertPipeline.conditionsAfterFailure(lastMetar: nil, lastGoodCheck: Self.now, at: Self.now) == nil)
    }

    @Test func backgroundRetriesTwiceForegroundThreeTimes() {
        #expect(RetryPolicy.background.delays == [2, 5])
        #expect(RetryPolicy.foreground.delays == [2, 5, 15])
    }

    /// The batch retry asks again only for the stations that failed transiently, and stops after the
    /// policy's retries with their last failure.
    @Test func runBatchRetriesOnlyTheTransientlyFailingIds() async throws {
        let waits = WaitRecorder()
        let policy = RetryPolicy(delays: [2, 5], sleep: { waits.record($0) })
        var asked: [[String]] = []
        let kvgt = try Self.metar()
        let outcomes: [String: FetchOutcome<Metar>] = try await policy.runBatch("test", ids: ["KVGT", "KSEE", "KCRQ"]) { ids in
            asked.append(ids.sorted())
            var r: [String: FetchOutcome<Metar>] = [:]
            for id in ids {
                switch id {
                case "KVGT": r[id] = asked.count == 1 ? .failed(FetchFailure(URLError(.timedOut))) : .loaded(kvgt)
                case "KSEE": r[id] = .failed(FetchFailure(WeatherError.httpStatus(503)))   // fails every time
                default:     r[id] = .noProduct
                }
            }
            return r
        }
        #expect(asked == [["KCRQ", "KSEE", "KVGT"], ["KSEE", "KVGT"], ["KSEE"]])
        #expect(waits.values == [2, 5])
        #expect(outcomes["KVGT"]?.value != nil)
        #expect(outcomes["KCRQ"]?.isNoProduct == true)
        if case .failed = outcomes["KSEE"] {} else { Issue.record("KSEE should end failed") }
    }
}

import Testing
import Foundation
@testable import MetarMate

// With no Synoptic token compiled in (launch-hardening A1), both public entry points throw
// .noToken from buildURL, before any URL or request exists. Nothing reaches the network.
struct SynopticNoTokenTests {

    private func isNoToken(_ error: Error) -> Bool {
        if case SynopticError.noToken = error { return true }
        return false
    }

    @Test func fetchLatestThrowsNoToken() async {
        do {
            _ = try await SynopticService.shared.fetchLatest(for: "KLAS")
            Issue.record("fetchLatest returned without a token")
        } catch {
            #expect(isNoToken(error), "got \(error)")
        }
    }

    @Test func fetchTimeSeriesThrowsNoToken() async {
        do {
            _ = try await SynopticService.shared.fetchTimeSeries(for: "KLAS")
            Issue.record("fetchTimeSeries returned without a token")
        } catch {
            #expect(isNoToken(error), "got \(error)")
        }
    }
}

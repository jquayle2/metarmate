import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Background task (#26), the tests A3 left for integration because AlertPipeline was A2's file.
// No fetch seam: a run cancelled the way the expiration handler cancels it (work.cancel()) has its
// NOAA request cancelled too, so these never depend on the network answering.
@MainActor
@Suite(.serialized)
struct AlertBackgroundTaskTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    /// Starters + one enabled watch, saved, then one unsaved edit so a save is observable.
    private func dirtyContext() throws -> (ModelContext, AirportWatch) {
        let ctx = try makeContext()
        MinimumsProfile.builtInStarters().forEach(ctx.insert)
        let watch = AirportWatch(icao: "KDEN")
        ctx.insert(watch)
        try ctx.save()
        watch.createdDate = Date(timeIntervalSince1970: 0)   // pending, unsaved
        #expect(ctx.hasChanges)
        return (ctx, watch)
    }

    private func withActivePointerRestored(_ body: () async throws -> Void) async rethrows {
        let saved = UserDefaults.standard.string(forKey: ActiveMinimumsProfile.key)
        defer { UserDefaults.standard.set(saved, forKey: ActiveMinimumsProfile.key) }
        try await body()
    }

    // Expiry: the handler cancels the work Task. The run stops without evaluating a watch and
    // never saves after cancel (0xdead10cc: no App Group write while iOS may suspend us).
    @Test func cancelledRunEvaluatesNothingAndSkipsTheSave() async throws {
        try await withActivePointerRestored {
            let (ctx, watch) = try dirtyContext()
            let work = Task { @MainActor in await AlertPipeline.runChecks(in: ctx) }
            work.cancel()   // what task.expirationHandler does
            let outcome = await work.value
            #expect(outcome.notificationsFired == 0)
            #expect(watch.lastEvaluatedDate == nil)
            #expect(watch.lastSide == nil)
            #expect(ctx.hasChanges)   // the pending edit was not saved
        }
    }

    // Control for the test above: the same run, not cancelled, does save, whatever NOAA answers.
    @Test func uncancelledRunSaves() async throws {
        try await withActivePointerRestored {
            let (ctx, _) = try dirtyContext()
            await AlertPipeline.runChecks(in: ctx)
            #expect(!ctx.hasChanges)
        }
    }

    // Short timeouts on the session every alert METAR fetch uses: 8 s per request, 15 s in all,
    // no waiting for connectivity (the background window is about 30 s).
    @Test func metarSessionUsesShortTimeouts() throws {
        let session = try #require(Mirror(reflecting: WeatherService.shared).children
            .first { $0.label == "session" }?.value as? URLSession)
        #expect(session.configuration.timeoutIntervalForRequest == 8)
        #expect(session.configuration.timeoutIntervalForResource == 15)
        #expect(session.configuration.waitsForConnectivity == false)
    }
}

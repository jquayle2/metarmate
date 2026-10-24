import Testing
import SwiftData
import Foundation
@testable import MetarMate

// A2 hand-off: favorites not in airports.json were saved with NOAA's meters as feet. Once per install,
// their elevation is re-read from NOAA station info and stored in feet; no elevation from NOAA → 0.
@MainActor
struct FavoriteElevationRefetchTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "FavoriteElevationRefetchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func insert(_ icao: String, elevation: Int, in ctx: ModelContext) {
        ctx.insert(AirportFavorite(from: Airport(icao: icao, iata: nil, name: icao, latitude: 0, longitude: 0,
                                                 elevation: elevation)))
    }

    private func elevation(_ icao: String, _ ctx: ModelContext) throws -> Int {
        try #require(try ctx.fetch(FetchDescriptor<AirportFavorite>()).first { $0.icao == icao }).elevation
    }

    @Test func storedMetersBecomeFeetAndMissingElevationBecomesZero() async throws {
        let ctx = try makeContext()
        let defaults = makeDefaults()
        insert("CXAA", elevation: 1_000, in: ctx)   // 1,000 m saved as "1,000 ft"
        insert("CXBB", elevation: 412, in: ctx)     // NOAA lists it without elev
        insert("CXCC", elevation: 77, in: ctx)      // NOAA doesn't list it
        insert("KDEN", elevation: 5_434, in: ctx)   // bundled: left to the #27 reconcile
        try ctx.save()
        var asked: [String] = []
        let json = #"[{"id":"CXAA","icaoId":"CXAA","elev":1000},{"id":"CXBB","icaoId":"CXBB","elev":null}]"#

        let changed = await FavoriteElevationRefetch.runIfNeeded(
            in: ctx, defaults: defaults, isBundled: { $0 == "KDEN" },
            fetch: { asked = $0; return Data(json.utf8) })

        #expect(Set(asked) == ["CXAA", "CXBB", "CXCC"])
        #expect(changed == 3)
        #expect(try elevation("CXAA", ctx) == 3_281)
        #expect(try elevation("CXBB", ctx) == 0)
        #expect(try elevation("CXCC", ctx) == 0)
        #expect(try elevation("KDEN", ctx) == 5_434)
        #expect(defaults.bool(forKey: FavoriteElevationRefetch.doneKey))
    }

    @Test func runsOncePerInstall() async throws {
        let ctx = try makeContext()
        let defaults = makeDefaults()
        insert("CXAA", elevation: 1_000, in: ctx)
        try ctx.save()
        var fetches = 0
        let fetch: ([String]) async -> Data? = { _ in fetches += 1; return Data(#"[{"icaoId":"CXAA","elev":1000}]"#.utf8) }

        await FavoriteElevationRefetch.runIfNeeded(in: ctx, defaults: defaults, isBundled: { _ in false }, fetch: fetch)
        let second = await FavoriteElevationRefetch.runIfNeeded(in: ctx, defaults: defaults, isBundled: { _ in false }, fetch: fetch)

        #expect(fetches == 1)
        #expect(second == 0)
        #expect(try elevation("CXAA", ctx) == 3_281)   // not converted twice
    }

    @Test func networkFailureChangesNothingAndRetriesNextLaunch() async throws {
        let ctx = try makeContext()
        let defaults = makeDefaults()
        insert("CXAA", elevation: 1_000, in: ctx)
        try ctx.save()

        let changed = await FavoriteElevationRefetch.runIfNeeded(in: ctx, defaults: defaults, isBundled: { _ in false },
                                                                 fetch: { _ in nil })

        #expect(changed == 0)
        #expect(try elevation("CXAA", ctx) == 1_000)
        #expect(!defaults.bool(forKey: FavoriteElevationRefetch.doneKey))
    }

    @Test func noNonBundledFavoritesMarksDoneWithoutFetching() async throws {
        let ctx = try makeContext()
        let defaults = makeDefaults()
        insert("KDEN", elevation: 5_434, in: ctx)
        try ctx.save()
        var fetched = false

        await FavoriteElevationRefetch.runIfNeeded(in: ctx, defaults: defaults, isBundled: { _ in true },
                                                   fetch: { _ in fetched = true; return nil })

        #expect(!fetched)
        #expect(defaults.bool(forKey: FavoriteElevationRefetch.doneKey))
    }

    @Test func parsesFAAIdentifiersAndRejectsNonArrays() {
        let feet = FavoriteElevationRefetch.elevationsFeet(fromStationInfo: Data(#"[{"id":"74V","icaoId":null,"elev":1500.4}]"#.utf8))
        #expect(feet == ["74V": 4_921])
        #expect(FavoriteElevationRefetch.elevationsFeet(fromStationInfo: Data(#"{"error":"x"}"#.utf8)) == nil)
    }
}

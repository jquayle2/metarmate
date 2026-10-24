import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Integration seam: three branches touch favorite elevations. A3's one-time NOAA refetch writes
// feet (0 when NOAA has none), A2 saves new favorites in feet (nil "not reported" stored as 0),
// and the verdict branch's asAirport reads a non-bundled stored 0 as "not reported". This runs
// both launch steps against the real airports.json and reads the result the way screens do.
@MainActor
struct ElevationSeamTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func favorite(_ icao: String, _ ctx: ModelContext) throws -> AirportFavorite {
        try #require(try ctx.fetch(FetchDescriptor<AirportFavorite>()).first { $0.icao == icao })
    }

    @Test func refetchAndReconcileAgreeWithAsAirport() async throws {
        let ctx = try makeContext()
        let name = "ElevationSeamTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        func add(_ icao: String, _ elevation: Int?) {
            ctx.insert(AirportFavorite(from: Airport(icao: icao, iata: nil, name: icao, latitude: 0,
                                                     longitude: 0, elevation: elevation)))
        }
        add("CXAA", 1_000)   // non-bundled, NOAA meters saved as feet before 9025643
        add("CXBB", 412)     // non-bundled, NOAA lists it without elev
        add("CXCC", nil)     // non-bundled, starred after A2 with no elev: saved as 0
        add("KDEN", 1_656)   // bundled, wrong stored value: the reconcile fixes it
        add("01MD", 0)       // bundled real 0 ft field
        try ctx.save()

        // Launch order (MetarMateApp): reconcile, then the one-time refetch.
        FavoritesReconciler.reconcile(in: ctx)
        let json = #"[{"icaoId":"CXAA","elev":1000},{"icaoId":"CXBB","elev":null},{"icaoId":"CXCC"}]"#
        await FavoriteElevationRefetch.runIfNeeded(in: ctx, defaults: defaults,
                                                   fetch: { _ in Data(json.utf8) })

        #expect(try favorite("CXAA", ctx).asAirport.elevation == 3_281)   // feet
        #expect(try favorite("CXBB", ctx).asAirport.elevation == nil)     // stored 0 → not reported
        #expect(try favorite("CXCC", ctx).asAirport.elevation == nil)
        #expect(try favorite("KDEN", ctx).asAirport.elevation == AirportService.shared.bundledAirport(icao: "KDEN")?.elevation)
        #expect(try favorite("KDEN", ctx).asAirport.elevation == 5_431)
        #expect(try favorite("01MD", ctx).asAirport.elevation == 0)       // a real 0 ft field stays 0
    }
}

import Testing
import SwiftData
import Foundation
@testable import MetarMate

// Audit #27: favorites refresh their airport details from airports.json at launch, keyed by ICAO;
// an ICAO missing from airports.json keeps its favorite untouched.
@MainActor
struct FavoritesReconcilerTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(versionedSchema: MetarMateSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func favorite(_ icao: String, name: String, iata: String? = nil, lat: Double = 0, lon: Double = 0,
                          elevation: Int = 0, hasMetar: Bool = true, sortOrder: Int? = nil) -> AirportFavorite {
        AirportFavorite(from: Airport(icao: icao, iata: iata, name: name, latitude: lat, longitude: lon,
                                      elevation: elevation, hasMetar: hasMetar), sortOrder: sortOrder)
    }

    @Test func staleFavoriteTakesEveryReferenceFieldFromAirportsJSON() throws {
        let ctx = try makeContext()
        let stale = favorite("KVGT", name: "Old Name", iata: nil, lat: 1, lon: 2, elevation: 0, hasMetar: false, sortOrder: 4)
        let added = stale.addedDate
        ctx.insert(stale)
        try ctx.save()
        let truth = Airport(icao: "KVGT", iata: "VGT", name: "North Las Vegas",
                            latitude: 36.2107, longitude: -115.1944, elevation: 2205, hasMetar: true)

        let changed = FavoritesReconciler.reconcile(in: ctx) { $0 == "KVGT" ? truth : nil }

        #expect(changed == 1)
        let f = try #require(try ctx.fetch(FetchDescriptor<AirportFavorite>()).first)
        #expect(f.name == "North Las Vegas")
        #expect(f.iata == "VGT")
        #expect(f.latitude == 36.2107)
        #expect(f.longitude == -115.1944)
        #expect(f.elevation == 2205)
        #expect(f.hasMetar == true)
        // The pilot's order and date added are not reference data.
        #expect(f.sortOrder == 4)
        #expect(f.addedDate == added)
    }

    @Test func icaoMissingFromAirportsJSONKeepsTheFavorite() throws {
        let ctx = try makeContext()
        ctx.insert(favorite("K36K", name: "Kearny County", lat: 37.97, lon: -101.25, elevation: 3076))
        try ctx.save()

        let changed = FavoritesReconciler.reconcile(in: ctx) { _ in nil }

        #expect(changed == 0)
        let all = try ctx.fetch(FetchDescriptor<AirportFavorite>())
        #expect(all.map(\.icao) == ["K36K"])
        #expect(all.first?.name == "Kearny County")
        #expect(all.first?.elevation == 3076)
    }

    @Test func matchingFavoriteIsUnchanged() throws {
        let ctx = try makeContext()
        let truth = Airport(icao: "KLAS", iata: "LAS", name: "Harry Reid International",
                            latitude: 36.08, longitude: -115.15, elevation: 2181)
        ctx.insert(AirportFavorite(from: truth))
        try ctx.save()
        #expect(FavoritesReconciler.reconcile(in: ctx) { _ in truth } == 0)
    }

    // The default lookup reads the real bundled airports.json.
    @Test func defaultLookupUsesBundledAirportsJSON() throws {
        let ctx = try makeContext()
        ctx.insert(favorite("KLAS", name: "Stale", elevation: 0))
        try ctx.save()
        let bundled = try #require(AirportService.shared.bundledAirport(icao: "KLAS"))

        #expect(FavoritesReconciler.reconcile(in: ctx) == 1)
        let f = try #require(try ctx.fetch(FetchDescriptor<AirportFavorite>()).first)
        #expect(f.name == bundled.name)
        #expect(f.elevation == bundled.elevation)
    }
}

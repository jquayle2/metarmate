import AppIntents

// MARK: - Airport AppEntity
// Lightweight AppEntity wrapping an ICAO/IATA code.
// Shared between the main app (Siri) and widget extension (configuration).

struct AirportEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Airport"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(name)")
    }

    static var defaultQuery = AirportEntityQuery()
}

struct AirportEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AirportEntity] {
        let snapshots = WidgetDataManager.loadAll()
        var results: [AirportEntity] = []
        for id in identifiers {
            let upper = id.uppercased()
            if let snap = snapshots.first(where: { $0.icao == upper }) {
                results.append(AirportEntity(id: snap.icao, name: snap.airportName))
            } else if let found = await MainActor.run(body: {
                AirportService.shared.airport(identifier: upper)
            }) {
                results.append(AirportEntity(id: found.icao.uppercased(), name: found.name))
            }
        }
        return results
    }

    // METAR stations only, ranked so a clear match is a single result and Siri doesn't ask
    // "Which one?" (SiriAirportResolver.matches).
    func entities(matching string: String) async throws -> [AirportEntity] {
        let favorites = SiriFavorites.load()
        let location = IntentLocationHelper.lastKnownLocation()
        return await MainActor.run {
            SiriAirportResolver.matches(string, favorites: favorites, location: location)
                .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
        }
    }

    // Favorites, then nearest METAR stations. Not the widget snapshot cache: it holds every
    // airport ever viewed, including non-METAR strips (Oct 22: 06NV, 07NV, 0CL3…).
    func suggestedEntities() async throws -> [AirportEntity] {
        let favorites = SiriFavorites.load()
        let location = IntentLocationHelper.lastKnownLocation()
        return await MainActor.run {
            SiriAirportResolver.suggestions(favorites: favorites, location: location)
                .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
        }
    }
}

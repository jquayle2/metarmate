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

    func entities(matching string: String) async throws -> [AirportEntity] {
        await MainActor.run {
            AirportService.shared.search(query: string, limit: 10)
                .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [AirportEntity] {
        let snapshots = WidgetDataManager.loadAll()
        if !snapshots.isEmpty {
            return snapshots.map { AirportEntity(id: $0.icao, name: $0.airportName) }
        }
        return await MainActor.run {
            ["KLAS", "KVGT", "KLAX", "KSFO", "KORD"].compactMap { icao in
                AirportService.shared.airport(icao: icao)
                    .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
            }
        }
    }
}

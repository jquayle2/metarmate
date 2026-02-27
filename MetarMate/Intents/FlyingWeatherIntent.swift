import AppIntents

// MARK: - Airport Code AppEnum (allows Shortcuts to pick from common airports)
// For a full dynamic list, this would be an AppEntity — kept simple for now.

struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Flying Weather"
    static var description = IntentDescription("Fetch the current METAR and flight category for an airport.")

    @Parameter(title: "Airport Code", description: "ICAO identifier, e.g. KLAS")
    var airportCode: AirportCodeEntity

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let icao = airportCode.id.uppercased()
        let metar = try await WeatherService.shared.fetchMetar(for: icao)
        let wind = metar.wind
        let windStr: String
        if wind.speed == 0 {
            windStr = "Calm"
        } else {
            let dir = wind.isVariable ? "Variable" : "\(wind.direction ?? 0) degrees"
            windStr = "\(dir) at \(wind.speed) knots" + (wind.gust.map { ", gusting \($0)" } ?? "")
        }
        let visStr = metar.visibility >= 10 ? "10 or more" : String(format: "%.1f", metar.visibility)
        let summary = "\(icao) is \(metar.flightCategory.rawValue). Wind \(windStr), visibility \(visStr) statute miles."
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - AppEntity wrapping an ICAO string
struct AirportCodeEntity: AppEntity {
    var id: String   // ICAO code

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Airport"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }

    static var defaultQuery = AirportCodeQuery()
}

struct AirportCodeQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AirportCodeEntity] {
        identifiers.map { AirportCodeEntity(id: $0.uppercased()) }
    }

    func entities(matching string: String) async throws -> [AirportCodeEntity] {
        AirportService.shared.search(query: string, limit: 10)
            .map { AirportCodeEntity(id: $0.icao) }
    }

    func suggestedEntities() async throws -> [AirportCodeEntity] {
        ["KLAS", "KLAX", "KSFO", "KORD", "KATL"].map { AirportCodeEntity(id: $0) }
    }
}

// MARK: - Shortcuts Provider
struct MetarMateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FlyingWeatherIntent(),
            phrases: [
                "Get flying weather for \(\.$airportCode) in \(.applicationName)",
                "Is it VFR at \(\.$airportCode) in \(.applicationName)"
            ],
            shortTitle: "Flying Weather",
            systemImageName: "airplane"
        )
    }
}

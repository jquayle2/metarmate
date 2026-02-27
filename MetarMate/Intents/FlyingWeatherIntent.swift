import AppIntents

// MARK: - Flying Weather Intent (Siri / Shortcuts)
struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Flying Weather"
    static var description = IntentDescription("Fetch the current METAR and flight category for an airport.")

    @Parameter(title: "Airport Code", description: "ICAO or IATA identifier, e.g. KLAS or LAS")
    var airportCode: String

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let metar = try await WeatherService.shared.fetchMetar(for: airportCode.uppercased())
        let wind = metar.wind
        let windStr: String
        if wind.speed == 0 {
            windStr = "Calm"
        } else {
            let dir = wind.isVariable ? "Variable" : "\(wind.direction ?? 0) degrees"
            windStr = "\(dir) at \(wind.speed) knots"
            + (wind.gust.map { ", gusting \($0)" } ?? "")
        }
        let visStr = metar.visibility >= 10 ? "10 or more" : String(format: "%.1f", metar.visibility)
        let summary = "\(airportCode.uppercased()) is \(metar.flightCategory.rawValue). Wind \(windStr), visibility \(visStr) statute miles."
        return .result(value: summary, dialog: "\(summary)")
    }
}

// MARK: - Shortcuts App Provider
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

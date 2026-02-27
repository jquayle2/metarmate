import AppIntents

// MARK: - Flying Weather Intent (Siri / Shortcuts)
struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Flying Weather"
    static var description = IntentDescription("Fetch the current METAR and flight category for an airport.")

    @Parameter(title: "Airport Code", description: "ICAO or IATA identifier, e.g. KLAS or LAS")
    var airportCode: String

    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let metar = try await WeatherService.shared.fetchMetar(for: airportCode.uppercased())
        let summary = "\(airportCode.uppercased()) is \(metar.flightCategory.rawValue). " +
                      "Wind \(metar.wind.displayString), visibility \(metar.visibility.visibilityString) sm."
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

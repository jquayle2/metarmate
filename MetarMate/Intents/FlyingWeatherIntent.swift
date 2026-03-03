import AppIntents
import CoreLocation
import SwiftUI

// MARK: - Flying Weather Intent
// "Hey Siri, check flying weather with MetarMate"
// "Hey Siri, check flying weather at KLAS with MetarMate"
// If an airport code is provided it is used directly; otherwise falls back to nearest airport.
struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Flying Weather"
    static var description = IntentDescription(
        "Get current METAR and weather trend. Specify an airport code or use your nearest airport."
    )

    @Parameter(title: "Airport", description: "ICAO or IATA identifier, e.g. KLAS or LAS. Leave empty to use nearest airport.", requestValueDialog: "Which airport? Spell out the ICAO code, like K-L-A-S.")
    var airport: AirportEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$airport, .hasAnyValue) {
            Summary("Check flying weather at \(\.$airport)")
        } otherwise: {
            Summary("Check flying weather near me")
        }
    }

    func perform() async throws -> some ProvidesDialog & ShowsSnippetView {
        NSLog("FlyingWeatherIntent: perform() called, airport entity='\(airport?.id ?? "nil")'")
        // 1. Resolve airport — from parameter, Siri prompt, or nearest
        let resolvedAirport: Airport

        if let entity = airport {
            // Came from Shortcuts picker — entity.id is already a clean ICAO code
            let code = entity.id.uppercased()
            NSLog("FlyingWeatherIntent: airport entity.id='\(entity.id)' normalized='\(code)'")
            guard let found = await MainActor.run(body: { AirportService.shared.airport(identifier: code) }) else {
                return .result(
                    dialog: IntentDialog("I couldn't find an airport with the code \(code)."),
                    view: snippetView(label: code, category: .unknown, detail: "Airport not found")
                )
            }
            resolvedAirport = found
        } else {
            // Siri didn't fill the parameter — ask interactively or fall back to nearest.
            // Request a value from the user; if they say "nearest" or cancel we fall back.
            let requestedEntity: AirportEntity
            do {
                requestedEntity = try await $airport.requestValue("Which airport? Say the ICAO code, like K-L-A-S, or say nearest airport.")
            } catch {
                // User said nearest, cancelled, or Siri timed out — use nearest airport
                let location: CLLocation
                do {
                    location = try await IntentLocationHelper.currentLocation()
                } catch {
                    return .result(
                        dialog: IntentDialog("I need location access to find your nearest airport. Please enable it in Settings."),
                        view: snippetView(label: "Location unavailable", category: .unknown, detail: "Enable location in Settings")
                    )
                }
                let airports = await MainActor.run { AirportService.shared.nearest(to: location, count: 1) }
                guard let nearest = airports.first else {
                    return .result(
                        dialog: IntentDialog("I couldn't find a nearby airport."),
                        view: snippetView(label: "No airport found", category: .unknown, detail: "No reporting station nearby")
                    )
                }
                resolvedAirport = nearest
                // Skip to weather fetch below
                return try await fetchAndRespond(airport: resolvedAirport)
            }
            let code = requestedEntity.id
                .components(separatedBy: .whitespaces)
                .joined()
                .uppercased()
            NSLog("FlyingWeatherIntent: requested entity='\(requestedEntity.id)' normalized='\(code)'")
            guard let found = await MainActor.run(body: { AirportService.shared.airport(identifier: code) }) else {
                return .result(
                    dialog: IntentDialog("I couldn't find an airport with the code \(code). Try again."),
                    view: snippetView(label: code, category: .unknown, detail: "Airport not found")
                )
            }
            resolvedAirport = found
        }

        return try await fetchAndRespond(airport: resolvedAirport)
    }

    // MARK: - Fetch weather and build response
    private func fetchAndRespond(airport: Airport) async throws -> some ProvidesDialog & ShowsSnippetView {

        // 2. Fetch METAR history
        let metarHistory: [Metar]
        do {
            metarHistory = try await WeatherService.shared.fetchMetarHistory(for: airport.icao, hours: 6)
        } catch {
            return .result(
                dialog: IntentDialog("No weather data available for \(airport.name)."),
                view: snippetView(label: airport.icao, category: .unknown, detail: "No data available")
            )
        }

        guard let metar = metarHistory.first else {
            return .result(
                dialog: IntentDialog("No weather data available for \(airport.name)."),
                view: snippetView(label: airport.icao, category: .unknown, detail: "No data available")
            )
        }

        // 3. Fetch TAF (optional)
        let taf = try? await WeatherService.shared.fetchTaf(for: airport.icao)

        // 4. Derive trend
        let trend = await MainActor.run { WeatherTrend.derive(metars: metarHistory, taf: taf) }

        // 5. Build spoken dialog
        let spokenText = buildDialog(airportName: airport.name, metar: metar, trend: trend)

        // 6. Build snippet summary
        let detail = buildSummaryLine(metar: metar)

        return .result(
            dialog: IntentDialog(stringLiteral: spokenText),
            view: snippetView(label: "\(airport.icao) · \(airport.name)", category: metar.flightCategory, detail: detail)
        )
    }

    // MARK: - Dialog Builder
    private func buildDialog(airportName: String, metar: Metar, trend: WeatherTrend) -> String {
        var parts: [String] = []

        // Category
        parts.append("\(airportName) is currently \(metar.flightCategory.rawValue).")

        // Ceiling
        if let ceiling = metar.ceilingFeet {
            let layer = metar.clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
            let coverageWord = layer?.coverage == .overcast ? "overcast" : "broken"
            parts.append("Ceiling \(coverageWord) at \(ceiling) feet.")
        } else {
            parts.append("Ceiling unlimited.")
        }

        // Visibility
        let visStr = metar.visibility >= 10 ? "10 or more" : String(format: "%.0f", metar.visibility)
        let wxSuffix = metar.weatherPhenomena.isEmpty ? "" : " in \(WeatherDecoder.decodeAll(metar.weatherPhenomena).lowercased())"
        parts.append("Visibility \(visStr) miles\(wxSuffix).")

        // Wind
        parts.append(windPhrase(metar.wind))

        // Trend — use observed if we have enough history, otherwise forecast
        if trend.observed.overall != .unknown {
            parts.append("Conditions are \(trend.observed.overall.rawValue.lowercased()).")
        } else if trend.forecast.overall != .unknown {
            parts.append("Forecast shows conditions \(trend.forecast.overall.rawValue.lowercased()).")
        } else {
            parts.append("No trend data available.")
        }

        return parts.joined(separator: " ")
    }

    private func windPhrase(_ wind: Wind) -> String {
        if wind.speed == 0 && !wind.isVariable {
            return "Wind calm."
        }
        let dir: String
        if wind.isVariable {
            dir = "variable"
        } else if let d = wind.direction {
            dir = "\(d)"
        } else {
            dir = "variable"
        }
        var phrase = "Wind \(dir) at \(wind.speed) knots"
        if let gust = wind.gust {
            phrase += ", gusting \(gust)"
        }
        return phrase + "."
    }

    private func buildSummaryLine(metar: Metar) -> String {
        let vis = metar.visibility >= 10 ? "Vis 10+" : String(format: "Vis %.0f sm", metar.visibility)
        let ceiling: String
        if let c = metar.ceilingFeet {
            ceiling = "Ceil \(c / 100 * 100)ft"
        } else {
            ceiling = "Sky clear"
        }
        let windStr: String
        if metar.wind.speed == 0 {
            windStr = "Calm"
        } else {
            windStr = "\(metar.wind.speed)kt"
        }
        return "\(ceiling) · \(vis) · Wind \(windStr)"
    }

    // MARK: - Snippet View
    @ViewBuilder
    private func snippetView(label: String, category: FlightCategory, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(category.rawValue)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(categoryColor(category))
                .foregroundStyle(.white)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
    }

    private func categoryColor(_ category: FlightCategory) -> Color {
        switch category {
        case .vfr:     return .green
        case .mvfr:    return .blue
        case .ifr:     return .red
        case .lifr:    return .purple
        case .unknown: return .gray
        }
    }
}

// MARK: - App Shortcuts Provider
struct MetarMateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FlyingWeatherIntent(),
            phrases: [
                "Check flying weather with \(.applicationName)",
                "What's the flying weather in \(.applicationName)",
                "Flying conditions with \(.applicationName)",
                "\(.applicationName) weather check",
                "Check flying weather at \(\.$airport) with \(.applicationName)",
                "What's the weather at \(\.$airport) in \(.applicationName)"
            ],
            shortTitle: "Flying Weather",
            systemImageName: "cloud.sun.fill"
        )
    }
}

// MARK: - Airport AppEntity
// Lightweight AppEntity wrapping an ICAO/IATA code so App Intents can accept it as a parameter.
struct AirportEntity: AppEntity {
    var id: String   // ICAO code (uppercased)
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Airport"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(name)")
    }

    static var defaultQuery = AirportEntityQuery()
}

struct AirportEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AirportEntity] {
        await MainActor.run {
            identifiers.compactMap { id in
                AirportService.shared.airport(identifier: id)
                    .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
            }
        }
    }

    func entities(matching string: String) async throws -> [AirportEntity] {
        await MainActor.run {
            AirportService.shared.search(query: string, limit: 10)
                .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [AirportEntity] {
        await MainActor.run {
            ["KLAS", "KVGT", "KLAX", "KSFO", "KORD"].compactMap { icao in
                AirportService.shared.airport(icao: icao)
                    .map { AirportEntity(id: $0.icao.uppercased(), name: $0.name) }
            }
        }
    }
}

// MARK: - Location Helper for Intents
// App Intents run outside the normal app lifecycle so we use a one-shot
// CLLocationManager wrapped in a CheckedContinuation with a timeout.
private enum IntentLocationError: Error {
    case notAuthorized
    case timeout
    case failed(Error)
}

private final class IntentLocationHelper: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    // Static strong reference to keep the helper alive during the async call
    private static var activeHelper: IntentLocationHelper?

    static func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            let helper = IntentLocationHelper()
            activeHelper = helper
            helper.start(continuation: continuation)
        }
    }

    private func start(continuation: CheckedContinuation<CLLocation, Error>) {
        self.continuation = continuation
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer

        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            finish(with: .failure(IntentLocationError.notAuthorized))
            return
        }

        // 5-second timeout using Task.sleep instead of Timer (no run loop needed)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                self?.finish(with: .failure(IntentLocationError.timeout))
            }
        }

        manager.requestLocation()
    }

    private func finish(with result: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let continuation else { return }
        self.continuation = nil
        Self.activeHelper = nil
        continuation.resume(with: result)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        finish(with: .success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: .failure(IntentLocationError.failed(error)))
    }
}

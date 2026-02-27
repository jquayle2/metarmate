import AppIntents
import CoreLocation
import SwiftUI

// MARK: - Flying Weather Intent
// Invoked by Siri ("Hey Siri, check flying weather with MetarMate")
// Uses current location to find the nearest airport — no parameter needed.
struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Flying Weather"
    static var description = IntentDescription(
        "Get current METAR and weather trend for your nearest airport."
    )

    // No parameters — location is resolved automatically
    static var parameterSummary: some ParameterSummary {
        Summary("Check flying weather near me")
    }

    func perform() async throws -> some ProvidesDialog & ShowsSnippetView {
        // 1. Get current location
        let location: CLLocation
        do {
            location = try await IntentLocationHelper.currentLocation()
        } catch {
            return .result(
                dialog: "I need location access to find your nearest airport. Please enable it in Settings.",
                view: snippetView(label: "Location unavailable", category: .unknown, detail: "Enable location in Settings")
            )
        }

        // 2. Find nearest airport
        let airports = await MainActor.run { AirportService.shared.nearest(to: location, count: 1) }
        guard let airport = airports.first else {
            return .result(
                dialog: "I couldn't find a nearby airport. Make sure you're within range of a reporting station.",
                view: snippetView(label: "No airport found", category: .unknown, detail: "No reporting station nearby")
            )
        }

        // 3. Fetch METAR (required)
        let metar: Metar
        do {
            metar = try await WeatherService.shared.fetchMetar(for: airport.icao)
        } catch {
            return .result(
                dialog: "No weather data available for \(airport.name). Try again in a few minutes.",
                view: snippetView(label: airport.icao, category: .unknown, detail: "No data available")
            )
        }

        // 4. Fetch TAF (optional — not all stations have one)
        let taf = try? await WeatherService.shared.fetchTaf(for: airport.icao)

        // 5. Derive trend
        let trend: WeatherTrend? = taf != nil ? WeatherTrend.derive(metar: metar, taf: taf) : nil

        // 6. Build spoken dialog
        let dialog = buildDialog(airportName: airport.name, metar: metar, taf: taf, trend: trend)

        // 7. Build one-line summary for snippet
        let detail = buildSummaryLine(metar: metar)

        return .result(
            dialog: "\(dialog)",
            view: snippetView(label: "\(airport.icao) · \(airport.name)", category: metar.flightCategory, detail: detail)
        )
    }

    // MARK: - Dialog Builder
    private func buildDialog(airportName: String, metar: Metar, taf: Taf?, trend: WeatherTrend?) -> String {
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
        let wxSuffix = metar.weatherPhenomena.isEmpty ? "" : " in \(metar.weatherPhenomena.joined(separator: ", "))"
        parts.append("Visibility \(visStr) miles\(wxSuffix).")

        // Wind
        parts.append(windPhrase(metar.wind))

        // Trend
        if let trend = trend, taf != nil, trend.overall != .unknown {
            parts.append("Conditions are \(trend.overall.rawValue.lowercased()).")
        } else {
            parts.append("No forecast available for trend.")
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
                "Airport weather with \(.applicationName)",
                "Flying conditions with \(.applicationName)",
                "\(.applicationName) weather check"
            ],
            shortTitle: "Flying Weather",
            systemImageName: "cloud.sun.fill"
        )
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
    private var timer: Timer?

    static func currentLocation() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            let helper = IntentLocationHelper()
            helper.start(continuation: continuation)
            // Retain helper for the duration of the async call
            Task { @MainActor in
                _ = helper // keep alive
            }
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

        // 5-second timeout
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.finish(with: .failure(IntentLocationError.timeout))
        }

        manager.requestLocation()
    }

    private func finish(with result: Result<CLLocation, Error>) {
        timer?.invalidate()
        timer = nil
        guard let continuation else { return }
        self.continuation = nil
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

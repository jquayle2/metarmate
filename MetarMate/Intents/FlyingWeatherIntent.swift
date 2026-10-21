import AppIntents
import CoreLocation
import SwiftUI

// MARK: - Flying Weather Intent
// "Hey Siri, check flying weather with MetarMate"
// "Hey Siri, check flying weather at KLAS with MetarMate"
// If an airport code is provided it is used directly; otherwise the nearest METAR station, with no
// prompt and no list (Oct 22 device test: the old "Which airport?" prompt listed cached strips).
struct FlyingWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Flying Weather"
    static var description = IntentDescription(
        "Get current METAR and weather trend. Specify an airport code or use your nearest METAR station."
    )

    @Parameter(title: "Airport", description: "ICAO or IATA identifier, e.g. KLAS or LAS. Leave empty to use the nearest METAR station.")
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

        // Gate behind Pro (disabled for beta via WidgetDataManager.widgetsRequirePro)
        let isPro = await MainActor.run { StoreManager.shared.isProUser }
        if WidgetDataManager.widgetsRequirePro && !isPro {
            return .result(
                dialog: IntentDialog("Siri shortcuts require MetarMate Pro. Upgrade in the app to enable this feature."),
                view: snippetView(label: "Pro Required", category: .unknown, detail: "Upgrade to MetarMate Pro")
            )
        }

        // 1. Resolve airport — from the spoken/picked entity, or the nearest METAR station.
        // Never prompts: a hands-free pilot can't tap a list.
        let resolvedAirport: Airport

        if let entity = airport {
            let code = entity.id.components(separatedBy: .whitespaces).joined().uppercased()
            NSLog("FlyingWeatherIntent: entity.id='\(entity.id)' normalized='\(code)'")
            guard let found = await Self.airportForIdent(code) else {
                return .result(
                    dialog: IntentDialog("I couldn't find an airport with the code \(code)."),
                    view: snippetView(label: code, category: .unknown, detail: "Airport not found")
                )
            }
            resolvedAirport = found

        } else {
            let location: CLLocation
            do {
                location = try await IntentLocationHelper.currentLocation()
            } catch {
                let reason = (error as? IntentLocationError) == .notAuthorized
                    ? "Location is off for MetarMate, so I can't find the nearest METAR station."
                    : "I couldn't get your location, so I can't find the nearest METAR station."
                return .result(
                    dialog: IntentDialog(stringLiteral: "\(reason) Name an airport instead. Say: check flying weather at K-V-G-T with MetarMate."),
                    view: snippetView(label: "Location unavailable", category: .unknown, detail: "Say \"…at KVGT with MetarMate\"")
                )
            }
            guard let nearest = await MainActor.run(body: { SiriAirportResolver.nearestMetarStation(to: location) }) else {
                return .result(
                    dialog: IntentDialog("No METAR station within 100 nautical miles. Name an airport instead."),
                    view: snippetView(label: "No airport found", category: .unknown, detail: "No reporting station nearby")
                )
            }
            resolvedAirport = nearest
        }

        // 3-char LIDs (CMA, 36K) publish under a K-prefixed id on NOAA.
        let fetchId = WeatherService.noaaCandidate(for: resolvedAirport.icao) ?? resolvedAirport.icao

        // 2. Fetch METAR history
        let metarHistory: [Metar]
        do {
            metarHistory = try await WeatherService.shared.fetchMetarHistory(for: fetchId, hours: 6)
        } catch {
            return .result(
                dialog: IntentDialog("No weather data available for \(resolvedAirport.name)."),
                view: snippetView(label: resolvedAirport.icao, category: .unknown, detail: "No data available")
            )
        }
        guard let metar = metarHistory.first else {
            return .result(
                dialog: IntentDialog("No weather data available for \(resolvedAirport.name)."),
                view: snippetView(label: resolvedAirport.icao, category: .unknown, detail: "No data available")
            )
        }

        // 3. TAF: the field's own, or the nearest current TAF within 50 nm (never on a failed request)
        let ownTaf = await WeatherService.shared.tafResult(for: fetchId)
        let field = (ids: Set([resolvedAirport.icao.uppercased(), fetchId.uppercased()]), latitude: resolvedAirport.latitude,
                     longitude: resolvedAirport.longitude, elevationFt: resolvedAirport.elevation)
        let (taf, tafStatus) = await NearbyTaf.resolve(own: NearbyTaf.outcome(of: ownTaf), field: field, at: Date()) {
            try await WeatherService.shared.tafCandidates(forField: fetchId,
                                                          latitude: field.latitude, longitude: field.longitude)
        }

        // 4. Derive trend. A borrowed TAF never feeds this field's forecast trend: Siri voices it
        // only with the borrowed-TAF sentence (nearby-TAF Step 6), so until then it isn't voiced.
        let tafForTrend = tafStatus.isBorrowed ? nil : taf
        let trend = await MainActor.run { WeatherTrend.derive(metars: metarHistory, taf: tafForTrend) }

        // 5. Build spoken dialog and snippet. Report age per D#4: every answer speaks it; over
        // 75 min there is no category, conditions or trend, in speech or on the card.
        let now = Date()
        let spokenText = SiriReportWording.dialog(airportName: resolvedAirport.name, metar: metar, trend: trend, at: now)
        let detail = SiriReportWording.summaryLine(metar: metar, at: now)

        return .result(
            dialog: IntentDialog(stringLiteral: spokenText),
            view: snippetView(label: "\(resolvedAirport.icao) · \(resolvedAirport.name)",
                              category: SiriReportWording.cardCategory(metar: metar, at: now), detail: detail)
        )
    }

    // MARK: - Identifier lookup
    static func airportForIdent(_ code: String) async -> Airport? {
        await MainActor.run { SiriAirportResolver.airport(forIdent: code) }
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
        category.swiftUIColor
    }
}

// MARK: - App Shortcuts Provider
// Phrases led by the app name, or without the bare word "weather", so Siri doesn't hand them to
// Apple Weather (Oct 22 device test). Airport phrases match the registered favorites:
// updateAppShortcutParameters() runs at launch and whenever favorites change (ContentView).
struct MetarMateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FlyingWeatherIntent(),
            phrases: [
                "Check flying weather with \(.applicationName)",
                "What's the flying weather in \(.applicationName)",
                "Flying conditions with \(.applicationName)",
                "\(.applicationName) weather check",
                "\(.applicationName) nearest METAR",
                "Ask \(.applicationName) for the METAR",
                "\(.applicationName), how's the flying",
                "Get the METAR with \(.applicationName)",
                "Check flying weather at \(\.$airport) with \(.applicationName)",
                "What's the weather at \(\.$airport) in \(.applicationName)",
                "\(.applicationName) METAR at \(\.$airport)",
                "Get the METAR at \(\.$airport) with \(.applicationName)"
            ],
            shortTitle: "Flying Weather",
            systemImageName: "cloud.sun.fill"
        )
    }
}

// MARK: - Location Helper for Intents
// App Intents run outside the normal app lifecycle so we use a one-shot
// CLLocationManager wrapped in a CheckedContinuation with a timeout.
enum IntentLocationError: Error {
    case notAuthorized
    case timeout
    case failed
}

final class IntentLocationHelper: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    // Static strong reference to keep the helper alive during the async call
    private static var activeHelper: IntentLocationHelper?

    /// The system's cached fix, without starting a request. For ranking Siri's airport lists,
    /// where waiting up to 5 s for a fresh fix would stall the query.
    static func lastKnownLocation() -> CLLocation? {
        let manager = CLLocationManager()
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return nil }
        return manager.location
    }

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
        NSLog("IntentLocationHelper: location failed: \(error)")
        finish(with: .failure(IntentLocationError.failed))
    }
}

import Foundation
import Combine
import SwiftUI
import CoreLocation
import os

// MARK: - Nearby Reporting Airport
struct NearbyReportingAirport: Identifiable {
    var id: String { airport.icao }
    let airport: Airport
    let metar: Metar
}

// MARK: - Weather View Model
@MainActor
class WeatherViewModel: ObservableObject {
    @Published var metar: Metar?
    @Published var metarHistory: [Metar] = []
    @Published var taf: Taf?
    @Published var tafStatus: TafStatus = .own   // own, borrowed from a nearby station, or none
    @Published var tafStationHistory: [Metar] = []   // a borrowed TAF's station's METARs, newest first
    // What the widget snapshot gets (no borrowed-TAF forecast/accuracy until the widget names the station).
    private var snapshotTrend: WeatherTrend?
    private var snapshotVerification: TafVerification?
    @Published var trend: WeatherTrend?
    @Published var tafVerification: TafVerification?
    @Published var isLoading = false
    @Published var error: Error?
    @Published var lastUpdated: Date?
    @Published var noWeatherReporting = false
    @Published var nearbyReportingAirports: [NearbyReportingAirport] = []
    @Published var advisoryWeather: AdvisoryWeather?  // Open-Meteo data for non-METAR airports
    @Published var isMetarFallback = false  // True when hasMetar station fell back to advisory
    @Published var synopticLatest: SynopticObservation?  // Most recent ASOS observation
    @Published var synopticHistory: [SynopticObservation] = []  // 6-hour ASOS time series
    @Published var isSynopticLoading = false
    @Published var synopticError: String?

    private let weatherService = WeatherService.shared
    private let synopticService = SynopticService.shared

    /// Whether ASOS data is available (Pro feature, auto-fetched)
    var hasASOSData: Bool { synopticLatest != nil }

    // MARK: - Load with full Airport (preferred — enables hasMetar routing)
    // force: true (pull-to-refresh) skips the 60s throttle AND clears the METAR cache so
    // the user always gets a genuine network fetch when they deliberately ask for one.
    func load(airport: Airport, force: Bool = false) async {
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < 60 {
            Log.load.info("[load] \(airport.icao, privacy: .public) skipped (cached \(String(format: "%.0f", Date().timeIntervalSince(last)), privacy: .public)s ago)")
            return
        }
        if force {
            await weatherService.clearMetarCache()
            await weatherService.clearTafCandidateCache()
            Log.load.info("[load] \(airport.icao, privacy: .public) FORCE refresh (cache cleared)")
        }
        let loadStart = DispatchTime.now()
        Log.load.info("[load] \(airport.icao, privacy: .public) START hasMetar=\(airport.hasMetar, privacy: .public)")
        // What's on screen stays until an outcome replaces it: a failed refresh keeps the last
        // reading (or the last advisory) instead of blanking it.
        isLoading = true
        error = nil
        synopticError = nil

        if !airport.hasMetar {
            // Numeric/short US LIDs (36K→K36K, CMA→KCMA) can still publish a real METAR; try the
            // K-prefixed ICAO first. Advisory only once NOAA confirms it has no METAR for it — a
            // failed request is not a miss (L35 showed an estimate while KL35 was reporting).
            if let kIcao = WeatherService.noaaCandidate(for: airport.icao) {
                switch await loadMETAR(icao: kIcao, field: airport) {
                case .loaded, .cancelled:
                    isLoading = false
                    return
                case .failed:
                    Log.load.warning("[fallback] \(airport.icao, privacy: .public) none: \(kIcao, privacy: .public) METAR request failed after retries — no advisory on a failure")
                    isLoading = false
                    return
                case .noProduct:
                    Log.load.info("[fallback] \(airport.icao, privacy: .public) → ADVISORY (no hasMetar; \(kIcao, privacy: .public) has no METAR)")
                    noWeatherReporting = false
                }
            }
            await loadAdvisory(airport: airport)
        } else {
            // For 3-char FAA LIDs, use the K-prefixed ICAO for NOAA lookup (CMA → KCMA)
            let icaoForFetch = WeatherService.noaaCandidate(for: airport.icao) ?? airport.icao
            switch await loadMETAR(icao: icaoForFetch, field: airport) {
            case .noProduct:
                // NOAA confirms this reporting station has no METAR right now: show the estimate.
                Log.load.warning("[load] \(airport.icao, privacy: .public) METAR fallback → ADVISORY (noProduct)")
                isMetarFallback = true
                await loadAdvisory(airport: airport)
            case .failed:
                // Never an advisory fallback on a failure: the last reading (if any) stays, and the
                // detail screen offers Retry when there's nothing to show.
                Log.load.warning("[load] \(airport.icao, privacy: .public) METAR failed after retries — keeping last reading (\(self.metar != nil, privacy: .public)), no fallback")
            case .loaded:
                Log.load.info("[load] \(airport.icao, privacy: .public) METAR OK (\(self.metarHistory.count, privacy: .public) obs)")
            case .cancelled:
                break
            }

            if StoreManager.shared.isAsosUser {
                await fetchASOS(icao: icaoForFetch)
            }
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - loadStart.uptimeNanoseconds) / 1_000_000
        Log.load.info("[load] \(airport.icao, privacy: .public) DONE - \(String(format: "%.0f", totalMs), privacy: .public) ms total, fallback=\(self.isMetarFallback, privacy: .public), advisory=\(self.advisoryWeather != nil, privacy: .public)")
        isLoading = false
    }
    func load(icao: String) async {
        if let airport = AirportService.shared.airport(icao: icao) {
            await load(airport: airport)
        } else {
            _ = await loadMETAR(icao: icao)
        }
    }

    // MARK: - Simulated seed (Test Harness only)
    // Seeds already-parsed, in-memory models straight onto the published properties — the exact
    // fields loadMETAR would set — WITHOUT any side effects. Deliberately does NOT: touch the
    // network, write the widget App-Group snapshot (no WidgetDataManager.save), fetch ASOS, or read
    // SwiftData. Trend/verification are derived with the same pure functions the live path uses.
    func seedSimulated(_ injection: SimulatedInjection) {
        isLoading = false
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []
        advisoryWeather = nil
        isMetarFallback = false
        synopticError = nil
        synopticLatest = nil
        synopticHistory = []

        metarHistory = injection.metars
        metar = injection.metars.first
        taf = injection.taf
        tafStatus = .own
        tafStationHistory = []
        trend = WeatherTrend.derive(metars: injection.metars, taf: injection.taf)
        if let taf = injection.taf {
            tafVerification = TafVerification.derive(metars: injection.metars, taf: taf)
        } else {
            tafVerification = nil
        }
        lastUpdated = Date()
    }

    // MARK: - METAR path (aviationweather.gov)
    private enum MetarLoad { case loaded, noProduct, failed, cancelled }

    /// The field's METARs and TAF, each retried on a transient failure (RetryPolicy). Loaded: shown.
    /// No product (NOAA confirms no METAR): the field is marked not reporting and nearby reporting
    /// stations are listed. Failed: nothing on screen changes; `error` is set for the Retry view.
    /// Cancelled: nothing changes.
    private func loadMETAR(icao: String, field: Airport? = nil) async -> MetarLoad {
        let service = weatherService
        do {
            async let ownTaf = RetryPolicy.foreground.run("TAF \(icao)") { try await service.tafOutcome(for: icao) }
            var history = try await RetryPolicy.foreground.run("METAR \(icao)") { try await service.metarHistoryOutcome(for: icao, hours: 6) }
            var fetchIcao = icao
            var tafOutcome: FetchOutcome<Taf>?

            // For 3-char FAA LIDs (CMA, 36K, 1G4, …) without an airport record, try the K-prefixed ICAO.
            if history.isNoProduct, let kIcao = WeatherService.noaaCandidate(for: icao) {
                history = try await RetryPolicy.foreground.run("METAR \(kIcao)") { try await service.metarHistoryOutcome(for: kIcao, hours: 6) }
                if history.value != nil {
                    fetchIcao = kIcao
                    tafOutcome = try await RetryPolicy.foreground.run("TAF \(kIcao)") { try await service.tafOutcome(for: kIcao) }
                }
            }

            switch history {
            case .loaded(let fetched):
                let ownTafOutcome: FetchOutcome<Taf>
                if let tafOutcome { ownTafOutcome = tafOutcome } else { ownTafOutcome = try await ownTaf }
                await show(history: fetched, ownTaf: ownTafOutcome, airportIcao: icao, fetchIcao: fetchIcao, field: field)
                return .loaded
            case .failed(let failure):
                Log.load.error("[load] \(icao, privacy: .public) METAR load failed: \(FetchLog.classify(failure), privacy: .public)")
                error = failure.underlying
                return .failed
            case .noProduct:
                error = nil
                noWeatherReporting = true
                metar = nil
                metarHistory = []
                taf = nil
                tafStatus = .own
                tafStationHistory = []
                trend = nil
                tafVerification = nil
                await loadNearbyReporting(icao: icao)
                return .noProduct
            }
        } catch {
            // Navigated away mid-load. Not a failure: nothing changes, and no fallback.
            Log.load.info("[load] \(icao, privacy: .public) METAR load cancelled (navigated away)")
            return .cancelled
        }
    }

    /// Publish a loaded METAR history and its TAF, and write the widget snapshot.
    private func show(history: [Metar], ownTaf: FetchOutcome<Taf>, airportIcao: String, fetchIcao: String, field: Airport?) async {
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []
        advisoryWeather = nil
        isMetarFallback = false
        metarHistory = history
        metar = history.first
        let (resolvedTaf, status) = await resolveTaf(ownTaf, fetchIcao: fetchIcao, field: field)
        await applyTaf(resolvedTaf, status: status, history: history)
        lastUpdated = Date()

        if let currentMetar = metar {
            let snapshot = WidgetWeatherSnapshot.from(
                airport: AirportService.shared.airport(icao: airportIcao) ?? Airport(
                    icao: airportIcao, iata: nil, name: airportIcao,
                    latitude: 0, longitude: 0, elevation: nil
                ),
                metar: currentMetar,
                trend: snapshotTrend,
                tafVerification: snapshotVerification
            )
            WidgetVerdictSync.publishRunways(for: [snapshot.icao])   // before save: its reload carries them
            WidgetDataManager.save(snapshot: withBorrowedTaf(snapshot))
        }
    }

    // MARK: - TAF: own, or the nearest current TAF within 50 nm (D#13–17)
    /// The field's own TAF when it has a current one; otherwise (204 / empty / expired) the nearest
    /// current TAF within 50 nm. A failed request never borrows. The nearby lookup is cached ~10 min
    /// per field; the field's own TAF is requested on every refresh, so one that appears wins at once.
    private func resolveTaf(_ ownResult: FetchOutcome<Taf>, fetchIcao: String, field: Airport?) async -> (Taf?, TafStatus) {
        let field = field ?? AirportService.shared.airport(icao: fetchIcao)
        let position = field.map { f in
            (ids: Set([fetchIcao.uppercased(), f.icao.uppercased()]), latitude: f.latitude, longitude: f.longitude, elevationFt: f.elevation)
        }
        let service = weatherService
        Log.load.info("[taf] \(fetchIcao, privacy: .public) own TAF request: \(FetchLog.classify(ownResult), privacy: .public) (only noProduct may borrow)")
        let resolved = await NearbyTaf.resolve(own: NearbyTaf.outcome(of: ownResult), field: position, at: Date()) {
            guard let position else { return [] }
            return try await service.tafCandidates(forField: fetchIcao, latitude: position.latitude, longitude: position.longitude)
        }
        switch resolved.status {
        case .borrowed(let source, let ownExpired):
            Log.load.info("[taf] \(fetchIcao, privacy: .public) borrowing \(source.stationId, privacy: .public) \(source.distanceNm, privacy: .public) nm \(source.bearing, privacy: .public) (own expired: \(ownExpired, privacy: .public))")
        case .noneWithin50nm:
            Log.load.info("[taf] \(fetchIcao, privacy: .public) no TAF within 50 nm")
        case .unavailable:
            Log.load.info("[taf] \(fetchIcao, privacy: .public) TAF unavailable (request or lookup failed)")
        case .own:
            break
        }
        return resolved
    }

    /// Publish the TAF and what's derived from it. A borrowed TAF is compared only with its own
    /// station's METARs (D#15), fetched here; never with this field's.
    private func applyTaf(_ resolvedTaf: Taf?, status: TafStatus, history: [Metar]) async {
        var stationHistory: [Metar] = []
        if case .borrowed(let source, _) = status {
            do {
                stationHistory = try await weatherService.fetchMetarHistory(for: source.stationId, hours: 6)
            } catch {
                Log.load.warning("[taf] borrowed station \(source.stationId, privacy: .public) METARs: \(FetchLog.classify(error), privacy: .public) — no trend/accuracy from it")
            }
        }
        taf = resolvedTaf
        tafStatus = status
        tafStationHistory = stationHistory
        let derived = NearbyTaf.derive(fieldHistory: history, taf: resolvedTaf, status: status, stationHistory: stationHistory)
        trend = derived.trend
        tafVerification = derived.verification
        snapshotTrend = derived.snapshotTrend
        snapshotVerification = derived.snapshotVerification
    }

    /// The snapshot with a borrowed TAF's station and substitution line, so the widget labels it.
    private func withBorrowedTaf(_ snapshot: WidgetWeatherSnapshot) -> WidgetWeatherSnapshot {
        guard case .borrowed(let source, let ownExpired) = tafStatus else { return snapshot }
        var labeled = snapshot
        labeled.borrowedTafStation = source.stationId
        labeled.borrowedTafLine = NearbyTaf.substitutionLine(fieldId: snapshot.icao, source: source, ownExpired: ownExpired)
        return labeled
    }

    // MARK: - Advisory weather path (Open-Meteo, for non-METAR airports)
    /// The estimate, retried on a transient failure. A failure keeps the last advisory on screen.
    private func loadAdvisory(airport: Airport) async {
        do {
            switch try await RetryPolicy.foreground.run("ADVISORY \(airport.icao)", { try await OpenMeteoService.shared.advisoryOutcome(for: airport) }) {
            case .loaded(let advisory):
                advisoryWeather = advisory
                lastUpdated = Date()
                WidgetDataManager.save(snapshot: WidgetWeatherSnapshot.fromAdvisory(airport: airport, advisory: advisory))
            case .failed(let failure):
                Log.load.error("[load] \(airport.icao, privacy: .public) advisory failed: \(FetchLog.classify(failure), privacy: .public)")
                error = failure.underlying
            case .noProduct:
                break
            }
        } catch {
            Log.load.info("[load] \(airport.icao, privacy: .public) advisory cancelled (navigated away)")
        }
    }

    // MARK: - ASOS (auto-fetch for Pro users)
    /// Fetch ASOS data in the background. Called automatically on load for Pro users.
    private func fetchASOS(icao: String) async {
        isSynopticLoading = true
        synopticError = nil

        let service = synopticService
        let result: Result<[SynopticObservation], Error> = await Task {
            do {
                let series = try await service.fetchTimeSeries(for: icao, recentMinutes: 360)
                return .success(series)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let series):
            synopticHistory = series
            synopticLatest = series.last
        case .failure:
            synopticError = "ASOS data unavailable for this airport."
            synopticLatest = nil
            synopticHistory = []
        }

        isSynopticLoading = false
    }

    private func loadNearbyReporting(icao: String) async {
        guard let airport = AirportService.shared.airport(icao: icao) else {
            Log.load.warning("[nearby] \(icao, privacy: .public) no airport record — skipping nearby lookup")
            return
        }
        let start = DispatchTime.now()

        let location = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        let nearby = AirportService.shared.nearest(
            to: location, count: 10
        ).filter { $0.icao != icao && $0.hasMetar }

        let icaos = nearby.map { $0.icao }
        Log.load.info("[nearby] \(icao, privacy: .public) fetching batch METAR for \(icaos.count, privacy: .public) reporting stations: \(icaos.joined(separator: ","), privacy: .public)")

        guard let metars = try? await weatherService.fetchMetars(for: icaos) else {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            Log.load.error("[nearby] \(icao, privacy: .public) batch METAR fetch failed/threw after \(String(format: "%.0f", ms), privacy: .public) ms — list will show all 'METAR unavailable'")
            return
        }

        nearbyReportingAirports = nearby.compactMap { apt in
            guard let m = metars[apt.icao] else { return nil }
            return NearbyReportingAirport(airport: apt, metar: m)
        }.prefix(5).map { $0 }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        Log.load.info("[nearby] \(icao, privacy: .public) DONE - \(String(format: "%.0f", ms), privacy: .public) ms, \(self.nearbyReportingAirports.count, privacy: .public) of \(icaos.count, privacy: .public) with usable METAR")
    }

    func refresh(icao: String) async {
        await load(icao: icao)
    }

    var flightCategory: FlightCategory {
        metar?.flightCategory ?? .unknown
    }

    var hasData: Bool {
        metar != nil
    }
}

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
        isLoading = true
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []
        advisoryWeather = nil
        isMetarFallback = false
        synopticError = nil

        if !airport.hasMetar {
            // Numeric/short US LIDs (36K→K36K, CMA→KCMA) can still publish a real METAR;
            // try the K-prefixed ICAO against NOAA before falling back to advisory. Only
            // fall back after this genuinely misses.
            if let kIcao = WeatherService.noaaCandidate(for: airport.icao) {
                await loadMETAR(icao: kIcao, field: airport)
                if metar != nil {
                    isLoading = false
                    return
                }
                Log.load.info("[fallback] \(airport.icao, privacy: .public) → ADVISORY (no hasMetar; \(kIcao, privacy: .public) noWeatherReporting=\(self.noWeatherReporting, privacy: .public) why=\(self.error.map(FetchLog.classify) ?? "noProduct", privacy: .public))")
                error = nil
                noWeatherReporting = false
            }
            await loadAdvisory(airport: airport)
        } else {
            // For 3-char FAA LIDs, use the K-prefixed ICAO for NOAA lookup (CMA → KCMA)
            let icaoForFetch = WeatherService.noaaCandidate(for: airport.icao) ?? airport.icao
            await loadMETAR(icao: icaoForFetch, field: airport)
            if noWeatherReporting || (metar == nil && error != nil) {
                // This is the silent-fallback case: a hasMetar station couldn't return a
                // real METAR (usually a slow/timed-out fetch), so we drop to advisory.
                // Log loudly so we can see when it happens and why.
                Log.load.warning("[load] \(airport.icao, privacy: .public) METAR fallback → ADVISORY (noWeatherReporting=\(self.noWeatherReporting, privacy: .public), metar=\(self.metar != nil, privacy: .public), err=\(self.error != nil ? String(describing: self.error!) : "none", privacy: .public), why=\(self.error.map(FetchLog.classify) ?? "noProduct", privacy: .public))")
                isMetarFallback = true
                error = nil
                await loadAdvisory(airport: airport)
            } else {
                Log.load.info("[load] \(airport.icao, privacy: .public) METAR OK (\(self.metarHistory.count, privacy: .public) obs)")
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
            await loadMETAR(icao: icao)
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
    private func loadMETAR(icao: String, field: Airport? = nil) async {
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []

        do {
            async let historyResult = weatherService.fetchMetarHistory(for: icao, hours: 6)
            async let tafResult = weatherService.tafResult(for: icao)

            let fetchedHistory = try await historyResult
            let ownTafResult = await tafResult

            if fetchedHistory.isEmpty {
                // For 3-char FAA LIDs (CMA, 36K, 1G4, …), try the K-prefixed ICAO (KCMA, K36K)
                if let kIcao = WeatherService.noaaCandidate(for: icao) {
                    if let retryHistory = try? await weatherService.fetchMetarHistory(for: kIcao, hours: 6),
                       !retryHistory.isEmpty {
                        metarHistory = retryHistory
                        metar = retryHistory.first
                        let (retryTaf, retryStatus) = await resolveTaf(await weatherService.tafResult(for: kIcao),
                                                                       fetchIcao: kIcao, field: field)
                        await applyTaf(retryTaf, status: retryStatus, history: retryHistory)
                        lastUpdated = Date()
                        if let currentMetar = metar {
                            let snapshot = WidgetWeatherSnapshot.from(
                                airport: AirportService.shared.airport(icao: icao) ?? Airport(
                                    icao: icao, iata: nil, name: icao,
                                    latitude: 0, longitude: 0, elevation: nil
                                ),
                                metar: currentMetar,
                                trend: snapshotTrend,
                                tafVerification: snapshotVerification
                            )
                            WidgetVerdictSync.publishRunways(for: [snapshot.icao])
                            WidgetDataManager.save(snapshot: withBorrowedTaf(snapshot))
                        }
                        return
                    }
                }
                noWeatherReporting = true
                metar = nil
                metarHistory = []
                taf = nil
                tafStatus = .own
                tafStationHistory = []
                trend = nil
                tafVerification = nil
                await loadNearbyReporting(icao: icao)
            } else {
                metarHistory = fetchedHistory
                metar = fetchedHistory.first
                let (resolvedTaf, status) = await resolveTaf(ownTafResult, fetchIcao: icao, field: field)
                await applyTaf(resolvedTaf, status: status, history: fetchedHistory)
            }

            lastUpdated = Date()

            // Write widget snapshot for this airport
            if let currentMetar = metar {
                let snapshot = WidgetWeatherSnapshot.from(
                    airport: AirportService.shared.airport(icao: icao) ?? Airport(
                        icao: icao, iata: nil, name: icao,
                        latitude: 0, longitude: 0, elevation: nil
                    ),
                    metar: currentMetar,
                    trend: snapshotTrend,
                    tafVerification: snapshotVerification
                )
                WidgetVerdictSync.publishRunways(for: [snapshot.icao])   // before save: its reload carries them
                WidgetDataManager.save(snapshot: withBorrowedTaf(snapshot))
            }
        } catch is CancellationError {
            // User navigated away mid-load. Not a failure — don't set error (which would
            // otherwise trip the METAR→advisory fallback for a load we abandoned anyway).
            Log.load.info("[load] \(icao, privacy: .public) METAR load cancelled (navigated away)")
        } catch let err as URLError where err.code == .cancelled {
            Log.load.info("[load] \(icao, privacy: .public) METAR load cancelled (navigated away)")
        } catch {
            Log.load.error("[load] \(icao, privacy: .public) METAR load failed: \(FetchLog.classify(error), privacy: .public)")
            self.error = error
        }
    }

    // MARK: - TAF: own, or the nearest current TAF within 50 nm (D#13–17)
    /// The field's own TAF when it has a current one; otherwise (204 / empty / expired) the nearest
    /// current TAF within 50 nm. A failed request never borrows. The nearby lookup is cached ~10 min
    /// per field; the field's own TAF is requested on every refresh, so one that appears wins at once.
    private func resolveTaf(_ ownResult: Result<Taf, Error>, fetchIcao: String, field: Airport?) async -> (Taf?, TafStatus) {
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
    private func loadAdvisory(airport: Airport) async {
        do {
            advisoryWeather = try await OpenMeteoService.shared.fetchAdvisory(for: airport)
            lastUpdated = Date()

            // Write advisory widget snapshot
            if let advisory = advisoryWeather {
                let snapshot = WidgetWeatherSnapshot.fromAdvisory(
                    airport: airport,
                    advisory: advisory
                )
                WidgetDataManager.save(snapshot: snapshot)
            }
        } catch {
            self.error = error
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

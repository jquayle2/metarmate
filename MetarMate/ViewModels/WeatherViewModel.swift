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
                await loadMETAR(icao: kIcao)
                if metar != nil {
                    isLoading = false
                    return
                }
                error = nil
                noWeatherReporting = false
            }
            await loadAdvisory(airport: airport)
        } else {
            // For 3-char FAA LIDs, use the K-prefixed ICAO for NOAA lookup (CMA → KCMA)
            let icaoForFetch = WeatherService.noaaCandidate(for: airport.icao) ?? airport.icao
            await loadMETAR(icao: icaoForFetch)
            if noWeatherReporting || (metar == nil && error != nil) {
                // This is the silent-fallback case: a hasMetar station couldn't return a
                // real METAR (usually a slow/timed-out fetch), so we drop to advisory.
                // Log loudly so we can see when it happens and why.
                Log.load.warning("[load] \(airport.icao, privacy: .public) METAR fallback → ADVISORY (noWeatherReporting=\(self.noWeatherReporting, privacy: .public), metar=\(self.metar != nil, privacy: .public), err=\(self.error != nil ? String(describing: self.error!) : "none", privacy: .public))")
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

    // MARK: - METAR path (aviationweather.gov)
    private func loadMETAR(icao: String) async {
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []

        do {
            async let historyResult = weatherService.fetchMetarHistory(for: icao, hours: 6)
            async let tafResult = try? weatherService.fetchTaf(for: icao)

            let fetchedHistory = try await historyResult
            let fetchedTaf = await tafResult

            if fetchedHistory.isEmpty {
                // For 3-char FAA LIDs (CMA, 36K, 1G4, …), try the K-prefixed ICAO (KCMA, K36K)
                if let kIcao = WeatherService.noaaCandidate(for: icao) {
                    if let retryHistory = try? await weatherService.fetchMetarHistory(for: kIcao, hours: 6),
                       !retryHistory.isEmpty {
                        metarHistory = retryHistory
                        metar = retryHistory.first
                        let retryTaf = try? await weatherService.fetchTaf(for: kIcao)
                        taf = retryTaf
                        trend = WeatherTrend.derive(metars: retryHistory, taf: retryTaf)
                        if let retryTaf {
                            tafVerification = TafVerification.derive(metars: retryHistory, taf: retryTaf)
                        } else {
                            tafVerification = nil
                        }
                        lastUpdated = Date()
                        if let currentMetar = metar {
                            let snapshot = WidgetWeatherSnapshot.from(
                                airport: AirportService.shared.airport(icao: icao) ?? Airport(
                                    icao: icao, iata: nil, name: icao,
                                    latitude: 0, longitude: 0, elevation: 0
                                ),
                                metar: currentMetar,
                                trend: trend,
                                tafVerification: tafVerification
                            )
                            WidgetDataManager.save(snapshot: snapshot)
                        }
                        return
                    }
                }
                noWeatherReporting = true
                metar = nil
                metarHistory = []
                taf = nil
                trend = nil
                tafVerification = nil
                await loadNearbyReporting(icao: icao)
            } else {
                metarHistory = fetchedHistory
                metar = fetchedHistory.first
                taf = fetchedTaf

                trend = WeatherTrend.derive(metars: fetchedHistory, taf: fetchedTaf)
                if let fetchedTaf {
                    tafVerification = TafVerification.derive(metars: fetchedHistory, taf: fetchedTaf)
                } else {
                    tafVerification = nil
                }
            }

            lastUpdated = Date()

            // Write widget snapshot for this airport
            if let currentMetar = metar {
                let snapshot = WidgetWeatherSnapshot.from(
                    airport: AirportService.shared.airport(icao: icao) ?? Airport(
                        icao: icao, iata: nil, name: icao,
                        latitude: 0, longitude: 0, elevation: 0
                    ),
                    metar: currentMetar,
                    trend: trend,
                    tafVerification: tafVerification
                )
                WidgetDataManager.save(snapshot: snapshot)
            }
        } catch is CancellationError {
            // User navigated away mid-load. Not a failure — don't set error (which would
            // otherwise trip the METAR→advisory fallback for a load we abandoned anyway).
            Log.load.info("[load] \(icao, privacy: .public) METAR load cancelled (navigated away)")
        } catch let err as URLError where err.code == .cancelled {
            Log.load.info("[load] \(icao, privacy: .public) METAR load cancelled (navigated away)")
        } catch {
            self.error = error
        }
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
    func fetchASOS(icao: String) async {
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

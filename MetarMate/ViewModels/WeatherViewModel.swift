import Foundation
import Combine
import SwiftUI
import CoreLocation

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
    @Published var synopticLatest: SynopticObservation?  // Most recent 5-min ASOS observation
    @Published var synopticHistory: [SynopticObservation] = []  // 6-hour ASOS time series
    @Published var isSynopticLoading = false
    @Published var synopticError: String?

    private let weatherService = WeatherService.shared
    private let synopticService = SynopticService.shared

    // MARK: - ASOS Boost rate limiting
    private static let boostLimitPerDay = 25
    private static let boostCountKey = "synoptic_boost_count"
    private static let boostDateKey = "synoptic_boost_date"

    var boostRemaining: Int {
        resetBoostIfNewDay()
        return max(0, Self.boostLimitPerDay - UserDefaults.standard.integer(forKey: Self.boostCountKey))
    }

    var hasBoostData: Bool { synopticLatest != nil }

    private func resetBoostIfNewDay() {
        let lastDate = UserDefaults.standard.string(forKey: Self.boostDateKey) ?? ""
        let today = Self.todayString()
        if lastDate != today {
            UserDefaults.standard.set(0, forKey: Self.boostCountKey)
            UserDefaults.standard.set(today, forKey: Self.boostDateKey)
        }
    }

    private func recordBoostUse() {
        resetBoostIfNewDay()
        let current = UserDefaults.standard.integer(forKey: Self.boostCountKey)
        UserDefaults.standard.set(current + 1, forKey: Self.boostCountKey)
    }

    nonisolated private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    // MARK: - Load with full Airport (preferred — enables hasMetar routing)
    func load(airport: Airport) async {
        isLoading = true
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []
        advisoryWeather = nil
        isMetarFallback = false
        synopticLatest = nil
        synopticHistory = []
        synopticError = nil

        if !airport.hasMetar {
            // Before falling back to advisory, try K-prefix for 3-letter FAA codes (CMA → KCMA)
            let upper = airport.icao.uppercased()
            if upper.count == 3, upper.allSatisfy({ $0.isLetter }), !upper.hasPrefix("K") {
                let kIcao = "K\(upper)"
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
            // For 3-letter FAA codes, use K-prefix for NOAA lookup (CMA → KCMA)
            let icaoForFetch: String
            let upper = airport.icao.uppercased()
            if upper.count == 3, upper.allSatisfy({ $0.isLetter }), !upper.hasPrefix("K") {
                icaoForFetch = "K\(upper)"
            } else {
                icaoForFetch = airport.icao
            }
            await loadMETAR(icao: icaoForFetch)
            if noWeatherReporting || (metar == nil && error != nil) {
                isMetarFallback = true
                error = nil
                await loadAdvisory(airport: airport)
            }
        }
        isLoading = false
    }

    // MARK: - Load by ICAO string (legacy path — still works for live-resolved stations)
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
                // For 3-letter FAA codes (CMA, SNA, etc.), try K-prefix (KCMA, KSNA)
                let upper = icao.uppercased()
                if upper.count == 3, upper.allSatisfy({ $0.isLetter }), !upper.hasPrefix("K") {
                    let kIcao = "K\(upper)"
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

    // MARK: - ASOS Boost (on-demand Synoptic 5-minute data)
    func activateASOSBoost(icao: String) async {
        guard boostRemaining > 0 else {
            synopticError = "Daily ASOS Boost limit reached. Resets at midnight."
            return
        }

        isSynopticLoading = true
        synopticError = nil

        do {
            let series = try await synopticService.fetchTimeSeries(for: icao, recentMinutes: 360)
            synopticHistory = series
            synopticLatest = series.last  // most recent observation
            recordBoostUse()
        } catch {
            synopticError = "ASOS data unavailable for this airport."
            synopticLatest = nil
            synopticHistory = []
        }

        isSynopticLoading = false
    }

    private func loadNearbyReporting(icao: String) async {
        guard let airport = AirportService.shared.airport(icao: icao) else { return }

        let location = CLLocation(latitude: airport.latitude, longitude: airport.longitude)
        let nearby = AirportService.shared.nearest(
            to: location, count: 10
        ).filter { $0.icao != icao && $0.hasMetar }

        let icaos = nearby.map { $0.icao }
        guard let metars = try? await weatherService.fetchMetars(for: icaos) else { return }

        nearbyReportingAirports = nearby.compactMap { apt in
            guard let m = metars[apt.icao] else { return nil }
            return NearbyReportingAirport(airport: apt, metar: m)
        }.prefix(5).map { $0 }
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

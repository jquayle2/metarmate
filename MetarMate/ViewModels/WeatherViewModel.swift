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

    private let weatherService = WeatherService.shared

    // MARK: - Load with full Airport (preferred — enables hasMetar routing)
    func load(airport: Airport) async {
        isLoading = true
        error = nil
        noWeatherReporting = false
        nearbyReportingAirports = []
        advisoryWeather = nil

        if !airport.hasMetar {
            await loadAdvisory(airport: airport)
        } else {
            await loadMETAR(icao: airport.icao)
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
                noWeatherReporting = true
                await loadNearbyReporting(icao: icao)
            } else {
                metarHistory = fetchedHistory
                metar = fetchedHistory.first
                taf = fetchedTaf

                if !fetchedHistory.isEmpty {
                    trend = WeatherTrend.derive(metars: fetchedHistory, taf: fetchedTaf)
                    if let taf = fetchedTaf {
                        tafVerification = TafVerification.derive(metars: fetchedHistory, taf: taf)
                    }
                }
            }

            lastUpdated = Date()
        } catch {
            self.error = error
        }
    }

    // MARK: - Advisory weather path (Open-Meteo, for non-METAR airports)
    private func loadAdvisory(airport: Airport) async {
        do {
            advisoryWeather = try await OpenMeteoService.shared.fetchAdvisory(for: airport)
            lastUpdated = Date()
        } catch {
            self.error = error
        }
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

import Foundation
import SwiftUI

// MARK: - Weather View Model
@MainActor
class WeatherViewModel: ObservableObject {
    @Published var metar: Metar?
    @Published var taf: Taf?
    @Published var trend: WeatherTrend?
    @Published var isLoading = false
    @Published var error: Error?
    @Published var lastUpdated: Date?

    private let weatherService = WeatherService.shared

    func load(icao: String) async {
        isLoading = true
        error = nil
        do {
            async let metarResult = weatherService.fetchMetar(for: icao)
            async let tafResult = try? weatherService.fetchTaf(for: icao)

            let fetchedMetar = try await metarResult
            let fetchedTaf = await tafResult

            metar = fetchedMetar
            taf = fetchedTaf
            trend = WeatherTrend.derive(metar: fetchedMetar, taf: fetchedTaf)
            lastUpdated = Date()
        } catch {
            self.error = error
        }
        isLoading = false
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

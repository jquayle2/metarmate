import Foundation
import Combine
import SwiftUI

// MARK: - Weather View Model
@MainActor
class WeatherViewModel: ObservableObject {
    @Published var metar: Metar?
    @Published var metarHistory: [Metar] = []
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
            async let historyResult = weatherService.fetchMetarHistory(for: icao, hours: 6)
            async let tafResult = try? weatherService.fetchTaf(for: icao)

            let fetchedHistory = try await historyResult
            let fetchedTaf = await tafResult

            metarHistory = fetchedHistory
            metar = fetchedHistory.first
            taf = fetchedTaf

            if !fetchedHistory.isEmpty {
                trend = WeatherTrend.derive(metars: fetchedHistory, taf: fetchedTaf)
            }

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

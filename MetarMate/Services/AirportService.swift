import Foundation
import CoreLocation

// MARK: - Airport Service
// Loads and searches the bundled airports.json database
class AirportService {
    static let shared = AirportService()

    private(set) var airports: [Airport] = []
    private var icaoIndex: [String: Airport] = [:]
    private var iataIndex: [String: Airport] = [:]

    private init() {
        loadAirports()
    }

    // MARK: - Loading
    private func loadAirports() {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("AirportService: airports.json not found in bundle")
            return
        }
        do {
            airports = try JSONDecoder().decode([Airport].self, from: data)
            for airport in airports {
                icaoIndex[airport.icao.uppercased()] = airport
                if let iata = airport.iata { iataIndex[iata.uppercased()] = airport }
            }
            print("AirportService: loaded \(airports.count) airports")
        } catch {
            print("AirportService: failed to decode airports.json — \(error)")
        }
    }

    // MARK: - Lookup
    func airport(icao: String) -> Airport? {
        icaoIndex[icao.uppercased()]
    }

    func airport(iata: String) -> Airport? {
        iataIndex[iata.uppercased()]
    }

    func airport(identifier: String) -> Airport? {
        airport(icao: identifier) ?? airport(iata: identifier)
    }

    // MARK: - Search
    func search(query: String, limit: Int = 20) -> [Airport] {
        guard !query.isEmpty else { return [] }
        let q = query.uppercased()
        return airports.filter {
            $0.icao.contains(q) ||
            ($0.iata?.contains(q) ?? false) ||
            $0.name.uppercased().contains(q)
        }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Nearby
    func nearest(to location: CLLocation, count: Int = 10, maxRadiusNm: Double = 100) -> [Airport] {
        let maxMeters = maxRadiusNm * 1852.0
        return airports
            .compactMap { airport -> (Airport, CLLocationDistance)? in
                let dist = airport.distance(from: location)
                guard dist <= maxMeters else { return nil }
                return (airport, dist)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(count)
            .map { $0.0 }
    }
}

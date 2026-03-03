import Foundation
import Combine
import CoreLocation

// MARK: - Airport Service
// Loads and searches the bundled airports.json database, with live NOAA fallback
// for FAA local identifiers (T78, 5T6, etc.) not in the bundled DB.
@MainActor
class AirportService {
    static let shared = AirportService()

    private(set) var airports: [Airport] = []
    private var icaoIndex: [String: Airport] = [:]
    private var iataIndex: [String: Airport] = [:]
    // Cache for live-resolved stations so we don't re-query repeatedly
    private var liveResolvedCache: [String: Airport] = [:]

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
        let key = icao.uppercased()
        return icaoIndex[key] ?? liveResolvedCache[key]
    }

    func airport(iata: String) -> Airport? {
        iataIndex[iata.uppercased()]
    }

    func airport(identifier: String) -> Airport? {
        let key = identifier.uppercased()
        return icaoIndex[key] ?? iataIndex[key] ?? liveResolvedCache[key]
    }

    // Cache a live-resolved airport (called after a successful NOAA lookup)
    func cacheLiveAirport(_ airport: Airport) {
        liveResolvedCache[airport.icao.uppercased()] = airport
    }

    // MARK: - Search
    func search(query: String, limit: Int = 20) -> [Airport] {
        guard !query.isEmpty else { return [] }
        let q = query.uppercased()
        let localResults = airports.filter {
            $0.icao.contains(q) ||
            ($0.iata?.contains(q) ?? false) ||
            $0.name.uppercased().contains(q)
        }
        .prefix(limit)
        .map { $0 }

        // Also include any cached live-resolved airports matching the query
        let cached = liveResolvedCache.values.filter {
            $0.icao.contains(q) || $0.name.uppercased().contains(q)
        }

        let combined = Array(localResults) + cached
        return Array(combined.prefix(limit))
    }

    // MARK: - Live Station Lookup
    // Tries to resolve an unknown station ID via a NOAA METAR fetch.
    // Returns an Airport built from the METAR response metadata, or nil if not found.
    func resolveUnknownStation(_ identifier: String) async -> Airport? {
        let id = identifier.uppercased()
        // Check cache first
        if let cached = liveResolvedCache[id] { return cached }
        // Only attempt for plausible station IDs (2–5 alphanumeric chars)
        guard (2...5).contains(id.count),
              id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }

        let urlString = "https://aviationweather.gov/api/data/metar?ids=\(id)&format=json&hours=2"
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let raws = try? JSONDecoder().decode([RawMetar].self, from: data),
              let raw = raws.first,
              let stationId = raw.icaoId ?? (raws.first != nil ? id : nil) else { return nil }

        let airport = Airport(
            icao: stationId,
            iata: nil,
            name: raw.name ?? stationId,
            latitude: raw.lat ?? 0,
            longitude: raw.lon ?? 0,
            elevation: raw.elev ?? 0
        )
        cacheLiveAirport(airport)
        return airport
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

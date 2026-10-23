import Foundation
import os
import SwiftData

// MARK: - FavoriteElevationRefetch (A2 hand-off)
// Favorites of airports not in airports.json were starred from NOAA METAR metadata, whose `elev` is
// meters, and saved it as feet (fixed at the source in 9025643). The #27 reconcile can't correct them:
// they have no airports.json row. Once per install, re-read each one's elevation from NOAA station info
// and store feet. A station NOAA lists without an elevation, or doesn't list, gets 0, which the verdict
// reads as "not reported" for a non-bundled airport.
enum FavoriteElevationRefetch {
    static let doneKey = "favorites.elevationRefetchDone"

    /// Runs once per install. `fetch` returns the stationinfo JSON for the ICAOs, or nil on a network
    /// failure; nothing is marked done then, so the next launch tries again. Returns favorites changed.
    @discardableResult
    static func runIfNeeded(in context: ModelContext,
                            defaults: UserDefaults = .standard,
                            isBundled: ((String) -> Bool)? = nil,
                            fetch: (([String]) async -> Data?)? = nil) async -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        let isBundled = isBundled ?? { AirportService.shared.bundledAirport(icao: $0) != nil }
        let fetch = fetch ?? fetchStationInfo
        let favorites = ((try? context.fetch(FetchDescriptor<AirportFavorite>())) ?? [])
            .filter { !isBundled($0.icao) }
        guard !favorites.isEmpty else { defaults.set(true, forKey: doneKey); return 0 }

        guard let data = await fetch(favorites.map(\.icao)),
              let feet = elevationsFeet(fromStationInfo: data) else {
            Log.load.info("[favorites] elevation refetch failed; retry next launch")
            return 0
        }
        var changed = 0
        for favorite in favorites {
            let elevation = feet[favorite.icao.uppercased()] ?? 0
            if favorite.elevation != elevation { favorite.elevation = elevation; changed += 1 }
        }
        if changed > 0 { try? context.save() }
        defaults.set(true, forKey: doneKey)
        Log.load.info("[favorites] elevation refetch changed \(changed) of \(favorites.count)")
        return changed
    }

    /// ICAO → elevation in feet, from a stationinfo response (`elev` is meters). A station listed
    /// without `elev` maps to 0. nil when the data isn't a stationinfo array.
    nonisolated static func elevationsFeet(fromStationInfo data: Data) -> [String: Int]? {
        struct Station: Decodable { let id: String?; let icaoId: String?; let elev: Double? }
        guard let stations = try? JSONDecoder().decode([Station].self, from: data) else { return nil }
        var result: [String: Int] = [:]
        for station in stations {
            guard let icao = (station.icaoId ?? station.id)?.uppercased() else { continue }
            result[icao] = station.elev.map { NearbyTaf.feet(fromMeters: Int($0.rounded())) } ?? 0
        }
        return result
    }

    private static func fetchStationInfo(_ icaos: [String]) async -> Data? {
        let ids = icaos.joined(separator: ",")
        guard let url = URL(string: "https://aviationweather.gov/api/data/stationinfo?ids=\(ids)&format=json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return Data("[]".utf8) }   // none listed: every elevation → 0
        return http.statusCode == 200 ? data : nil
    }
}

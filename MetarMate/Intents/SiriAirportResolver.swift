import Foundation
import CoreLocation

// MARK: - Siri airport resolver
// Picks airports for FlyingWeatherIntent without a tap. Pure over its inputs (location and
// favorites are passed in) so the ranking is testable without Siri or CoreLocation.
// Oct 22 device test: suggestions were cached private strips in storage order, and "Kingman"
// offered KIGM and 9K8 (Kingman, KS, no METAR), so Siri asked "Which one?".
enum SiriAirportResolver {

    /// Nearest airport that actually reports a METAR, not just the nearest strip.
    static func nearestMetarStation(to location: CLLocation) -> Airport? {
        AirportService.shared.nearest(to: location, count: 25).first(where: { $0.hasMetar })
    }

    // MARK: - Suggestions

    /// Favorites in the user's order, then the nearest METAR stations by distance. METAR
    /// stations only.
    static func suggestions(favorites: [String], location: CLLocation?, limit: Int = 8) -> [Airport] {
        var result = favorites
            .compactMap { AirportService.shared.airport(identifier: $0) }
            .filter { $0.hasMetar }
        if let location {
            let seen = Set(result.map(\.icao))
            result += AirportService.shared.nearest(to: location, count: 40)
                .filter { $0.hasMetar && !seen.contains($0.icao) }
        }
        return Array(result.prefix(limit))
    }

    // MARK: - Spoken name or ident

    /// An exact ident returns just that airport. Otherwise METAR stations whose name, city or
    /// ident matches, ranked favorites → distance → search relevance. When location is known and
    /// a match is within 50 nm, matches beyond 150 nm are dropped ("Las Vegas" near KVGT loses
    /// KLVS, Las Vegas NM). One result means Siri doesn't ask "Which one?"; several still do.
    static func matches(_ spoken: String, favorites: [String], location: CLLocation?, limit: Int = 10) -> [Airport] {
        let code = spoken.components(separatedBy: .whitespaces).joined().uppercased()
        if (2...5).contains(code.count), code.allSatisfy({ $0.isLetter || $0.isNumber }),
           let exact = airport(forIdent: code) {
            return [exact]
        }

        // search() caps before we filter, so ask for enough that strips can't crowd out stations.
        var found = AirportService.shared.search(query: spoken, limit: 100).filter { $0.hasMetar }
        if let location, found.contains(where: { $0.distance(from: location) <= 50 * 1852 }) {
            found.removeAll { $0.distance(from: location) > 150 * 1852 }
        }
        let favoriteRank = Dictionary(favorites.enumerated().map { ($1.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let ranked = found.enumerated().sorted { a, b in
            let fa = favoriteRank[a.element.icao.uppercased()] ?? .max
            let fb = favoriteRank[b.element.icao.uppercased()] ?? .max
            if fa != fb { return fa < fb }
            if let location {
                let da = a.element.distance(from: location), db = b.element.distance(from: location)
                if da != db { return da < db }
            }
            return a.offset < b.offset   // search relevance order
        }
        return Array(ranked.map(\.element).prefix(limit))
    }

    // MARK: - Identifier lookup

    /// Exact ident as heard (with the O/0 swap), then the K-prefixed form of a 3-char LID
    /// ("CMA" is KCMA in the database).
    static func airport(forIdent code: String) -> Airport? {
        if let found = airportForSpokenCode(code) { return found }
        guard let k = WeatherService.noaaCandidate(for: code) else { return nil }
        return AirportService.shared.airport(identifier: k)
    }

    // Speech recognition hears "oh" and "zero" interchangeably. Try the code exactly as heard
    // first, so O-prefixed idents (O22, OK36) resolve, and only then with the leading O/0 swapped
    // (0L7 heard as "OL7"). A blanket O→0 rewrite broke every O-prefixed identifier.
    static func airportForSpokenCode(_ code: String) -> Airport? {
        var heard = [code]
        if code.hasPrefix("O") { heard.append("0" + code.dropFirst()) }
        if code.hasPrefix("0") { heard.append("O" + code.dropFirst()) }
        let found = heard.compactMap { AirportService.shared.airport(identifier: $0) }
        // Both readings can exist; prefer the one that reports a METAR.
        return found.first(where: { $0.hasMetar }) ?? found.first
    }
}

// MARK: - Favorites for Siri
// Siri must not open the SwiftData store (background launches + App Group WAL lock = 0xdead10cc,
// see MetarMateApp.sharedModelContainer), so ContentView mirrors the ordered favorite idents here.
enum SiriFavorites {
    private static let key = "siriFavoriteIcaos"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ icaos: [String]) {
        UserDefaults.standard.set(icaos, forKey: key)
    }
}

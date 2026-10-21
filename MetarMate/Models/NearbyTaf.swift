import Foundation

// MARK: - Nearby-TAF fallback (D#13–17)
// When the field has no current TAF of its own, the nearest current TAF within 50 nm stands in for
// it, always labeled with where it comes from. This file is the pure part: whether to borrow,
// which station to pick, and the source record every consumer labels the forecast with.

/// Where the forecast on screen comes from. `isBorrowed` is false for the field's own TAF.
struct TafSource: Codable, Equatable {
    let stationId: String
    let name: String?
    let distanceNm: Int              // rounded once; distance tiers and text both use this number
    let bearing: String              // 8-point compass from the field to the TAF station ("W")
    let elevationDifferenceFt: Int?  // TAF station minus field; nil when the station's elevation is unknown
    let isBorrowed: Bool
}

/// A TAF from the `taf?bbox=` lookup, with the station position NOAA returns alongside it.
struct NearbyTafCandidate {
    let taf: Taf
    let latitude: Double
    let longitude: Double
    let elevationMeters: Int?        // NOAA `elev` is meters (KLAS 662 = 2,172 ft)
    let name: String?
}

/// What the forecast card shows for a field.
enum TafStatus: Equatable {
    case own                                       // the field's own current TAF (or nothing to show)
    case borrowed(TafSource, ownExpired: Bool)     // the nearest current TAF within 50 nm stands in
    case noneWithin50nm(ownExpired: Bool)          // looked: no current TAF within 50 nm
    case unavailable                               // the field's TAF request or the nearby lookup failed

    var isBorrowed: Bool { if case .borrowed = self { return true }; return false }
    var isNoneWithin50nm: Bool { if case .noneWithin50nm = self { return true }; return false }
}

/// Nearby-TAF lookups per field, kept ~10 min so the 5-min auto-refresh doesn't repeat the bbox
/// request. Only the lookup is cached: the field's own TAF is requested on every refresh.
nonisolated struct NearbyTafCandidateCache {
    static let ttl: TimeInterval = 600
    private var entries: [String: (candidates: [NearbyTafCandidate], fetchedAt: Date)] = [:]

    func candidates(for field: String, at now: Date) -> [NearbyTafCandidate]? {
        guard let entry = entries[field], now.timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.candidates
    }

    mutating func store(_ candidates: [NearbyTafCandidate], for field: String, at now: Date) {
        entries[field] = (candidates, now)
    }

    mutating func removeAll() { entries.removeAll() }
}

enum NearbyTaf {

    nonisolated static let maxDistanceNm = 50

    // MARK: Whether to borrow

    /// What the field's own TAF request came back with.
    enum OwnTaf {
        case found(Taf)
        case none      // 204, or 200 with an empty list: the field has no TAF
        case failed    // anything else: we don't know, so never borrow
    }

    static func outcome(of result: Result<Taf, Error>) -> OwnTaf {
        switch result {
        case .success(let taf):
            return .found(taf)
        case .failure(let error):
            switch error as? WeatherError {
            case .noContent, .noData: return .none
            default:                  return .failed
            }
        }
    }

    /// Borrow when the field has no TAF, or its TAF isn't current (expired). A TAF starting within
    /// 2 hours counts as current (D#13 rulings, Oct 21) and is never replaced; a failed request
    /// never borrows.
    static func needsBorrow(_ own: OwnTaf, at now: Date) -> Bool {
        switch own {
        case .found(let taf): return taf.currentForecast(at: now) == nil
        case .none:           return true
        case .failed:         return false
        }
    }

    /// The TAF to show and its status. The field's own current TAF always wins (one that appears
    /// replaces a borrowed one on the next refresh); `candidates` (the bbox lookup) runs only when
    /// borrowing is needed and the field's position is known.
    static func resolve(own: OwnTaf,
                        field: (ids: Set<String>, latitude: Double, longitude: Double, elevationFt: Int)?,
                        at now: Date,
                        candidates: () async throws -> [NearbyTafCandidate]) async -> (taf: Taf?, status: TafStatus) {
        if case .found(let taf) = own, taf.currentForecast(at: now) != nil { return (taf, .own) }
        guard needsBorrow(own, at: now), let field else { return (nil, .unavailable) }
        let ownExpired: Bool = { if case .found = own { return true }; return false }()
        do {
            let found = try await candidates()
            guard let pick = select(from: found, fieldLatitude: field.latitude, fieldLongitude: field.longitude,
                                    fieldElevationFt: field.elevationFt, excluding: field.ids, at: now)
            else { return (nil, .noneWithin50nm(ownExpired: ownExpired)) }
            return (pick.taf, .borrowed(pick.source, ownExpired: ownExpired))
        } catch {
            return (nil, .unavailable)
        }
    }

    // MARK: Wording (D#14, D#17)

    /// "No TAF for KBVU · using KHND (13 nm W)" — the forecast card's first line (also widget, Siri).
    static func substitutionLine(fieldId: String, source: TafSource, ownExpired: Bool) -> String {
        substitutionParts(fieldId: fieldId, source: source, ownExpired: ownExpired).map(\.text).joined()
    }

    /// The same line in pieces; the card sets "No TAF for KBVU" and "KHND" in heavy type.
    static func substitutionParts(fieldId: String, source: TafSource, ownExpired: Bool) -> [(text: String, emphasized: Bool)] {
        [("\(ownExpired ? "No current TAF" : "No TAF") for \(fieldId)", true),
         (" · using ", false),
         (source.stationId, true),
         (" (\(source.distanceNm) nm \(source.bearing))", false)]
    }

    /// Distance tier and elevation cautions under the substitution line. Wording only — no color
    /// encodes distance.
    static func cautions(for source: TafSource) -> [String] {
        var lines: [String] = []
        switch source.distanceNm {
        case ...10:  break
        case ...25:  lines.append("TAF site \(source.distanceNm) nm away. Local conditions may differ.")
        default:     lines.append("TAF site \(source.distanceNm) nm away. Conditions here may be quite different.")
        }
        if let diff = source.elevationDifferenceFt, abs(diff) >= 1000 {
            let rounded = Int((Double(abs(diff)) / 100).rounded()) * 100
            lines.append("TAF site is \(rounded.formatted()) ft \(diff > 0 ? "higher" : "lower").")
        }
        return lines
    }

    // MARK: Which station

    /// The nearest station within 50 nm whose TAF is current at `now` (same rule as the field's own:
    /// starting within 2 hours counts), excluding the field itself. nil when there is none.
    static func select(from candidates: [NearbyTafCandidate],
                       fieldLatitude: Double, fieldLongitude: Double, fieldElevationFt: Int,
                       excluding fieldIds: Set<String>, at now: Date) -> (taf: Taf, source: TafSource)? {
        // One TAF per station: the latest issued.
        var latest: [String: NearbyTafCandidate] = [:]
        for c in candidates where !fieldIds.contains(c.taf.stationId.uppercased()) {
            if let existing = latest[c.taf.stationId], existing.taf.issueTime >= c.taf.issueTime { continue }
            latest[c.taf.stationId] = c
        }

        let ranked = latest.values
            .filter { $0.taf.currentForecast(at: now) != nil }
            .map { (candidate: $0, nm: distanceNm(fieldLatitude, fieldLongitude, $0.latitude, $0.longitude)) }
            .filter { Int($0.nm.rounded()) <= maxDistanceNm }
            .sorted { ($0.nm, $0.candidate.taf.stationId) < ($1.nm, $1.candidate.taf.stationId) }
        guard let best = ranked.first else { return nil }

        let c = best.candidate
        let source = TafSource(
            stationId: c.taf.stationId,
            name: c.name,
            distanceNm: Int(best.nm.rounded()),
            bearing: compass8(bearingDegrees(fieldLatitude, fieldLongitude, c.latitude, c.longitude)),
            elevationDifferenceFt: c.elevationMeters.map { feet(fromMeters: $0) - fieldElevationFt },
            isBorrowed: true
        )
        return (c.taf, source)
    }

    // MARK: Geometry

    nonisolated private static let earthRadiusNm = 3440.065

    /// Great-circle distance in nautical miles.
    nonisolated static func distanceNm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(h)))
    }

    /// Initial great-circle bearing from point 1 to point 2, degrees true 0..<360.
    nonisolated static func bearingDegrees(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 8-point compass, 45° sectors centered on each point (N is 337.5..<22.5).
    nonisolated static func compass8(_ degrees: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized + 22.5) / 45) % 8]
    }

    nonisolated static func feet(fromMeters meters: Int) -> Int {
        Int((Double(meters) * 3.28084).rounded())
    }

    /// The `taf?bbox=` box covering `radiusNm` around a point, as NOAA wants it: lat0,lon0,lat1,lon1
    /// (lon,lat returns 204). Longitude span widens by 1/cos(lat).
    nonisolated static func boundingBox(latitude: Double, longitude: Double, radiusNm: Int = maxDistanceNm) -> String {
        let dLat = Double(radiusNm) / 60
        let dLon = dLat / max(cos(latitude * .pi / 180), 0.01)
        let lat0 = max(latitude - dLat, -90), lat1 = min(latitude + dLat, 90)
        let lon0 = max(longitude - dLon, -180), lon1 = min(longitude + dLon, 180)
        return String(format: "%.4f,%.4f,%.4f,%.4f", lat0, lon0, lat1, lon1)
    }
}

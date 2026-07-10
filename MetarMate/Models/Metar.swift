import Foundation

// MARK: - Flight Category
enum FlightCategory: String, Codable, CaseIterable {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"
    case unknown = "UNKN"

    var description: String {
        switch self {
        case .vfr: return "Visual Flight Rules"
        case .mvfr: return "Marginal VFR"
        case .ifr: return "Instrument Flight Rules"
        case .lifr: return "Low IFR"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Wind
struct Wind: Codable {
    var direction: Int?      // degrees true; nil = variable
    var speed: Int           // knots
    var gust: Int?           // knots
    var isVariable: Bool
    // Whether the observation actually reported a wind group. A missing wind (wdir AND wspd both
    // absent) must NOT read as a real 00000KT calm — that turned "unknown" into benign. Callers
    // render "—"/skip and a "wind not reported" pilot note when false. Safe as a defaulted field:
    // Wind is never decoded from persisted JSON, only memberwise-init (see Metar.visibilityReported).
    var isReported: Bool = true

    static let calm = Wind(direction: 0, speed: 0, gust: nil, isVariable: false)
}

// MARK: - Cloud Layer
enum CloudCoverage: String, Codable {
    case few = "FEW"
    case scattered = "SCT"
    case broken = "BKN"
    case overcast = "OVC"
    case clear = "CLR"
    case skyClear = "SKC"
    case verticalVisibility = "VV"
}

struct CloudLayer: Codable {
    var coverage: CloudCoverage
    var altitude: Int        // hundreds of feet AGL
    var isCumulonimbus: Bool
}

// MARK: - Visibility
// Parsed visibility. Replaces a bare Double so "P6SM"/"6+" (greater-than) is distinguishable from
// an exactly-6-SM report, and "unknown" is representable without a fabricated number or a separate
// flag. NOAA emits greater-than only at 6 and 10 (the "6+"/"P6SM"/"10+"/"P10SM" strings — see
// MetarParser/TafParser.parseVisibility); every other input is .exact or .unknown.
enum Visibility: Codable, Equatable {
    case exact(Double)
    case greaterThan(Double)   // true value is strictly greater than the associated SM value
    case unknown

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    var isGreaterThan: Bool {
        if case .greaterThan = self { return true }
        return false
    }

    // Lower bound in statute miles, for category thresholds and "is it below X" checks.
    // For .greaterThan the true value is > n, so n is the conservative (worst-case) floor:
    // reading a threshold off n can only under-state the visibility, never over-state it.
    // .unknown has no bound. Do NOT use this for orderings/deltas between two known values — a
    // .greaterThan can't be ordered against another value off its floor without fabricating one.
    var lowerBoundSM: Double? {
        switch self {
        case .exact(let v), .greaterThan(let v): return v
        case .unknown: return nil
        }
    }

    // The exact reported value, ONLY when it is exact. nil for .greaterThan (a range) and .unknown.
    // Use this for deltas/orderings so a greater-than never fabricates a comparable number.
    var exactSM: Double? {
        if case .exact(let v) = self { return v }
        return nil
    }

    // Shared numeric display core so every parsed-visibility formatter agrees on the ONE rule:
    // .exact(6) -> "6" (never "6+"), .greaterThan(6) -> "6+", .unknown -> nil (caller renders "—").
    // %g drops trailing zeros (6.0 -> "6", 1.5 -> "1.5"). Callers add their own "SM"/spacing.
    var displayNumber: String? {
        switch self {
        case .exact(let v):       return String(format: "%g", v)
        case .greaterThan(let v): return String(format: "%g", v) + "+"
        case .unknown:            return nil
        }
    }
}

// MARK: - METAR
struct Metar: Identifiable, Codable {
    var id: String { stationId + observationTime.ISO8601Format() }
    var rawText: String
    var stationId: String
    var observationTime: Date
    var wind: Wind
    var visibility: Visibility   // .exact / .greaterThan (P6SM/P10SM) / .unknown — see Visibility
    var clouds: [CloudLayer]
    var temperature: Int     // Celsius
    var dewpoint: Int        // Celsius
    var altimeter: Double    // inHg
    var flightCategory: FlightCategory
    var weatherPhenomena: [String]
    var remarks: String?

    nonisolated var ceilingFeet: Int? {
        clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
               .map { $0.altitude * 100 }
    }

    /// Coverage code (BKN/OVC/VV) of the ceiling layer — the same layer that produces ceilingFeet.
    nonisolated var ceilingCoverage: String? {
        clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })?
              .coverage.rawValue
    }

    var isOld: Bool {
        Date().timeIntervalSince(observationTime) > 3600
    }
}

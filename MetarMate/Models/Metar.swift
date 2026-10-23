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

// MARK: - Category thresholds (one definition, audit #18)
// FAA/NWS: LIFR ceiling < 500 ft or vis < 1 SM; IFR ceiling < 1,000 or vis < 3; MVFR ceiling
// 1,000-3,000 INCLUSIVE or vis 3-5 INCLUSIVE; VFR above both. Every place that derives a category
// from a ceiling or visibility uses these — 3,000 ft and 5 SM are MVFR, not VFR.
extension FlightCategory {
    nonisolated static func forCeiling(_ feet: Int) -> FlightCategory {
        feet < 500 ? .lifr : feet < 1000 ? .ifr : feet <= 3000 ? .mvfr : .vfr
    }

    nonisolated static func forVisibility(_ sm: Double) -> FlightCategory {
        sm < 1 ? .lifr : sm < 3 ? .ifr : sm <= 5 ? .mvfr : .vfr
    }

    /// Worst of the known axes. With one axis unknown, a known MVFR/IFR/LIFR is a real lower bound
    /// and stands; a known VFR axis can't vouch for the other, so the category is unknown.
    nonisolated static func from(ceiling: CeilingStatus, visibilitySM: Double?) -> FlightCategory {
        var axes: [FlightCategory] = []
        switch ceiling {
        case .feet(let f):  axes.append(forCeiling(f))
        case .none:         axes.append(.vfr)
        case .notReported:  break
        }
        if let visibilitySM { axes.append(forVisibility(visibilitySM)) }
        let order: [FlightCategory] = [.vfr, .mvfr, .ifr, .lifr]
        guard let worst = axes.max(by: { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }) else {
            return .unknown
        }
        if axes.count == 1 && worst == .vfr { return .unknown }
        return worst
    }
}

// MARK: - Wind
struct Wind: Codable {
    var direction: Int?      // degrees true; nil = variable (isVariable) or not reported (audit #10)
    var speed: Int           // knots
    var gust: Int?           // knots
    var isVariable: Bool
    // Whether the observation actually reported a wind group. A missing wind (wdir AND wspd both
    // absent) must NOT read as a real 00000KT calm — that turned "unknown" into benign. Callers
    // render "—"/skip and a "wind not reported" pilot note when false. Safe as a defaulted field:
    // Wind is never decoded from persisted JSON, only memberwise-init (see Metar.visibilityReported).
    var isReported: Bool = true

    static let calm = Wind(direction: 0, speed: 0, gust: nil, isVariable: false)

    /// METAR-style direction: "VRB", "270", or "///" when the direction wasn't reported
    /// (`///25KT`). Never "000": a missing direction is not north.
    nonisolated var directionCode: String {
        if isVariable { return "VRB" }
        return direction.map { String(format: "%03d", $0) } ?? "///"
    }
}

// MARK: - Cloud Layer
enum CloudCoverage: String, Codable {
    case few = "FEW"
    case scattered = "SCT"
    case broken = "BKN"
    case overcast = "OVC"
    case clear = "CLR"
    case skyClear = "SKC"
    case noSignificantCloud = "NSC"   // also how NOAA decodes CAVOK
    case verticalVisibility = "VV"
}

struct CloudLayer: Codable {
    var coverage: CloudCoverage
    var altitude: Int?       // hundreds of feet AGL; nil = base not reported (BKN///), never 0 ft (audit #12)
    var isCumulonimbus: Bool

    /// BKN, OVC or VV: a layer that can be a ceiling.
    nonisolated var isCeilingLayer: Bool {
        coverage == .broken || coverage == .overcast || coverage == .verticalVisibility
    }

    nonisolated var baseFeet: Int? { altitude.map { $0 * 100 } }
}

// MARK: - Ceiling
/// The ceiling as reported: a height, no ceiling (clear sky or only FEW/SCT), or not reported.
/// "Not reported" is never "no ceiling" (audit #6) and never 0 ft (audit #12).
enum CeilingStatus: Equatable {
    case feet(Int)
    case none
    case notReported

    nonisolated var feet: Int? {
        if case .feet(let f) = self { return f }
        return nil
    }
}

extension Array where Element == CloudLayer {
    /// The ceiling layer: the LOWEST BKN/OVC/VV layer with a known base (by height, never list
    /// position — P3 ".first vs .min()").
    nonisolated var ceilingLayer: CloudLayer? {
        filter { $0.isCeilingLayer && $0.altitude != nil }.min { $0.altitude! < $1.altitude! }
    }

    /// One ceiling rule for METAR and TAF. `skyReported`: the report has a sky condition at all.
    /// A BKN/OVC/VV layer with no base leaves the ceiling unknown unless a known ceiling layer is
    /// listed before it (layers are reported in ascending order, so it's above that one).
    nonisolated func ceilingStatus(skyReported: Bool) -> CeilingStatus {
        guard skyReported else { return .notReported }
        guard let lowest = ceilingLayer, let lowestFt = lowest.baseFeet else {
            return contains(where: \.isCeilingLayer) ? .notReported : .none
        }
        let lowestIndex = firstIndex { $0.isCeilingLayer && $0.altitude == lowest.altitude }!
        let unknownBaseBelow = self[..<lowestIndex].contains { $0.isCeilingLayer && $0.altitude == nil }
        return unknownBaseBelow ? .notReported : .feet(lowestFt)
    }
}

// MARK: - Visibility
// Parsed visibility. Replaces a bare Double so "P6SM"/"6+" (greater-than) is distinguishable from
// an exactly-6-SM report, and "unknown" is representable without a fabricated number or a separate
// flag. NOAA emits greater-than only at 6 and 10 (the "6+"/"P6SM"/"10+"/"P10SM" strings — see
// MetarParser/TafParser.parseVisibility); every other input is .exact or .unknown.
enum Visibility: Codable, Equatable {
    case exact(Double)
    case greaterThan(Double)   // true value is strictly greater than the associated SM value
    case lessThan(Double)      // true value is strictly less (METAR "M1/4SM"; P3: was .exact(0.25))
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
    // .lessThan(n) reads off n too: the only less-than a METAR carries is M1/4SM, which is LIFR
    // under every category boundary and below any realistic visibility minimum either way.
    // .unknown has no bound. Do NOT use this for orderings/deltas between two known values — a
    // .greaterThan can't be ordered against another value off its floor without fabricating one.
    var lowerBoundSM: Double? {
        switch self {
        case .exact(let v), .greaterThan(let v), .lessThan(let v): return v
        case .unknown: return nil
        }
    }

    var isLessThan: Bool {
        if case .lessThan = self { return true }
        return false
    }

    /// 0.25 -> "1/4", 1.5 -> "1 1/2", 6 -> "6": how a METAR writes statute miles.
    static func milesText(_ v: Double) -> String {
        let whole = Int(v)
        let frac = v - Double(whole)
        let fracText = [0.125: "1/8", 0.25: "1/4", 0.375: "3/8", 0.5: "1/2", 0.625: "5/8", 0.75: "3/4"]
            .first { abs($0.key - frac) < 0.001 }?.value
        guard let fracText else { return String(format: "%g", v) }
        return whole == 0 ? fracText : "\(whole) \(fracText)"
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
        case .lessThan(let v):    return "<" + Self.milesText(v)   // "<1/4"
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
    // nil = not reported. Never 0 °C or 29.92 (audit #8 / F15): those fed density altitude, the
    // pressure trend, the fog note and the widget snapshot as if they'd been observed.
    var temperature: Int?    // Celsius
    var dewpoint: Int?       // Celsius
    var altimeter: Double?   // inHg
    var flightCategory: FlightCategory
    var weatherPhenomena: [String]
    var remarks: String?

    /// The report has a sky condition. NOAA sends no layers for a stated clear sky (`10SM CLR` ->
    /// `clouds: []`), so an empty list is clear only when the report body says so; otherwise the
    /// sky group is missing and the ceiling is unknown, not unlimited (audit #6).
    nonisolated var skyReported: Bool {
        if !clouds.isEmpty { return true }
        let body = rawText.components(separatedBy: " RMK").first ?? rawText
        let tokens = Set(body.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: ["CLR", "SKC", "NCD", "NSC", "CAVOK"])
    }

    nonisolated var ceiling: CeilingStatus { clouds.ceilingStatus(skyReported: skyReported) }

    /// Height of a KNOWN ceiling. nil is "no ceiling" OR "not reported": use `ceiling` wherever the
    /// difference matters.
    nonisolated var ceilingFeet: Int? { ceiling.feet }

    /// Coverage code (BKN/OVC/VV) of the ceiling layer — the same layer that produces ceilingFeet.
    nonisolated var ceilingCoverage: String? {
        ceilingFeet == nil ? nil : clouds.ceilingLayer?.coverage.rawValue
    }

    /// The sky when there's no known ceiling, in words: "Clear" only for a stated clear sky,
    /// "No ceiling" with FEW/SCT (F18), "Sky not reported" when there's no sky group (audit #6).
    nonisolated var noCeilingWords: String {
        if ceiling == .notReported { return "Sky not reported" }
        return clouds.contains { $0.coverage == .few || $0.coverage == .scattered } ? "No ceiling" : "Clear"
    }

    /// Compact sky token for list rows: "BKN 25" (hundreds of feet), the lowest FEW/SCT layer when
    /// there's no ceiling ("FEW 55"), "CLR" only for a stated clear sky, "Sky —" when not reported.
    nonisolated var skyCode: String {
        switch ceiling {
        case .feet(let f):
            return "\(ceilingCoverage ?? "BKN") \(f / 100)"
        case .none:
            let partial = clouds.filter { $0.coverage == .few || $0.coverage == .scattered }
            guard let low = partial.min(by: { ($0.altitude ?? .max) < ($1.altitude ?? .max) }) else { return "CLR" }
            return "\(low.coverage.rawValue) \(low.altitude.map(String.init) ?? "///")"
        case .notReported:
            return "Sky —"
        }
    }

    var isOld: Bool {
        Date().timeIntervalSince(observationTime) > 3600
    }
}

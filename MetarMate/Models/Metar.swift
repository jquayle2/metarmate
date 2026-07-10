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

// MARK: - METAR
struct Metar: Identifiable, Codable {
    var id: String { stationId + observationTime.ISO8601Format() }
    var rawText: String
    var stationId: String
    var observationTime: Date
    var wind: Wind
    var visibility: Double   // statute miles; meaningful only when visibilityReported == true
    // Whether the observation actually reported a visibility. METAR flight category is
    // authoritative from NOAA's fltCat, so visibility here is DISPLAY-ONLY — a flag suffices and
    // callers render "—"/skip when false (see Wind.isReported for the same idiom). This is
    // deliberately NOT the Double? that TafForecast.visibility uses: TAF category is *computed*
    // from visibility, so it must express unknown in the value itself; do not "unify" the two.
    var visibilityReported: Bool = true
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

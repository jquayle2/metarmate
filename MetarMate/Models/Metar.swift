import Foundation

// MARK: - Flight Category
enum FlightCategory: String, Codable, CaseIterable {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"
    case unknown = "UNKN"

    var color: String {
        switch self {
        case .vfr: return "green"
        case .mvfr: return "blue"
        case .ifr: return "red"
        case .lifr: return "purple"
        case .unknown: return "gray"
        }
    }

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
    var visibility: Double   // statute miles
    var clouds: [CloudLayer]
    var temperature: Int     // Celsius
    var dewpoint: Int        // Celsius
    var altimeter: Double    // inHg
    var flightCategory: FlightCategory
    var weatherPhenomena: [String]
    var remarks: String?

    var ceilingFeet: Int? {
        clouds.first(where: { $0.coverage == .broken || $0.coverage == .overcast || $0.coverage == .verticalVisibility })
               .map { $0.altitude * 100 }
    }

    var isOld: Bool {
        Date().timeIntervalSince(observationTime) > 3600
    }
}

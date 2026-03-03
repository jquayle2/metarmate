import Foundation

// MARK: - Shared Codable Types
// Extracted from WeatherService so they can be used by both
// the main app and the widget extension (e.g. AirportService NOAA fallback).

// Type-erased Codable wrapper for heterogeneous JSON values.
struct AnyCodable: Codable, @unchecked Sendable {
    nonisolated(unsafe) let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        }
        else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let bool as Bool: try container.encode(bool)
        case is NSNull: try container.encodeNil()
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encodeNil()
        }
    }
}

// Lightweight raw METAR response from aviationweather.gov
struct RawMetar: Codable {
    let icaoId: String?
    let receiptTime: String?
    let obsTime: Int?
    let reportTime: String?
    let temp: Double?
    let dewp: Double?
    let wdir: AnyCodable?
    let wspd: Int?
    let wgst: Int?
    let visib: AnyCodable?
    let altim: Double?
    let slp: Double?
    let rawOb: String?
    let lat: Double?
    let lon: Double?
    let elev: Int?
    let name: String?
    let cover: String?
    let clouds: [[String: AnyCodable]]?
    let wxString: String?
    let fltCat: String?
    let metarType: String?
}

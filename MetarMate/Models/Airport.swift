import Foundation
import SwiftData
import CoreLocation

// MARK: - Plain struct for bundled airport database
struct Airport: Identifiable, Codable, Hashable {
    var id: String { icao }
    let icao: String
    let iata: String?
    let name: String
    let latitude: Double
    let longitude: Double
    let elevation: Int
    let hasMetar: Bool  // true = official METAR station → aviationweather.gov; false → Open-Meteo advisory

    // MARK: Codable — backward-compatible: defaults true if field absent (e.g. live-resolved airports)
    private enum CodingKeys: String, CodingKey {
        case icao, iata, name, latitude, longitude, elevation, hasMetar
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icao      = try c.decode(String.self, forKey: .icao)
        iata      = try c.decodeIfPresent(String.self, forKey: .iata)
        name      = try c.decode(String.self, forKey: .name)
        latitude  = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        elevation = try c.decode(Int.self, forKey: .elevation)
        hasMetar  = try c.decodeIfPresent(Bool.self, forKey: .hasMetar) ?? true
    }

    init(icao: String, iata: String?, name: String,
         latitude: Double, longitude: Double, elevation: Int, hasMetar: Bool = true) {
        self.icao      = icao
        self.iata      = iata
        self.name      = name
        self.latitude  = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.hasMetar  = hasMetar
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(from location: CLLocation) -> CLLocationDistance {
        let airportLocation = CLLocation(latitude: latitude, longitude: longitude)
        return location.distance(from: airportLocation)
    }
}

// MARK: - SwiftData model for favorites persistence
@Model
final class AirportFavorite {
    @Attribute(.unique) var icao: String
    var iata: String?
    var name: String
    var latitude: Double
    var longitude: Double
    var elevation: Int
    var hasMetar: Bool = true
    var addedDate: Date

    init(from airport: Airport) {
        self.icao     = airport.icao
        self.iata     = airport.iata
        self.name     = airport.name
        self.latitude = airport.latitude
        self.longitude = airport.longitude
        self.elevation = airport.elevation
        self.hasMetar  = airport.hasMetar
        self.addedDate = Date()
    }

    var asAirport: Airport {
        Airport(icao: icao, iata: iata, name: name,
                latitude: latitude, longitude: longitude,
                elevation: elevation, hasMetar: hasMetar)
    }
}

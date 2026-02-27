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
    var addedDate: Date

    init(from airport: Airport) {
        self.icao = airport.icao
        self.iata = airport.iata
        self.name = airport.name
        self.latitude = airport.latitude
        self.longitude = airport.longitude
        self.elevation = airport.elevation
        self.addedDate = Date()
    }

    var asAirport: Airport {
        Airport(icao: icao, iata: iata, name: name,
                latitude: latitude, longitude: longitude, elevation: elevation)
    }
}

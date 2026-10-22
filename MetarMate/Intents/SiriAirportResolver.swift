import Foundation
import CoreLocation

// MARK: - Siri airport resolver
// Picks airports for FlyingWeatherIntent without a tap. Pure over its inputs (location and
// favorites are passed in) so the ranking is testable without Siri or CoreLocation.
enum SiriAirportResolver {

    /// Nearest airport that actually reports a METAR, not just the nearest strip.
    static func nearestMetarStation(to location: CLLocation) -> Airport? {
        AirportService.shared.nearest(to: location, count: 25).first(where: { $0.hasMetar })
    }
}

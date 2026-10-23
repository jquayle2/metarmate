import Foundation
import os
import SwiftData

// MARK: - FavoritesReconciler (audit #27)
// A favorite stores a copy of its airport's details from the day it was starred. Each launch,
// refresh that copy from the bundled airports.json, keyed by ICAO, so a corrected name, elevation,
// position, IATA code or METAR flag reaches favorites made before the fix. An ICAO that is no longer
// in airports.json keeps its favorite as is: never delete a pilot's favorite.
enum FavoritesReconciler {

    /// Returns the number of favorites changed. Saves only when something changed. `lookup`
    /// defaults to airports.json; tests inject their own.
    @discardableResult
    static func reconcile(in context: ModelContext, lookup: ((String) -> Airport?)? = nil) -> Int {
        let lookup = lookup ?? { AirportService.shared.bundledAirport(icao: $0) }
        let favorites = (try? context.fetch(FetchDescriptor<AirportFavorite>())) ?? []
        var changed = 0
        for favorite in favorites {
            guard let airport = lookup(favorite.icao) else { continue }   // missing: keep as is
            if apply(airport, to: favorite) { changed += 1 }
        }
        if changed > 0 {
            try? context.save()
            Log.load.info("[favorites] reconciled \(changed) of \(favorites.count) with airports.json")
        }
        return changed
    }

    // Copies the reference fields. Order and date added are the pilot's and are left alone.
    private static func apply(_ airport: Airport, to favorite: AirportFavorite) -> Bool {
        var changed = false
        if favorite.name != airport.name { favorite.name = airport.name; changed = true }
        if favorite.iata != airport.iata { favorite.iata = airport.iata; changed = true }
        if favorite.latitude != airport.latitude { favorite.latitude = airport.latitude; changed = true }
        if favorite.longitude != airport.longitude { favorite.longitude = airport.longitude; changed = true }
        if favorite.elevation != airport.elevation { favorite.elevation = airport.elevation; changed = true }
        if favorite.hasMetar != airport.hasMetar { favorite.hasMetar = airport.hasMetar; changed = true }
        return changed
    }
}

import Foundation

// MARK: - AlertConditions
// One normalized snapshot of an airport's current conditions, regardless of where it came
// from. METAR (hourly, aviationweather.gov) and live ASOS/AWOS (5-min, Synoptic) carry the
// same facts in different shapes and units; the two adapters below reconcile them so the
// GoNoGoEvaluator only ever sees this one type. This is the single place source differences
// are handled. (For ASOS, flight category is derived upstream via SynopticObservation's
// estimatedCategory so both sources are directly comparable.)
struct AlertConditions {

    enum Source: String {
        case metar
        case asos
    }

    var windDirection: Int?          // degrees true; nil = variable / calm
    var windSpeed: Int               // knots
    var windGust: Int?               // knots; nil = no gust reported
    var ceilingFeet: Int?            // lowest BKN/OVC/VV layer, feet AGL; nil = no ceiling
    var ceilingCoverage: String?     // coverage code (BKN/OVC/VV) of the ceiling layer; nil = no/unknown
    var visibilitySM: Double?         // statute miles; nil = not reported (visibility criterion is skipped)
    var flightCategory: FlightCategory
    var source: Source
    var timestamp: Date              // observation time (UTC)

    init(windDirection: Int?,
         windSpeed: Int,
         windGust: Int?,
         ceilingFeet: Int?,
         ceilingCoverage: String? = nil,
         visibilitySM: Double?,
         flightCategory: FlightCategory,
         source: Source,
         timestamp: Date) {
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.windGust = windGust
        self.ceilingFeet = ceilingFeet
        self.ceilingCoverage = ceilingCoverage
        self.visibilitySM = visibilitySM
        self.flightCategory = flightCategory
        self.source = source
        self.timestamp = timestamp
    }

    // MARK: - METAR adapter
    // Metar already exposes everything in alert units (speed kt, vis SM, ceilingFeet computed,
    // flightCategory parsed), so this is a straight field map.
    init(from metar: Metar) {
        self.init(windDirection: metar.wind.direction,
                  windSpeed: metar.wind.speed,
                  windGust: metar.wind.gust,
                  ceilingFeet: metar.ceilingFeet,
                  ceilingCoverage: metar.ceilingCoverage,
                  visibilitySM: metar.visibilityReported ? metar.visibility : nil,
                  flightCategory: metar.flightCategory,
                  source: .metar,
                  timestamp: metar.observationTime)
    }

    // MARK: - ASOS / Synoptic adapter
    // SynopticObservation stores wind speed/gust as optional Doubles and derives ceiling and
    // category via computed helpers (estimatedCategory, ceilingAGL). The two non-optional
    // alert fields (windSpeed, visibilitySM) need a fallback when Synoptic omits them — see
    // the two defaults below, both flagged for aviation sanity-check.
    init(from obs: SynopticObservation) {
        self.init(windDirection: obs.windDirection,
                  windSpeed: obs.windSpeed.map { Int($0.rounded()) } ?? Self.missingWindSpeedKt,
                  windGust: obs.windGust.map { Int($0.rounded()) },
                  ceilingFeet: obs.ceilingAGL,
                  ceilingCoverage: obs.ceilingCoverage,
                  visibilitySM: obs.visibility,   // nil (Synoptic omitted it) -> visibility criterion skipped
                  flightCategory: obs.estimatedCategory,
                  source: .asos,
                  timestamp: obs.observationTime)
    }

    // MARK: - Fallback for missing ASOS wind (AVIATION DEFAULT — sanity-check)
    // A live ASOS reading that omits wind is rare and usually means a degraded sensor.
    //  - missing wind speed -> 0 kt (calm): a calm wind produces no crosswind/wind exceedance.
    // Visibility is deliberately NOT defaulted: a missing vis leaves visibilitySM == nil and the
    // GoNoGo visibility criterion is SKIPPED, so a dropped vis sensor can never silently clear a
    // low-vis alert (the old `?? 10 SM` did exactly that).
    static let missingWindSpeedKt = 0
}

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
    var windSpeed: Int?              // knots; nil = not reported (wind criteria are skipped)
    var windGust: Int?               // knots; nil = no gust reported
    var ceilingFeet: Int?            // lowest BKN/OVC/VV layer, feet AGL; nil = no ceiling
    var ceilingCoverage: String?     // coverage code (BKN/OVC/VV) of the ceiling layer; nil = no/unknown
    var visibilitySM: Double?         // statute miles; nil = not reported (visibility criterion is skipped)
    var flightCategory: FlightCategory
    var source: Source
    var timestamp: Date              // observation time (UTC)

    init(windDirection: Int?,
         windSpeed: Int?,
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
                  windSpeed: metar.wind.isReported ? metar.wind.speed : nil,
                  windGust: metar.wind.isReported ? metar.wind.gust : nil,
                  ceilingFeet: metar.ceilingFeet,
                  ceilingCoverage: metar.ceilingCoverage,
                  visibilitySM: metar.visibility.lowerBoundSM,   // .greaterThan uses its floor; a >n clears a min if n does; .unknown -> nil (criterion skipped)
                  flightCategory: metar.flightCategory,
                  source: .metar,
                  timestamp: metar.observationTime)
    }

    // MARK: - ASOS / Synoptic adapter
    // SynopticObservation stores wind speed/gust as optional Doubles and derives ceiling and
    // category via computed helpers (estimatedCategory, ceilingAGL). Wind speed and visibility
    // stay nil when Synoptic omits them — an unreported wind must NOT become a fabricated 0 kt
    // calm (a degraded sensor would then silently satisfy every crosswind/wind minimum). nil
    // makes the GoNoGo wind criteria SKIP, exactly as a nil visibilitySM skips the vis criterion.
    init(from obs: SynopticObservation) {
        self.init(windDirection: obs.windDirection,
                  windSpeed: obs.windSpeed.map { Int($0.rounded()) },   // nil (Synoptic omitted it) -> wind criteria skipped
                  windGust: obs.windGust.map { Int($0.rounded()) },
                  ceilingFeet: obs.ceilingAGL,
                  ceilingCoverage: obs.ceilingCoverage,
                  visibilitySM: obs.visibility,   // nil (Synoptic omitted it) -> visibility criterion skipped
                  flightCategory: obs.estimatedCategory,
                  source: .asos,
                  timestamp: obs.observationTime)
    }
}

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
    var visibilitySM: Double         // statute miles
    var flightCategory: FlightCategory
    var source: Source
    var timestamp: Date              // observation time (UTC)

    init(windDirection: Int?,
         windSpeed: Int,
         windGust: Int?,
         ceilingFeet: Int?,
         visibilitySM: Double,
         flightCategory: FlightCategory,
         source: Source,
         timestamp: Date) {
        self.windDirection = windDirection
        self.windSpeed = windSpeed
        self.windGust = windGust
        self.ceilingFeet = ceilingFeet
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
                  visibilitySM: metar.visibility,
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
                  visibilitySM: obs.visibility ?? Self.missingVisibilitySM,
                  flightCategory: obs.estimatedCategory,
                  source: .asos,
                  timestamp: obs.observationTime)
    }

    // MARK: - Fallbacks for missing ASOS fields (AVIATION DEFAULTS — sanity-check)
    // A live ASOS reading that omits a field is rare and usually means a degraded sensor.
    // Both defaults are chosen to fail toward "do not false-fire" rather than "do not miss":
    //  - missing wind speed -> 0 kt (calm): a calm wind produces no crosswind/wind exceedance.
    //  - missing visibility  -> 10 SM (unrestricted): won't trip a low-vis alert on a sensor
    //    that simply stopped reporting vis. Trade-off: a genuinely low-vis event on a station
    //    that drops the vis field would be missed until the next full METAR.
    static let missingWindSpeedKt = 0
    static let missingVisibilitySM = 10.0
}

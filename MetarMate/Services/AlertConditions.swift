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

    var windDirection: Int?          // degrees true; nil = variable (windIsVariable) or not reported
    var windIsVariable: Bool = false
    var windSpeed: Int?              // knots; nil = not reported (wind criteria are skipped)
    var windGust: Int?               // knots; nil = no gust reported
    var ceilingFeet: Int?            // lowest BKN/OVC/VV layer, feet AGL; nil = no ceiling or not reported
    var ceiling: CeilingStatus = .none   // distinguishes "no ceiling" from "not reported" (audit #6)
    var skyCode: String? = nil       // compact sky token for the watch row (METAR only)
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
        windIsVariable = metar.wind.isVariable
        ceiling = metar.ceiling
        skyCode = metar.skyCode
    }

    // MARK: - Widget snapshot adapter
    // The widget's verdict input. Same fields as the METAR adapter, from the flat snapshot: an
    // unreported wind or visibility stays nil (never 0 kt / 0 SM), and a missing ceiling is "no
    // ceiling" only when the snapshot says the sky was reported.
    init(snapshot s: WidgetWeatherSnapshot) {
        let windKnown = s.windReported != false
        self.init(windDirection: windKnown ? s.windDirection : nil,
                  windSpeed: windKnown ? s.windSpeed : nil,
                  windGust: windKnown ? s.windGust : nil,
                  ceilingFeet: s.ceilingFeet,
                  visibilitySM: s.visibilityReported == false ? nil : s.visibility,
                  flightCategory: s.flightCategory,
                  source: .metar,
                  timestamp: s.observationTime)
        windIsVariable = s.windIsVariable
        if let ft = s.ceilingFeet {
            ceiling = .feet(ft)
        } else {
            ceiling = s.ceilingReported == true ? .none : .notReported
        }
    }

    // The ASOS / Synoptic adapter is an extension in SynopticService.swift, so this file can be
    // shared with the widget extension (which has no Synoptic code).
}

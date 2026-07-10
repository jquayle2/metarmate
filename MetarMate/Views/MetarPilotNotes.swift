import SwiftUI

// MARK: - Pilot Notes (METAR)
// Safety-critical pilot-advisory text. Extracted from WeatherDetailView so the derivation is a
// PURE, unit-testable function instead of a private method on a SwiftUI View (which couldn't be
// reached by tests and was coupled to `airport`/RunwayService). The single runway-dependent input
// — the crosswind display data — is INJECTED (default: none), keeping `build` free of View and
// RunwayService coupling. WeatherDetailView calls `build` with its own crosswindDisplays.
// Regression coverage: MetarMateTests/AdverseWeatherParsingTests.swift.

struct PilotNote {
    let icon: String
    let text: String
    let severity: Severity   // .caution (amber) · .warning (orange) · .danger (red)
    var crosswind: CrosswindDisplay? = nil   // when set, renders the 3-line crosswind body
    enum Severity { case caution, warning, danger }
    var color: Color {
        if let cw = crosswind { return cw.windColor }   // amber/red wind palette for the icon
        switch severity {
        case .danger:  return .red
        case .warning: return .orange
        case .caution: return Color(red: 1.0, green: 0.6, blue: 0.0)
        }
    }
}

// MARK: - Crosswind display data
/// Structured crosswind display data for a Pilot Notes line. DISPLAY ONLY — every number
/// comes from RunwayService (magnetic-frame math); this only reads it at two speeds and
/// formats. `side`/colors are borrowed from the calculator's CrosswindReadout so the two
/// agree. `line1` is set by the caller (METAR vs TAF-with-timing).
struct CrosswindDisplay {
    var line1: String = ""
    let side: String          // calc convention: "L" arrow-before-points-right, "R" arrow-after-points-left
    let xwLow: Int, xwHigh: Int
    let hwLow: Int, hwHigh: Int   // along-track; negative = tailwind (rare on the best runway)
    let isRed: Bool           // gust (high-end) crosswind crosses the calc's red threshold
    let vref: String?
    let ident: String
    /// Calc wind palette: amber by default, red when the gust crosswind crosses the threshold.
    static let amberWind = Color(red: 1.0, green: 0.6, blue: 0.0)
    var windColor: Color { isRed ? .red : Self.amberWind }
}

// MARK: - Derivation
enum MetarPilotNotes {

    /// Pure derivation of the METAR Pilot Notes list, in display order. The runway-specific
    /// crosswind detail is injected as DATA via `crosswindDisplays` (default: none) — computed by
    /// the caller for `metar.wind` — so this function has no View / RunwayService / @MainActor
    /// coupling and is directly unit-testable. When no runway data is supplied the crosswind note
    /// falls back to its runway-agnostic form.
    static func build(
        metar: Metar,
        history: [Metar],
        crosswindDisplays: [CrosswindDisplay] = []
    ) -> [PilotNote] {
        var notes: [PilotNote] = []
        let wind = metar.wind
        let gust = wind.gust ?? 0
        let speed = wind.speed
        let spread = gust - speed

        // Missing wind group — unknown, not calm. Surface it so the reader doesn't mistake an
        // unreported wind for a genuine 00000KT. (All wind-derived notes below stay silent because
        // speed/gust are 0 when isReported is false.)
        if !wind.isReported {
            notes.append(.init(icon: "wind", text: "Wind not reported — no wind group in this observation", severity: .caution))
        }

        // Windshear in remarks
        if let remarks = metar.remarks?.uppercased(), remarks.contains("WS ") || remarks.contains("LLWS") {
            notes.append(.init(icon: "wind", text: "Windshear reported in remarks — check NOTAM and PIREP", severity: .warning))
        }
        // WS in phenomena codes
        if metar.weatherPhenomena.contains(where: { $0.contains("WS") }) {
            notes.append(.init(icon: "wind", text: "Windshear in weather phenomena", severity: .warning))
        }

        // Crosswind — one consolidated note showing the sustained→gust range on the best runway.
        // Triggers on a notable sustained wind or any gust crossing the caution threshold.
        let hasGust = gust > speed
        if speed >= 20 || gust >= 15 {
            let severity: PilotNote.Severity = (speed >= 25 || gust >= 20) ? .warning : .caution
            let displays = crosswindDisplays
            if !displays.isEmpty {
                // Best runway first; a near-tie runner-up follows with subtler "or RWY" framing.
                for (i, display) in displays.enumerated() {
                    var cw = display
                    if i == 0 {
                        let lead = hasGust ? "Gusts \(gust) kt" : "Wind \(speed) kt"
                        cw.line1 = "\(lead) — RWY \(cw.ident)"
                    } else {
                        cw.line1 = "or RWY \(cw.ident)"
                    }
                    notes.append(.init(icon: "wind", text: cw.line1, severity: severity, crosswind: cw))
                }
            } else {
                let lead = hasGust ? "Gusts \(gust) kt" : "Sustained \(speed) kt"
                let vref = hasGust ? "; \(gust >= 20 ? "add" : "consider adding") \(gust / 2) kt to approach speed" : ""
                notes.append(.init(icon: "wind", text: "\(lead) — check crosswind component for your runway\(vref)", severity: severity))
            }
        }

        // Gust spread (turbulence indicator)
        if spread >= 15 {
            notes.append(.init(icon: "tornado", text: "Gust spread \(spread) kt — significant mechanical turbulence likely", severity: .warning))
        } else if spread >= 10 {
            notes.append(.init(icon: "tornado", text: "Gust spread \(spread) kt — moderate turbulence possible", severity: .caution))
        }

        // Variable wind — crosswind unpredictable
        if wind.isVariable && speed >= 8 {
            notes.append(.init(icon: "wind", text: "Variable wind direction at \(speed) kt — crosswind component unpredictable", severity: .caution))
        }

        // Low visibility — only when reported (.unknown -> lowerBoundSM nil -> no note, never off a
        // placeholder). Only .exact can be below 5 (a .greaterThan is >= 6), so displayNumber here
        // is always the plain "%g" number, never a "+".
        if let v = metar.visibility.lowerBoundSM {
            let visStr = metar.visibility.displayNumber ?? ""
            if v < 3 {
                notes.append(.init(icon: "eye.slash.fill", text: "Visibility \(visStr) SM — IFR conditions", severity: .warning))
            } else if v < 5 {
                notes.append(.init(icon: "eye.slash", text: "Visibility \(visStr) SM — reduced; VFR marginal", severity: .caution))
            }
        }

        // Low ceiling
        if let ceiling = metar.ceilingFeet {
            if ceiling < 500 {
                notes.append(.init(icon: "cloud.fill", text: "Ceiling \(ceiling.formatted()) ft — LIFR", severity: .warning))
            } else if ceiling < 1000 {
                notes.append(.init(icon: "cloud.fill", text: "Ceiling \(ceiling.formatted()) ft — IFR ceiling", severity: .warning))
            } else if ceiling < 3000 {
                notes.append(.init(icon: "cloud", text: "Ceiling \(ceiling.formatted()) ft — below VFR minimums in many areas", severity: .caution))
            }
        }

        // Fog risk: temp/dewpoint spread ≤4° (red at ≤2°, yellow at 3–4°)
        let tempDewSpread = metar.temperature - metar.dewpoint
        if tempDewSpread <= 2 {
            notes.append(.init(icon: "cloud.fog.fill", text: "Temp/dewpoint spread \(tempDewSpread)°C — fog or low stratus imminent", severity: .warning))
        } else if tempDewSpread <= 4 {
            notes.append(.init(icon: "cloud.fog", text: "Temp/dewpoint spread \(tempDewSpread)°C — fog risk; watch for rapid deterioration", severity: .caution))
        }

        // Thunderstorm / CB
        let hasTS = metar.weatherPhenomena.contains(where: { $0.hasPrefix("TS") || $0.hasPrefix("+TS") || $0.hasPrefix("VCTS") })
        let hasCB = metar.clouds.contains(where: { $0.isCumulonimbus })
        if hasTS {
            notes.append(.init(icon: "bolt.fill", text: "Thunderstorm reported — do not depart until clear", severity: .danger))
        } else if hasCB {
            notes.append(.init(icon: "bolt", text: "Cumulonimbus cloud reported — convective activity nearby", severity: .danger))
        }

        // Low altimeter — only flag when pressure is genuinely low, not just below ISA standard
        if metar.altimeter < 29.70 {
            notes.append(.init(icon: "gauge.low", text: "Altimeter \(String(format: "%.2f", metar.altimeter)) inHg — deep low pressure system; check area weather and PIREPs", severity: .warning))
        } else if metar.altimeter < 29.80 {
            notes.append(.init(icon: "gauge", text: "Altimeter \(String(format: "%.2f", metar.altimeter)) inHg — notable low pressure; monitor for developing weather", severity: .caution))
        }

        // Falling altimeter trend from history
        if history.count >= 3 {
            let recent = Array(history.prefix(3))
            let oldest = recent.last!.altimeter
            let newest = recent.first!.altimeter
            let drop = oldest - newest
            if drop >= 0.06 {
                notes.append(.init(icon: "arrow.down.circle.fill", text: String(format: "Altimeter falling %.2f inHg over recent observations — deepening low pressure", drop), severity: .warning))
            } else if drop >= 0.03 {
                notes.append(.init(icon: "arrow.down.circle", text: String(format: "Altimeter dropping %.2f inHg over recent observations — watch for continued deterioration", drop), severity: .caution))
            }
        }

        // Stale data
        if metar.isOld {
            let minutes = Int(Date().timeIntervalSince(metar.observationTime) / 60)
            notes.append(.init(icon: "clock.badge.exclamationmark", text: "Observation is \(minutes) min old — conditions may have changed", severity: .caution))
        }

        // Freezing precipitation — fire regardless of the reported surface temp. Freezing precip is
        // reported precisely because it's freezing on contact, routinely at a 2 m temp of 0 to +3 C;
        // the old `temp <= 0` gate suppressed the icing warning at ice-storm onset. Match the "FZ"
        // descriptor on ANY precip (FZRA/FZDZ/FZUP) — everything the old contains("FZ") caught EXCEPT
        // freezing fog, handled just below; narrowing to FZRA/FZDZ would silently drop FZUP.
        // CFII ruling (Mike): freezing precip icing reads red → .danger (freezing fog stays .warning).
        let hasFreezingPrecip = metar.weatherPhenomena.contains { let c = $0.uppercased(); return c.contains("FZ") && !c.contains("FZFG") }
        let hasFreezingFog = metar.weatherPhenomena.contains { $0.uppercased().contains("FZFG") }
        if hasFreezingPrecip {
            notes.append(.init(icon: "thermometer.snowflake", text: "Freezing precipitation — icing on aircraft and runway surfaces", severity: .danger))
        } else if hasFreezingFog {
            notes.append(.init(icon: "cloud.fog.fill", text: "Freezing fog — icing and obscuration", severity: .warning))
        } else if metar.temperature <= 2 && metar.temperature - metar.dewpoint <= 3 {
            notes.append(.init(icon: "thermometer.snowflake", text: "Near-freezing with high moisture — frost or freezing precip risk", severity: .caution))
        }

        return notes
    }
}

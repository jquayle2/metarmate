import Foundation

struct Runway: Codable {
    let le: String
    let leHdg: Int
    let he: String
    let heHdg: Int
    let len: Int?
    let wid: Int?
    let sfc: String?
}

struct RunwayEnd {
    let ident: String
    let heading: Int
    let length: Int?
    let width: Int?
    let surface: String?
}

struct RunwayResult {
    let runwayEnd: RunwayEnd
    let crosswind: Int
    let headwind: Int
    let isLeft: Bool
}

@MainActor
final class RunwayService {
    static let shared = RunwayService()
    private var runwayData: [String: [Runway]] = [:]
    private var loaded = false

    private init() {}

    func loadIfNeeded() {
        guard !loaded else { return }
        guard let url = Bundle.main.url(forResource: "runways", withExtension: "json") else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [Runway]].self, from: data) else { return }
        runwayData = decoded
        loaded = true
    }

    /// Numeric runway designator without the L/C/R position suffix ("12L" → "12").
    static func runwayNumber(_ ident: String) -> String {
        String(ident.prefix(while: { $0.isNumber }))
    }

    /// Display ident: the bare number when parallel runways share it (12L/12R have an
    /// identical heading, so identical crosswind), else the full ident.
    func displayIdent(_ end: RunwayEnd, icao: String) -> String {
        let number = Self.runwayNumber(end.ident)
        let count = runways(for: icao).filter { Self.runwayNumber($0.ident) == number }.count
        return count > 1 ? number : end.ident
    }

    /// East-positive WMM declination at the airport, or 0 when its coordinates are unknown.
    /// Computed once per crosswind pass and applied to BOTH the true METAR wind and each
    /// runway's true heading so the whole comparison runs in one magnetic frame.
    private func declination(for icao: String) -> Double {
        guard let airport = AirportService.shared.airport(icao: icao),
              !(airport.latitude == 0 && airport.longitude == 0) else { return 0 }
        return MagneticDeclination.shared.declination(
            latitude: airport.latitude, longitude: airport.longitude)
    }

    /// Rotate a TRUE bearing into the MAGNETIC frame using a pre-computed declination
    /// (east is least / subtract east), normalized to [0, 360).
    private func magnetic(_ trueDeg: Double, declination: Double) -> Double {
        let m = trueDeg - declination
        return (m.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    func runways(for icao: String) -> [RunwayEnd] {
        loadIfNeeded()
        guard let rwys = runwayData[icao] else { return [] }
        var ends: [RunwayEnd] = []
        for rwy in rwys {
            ends.append(RunwayEnd(ident: rwy.le, heading: rwy.leHdg, length: rwy.len, width: rwy.wid, surface: rwy.sfc))
            ends.append(RunwayEnd(ident: rwy.he, heading: rwy.heHdg, length: rwy.len, width: rwy.wid, surface: rwy.sfc))
        }
        return ends
    }

    /// Crosswind/headwind for every runway end at the given wind. `windGust` (when present)
    /// is used as the effective speed — the same worst-case convention bestRunway uses.
    ///
    /// `windDirection` is the TRUE-north METAR value and runways.json carries FAA-surveyed TRUE
    /// headings; both are rotated into the MAGNETIC frame via the same WMM declination, so results
    /// match the magnetic frame pilots and ForeFlight reason in. (The manual XWind tab is a
    /// separate path that still uses designator×10 — it has no airport context.)
    func crosswinds(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?) -> [RunwayResult] {
        let ends = runways(for: icao)
        guard !ends.isEmpty else { return [] }

        let effectiveSpeed = windGust ?? windSpeed
        let dec = declination(for: icao)
        let windMag = magnetic(Double(windDirection), declination: dec)

        return ends.map { end in
            let heading = magnetic(Double(end.heading), declination: dec)
            let angle = (windMag - heading) * .pi / 180.0
            let xw = abs(Int(round(effectiveSpeed * sin(angle))))
            let hw = Int(round(effectiveSpeed * cos(angle)))
            let left: Bool = {
                let diff = ((windMag - heading).truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                return diff > 0 && diff < 180
            }()
            return RunwayResult(runwayEnd: end, crosswind: xw, headwind: hw, isLeft: left)
        }
    }

    /// Strict "a is the better runway than b" ordering, matching the pilot's preference:
    /// a usable headwind beats a tailwind/zero; then least crosswind; then most headwind.
    private static func preferred(_ a: RunwayResult, _ b: RunwayResult) -> Bool {
        let aLand = a.headwind > 0, bLand = b.headwind > 0
        if aLand != bLand { return aLand }
        if a.crosswind != b.crosswind { return a.crosswind < b.crosswind }
        return a.headwind > b.headwind
    }

    func bestRunway(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?) -> RunwayResult? {
        crosswinds(for: icao, windDirection: windDirection, windSpeed: windSpeed, windGust: windGust)
            .min(by: Self.preferred)
    }

    /// The best runway plus, when it's a genuine near-tie, the runner-up — so Pilot Notes can
    /// show both rather than forcing one pick (more "thinks like a pilot" than a single badge).
    /// The runner-up is the best-ranked end with a DIFFERENT runway number (not the reciprocal
    /// or a parallel of the best), and is included only when its headwind component is within
    /// `tieKt` of the best. Best first, at most two.
    func bestRunways(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?,
                     tieKt: Int = 3) -> [RunwayResult] {
        let ranked = crosswinds(for: icao, windDirection: windDirection, windSpeed: windSpeed, windGust: windGust)
            .sorted(by: Self.preferred)
        guard let best = ranked.first else { return [] }
        let bestNumber = Self.runwayNumber(best.runwayEnd.ident)
        if let second = ranked.dropFirst().first(where: { Self.runwayNumber($0.runwayEnd.ident) != bestNumber }),
           abs(second.headwind - best.headwind) <= tieKt {
            return [best, second]
        }
        return [best]
    }
}

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

    /// A runway's MAGNETIC heading for crosswind math: the designator number ×10. Runway
    /// numbers ARE the magnetic heading rounded to 10°, which is the frame pilots and ForeFlight
    /// reason in — so this matches their crosswind component and best-runway pick. (runways.json
    /// stores TRUE headings, a different frame; mixing those with magnetic runway numbers was the
    /// bug — see XW_TRUE_MAGNETIC_BRIEF.)
    static func designatorMagneticHeading(_ ident: String) -> Int {
        (Int(runwayNumber(ident)) ?? 0) * 10
    }

    /// Convert a METAR wind direction (referenced to TRUE north) into the MAGNETIC frame at the
    /// given airport, using the WMM declination from its lat/lon. Falls back to the true value
    /// unchanged when the airport's coordinates are unknown (declination can't be computed).
    func magneticWind(_ trueDirection: Int, for icao: String) -> Int {
        guard let airport = AirportService.shared.airport(icao: icao),
              !(airport.latitude == 0 && airport.longitude == 0) else { return trueDirection }
        let mag = MagneticDeclination.shared.magneticFromTrue(
            Double(trueDirection), latitude: airport.latitude, longitude: airport.longitude)
        return ((Int(mag.rounded()) % 360) + 360) % 360
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
    /// `windDirection` is the TRUE-north METAR value; it is converted to MAGNETIC here and the
    /// math runs against each runway's magnetic (designator×10) heading, so results match the
    /// magnetic frame pilots and ForeFlight use.
    func crosswinds(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?) -> [RunwayResult] {
        let ends = runways(for: icao)
        guard !ends.isEmpty else { return [] }

        let effectiveSpeed = windGust ?? windSpeed
        let windMag = magneticWind(windDirection, for: icao)

        return ends.map { end in
            let heading = Self.designatorMagneticHeading(end.ident)
            let angle = Double(windMag - heading) * .pi / 180.0
            let xw = abs(Int(round(effectiveSpeed * sin(angle))))
            let hw = Int(round(effectiveSpeed * cos(angle)))
            let left: Bool = {
                let diff = ((windMag - heading) % 360 + 360) % 360
                return diff > 0 && diff < 180
            }()
            return RunwayResult(runwayEnd: end, crosswind: xw, headwind: hw, isLeft: left)
        }
    }

    func bestRunway(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?) -> RunwayResult? {
        let results = crosswinds(for: icao, windDirection: windDirection, windSpeed: windSpeed, windGust: windGust)
        guard !results.isEmpty else { return nil }

        var best: RunwayResult?
        for result in results {
            guard let current = best else {
                best = result
                continue
            }

            if result.headwind > 0 && current.headwind <= 0 {
                best = result
            } else if result.headwind > 0 && current.headwind > 0 {
                if result.crosswind < current.crosswind {
                    best = result
                }
            } else if result.headwind <= 0 && current.headwind <= 0 {
                if result.crosswind < current.crosswind {
                    best = result
                } else if result.crosswind == current.crosswind && result.headwind > current.headwind {
                    best = result
                }
            }
        }

        return best
    }
}

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

    /// True magnetic heading for the given runway designator number (1...36) at this airport,
    /// pulled from the same runways.json data bestRunway uses — so the contextual crosswind
    /// calculator computes off the exact heading, not the designator×10 approximation. Parallel
    /// ends (12L/12R) share a heading, so the bare number resolves unambiguously. Returns nil
    /// when the airport or runway is unknown (caller falls back to designator×10).
    func heading(for icao: String, runwayNumber: Int) -> Int? {
        runways(for: icao).first { Int(Self.runwayNumber($0.ident)) == runwayNumber }?.heading
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
    func crosswinds(for icao: String, windDirection: Int, windSpeed: Double, windGust: Double?) -> [RunwayResult] {
        let ends = runways(for: icao)
        guard !ends.isEmpty else { return [] }

        let effectiveSpeed = windGust ?? windSpeed

        return ends.map { end in
            let angle = Double(windDirection - end.heading) * .pi / 180.0
            let xw = abs(Int(round(effectiveSpeed * sin(angle))))
            let hw = Int(round(effectiveSpeed * cos(angle)))
            let left: Bool = {
                let diff = ((windDirection - end.heading) % 360 + 360) % 360
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

import Foundation
import os

// MARK: - Harness Audit (console dump)
//
// Prints the PARSED result of every injected fixture to the Xcode console / Console.app so the corpus
// can be audited without scrolling each screen. Filter the console by "harness" (the os_log category)
// to see only this output. Everything logged here comes from the SAME decode → parse path the screen
// renders from (SimulatedDecode → MetarParser/TafParser), so the console values match the UI exactly.
//
// Reached from the harness (which is receipt-gated), so this never runs in an App Store build.
enum HarnessAudit {
    private static let logger = Logger(subsystem: "com.jeffquayle.MetarMate", category: "harness")

    /// Dump the whole corpus (A1–A13, T1–T4) in one pass to the console.
    static func logAll() { for l in reportAll() { line(l) } }

    /// Dump one fixture to the console.
    static func log(_ fx: InjectionFixture) { for l in report(fx) { line(l) } }

    /// The whole corpus as lines (what `logAll` emits) — pure, so it can be asserted/shown in tests.
    static func reportAll() -> [String] {
        let all = MetarInjectionFixtures.all
        var out = ["════════════ METAR INJECTION AUDIT — \(all.count) fixtures ════════════",
                   "gate: receiptName=\(TestHarnessGate.receiptName ?? "nil") available=\(TestHarnessGate.isAvailable)"]
        for fx in all { out += report(fx) }
        out.append("════════════ END AUDIT ════════════")
        return out
    }

    /// One fixture's audit block — its expectation plus the actual parsed/derived values.
    static func report(_ fx: InjectionFixture) -> [String] {
        var out = ["──── [\(fx.id)] \(fx.title)",
                   "     expect: \(fx.subtitle)"]
        do {
            let inj = try fx.make()
            guard let m = inj.metars.first else { return out + ["     ⚠️ no observation parsed"] }

            let vis  = m.visibility.displayNumber.map { "\($0) SM" } ?? "— (unknown)"
            let ceil = m.ceilingFeet.map { "\($0) ft (\(m.ceilingCoverage ?? "?"))" } ?? "— (none)"
            let wx   = m.weatherPhenomena.isEmpty ? "none" : m.weatherPhenomena.joined(separator: " ")
            out.append("     current: station=\(m.stationId) cat=\(m.flightCategory.rawValue) vis=\(vis) wind=\(windText(m.wind)) ceiling=\(ceil) wx=[\(wx)]")

            let da = DensityAltitude.calculate(temperatureC: Double(m.temperature), dewpointC: Double(m.dewpoint),
                                               altimeterInHg: m.altimeter, fieldElevationFt: fx.airport.elevation)
            let altimNote = abs(m.altimeter - 29.92) < 0.001 ? " (29.92 — may be the fabricated default; see Finding 15)" : ""
            out.append("     temp=\(m.temperature)°C dew=\(m.dewpoint)°C altim=\(String(format: "%.2f", m.altimeter)) inHg\(altimNote)  DA=\(da.densityAltitudeFt) ft MSL (elev \(fx.airport.elevation) ft)")

            let obs = WeatherTrend.derive(metars: inj.metars, taf: inj.taf).observed
            out.append("     trend(\(inj.metars.count) obs): vis=\(obs.visibility.rawValue) ceiling=\(obs.ceiling.rawValue) wind=\(obs.wind.rawValue) — \(obs.summaryText)")

            let notes = MetarPilotNotes.build(metar: m, history: inj.metars)
            if notes.isEmpty {
                out.append("     notes: none")
            } else {
                for n in notes { out.append("     note[\(sev(n.severity))]: \(n.text)") }
            }

            if let taf = inj.taf {
                out.append("     TAF hero: \(TafHeroBrief.build(taf).map(\.text).joined())")
                for p in taf.forecasts {
                    let pv = p.visibility.displayNumber.map { "\($0) SM" } ?? "—"
                    let pwx = p.weatherPhenomena.isEmpty ? "none" : p.weatherPhenomena.joined(separator: " ")
                    out.append("     TAF \(p.type.rawValue): cat=\(p.flightCategory.rawValue) vis=\(pv) wx=[\(pwx)]")
                }
            }
        } catch {
            out.append("     ❌ PARSE FAILED: \(error.localizedDescription)  (surfaced honestly — no fallback model)")
        }
        return out
    }

    // MARK: - formatting

    private static func windText(_ w: Wind) -> String {
        if !w.isReported { return "— (not reported)" }
        if w.isVariable { return "VRB@\(w.speed)\(gust(w))KT (reported)" }
        if w.speed == 0 && (w.direction ?? 0) == 0 { return "Calm (reported)" }
        let dir = w.direction.map { String(format: "%03d", $0) } ?? "VRB"
        return "\(dir)@\(w.speed)\(gust(w))KT (reported)"
    }

    private static func gust(_ w: Wind) -> String { w.gust.map { "G\($0)" } ?? "" }

    private static func sev(_ s: PilotNote.Severity) -> String {
        switch s {
        case .caution: return "CAUTION"
        case .warning: return "WARNING"
        case .danger:  return "DANGER"
        }
    }

    // .public so the values actually print (Logger redacts dynamic strings as <private> otherwise).
    private static func line(_ s: String) {
        logger.info("\(s, privacy: .public)")
    }
}

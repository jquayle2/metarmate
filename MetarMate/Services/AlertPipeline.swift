import Foundation
import SwiftData

// MARK: - AlertPipeline
// The single evaluation pipeline shared by the manual "Check now" action and the background
// task (Part C) — no divergent logic, so what the user tests by hand is exactly what runs in
// the background.
@MainActor
enum AlertPipeline {

    struct Outcome {
        let watchesChecked: Int
        let notificationsFired: Int
    }

    // Load enabled watches → resolve the active profile → batch-fetch conditions for the
    // distinct ICAOs (METAR only) → run each through the GoNoGoEvaluator → fire a notification
    // on a verdict transition vs lastSide → persist the new side + evaluation time.
    @discardableResult
    static func runChecks(in context: ModelContext) async -> Outcome {
        let watches = (try? context.fetch(
            FetchDescriptor<AirportWatch>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        guard !watches.isEmpty, let profile = ActiveMinimumsProfile.resolve(in: context) else {
            return Outcome(watchesChecked: 0, notificationsFired: 0)
        }

        let icaos = Array(Set(watches.map { $0.icao }))
        // Background checks always fetch fresh (force) so notification verdicts never ride on a
        // stale cached METAR; the fetch still warms the shared cache for the UI.
        let conditions = await fetchConditions(for: icaos, force: true)

        var fired = 0
        for watch in watches {
            // BG task expired (expirationHandler cancelled us): stop posting and wind down.
            if Task.isCancelled { break }
            guard let c = conditions[watch.icao] else { continue }   // no data this cycle → leave side untouched
            let verdict = GoNoGoEvaluator.evaluate(profile, c, previousSide: watch.side,
                                                   wasInCheck: CheckState.isInCheck(watch.icao), icao: watch.icao)
            if verdict.shouldFire {
                let posted = await NotificationManager.shared.post(title: title(for: verdict, icao: watch.icao),
                                                                   body: body(for: verdict, icao: watch.icao, profile: profile))
                if posted { fired += 1 }   // count only confirmed adds, not intentions
            }
            // CHECK and "no current METAR" leave lastSide as it was (the last real GO/NO-GO).
            if let side = verdict.newSide { watch.side = side }
            switch verdict.outcome {
            case .check:      CheckState.set(watch.icao, inCheck: true)
            case .go, .noGo:  CheckState.set(watch.icao, inCheck: false)
            case .noCurrent:  break   // no evaluation happened: keep whatever it was
            }
            watch.lastEvaluatedDate = Date()
        }
        // Don't write to the App Group store after expiry — the process may be suspended mid-write
        // while holding the SQLite lock (0xdead10cc). Trade-off: a watch whose notification already
        // posted this run keeps its old side, so it can re-fire next cycle.
        if !Task.isCancelled {
            try? context.save()
        }
        return Outcome(watchesChecked: watches.count, notificationsFired: fired)
    }

    // The user-facing "Check now" trigger. Ensures notification permission FIRST — so a manual
    // check can never silently run without being able to surface a result (the "check ran but
    // no notification appeared" trap) — then runs the exact same pipeline the background uses.
    @discardableResult
    static func checkNow(in context: ModelContext) async -> Outcome {
        await NotificationManager.shared.requestAuthorizationIfNeeded()
        return await runChecks(in: context)
    }

    // MARK: - Read-only display evaluation
    // For the watches-list UI: fetch conditions via the same source ladder and evaluate each
    // watch against the active profile, but WITHOUT firing notifications or mutating lastSide —
    // viewing the list must never change alert state. conditions/verdict are nil when a station
    // returned no data (or no active profile resolves).
    struct WatchDisplay {
        let conditions: AlertConditions?
        let verdict: Verdict?
    }

    // `force` (pull-to-refresh) bypasses the shared cache's freshness window; the auto/appear
    // refresh reads through it so a tab revisit within 5 min doesn't re-fetch.
    static func evaluateForDisplay(_ watches: [AirportWatch], in context: ModelContext, force: Bool = false) async -> [String: WatchDisplay] {
        guard !watches.isEmpty, let profile = ActiveMinimumsProfile.resolve(in: context) else { return [:] }
        let icaos = Array(Set(watches.map { $0.icao }))
        let conditions = await fetchConditions(for: icaos, force: force)
        var result: [String: WatchDisplay] = [:]
        for watch in watches {
            let c = conditions[watch.icao]
            // Bare limits (previousSide nil), like the detail screen and widgets, so every surface
            // shows the same verdict for the same report. Hysteresis only decides notifications.
            let verdict = c.map { GoNoGoEvaluator.evaluate(profile, $0, previousSide: nil, icao: watch.icao) }
            result[watch.icao] = WatchDisplay(conditions: c, verdict: verdict)
        }
        return result
    }

    // MARK: - Conditions source
    // METAR only. 5-minute ASOS data never sets or changes a verdict, whatever the feature flag
    // or subscription says (DECISIONS_2026-10 #1).
    private static func fetchConditions(for icaos: [String], force: Bool = false) async -> [String: AlertConditions] {
        // Read-through the shared cache for METARs: keep fresh cached values, and only fetch the
        // misses. Normalize FAA LIDs to their K-prefixed ICAO for NOAA (36K→K36K) for the fetch,
        // then map back to the watch's own id so numeric-LID stations are actually evaluated.
        var metars: [String: Metar] = [:]
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for code in icaos {
            if !force, let cached = WeatherCache.shared.freshMetar(for: code) {
                metars[code] = cached
                continue
            }
            let id = WeatherService.noaaCandidate(for: code) ?? code
            noaaToOriginal[id] = code
            noaaIds.append(id)
        }
        if !noaaIds.isEmpty {
            let metarsByNoaa = (try? await WeatherService.shared.fetchMetars(for: noaaIds)) ?? [:]
            var fetched: [String: Metar] = [:]
            for (key, m) in metarsByNoaa { fetched[noaaToOriginal[key] ?? key] = m }
            WeatherCache.shared.store(metars: fetched)
            for (k, m) in fetched { metars[k] = m }
        }

        var result: [String: AlertConditions] = [:]
        for icao in icaos {
            if let metar = metars[icao] {
                result[icao] = AlertConditions(from: metar)
            }
        }
        return result
    }

    // MARK: - CHECK memory
    // Whether a watch's last evaluation was CHECK. Kept in UserDefaults, not on AirportWatch, so
    // lastSide stays the last real GO/NO-GO and the SwiftData schema is unchanged (Jeff, Oct 23).
    // Used to send the "Can't confirm" notification once, and never "Back within" out of CHECK.
    enum CheckState {
        private static func key(_ icao: String) -> String { "alertInCheck.\(icao.uppercased())" }
        static func isInCheck(_ icao: String) -> Bool { UserDefaults.standard.bool(forKey: key(icao)) }
        static func set(_ icao: String, inCheck: Bool) {
            if inCheck { UserDefaults.standard.set(true, forKey: key(icao)) }
            else { UserDefaults.standard.removeObject(forKey: key(icao)) }
        }
    }

    // MARK: - Notification text
    static func title(for verdict: Verdict, icao: String) -> String {
        switch verdict.outcome {
        case .noGo:              return "NO-GO — \(icao)"
        case .check:             return "CHECK — \(icao)"
        case .go, .noCurrent:    return "GO — \(icao)"
        }
    }

    static func body(for verdict: Verdict, icao: String, profile: MinimumsProfile) -> String {
        // A starter profile's verdict always says which profile it is (D#19).
        let against = profile.isBuiltIn ? " (vs \(profile.name) starter)" : ""
        let late = verdict.lateMinutes.map { " METAR late: \($0) min old." } ?? ""
        switch verdict.outcome {
        case .noGo:
            let reasons = verdict.failingFactors.isEmpty
                ? "below your minimums"
                : verdict.failingFactors.joined(separator: "; ")
            return "NO-GO\(against): \(reasons). \(verdict.sourceLabel).\(late)"
        case .check:
            return "Can't confirm your minimums at \(icao)\(against): \(verdict.uncheckedFactors.joined(separator: "; ")). \(verdict.sourceLabel).\(late)"
        case .go, .noCurrent:
            return "Back within your minimums\(against). \(verdict.sourceLabel).\(late)"
        }
    }
}

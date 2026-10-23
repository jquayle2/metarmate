import Foundation
import SwiftData
import os

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
    // `retry`: the background task's short budget by default (2 s, 5 s); "Check now" uses the
    // foreground policy.
    @discardableResult
    static func runChecks(in context: ModelContext, retry: RetryPolicy = .background) async -> Outcome {
        let watches = (try? context.fetch(
            FetchDescriptor<AirportWatch>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        guard !watches.isEmpty, let profile = VerdictProfile.current(in: context) else {
            return Outcome(watchesChecked: 0, notificationsFired: 0)
        }

        let icaos = Array(Set(watches.map { $0.icao }))
        // Background checks always fetch fresh (force) so notification verdicts never ride on a
        // stale cached METAR; the fetch still warms the shared cache for the UI.
        let conditions = await fetchConditions(for: icaos, force: true, retry: retry)

        var fired = 0
        for watch in watches {
            // BG task expired (expirationHandler cancelled us): stop posting and wind down.
            if Task.isCancelled { break }
            let c: AlertConditions
            switch conditions[watch.icao] {
            case .conditions(let fetched)?:
                c = fetched
            case .failed?:
                // Couldn't reach the weather service after retries: not evaluated. Side, CHECK and the
                // last good check time stay as they were, and no notification is sent.
                Log.load.warning("[alerts] \(watch.icao, privacy: .public) not checked — METAR request failed after retries")
                continue
            case .noProduct?, nil:
                continue   // no METAR this cycle (or cancelled) → leave side untouched
            }
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
        return await runChecks(in: context, retry: .foreground)
    }

    // MARK: - Read-only display evaluation
    // For the watches-list UI: fetch conditions via the same source ladder and evaluate each
    // watch against the active profile, but WITHOUT firing notifications or mutating lastSide —
    // viewing the list must never change alert state. conditions/verdict are nil when a station
    // returned no data (or no active profile resolves).
    struct WatchDisplay {
        let conditions: AlertConditions?
        let verdict: Verdict?
        let profile: VerdictProfileSnapshot   // the profile the verdict was judged against (its label)
        var notChecked: NotChecked? = nil     // set when this refresh couldn't reach the weather service
    }

    /// This refresh failed after retries. `lastGoodCheck` is when the station's METAR was last
    /// fetched (nil: never). The row shows "Not checked — couldn't reach weather service".
    struct NotChecked {
        let lastGoodCheck: Date?
    }

    // `force` (pull-to-refresh) bypasses the shared cache's freshness window; the auto/appear
    // refresh reads through it so a tab revisit within 5 min doesn't re-fetch.
    static func evaluateForDisplay(_ watches: [AirportWatch], in context: ModelContext, force: Bool = false) async -> [String: WatchDisplay] {
        guard !watches.isEmpty, let profile = VerdictProfile.current(in: context) else { return [:] }
        let icaos = Array(Set(watches.map { $0.icao }))
        let conditions = await fetchConditions(for: icaos, force: force, retry: .foreground)
        var result: [String: WatchDisplay] = [:]
        let now = Date()
        for watch in watches {
            var c: AlertConditions?
            var notChecked: NotChecked?
            switch conditions[watch.icao] {
            case .conditions(let fetched)?:
                c = fetched
            case .failed?:
                let lastGoodCheck = [WeatherCache.shared.lastMetarFetchedAt(for: watch.icao), watch.lastEvaluatedDate]
                    .compactMap { $0 }.max()
                c = conditionsAfterFailure(lastMetar: WeatherCache.shared.lastMetar(for: watch.icao),
                                           lastGoodCheck: lastGoodCheck, at: now)
                notChecked = NotChecked(lastGoodCheck: lastGoodCheck)
            case .noProduct?, nil:
                c = nil
            }
            // Bare limits (previousSide nil), like the detail screen and widgets, so every surface
            // shows the same verdict for the same report. Hysteresis only decides notifications.
            let verdict = c.map { GoNoGoEvaluator.evaluate(profile, $0, previousSide: nil, icao: watch.icao) }
            result[watch.icao] = WatchDisplay(conditions: c, verdict: verdict,
                                              profile: GoNoGoEvaluator.snapshot(of: profile), notChecked: notChecked)
        }
        return result
    }

    /// After a failed check, the previous reading still shows (with its verdict) while the last good
    /// check is within 75 min (D#4 cutoff); after that the row drops it and is neutral and
    /// unevaluated, so a stale GO never looks current.
    static func conditionsAfterFailure(lastMetar: Metar?, lastGoodCheck: Date?, at now: Date) -> AlertConditions? {
        guard let lastMetar, let lastGoodCheck,
              now.timeIntervalSince(lastGoodCheck) <= TimeInterval(WidgetWeatherSnapshot.noCurrentAfterMinutes * 60)
        else { return nil }
        return AlertConditions(from: lastMetar)
    }

    // MARK: - Conditions source
    // METAR only. 5-minute ASOS data never sets or changes a verdict, whatever the feature flag
    // or subscription says (DECISIONS_2026-10 #1).
    /// A watch's conditions for this check: from a METAR, NOAA has no METAR, or the request failed
    /// after retries (we don't know: never evaluated, never notified).
    enum ConditionsResult {
        case conditions(AlertConditions)
        case noProduct
        case failed
    }

    private static func fetchConditions(for icaos: [String], force: Bool, retry: RetryPolicy) async -> [String: ConditionsResult] {
        // Read-through the shared cache for METARs: keep fresh cached values, and only fetch the
        // misses. Normalize FAA LIDs to their K-prefixed ICAO for NOAA (36K→K36K) for the fetch,
        // then map back to the watch's own id so numeric-LID stations are actually evaluated.
        var result: [String: ConditionsResult] = [:]
        var noaaToOriginal: [String: String] = [:]
        var noaaIds: [String] = []
        for code in icaos {
            if !force, let cached = WeatherCache.shared.freshMetar(for: code) {
                result[code] = .conditions(AlertConditions(from: cached))
                continue
            }
            let id = WeatherService.noaaCandidate(for: code) ?? code
            noaaToOriginal[id] = code
            noaaIds.append(id)
        }
        guard !noaaIds.isEmpty else { return result }
        // Transient failures retry (only the failing stations); cancellation (BG expiry) leaves
        // those watches out entirely, as if this check never ran for them.
        guard let outcomes = try? await retry.runBatch("alerts METAR", ids: noaaIds, {
            try await WeatherService.shared.metarOutcomes(for: $0)
        }) else { return result }
        for (id, outcome) in outcomes {
            let code = noaaToOriginal[id] ?? id
            switch outcome {
            case .loaded(let metar):
                WeatherCache.shared.store(metar: metar, for: code)
                result[code] = .conditions(AlertConditions(from: metar))
            case .noProduct:
                result[code] = .noProduct
            case .failed:
                result[code] = .failed
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

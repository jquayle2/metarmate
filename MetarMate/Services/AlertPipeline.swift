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
    // distinct ICAOs (live ASOS for eligible subscribers, else METAR) → run each through the
    // GoNoGoEvaluator → fire a notification on a verdict transition vs lastSide → persist the
    // new side + evaluation time.
    @discardableResult
    static func runChecks(in context: ModelContext) async -> Outcome {
        let watches = (try? context.fetch(
            FetchDescriptor<AirportWatch>(predicate: #Predicate { $0.isEnabled })
        )) ?? []
        guard !watches.isEmpty, let profile = ActiveMinimumsProfile.resolve(in: context) else {
            return Outcome(watchesChecked: 0, notificationsFired: 0)
        }

        let icaos = Array(Set(watches.map { $0.icao }))
        let conditions = await fetchConditions(for: icaos)

        var fired = 0
        for watch in watches {
            guard let c = conditions[watch.icao] else { continue }   // no data this cycle → leave side untouched
            let verdict = GoNoGoEvaluator.evaluate(profile, c, previousSide: watch.side, icao: watch.icao)
            if verdict.shouldFire {
                NotificationManager.shared.post(title: title(for: verdict, icao: watch.icao),
                                                body: body(for: verdict))
                fired += 1
            }
            watch.side = verdict.newSide
            watch.lastEvaluatedDate = Date()
        }
        try? context.save()
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

    // MARK: - Source ladder
    // Live ASOS only when the app's existing ASOS eligibility holds (StoreManager.isAsosUser —
    // the single source of truth, not re-invented here) AND the user has alerts opted into live
    // ASOS. Per station, a successful Synoptic fetch IS the "station has ASOS" check; any
    // failure falls back to the batch METAR for that station.
    private static func fetchConditions(for icaos: [String]) async -> [String: AlertConditions] {
        let metars = (try? await WeatherService.shared.fetchMetars(for: icaos)) ?? [:]
        let useLiveAsos = StoreManager.shared.isAsosUser && useLiveAsosForAlerts

        var result: [String: AlertConditions] = [:]
        for icao in icaos {
            if useLiveAsos, let obs = try? await SynopticService.shared.fetchLatest(for: icao) {
                result[icao] = AlertConditions(from: obs)        // live ASOS
            } else if let metar = metars[icao] {
                result[icao] = AlertConditions(from: metar)      // METAR fallback
            }
        }
        return result
    }

    // Per-alerts opt-in (default on). isAsosUser already gates the subscription; this lets a
    // subscriber keep alerts on METAR if they prefer (e.g. to limit background API use). Step 5
    // surfaces the toggle; until then it reads its default.
    private static var useLiveAsosForAlerts: Bool {
        UserDefaults.standard.object(forKey: "useLiveAsosForAlerts") as? Bool ?? true
    }

    // MARK: - Notification text
    private static func title(for verdict: Verdict, icao: String) -> String {
        verdict.newSide == .noGo ? "NO-GO — \(icao)" : "GO — \(icao)"
    }

    private static func body(for verdict: Verdict) -> String {
        switch verdict.newSide {
        case .noGo:
            let reasons = verdict.failingFactors.isEmpty
                ? "below your minimums"
                : verdict.failingFactors.joined(separator: "; ")
            return "NO-GO: \(reasons). \(verdict.sourceLabel)."
        case .go:
            return "Back within your minimums. \(verdict.sourceLabel)."
        }
    }
}

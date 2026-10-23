import Foundation

// MARK: - GoNoGoEvaluator
// The app's entry to VerdictEngine: resolves a MinimumsProfile into plain limits (with the
// global crosswind floor) and the field's runways from RunwayService, then runs the shared rule.
// @MainActor because RunwayService is a @MainActor singleton over the bundled runways.json.
@MainActor
enum GoNoGoEvaluator {

    /// Alerts and notifications pass the watch's `previousSide` (hysteresis); screens pass nil
    /// so they show the bare-limit verdict, identical on every surface. See VerdictEngine.evaluate.
    static func evaluate(_ profile: MinimumsProfile,
                         _ conditions: AlertConditions,
                         previousSide: Side?,
                         wasInCheck: Bool = false,
                         icao: String,
                         now: Date = Date()) -> Verdict {
        VerdictEngine.evaluate(limits(for: profile), conditions,
                               runways: RunwayService.shared.runways(for: icao),
                               previousSide: previousSide, wasInCheck: wasInCheck, now: now)
    }

    /// The profile's minimums as plain values. Crosswind is always tested: a profile without a
    /// crosswind limit uses the global minimum (registered default 15 kt).
    static func limits(for profile: MinimumsProfile) -> VerdictLimits {
        VerdictLimits(maxCrosswindKt: profile.maxCrosswindKt
                        ?? UserDefaults.standard.integer(forKey: "globalCrosswindMinimumKt"),
                      maxGustKt: profile.maxGustKt,
                      minVisibilitySM: profile.minVisibilitySM,
                      minCeilingFt: profile.minCeilingFt,
                      minCategory: profile.minCategory,
                      maxSustainedWindKt: profile.maxSustainedWindKt)
    }

    /// The profile as the widget carries it (name, starter or not, limits).
    static func snapshot(of profile: MinimumsProfile) -> VerdictProfileSnapshot {
        VerdictProfileSnapshot(name: profile.name, isStarter: profile.isBuiltIn, limits: limits(for: profile))
    }
}

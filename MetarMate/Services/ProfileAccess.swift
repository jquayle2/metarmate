import Foundation

// MARK: - ProfileAccess (A3 step 3, lapsed-Pro rule)
// Custom minimums profiles are Pro (D#20); the built-in starters are free (D#19). This is the one
// rule for which profile a verdict may use. It doesn't pick the active profile: callers pass the
// active one in (VerdictProfile.current() calls this at merge; Jeff, Oct 23).
enum ProfileAccess {

    /// The profile verdicts may use. A starter is always usable. A custom profile needs Pro (or
    /// gating off); without it the verdict uses a starter, VFR day first. The custom profile stays
    /// stored and selected, so it comes back as soon as Pro does.
    static func usableProfile(active: MinimumsProfile?, isPro: Bool, starters: [MinimumsProfile],
                              gatingEnabled: Bool = FeatureFlags.proGatingEnabled) -> MinimumsProfile? {
        if let active,
           active.isBuiltIn || ProGate.allows(.customProfiles, isPro: isPro, gatingEnabled: gatingEnabled) {
            return active
        }
        return fallbackStarter(starters)
    }

    /// VFR day, else any starter. Non-starters in the list are ignored.
    static func fallbackStarter(_ starters: [MinimumsProfile]) -> MinimumsProfile? {
        starters.first { $0.isBuiltIn && $0.builtInKey == "vfrDay" } ?? starters.first { $0.isBuiltIn }
    }

    /// Shown when the active profile is custom and Pro has lapsed (wording approved Oct 23, with
    /// the starter's actual name).
    static func lapsedNotice(starterName: String) -> String {
        "Your custom profiles are saved. Verdicts use the \(starterName) starter until Pro is restored."
    }
}

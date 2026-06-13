import Foundation
import SwiftData

// MARK: - MinimumsProfile
// A named, reusable set of personal weather minimums. Every factor is optional: nil means
// "don't test this factor", so a profile can be as sparse as a single limit. The three
// starter profiles (seeded on first launch) happen to fill all six, but user-made profiles
// need not. flightCategory is stored as a raw String (FlightCategory.rawValue) per the
// migration-safety pattern — a renamed/removed case leaves old rows readable, just inert.
@Model
final class MinimumsProfile {
    var uuid: UUID = UUID()              // stable identity for the active-profile pointer;
                                         // survives store resets, unlike a PersistentIdentifier
    var name: String
    var isBuiltIn: Bool                  // true = seeded starter, false = user-made/cloned
    var builtInKey: String?              // stable starter identity, INDEPENDENT of display name,
                                         // so "reset to default" works after a rename; nil for
                                         // user profiles

    var maxCrosswindKt: Int?
    var maxGustKt: Int?
    var minVisibilitySM: Double?
    var minCeilingFt: Int?
    var minFlightCategory: String?       // FlightCategory.rawValue — access via `minCategory`
    var maxSustainedWindKt: Int?

    var createdDate: Date

    init(name: String,
         isBuiltIn: Bool = false,
         builtInKey: String? = nil,
         uuid: UUID = UUID(),
         maxCrosswindKt: Int? = nil,
         maxGustKt: Int? = nil,
         minVisibilitySM: Double? = nil,
         minCeilingFt: Int? = nil,
         minFlightCategory: FlightCategory? = nil,
         maxSustainedWindKt: Int? = nil,
         createdDate: Date = Date()) {
        self.uuid = uuid
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.builtInKey = builtInKey
        self.maxCrosswindKt = maxCrosswindKt
        self.maxGustKt = maxGustKt
        self.minVisibilitySM = minVisibilitySM
        self.minCeilingFt = minCeilingFt
        self.minFlightCategory = minFlightCategory?.rawValue
        self.maxSustainedWindKt = maxSustainedWindKt
        self.createdDate = createdDate
    }

    // Type-safe accessor over the stored string; nil if the value no longer maps to a case.
    var minCategory: FlightCategory? {
        get { minFlightCategory.flatMap { FlightCategory(rawValue: $0) } }
        set { minFlightCategory = newValue?.rawValue }
    }

    // Stable token for the active-profile pointer. Built-ins anchor on builtInKey ("builtin:<key>")
    // so the selection survives uuid churn / store migration / the ensureUniqueUUIDs repair;
    // user profiles use their uuid (kept stable per object by the dedup repair). A built-in whose
    // key hasn't been backfilled yet falls back to its uuid — the next resolve() self-heals it to
    // the stable form once the key lands.
    var activeToken: String {
        if isBuiltIn, let key = builtInKey { return "builtin:\(key)" }
        return uuid.uuidString
    }
}

// MARK: - Starter profiles
extension MinimumsProfile {

    // STRAWMAN NUMBERS — flagged for CFII review. Editing later is trivial (a value tweak),
    // and users can clone/edit these or build their own from scratch.
    //   Student     : xwind 8,  gust 15, vis 8, ceiling 3500, VFR, sustained 15
    //   VFR day     : xwind 12, gust 20, vis 6, ceiling 3000, VFR, sustained 20
    //   IFR current : xwind 15, gust 25, vis 1, ceiling 500,  IFR, sustained 25
    static func builtInStarters() -> [MinimumsProfile] {
        [
            MinimumsProfile(name: "Student", isBuiltIn: true, builtInKey: "student",
                            maxCrosswindKt: 8, maxGustKt: 15, minVisibilitySM: 8,
                            minCeilingFt: 3500, minFlightCategory: .vfr, maxSustainedWindKt: 15),
            MinimumsProfile(name: "VFR day", isBuiltIn: true, builtInKey: "vfrDay",
                            maxCrosswindKt: 12, maxGustKt: 20, minVisibilitySM: 6,
                            minCeilingFt: 3000, minFlightCategory: .vfr, maxSustainedWindKt: 20),
            MinimumsProfile(name: "IFR current", isBuiltIn: true, builtInKey: "ifrCurrent",
                            maxCrosswindKt: 15, maxGustKt: 25, minVisibilitySM: 1,
                            minCeilingFt: 500, minFlightCategory: .ifr, maxSustainedWindKt: 25),
        ]
    }

    // Re-applies the canonical starter values in place. builtInStarters() is the single source
    // of truth — it both seeds and serves as the reset target. Matches on the stable builtInKey
    // (NOT the display name) so a renamed built-in still resets correctly. No-op for user profiles.
    func resetToBuiltInDefault() {
        guard isBuiltIn, let key = builtInKey,
              let canonical = Self.builtInStarters().first(where: { $0.builtInKey == key }) else { return }
        maxCrosswindKt = canonical.maxCrosswindKt
        maxGustKt = canonical.maxGustKt
        minVisibilitySM = canonical.minVisibilitySM
        minCeilingFt = canonical.minCeilingFt
        minFlightCategory = canonical.minFlightCategory
        maxSustainedWindKt = canonical.maxSustainedWindKt
    }

    // Backfills builtInKey on built-ins seeded before the field existed, matching their current
    // name to a starter. Runs at launch BEFORE any rename is possible (built-in names are still
    // canonical), so keys land before the user can rename. Idempotent: no-op once keys are set.
    @MainActor
    static func backfillBuiltInKeys(in context: ModelContext) {
        let keyByName: [String: String] = builtInStarters().reduce(into: [:]) { dict, s in
            if let key = s.builtInKey { dict[s.name] = key }
        }
        let builtIns = (try? context.fetch(
            FetchDescriptor<MinimumsProfile>(predicate: #Predicate { $0.isBuiltIn })
        )) ?? []
        var changed = false
        for profile in builtIns where profile.builtInKey == nil {
            if let key = keyByName[profile.name] {
                profile.builtInKey = key
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    // Idempotent: inserts the starters only if no built-in profile exists yet, so it runs
    // once on first launch and is a no-op on every launch after. On that first seed it also
    // points the global active profile at "VFR day".
    @MainActor
    static func seedBuiltInsIfNeeded(in context: ModelContext) {
        let builtInCount = (try? context.fetchCount(
            FetchDescriptor<MinimumsProfile>(predicate: #Predicate { $0.isBuiltIn })
        )) ?? 0
        guard builtInCount == 0 else { return }
        let starters = builtInStarters()
        for profile in starters { context.insert(profile) }
        try? context.save()
        if let vfrDay = starters.first(where: { $0.name == "VFR day" }) {
            ActiveMinimumsProfile.set(vfrDay)
        }
    }

    // Repairs duplicate uuids. Built-ins seeded BEFORE the `uuid` field existed get a uuid via
    // SwiftData lightweight migration, which can assign the same default value to every existing
    // row — leaving all profiles sharing one uuid. Any colliding profile gets a fresh uuid.
    //
    // Crucially, this must NOT silently change the user's active selection. Built-ins now anchor
    // the pointer on builtInKey (uuid-independent), so reassigning a built-in's uuid never touches
    // the pointer. For a user profile whose uuid we change, we re-point to that SAME profile by
    // object identity (captured before any reassignment) — not blindly to "VFR day". We only fall
    // back when the pointer genuinely designated nothing resolvable.
    // Idempotent: a no-op once uuids are unique, so fresh installs are never affected.
    @MainActor
    static func ensureUniqueUUIDs(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<MinimumsProfile>())) ?? []
        guard !all.isEmpty else { return }
        let activeBefore = ActiveMinimumsProfile.resolve(in: context)   // the SAME object to keep
        var seen = Set<UUID>()
        var deduped = false
        for profile in all {
            if seen.contains(profile.uuid) {
                profile.uuid = UUID()
                deduped = true
            }
            seen.insert(profile.uuid)
        }
        guard deduped else { return }
        try? context.save()
        // Re-anchor to the same profile (its uuid may have just changed). activeToken is stable
        // for built-ins and the fresh uuid for user profiles, so the selection is preserved.
        if let active = activeBefore {
            ActiveMinimumsProfile.set(active)
        } else if let vfrDay = all.first(where: { $0.name == "VFR day" }) ?? all.first {
            ActiveMinimumsProfile.set(vfrDay)
        }
    }
}

// MARK: - ActiveMinimumsProfile
// The single, globally-active profile applied to every AirportWatch. Stored under
// "activeMinimumsProfileID" (the @AppStorage key the picker UI binds to) as the active profile's
// stable `activeToken`: "builtin:<key>" for built-ins, the uuid string for user profiles. Anchoring
// built-ins on builtInKey — not the volatile uuid — is what lets the selection survive uuid churn,
// store migration, and the ensureUniqueUUIDs repair (the Item-0 regression: a uuid-keyed pointer
// got silently re-anchored away from the user's choice). resolve() also accepts the LEGACY raw-uuid
// form so existing installs keep resolving, and self-heals it to the stable token on first read.
enum ActiveMinimumsProfile {
    static let key = "activeMinimumsProfileID"

    static func set(_ profile: MinimumsProfile) {
        UserDefaults.standard.set(profile.activeToken, forKey: key)
    }

    static func storedToken() -> String? {
        UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The live active profile. Matches the stored token (stable or legacy-uuid form); falls back
    /// to "VFR day" (then any built-in, then any profile) if the pointer is missing or doesn't
    /// resolve to exactly one profile. Persists the resolved/healed token so the pointer stays
    /// valid and canonical.
    @MainActor
    static func resolve(in context: ModelContext) -> MinimumsProfile? {
        let all = (try? context.fetch(FetchDescriptor<MinimumsProfile>())) ?? []
        guard !all.isEmpty else { return nil }
        if let token = storedToken(), let match = match(token, in: all) {
            if match.activeToken != token { set(match) }   // self-heal legacy raw-uuid pointer
            return match
        }
        let fallback = all.first(where: { $0.name == "VFR day" })
            ?? all.first(where: { $0.isBuiltIn })
            ?? all.first
        if let fallback { set(fallback) }   // keep the stored pointer valid + canonical
        return fallback
    }

    /// Resolve a stored token to a single profile. Handles the stable "builtin:<key>" form and the
    /// legacy raw-uuid form. A raw uuid that matches more than one profile (the shared-uuid latent
    /// state) is treated as unresolvable so the caller falls back rather than picking arbitrarily.
    @MainActor
    private static func match(_ token: String, in all: [MinimumsProfile]) -> MinimumsProfile? {
        if token.hasPrefix("builtin:") {
            let key = String(token.dropFirst("builtin:".count))
            return all.first { $0.isBuiltIn && $0.builtInKey == key }
        }
        let matches = all.filter { $0.uuid.uuidString == token }
        return matches.count == 1 ? matches[0] : nil
    }
}

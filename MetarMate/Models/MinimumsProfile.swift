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

    var maxCrosswindKt: Int?
    var maxGustKt: Int?
    var minVisibilitySM: Double?
    var minCeilingFt: Int?
    var minFlightCategory: String?       // FlightCategory.rawValue — access via `minCategory`
    var maxSustainedWindKt: Int?

    var createdDate: Date

    init(name: String,
         isBuiltIn: Bool = false,
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
            MinimumsProfile(name: "Student", isBuiltIn: true,
                            maxCrosswindKt: 8, maxGustKt: 15, minVisibilitySM: 8,
                            minCeilingFt: 3500, minFlightCategory: .vfr, maxSustainedWindKt: 15),
            MinimumsProfile(name: "VFR day", isBuiltIn: true,
                            maxCrosswindKt: 12, maxGustKt: 20, minVisibilitySM: 6,
                            minCeilingFt: 3000, minFlightCategory: .vfr, maxSustainedWindKt: 20),
            MinimumsProfile(name: "IFR current", isBuiltIn: true,
                            maxCrosswindKt: 15, maxGustKt: 25, minVisibilitySM: 1,
                            minCeilingFt: 500, minFlightCategory: .ifr, maxSustainedWindKt: 25),
        ]
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
            ActiveMinimumsProfile.set(vfrDay.uuid)
        }
    }

    // Repairs duplicate uuids. Built-ins seeded BEFORE the `uuid` field existed get a uuid via
    // SwiftData lightweight migration, which can assign the same default value to every existing
    // row — leaving all profiles sharing one uuid. That makes the active-profile pointer resolve
    // ambiguously (so switching silently can't take) and makes the switcher check every row. Any
    // colliding profile gets a fresh uuid and the active pointer is re-anchored to VFR day.
    // Idempotent: a no-op once uuids are unique, so fresh installs are never affected.
    @MainActor
    static func ensureUniqueUUIDs(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<MinimumsProfile>())) ?? []
        guard !all.isEmpty else { return }
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
        if let vfrDay = all.first(where: { $0.name == "VFR day" }) ?? all.first {
            ActiveMinimumsProfile.set(vfrDay.uuid)
        }
    }
}

// MARK: - ActiveMinimumsProfile
// The single, globally-active profile applied to every AirportWatch. Stored as the active
// MinimumsProfile's stable `uuid` (string form) under "activeMinimumsProfileID" (the
// @AppStorage key the picker UI binds to), sitting alongside the other alert globals in
// UserDefaults. A UUID — unlike a PersistentIdentifier — survives a SwiftData store reset, so
// the pointer can't be left dangling by the no-migration store moves this app uses. resolve()
// still falls back to "VFR day" if the stored uuid is missing or no longer matches exactly one
// profile (e.g. a stale pointer left over from the old PersistentIdentifier format).
enum ActiveMinimumsProfile {
    static let key = "activeMinimumsProfileID"

    static func set(_ uuid: UUID) {
        UserDefaults.standard.set(uuid.uuidString, forKey: key)
    }

    static func storedUUID() -> UUID? {
        UserDefaults.standard.string(forKey: key).flatMap { UUID(uuidString: $0) }
    }

    /// The live active profile. Falls back to "VFR day" (then any built-in, then any profile)
    /// if the stored uuid is missing or doesn't resolve to exactly one profile.
    @MainActor
    static func resolve(in context: ModelContext) -> MinimumsProfile? {
        let all = (try? context.fetch(FetchDescriptor<MinimumsProfile>())) ?? []
        if let uuid = storedUUID() {
            let matches = all.filter { $0.uuid == uuid }
            if matches.count == 1 { return matches[0] }
        }
        return all.first(where: { $0.name == "VFR day" })
            ?? all.first(where: { $0.isBuiltIn })
            ?? all.first
    }
}

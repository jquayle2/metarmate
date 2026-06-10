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
         maxCrosswindKt: Int? = nil,
         maxGustKt: Int? = nil,
         minVisibilitySM: Double? = nil,
         minCeilingFt: Int? = nil,
         minFlightCategory: FlightCategory? = nil,
         maxSustainedWindKt: Int? = nil,
         createdDate: Date = Date()) {
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
    // once on first launch and is a no-op on every launch after.
    @MainActor
    static func seedBuiltInsIfNeeded(in context: ModelContext) {
        let builtInCount = (try? context.fetchCount(
            FetchDescriptor<MinimumsProfile>(predicate: #Predicate { $0.isBuiltIn })
        )) ?? 0
        guard builtInCount == 0 else { return }
        for profile in builtInStarters() { context.insert(profile) }
        try? context.save()
    }
}

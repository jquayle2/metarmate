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

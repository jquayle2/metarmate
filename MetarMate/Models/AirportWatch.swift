import Foundation
import SwiftData

// MARK: - Side
// The binary go/no-go state. Persisted on AirportWatch as a raw string and used by the
// GoNoGoEvaluator as its hysteresis memory — defined here because the model owns the stored
// state. Fire only happens on a GO<->NO_GO transition.
enum Side: String {
    case go = "GO"
    case noGo = "NO_GO"
}

// MARK: - AirportWatch
// One MinimumsProfile applied to one airport. Carries the hysteresis memory (lastSide) so the
// background evaluator only notifies on a side change, not on every wake-up.
@Model
final class AirportWatch {
    var icao: String
    var profile: MinimumsProfile?        // relationship; nullified if the profile is deleted
    var isEnabled: Bool

    var lastSide: String?                // Side.rawValue (GO / NO_GO) — access via `side`
    var lastEvaluatedDate: Date?
    var createdDate: Date

    init(icao: String,
         profile: MinimumsProfile?,
         isEnabled: Bool = true,
         lastSide: Side? = nil,
         lastEvaluatedDate: Date? = nil,
         createdDate: Date = Date()) {
        self.icao = icao
        self.profile = profile
        self.isEnabled = isEnabled
        self.lastSide = lastSide?.rawValue
        self.lastEvaluatedDate = lastEvaluatedDate
        self.createdDate = createdDate
    }

    // Type-safe accessor over the stored string; nil if the value no longer maps to a case.
    var side: Side? {
        get { lastSide.flatMap { Side(rawValue: $0) } }
        set { lastSide = newValue?.rawValue }
    }
}

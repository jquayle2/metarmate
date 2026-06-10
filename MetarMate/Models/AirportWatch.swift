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
// One watched airport. Personal minimums are a single globally-active MinimumsProfile (see
// ActiveMinimumsProfile), not chosen per-watch — so a watch is just the airport plus its
// hysteresis memory (lastSide), letting the background evaluator notify only on a side change.
@Model
final class AirportWatch {
    var icao: String
    var isEnabled: Bool

    var lastSide: String?                // Side.rawValue (GO / NO_GO) — access via `side`
    var lastEvaluatedDate: Date?
    var createdDate: Date

    init(icao: String,
         isEnabled: Bool = true,
         lastSide: Side? = nil,
         lastEvaluatedDate: Date? = nil,
         createdDate: Date = Date()) {
        self.icao = icao
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

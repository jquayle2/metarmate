import Foundation
import SwiftData

// MARK: - Alert taxonomy
// String-backed enums: SwiftData persists plain `String` columns (see WeatherAlert below),
// while call sites stay type-safe via the computed accessors. Storing strings rather than
// the enums themselves avoids the enum-Codable lightweight-migration pitfalls this app has
// hit before — a renamed/removed case can never make an existing row undecodable.

enum TriggerType: String, Codable, CaseIterable {
    case crosswind          // crosswind component vs limit on the favored runway
    case category           // flight-category transition (VFR/MVFR/IFR/LIFR)
    case threshold          // wind / gust / visibility / ceiling threshold crossing
    case tafChange          // forecast change within a TAF watch window
}

enum AlertDirection: String, Codable, CaseIterable {
    case worsening          // fire only when conditions cross toward worse
    case improving          // fire only when conditions cross toward better
    case both               // fire on any qualifying transition
}

// MARK: - WeatherAlert
@Model
final class WeatherAlert {
    // Core (non-optional) — every alert has these.
    var icao: String
    var triggerType: String          // TriggerType.rawValue — access via `trigger`
    var direction: String            // AlertDirection.rawValue — access via `alertDirection`
    var isEnabled: Bool

    // Transition state — written by the background evaluator to suppress re-fires.
    var lastFiredState: String?
    var lastFiredDate: Date?

    // Type-specific limits — all optional for additive SwiftData migration safety.
    var crosswindLimitKt: Int?
    var windLimitKt: Int?
    var gustLimitKt: Int?
    var visLimitSM: Double?
    var ceilingLimitFt: Int?

    // TAF-change watch window (used by the tafChange trigger).
    var tafWindowStart: Date?
    var tafWindowEnd: Date?

    var createdDate: Date

    init(icao: String,
         triggerType: TriggerType,
         direction: AlertDirection,
         isEnabled: Bool = true,
         lastFiredState: String? = nil,
         lastFiredDate: Date? = nil,
         crosswindLimitKt: Int? = nil,
         windLimitKt: Int? = nil,
         gustLimitKt: Int? = nil,
         visLimitSM: Double? = nil,
         ceilingLimitFt: Int? = nil,
         tafWindowStart: Date? = nil,
         tafWindowEnd: Date? = nil,
         createdDate: Date = Date()) {
        self.icao = icao
        self.triggerType = triggerType.rawValue
        self.direction = direction.rawValue
        self.isEnabled = isEnabled
        self.lastFiredState = lastFiredState
        self.lastFiredDate = lastFiredDate
        self.crosswindLimitKt = crosswindLimitKt
        self.windLimitKt = windLimitKt
        self.gustLimitKt = gustLimitKt
        self.visLimitSM = visLimitSM
        self.ceilingLimitFt = ceilingLimitFt
        self.tafWindowStart = tafWindowStart
        self.tafWindowEnd = tafWindowEnd
        self.createdDate = createdDate
    }

    // MARK: - Type-safe accessors over the stored strings.
    // Getters return nil if a stored value no longer maps to a known case — callers treat
    // an unmapped alert as inert rather than crashing, which keeps old rows migration-safe.
    var trigger: TriggerType? {
        get { TriggerType(rawValue: triggerType) }
        set { if let newValue { triggerType = newValue.rawValue } }
    }

    var alertDirection: AlertDirection? {
        get { AlertDirection(rawValue: direction) }
        set { if let newValue { direction = newValue.rawValue } }
    }
}

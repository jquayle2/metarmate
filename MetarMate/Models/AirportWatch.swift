import Foundation
import SwiftData

// Side (GO / NO_GO) lives in VerdictEngine.swift, shared with the widget.

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

    // nil = watch until cancelled (permanent). A date = the watch expires then: it stops firing
    // and stops background-checking, but stays visible in the list as "Expired". Optional so
    // existing watches migrate to nil (permanent) — no surprise expiry of pre-feature watches.
    var expiresAt: Date?

    init(icao: String,
         isEnabled: Bool = true,
         lastSide: Side? = nil,
         lastEvaluatedDate: Date? = nil,
         expiresAt: Date? = nil,
         createdDate: Date = Date()) {
        self.icao = icao
        self.isEnabled = isEnabled
        self.lastSide = lastSide?.rawValue
        self.lastEvaluatedDate = lastEvaluatedDate
        self.expiresAt = expiresAt
        self.createdDate = createdDate
    }

    // Expired = has an expiry date that's now in the past. nil expiry is never expired.
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    // Type-safe accessor over the stored string; nil if the value no longer maps to a case.
    var side: Side? {
        get { lastSide.flatMap { Side(rawValue: $0) } }
        set { lastSide = newValue?.rawValue }
    }
}

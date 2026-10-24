import Foundation
import StoreKit

// MARK: - Pro access (A3 step 3)
// Compiled into the app AND the widget extension, so both decide Pro access the same way.

/// What MetarMate Pro adds (D#20). Free features are deliberately absent, so nothing can gate
/// them: favorites, search, the crosswind calculator, verdicts against the built-in starter
/// profiles, and all weather and safety information (D#19).
nonisolated enum ProFeature: String, CaseIterable {
    case widgets          // home and lock screen
    case customProfiles   // create, clone, edit a non-built-in minimums profile
    case alerts           // airport watches and background checks
    case siri
    case layout           // Customize Layout
}

nonisolated enum ProGate {
    /// The one gate check. With gating off (TestFlight builds) every feature is open.
    static func allows(_ feature: ProFeature, isPro: Bool,
                       gatingEnabled: Bool = FeatureFlags.proGatingEnabled) -> Bool {
        !gatingEnabled || isPro
    }
}

// MARK: - Entitlement rule
/// Product IDs and the rule for "is this user Pro", shared by StoreManager (app) and the widget.
nonisolated enum ProEntitlement {
    static let proID         = "com.jeffquayle.MetarMate.pro"
    static let asosMonthlyID = "com.jeffquayle.MetarMate.asosupdates.monthly"
    static let asosAnnualID  = "com.jeffquayle.MetarMate.asosupdates.annual"

    struct Record {
        let productID: String
        let ownership: Transaction.OwnershipType
        let isRevoked: Bool
        let isExpired: Bool

        init(productID: String, ownership: Transaction.OwnershipType = .purchased,
             isRevoked: Bool = false, isExpired: Bool = false) {
            self.productID = productID
            self.ownership = ownership
            self.isRevoked = isRevoked
            self.isExpired = isExpired
        }

        init(_ t: Transaction, now: Date = Date()) {
            self.init(productID: t.productID, ownership: t.ownershipType,
                      isRevoked: t.revocationDate != nil,
                      isExpired: t.expirationDate.map { $0 <= now } ?? false)
        }
    }

    /// Pro = the Pro purchase OR an active ASOS Updates subscription, which includes Pro (D#21).
    /// currentEntitlements already leaves out refunded/revoked and expired transactions; they're
    /// skipped here as well so a refund always turns Pro off. Ownership is deliberately ignored:
    /// a purchase shared by a family member counts the same as the user's own.
    static func resolve(_ records: [Record]) -> (pro: Bool, asos: Bool) {
        let live = records.filter { !$0.isRevoked && !$0.isExpired }
        let asos = live.contains { $0.productID == asosMonthlyID || $0.productID == asosAnnualID }
        let ownPro = live.contains { $0.productID == proID }
        return (pro: ownPro || asos, asos: asos)
    }

    /// Reads StoreKit directly. Used by the widget, which has no StoreManager.
    static func currentlyPro() async -> Bool {
        var records: [Record] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result { records.append(Record(t)) }
        }
        return resolve(records).pro
    }
}

// MARK: - Widget access
nonisolated enum WidgetProAccess {
    /// Whether the widget may show weather. Open when gating is off, when the app last saved Pro,
    /// or when StoreKit says Pro right now (a family purchase, or a fresh install before the app
    /// has run). A missing or false saved status alone never locks out a payer StoreKit knows.
    static func isAllowed() async -> Bool {
        guard FeatureFlags.proGatingEnabled else { return true }
        if WidgetDataManager.savedProStatus() == true { return true }
        return await ProEntitlement.currentlyPro()
    }

    /// The same rule as a pure function, for tests.
    static func decide(gatingEnabled: Bool, savedStatus: Bool?, storeKitSaysPro: Bool) -> Bool {
        !gatingEnabled || savedStatus == true || storeKitSaysPro
    }
}

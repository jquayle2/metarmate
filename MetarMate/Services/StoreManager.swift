import Foundation
import StoreKit
import Combine

// MARK: - StoreManager
// Manages MetarMate Pro (one-time) and ASOS Updates (subscription) via StoreKit 2.
@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // MARK: - Product IDs
    static let proID              = "com.jeffquayle.MetarMate.pro"
    static let asosMonthlyID      = "com.jeffquayle.MetarMate.asosupdates.monthly"
    static let asosAnnualID       = "com.jeffquayle.MetarMate.asosupdates.annual"
    // Only products that can be sold: the ASOS subscriptions are requested only once ASOS is
    // switched on, so a build with ASOS off never shows or offers them (audit #24).
    private static var requestedIDs: Set<String> {
        FeatureFlags.asosAvailable ? [proID, asosMonthlyID, asosAnnualID] : [proID]
    }

    // MARK: - Published state
    @Published private(set) var products: [Product] = []
    /// Pro features unlocked: the Pro purchase (own or family-shared) OR an active ASOS Updates
    /// subscription, which includes Pro (D#21). False until entitlements load; check
    /// `entitlementsLoaded` (or use `proAccessForSiri`) before telling anyone they lack Pro.
    @Published private(set) var isProUser = false
    /// True once the first `checkEntitlements()` has finished this launch.
    @Published private(set) var entitlementsLoaded = false
    @Published private(set) var isAsosSubscriber = false
    @Published private(set) var isLoading = false
    @Published private(set) var purchaseError: String?

    // True if ASOS data should be shown. Gated on the feature flag: every Synoptic fetch keys
    // off this, so with ASOS off no build may call Synoptic. There is no first-launch free
    // period; a StoreKit introductory offer replaces it later (DECISIONS_2026-10 #21).
    var isAsosUser: Bool {
        FeatureFlags.asosAvailable && isAsosSubscriber
    }

    private var updateTask: Task<Void, Never>?
    // checkEntitlements runs from launch, the Transaction.updates listener, foreground and
    // purchase/restore, and suspends inside StoreKit, so runs overlap. Only the most recently
    // started run publishes; an older run finishing later would overwrite newer state (a stale
    // "not Pro" right after a purchase).
    private var entitlementCheckGeneration = 0

    // Created from App.init (audit #24) so the Transaction.updates listener runs from launch, not
    // from the first screen that happens to touch the store. Opens no SwiftData store, so it's
    // safe on background launches.
    private init() {
        updateTask = listenForTransactions()
        Task { await checkEntitlements() }
    }

    deinit { updateTask?.cancel() }

    // MARK: - Load products
    func loadProducts() async {
        isLoading = true
        do {
            let fetched = try await Product.products(for: Self.requestedIDs)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            // failed to load products
        }
        isLoading = false
    }

    // MARK: - Purchase
    func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlements()
            case .pending:
                purchaseError = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Restore
    func restore() async {
        try? await AppStore.sync()
        await checkEntitlements()
    }

    // MARK: - Entitlement check
    func checkEntitlements() async {
        entitlementCheckGeneration += 1
        let generation = entitlementCheckGeneration
        // Sweep unfinished transactions first. A verified-but-unfinished transaction
        // (seen on iOS 26 TestFlight/sandbox) can block entitlements from resolving.
        for await result in Transaction.unfinished {
            if let transaction = try? checkVerified(result) {
                await transaction.finish()
            }
        }

        var records: [EntitlementRecord] = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            records.append(EntitlementRecord(transaction))
        }

        guard generation == entitlementCheckGeneration else { return }   // a newer check owns the result
        let resolved = Self.resolve(records)
        isProUser = resolved.pro
        isAsosSubscriber = resolved.asos
        entitlementsLoaded = true
        WidgetDataManager.saveProStatus(resolved.pro)
    }

    // MARK: - Entitlement rules (pure, unit-tested)

    struct EntitlementRecord {
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

    /// currentEntitlements already leaves out refunded/revoked and expired transactions; they're
    /// skipped here as well so a refund always turns Pro off. Ownership is deliberately ignored:
    /// a purchase shared by a family member counts the same as the user's own.
    nonisolated static func resolve(_ records: [EntitlementRecord]) -> (pro: Bool, asos: Bool) {
        let live = records.filter { !$0.isRevoked && !$0.isExpired }
        let asos = live.contains { $0.productID == asosMonthlyID || $0.productID == asosAnnualID }
        let ownPro = live.contains { $0.productID == proID }
        return (pro: ownPro || asos, asos: asos)
    }

    // MARK: - Waiting for entitlements (Siri)

    /// Waits up to `timeout` for the first entitlement check. Returns whether it finished.
    func waitUntilEntitlementsLoaded(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entitlementsLoaded && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return entitlementsLoaded
    }

    /// Pro access for Siri, which can launch the app cold and ask before StoreKit answers (#24).
    /// A paying user must never hear "Pro required", so if entitlements haven't loaded in time it
    /// falls back to the last status the app saved, and allows when there is none.
    func proAccessForSiri(timeout: Duration = .seconds(3)) async -> Bool {
        let loaded = await waitUntilEntitlementsLoaded(timeout: timeout)
        return Self.siriProAccess(loaded: loaded, isPro: isProUser,
                                  savedStatus: WidgetDataManager.savedProStatus())
    }

    nonisolated static func siriProAccess(loaded: Bool, isPro: Bool, savedStatus: Bool?) -> Bool {
        if loaded { return isPro }
        return savedStatus ?? true
    }

    // MARK: - Transaction listener
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { @MainActor [weak self] in
            for await result in Transaction.updates {
                if let transaction = try? self?.checkVerified(result) {
                    await transaction.finish()
                    await self?.checkEntitlements()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.unverifiedTransaction
        case .verified(let item):
            return item
        }
    }
}

// MARK: - Errors
enum StoreError: LocalizedError {
    case unverifiedTransaction
    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction: return "Transaction could not be verified."
        }
    }
}

import Foundation
import StoreKit
import Combine

// MARK: - StoreManager
// Manages MetarMate Pro (one-time) and ASOS Updates (subscription) via StoreKit 2.
@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // MARK: - Product IDs
    static let proID              = ProEntitlement.proID
    static let asosMonthlyID      = ProEntitlement.asosMonthlyID
    static let asosAnnualID       = ProEntitlement.asosAnnualID
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

    /// For UI gates: Pro, or entitlements still loading, so a payer never sees a paywall flash
    /// in the first moment after launch.
    var isProForUI: Bool { isProUser || !entitlementsLoaded }
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

    // MARK: - Entitlement rule (shared with the widget: ProAccess.swift)

    typealias EntitlementRecord = ProEntitlement.Record

    nonisolated static func resolve(_ records: [EntitlementRecord]) -> (pro: Bool, asos: Bool) {
        ProEntitlement.resolve(records)
    }

    // MARK: - Waiting for entitlements (Siri, background alerts)

    /// Waits up to `timeout` for the first entitlement check. Returns whether it finished.
    func waitUntilEntitlementsLoaded(timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !entitlementsLoaded && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return entitlementsLoaded
    }

    /// Pro status for code that can run before StoreKit answers: Siri and the background alert
    /// task launch the app cold (#24). A paying user must never be told "Pro required", so if
    /// entitlements haven't loaded in time it uses the last status the app saved, and says Pro
    /// when there is none.
    func isProWhenLoaded(timeout: Duration = .seconds(3)) async -> Bool {
        let loaded = await waitUntilEntitlementsLoaded(timeout: timeout)
        return Self.proStatus(loaded: loaded, isPro: isProUser,
                              savedStatus: WidgetDataManager.savedProStatus())
    }

    /// Pro status for which profile a verdict may use (VerdictProfile): the same rule without the
    /// wait, so a payer's custom profile never drops to a starter while StoreKit loads at launch.
    var isProForVerdicts: Bool {
        Self.proStatus(loaded: entitlementsLoaded, isPro: isProUser,
                       savedStatus: WidgetDataManager.savedProStatus())
    }

    nonisolated static func proStatus(loaded: Bool, isPro: Bool, savedStatus: Bool?) -> Bool {
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

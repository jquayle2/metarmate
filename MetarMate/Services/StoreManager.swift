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
    @Published private(set) var isProUser = false
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
        // Sweep unfinished transactions first. A verified-but-unfinished transaction
        // (seen on iOS 26 TestFlight/sandbox) can block entitlements from resolving.
        for await result in Transaction.unfinished {
            if let transaction = try? checkVerified(result) {
                await transaction.finish()
            }
        }

        var foundPro = false
        var foundAsos = false

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            switch transaction.productID {
            case Self.proID:
                foundPro = true
            case Self.asosMonthlyID, Self.asosAnnualID:
                foundAsos = true
            default:
                break
            }
        }

        isProUser = foundPro
        isAsosSubscriber = foundAsos
        WidgetDataManager.saveProStatus(foundPro)
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

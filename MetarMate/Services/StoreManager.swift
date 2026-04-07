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
    private static let allIDs: Set<String> = [proID, asosMonthlyID, asosAnnualID]

    // MARK: - First launch tracking (60-day free ASOS window)
    private static let firstLaunchKey = "metarmate_first_launch_date"
    static let asosFreeDays: Double = 60

    static var firstLaunchDate: Date {
        if let stored = UserDefaults.standard.object(forKey: firstLaunchKey) as? Date {
            return stored
        }
        let now = Date()
        UserDefaults.standard.set(now, forKey: firstLaunchKey)
        return now
    }

    // MARK: - Published state
    @Published private(set) var products: [Product] = []
    @Published private(set) var isProUser = false
    @Published private(set) var isAsosSubscriber = false
    @Published private(set) var isLoading = false
    @Published private(set) var purchaseError: String?

    // True if within the 60-day free ASOS launch window
    var isAsosInFreePeriod: Bool {
        let elapsed = Date().timeIntervalSince(Self.firstLaunchDate)
        return elapsed < Self.asosFreeDays * 86400
    }

    // True if ASOS data should be shown (subscribed OR in free period)
    var isAsosUser: Bool {
        isAsosSubscriber || isAsosInFreePeriod
    }

    // Days remaining in free period (0 if expired)
    var asosFreeDaysRemaining: Int {
        let elapsed = Date().timeIntervalSince(Self.firstLaunchDate)
        let remaining = Self.asosFreeDays * 86400 - elapsed
        return max(0, Int(remaining / 86400))
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
            let fetched = try await Product.products(for: Self.allIDs)
            products = fetched.sorted { $0.price < $1.price }
        } catch {
            print("StoreManager: failed to load products — \(error)")
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

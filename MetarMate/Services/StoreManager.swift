import Foundation
import StoreKit
import Combine

// MARK: - StoreManager
// Manages MetarMate Pro subscription via StoreKit 2.
// Pro unlocks live ASOS data on the airport detail page.
@MainActor
class StoreManager: ObservableObject {
    static let shared = StoreManager()

    // MARK: - Product IDs (must match App Store Connect)
    static let proMonthlyID = "com.jeffquayle.MetarMate.pro.monthly"
    static let proAnnualID  = "com.jeffquayle.MetarMate.pro.annual"
    private static let productIDs: Set<String> = [proMonthlyID, proAnnualID]

    // MARK: - Published state
    @Published private(set) var products: [Product] = []
    // Set to true for TestFlight/beta testing — remove before App Store release
    static let testFlightOverride = true
    @Published private(set) var isProUser = testFlightOverride
    @Published private(set) var isLoading = false
    @Published private(set) var purchaseError: String?
    @Published private(set) var currentSubscription: Product?

    private var updateTask: Task<Void, Never>?

    private init() {
        updateTask = listenForTransactions()
        Task { await checkEntitlements() }
    }

    deinit {
        updateTask?.cancel()
    }

    // MARK: - Load products from App Store
    func loadProducts() async {
        isLoading = true
        do {
            let fetched = try await Product.products(for: Self.productIDs)
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
        var activeSub: Product?

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if Self.productIDs.contains(transaction.productID) {
                    foundPro = true
                    activeSub = products.first(where: { $0.id == transaction.productID })
                }
            }
        }

        isProUser = foundPro || Self.testFlightOverride
        currentSubscription = activeSub
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

import Testing
import StoreKit
import StoreKitTest
@testable import MetarMate

// Audit #24 / A3 step 2: one entitlement source of truth. Pro = the Pro purchase (own or
// family-shared) OR an active ASOS Updates subscription; refunds turn it off; Siri never says
// "Pro required" to a paying user just because StoreKit hasn't answered yet.
struct EntitlementRulesTests {
    typealias R = StoreManager.EntitlementRecord

    @Test func noTransactionsIsNotPro() {
        #expect(StoreManager.resolve([]) == (pro: false, asos: false))
    }

    @Test func ownProPurchaseIsPro() {
        #expect(StoreManager.resolve([R(productID: StoreManager.proID)]).pro)
    }

    @Test func familySharedProPurchaseIsPro() {
        #expect(StoreManager.resolve([R(productID: StoreManager.proID, ownership: .familyShared)]).pro)
    }

    @Test func refundedProPurchaseIsNotPro() {
        #expect(!StoreManager.resolve([R(productID: StoreManager.proID, isRevoked: true)]).pro)
    }

    @Test func activeAsosSubscriptionIncludesPro() {
        let r = StoreManager.resolve([R(productID: StoreManager.asosAnnualID)])
        #expect(r.pro && r.asos)
        #expect(StoreManager.resolve([R(productID: StoreManager.asosMonthlyID)]).pro)
    }

    @Test func expiredAsosSubscriptionIsNeither() {
        #expect(StoreManager.resolve([R(productID: StoreManager.asosAnnualID, isExpired: true)]) == (pro: false, asos: false))
    }

    @Test func siriUsesLoadedStatusWhenAvailable() {
        #expect(StoreManager.siriProAccess(loaded: true, isPro: true, savedStatus: false))
        #expect(!StoreManager.siriProAccess(loaded: true, isPro: false, savedStatus: true))
    }

    @Test func siriFallsBackToSavedStatusThenAllows() {
        #expect(StoreManager.siriProAccess(loaded: false, isPro: false, savedStatus: true))
        #expect(!StoreManager.siriProAccess(loaded: false, isPro: false, savedStatus: false))
        // Never saved (fresh install, StoreKit slow): allow rather than tell a payer "Pro required".
        #expect(StoreManager.siriProAccess(loaded: false, isPro: false, savedStatus: nil))
    }
}

// End to end against MetarMateProducts.storekit: a real (local) purchase turns Pro on through
// Transaction.currentEntitlements, a refund turns it off, and ASOS includes Pro.
@MainActor
@Suite(.serialized)
struct StoreKitEntitlementTests {

    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func session() throws -> SKTestSession {
        let s = try SKTestSession(configurationFileNamed: "MetarMateProducts")
        s.resetToDefaultState()
        s.clearTransactions()
        s.disableDialogs = true
        return s
    }

    @Test func configHasProAtFiveNinetyNineFamilyShareable() async throws {
        _ = try session()
        let products = try await Product.products(for: [StoreManager.proID])
        let pro = try #require(products.first)
        #expect(pro.displayPrice == "$5.99")
        #expect(pro.isFamilyShareable)
        #expect(pro.type == .nonConsumable)
    }

    @Test func purchaseThenRefund() async throws {
        let s = try session()
        let store = StoreManager.shared
        await store.checkEntitlements()
        #expect(store.entitlementsLoaded)
        #expect(!store.isProUser)

        // The app's own purchase path: Product.purchase() → finish → checkEntitlements.
        let pro = try #require(try await Product.products(for: [StoreManager.proID]).first)
        await store.purchase(pro)
        #expect(store.purchaseError == nil)
        #expect(store.isProUser)
        #expect(WidgetDataManager.savedProStatus() == true)

        let transaction = try #require(s.allTransactions().first { $0.productIdentifier == StoreManager.proID })
        // A refund reaches the app through Transaction.updates; the listener re-checks.
        try s.refundTransaction(identifier: transaction.identifier)
        #expect(await eventually { !store.isProUser }, "refund never turned Pro off")
        #expect(WidgetDataManager.savedProStatus() == false)
    }

    @Test func asosSubscriptionIncludesPro() async throws {
        let s = try session()
        let store = StoreManager.shared
        _ = try await s.buyProduct(identifier: StoreManager.asosAnnualID)
        await store.checkEntitlements()
        #expect(store.isProUser)
        #expect(store.isAsosSubscriber)
        s.clearTransactions()
        await store.checkEntitlements()
        #expect(!store.isProUser)
    }
}

import SwiftUI
import StoreKit

enum UpgradeMode {
    case pro
    case asos
}

// MARK: - Upgrade View
// Used for both MetarMate Pro (one-time) and ASOS Updates (subscription).
struct ProUpgradeView: View {
    var mode: UpgradeMode = .asos
    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var restoreMessage: String?
    @State private var showRedeemSheet = false

    // The ASOS screen (heroSection … footerSection) stays hidden while ASOS is off.
    private var asosProducts: [Product] {
        store.products.filter { $0.id == StoreManager.asosMonthlyID || $0.id == StoreManager.asosAnnualID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if mode == .pro {
                    proScreen
                } else {
                    VStack(spacing: 24) {
                        heroSection
                        featureSection
                        productSection
                        footerSection
                    }
                }
            }
            .background(mode == .pro ? Brand.navy : Color.clear)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("proPaywall")   // UI tests: a gate opened the paywall
            .task {
                if store.products.isEmpty { await store.loadProducts() }
            }
            .onChange(of: store.isProUser) { _, isPro in
                if mode == .pro, isPro { dismiss() }
            }
            .onChange(of: store.isAsosSubscriber) { _, isSub in
                if mode == .asos, isSub { dismiss() }
            }
            // Apple's offer-code sheet (Step 5: one-time codes). A redeemed code arrives as a
            // transaction; re-check so the screen closes without waiting for Transaction.updates.
            .offerCodeRedemption(isPresented: $showRedeemSheet) { _ in
                Task { await store.checkEntitlements() }
            }
        }
    }

    // MARK: - Pro paywall (A3 step 4)
    // Lists only what Pro adds. Price comes from StoreKit. Restore Purchases is always visible and
    // there are no links out of the app (guideline 3.1.1). No Apple Watch line until it ships.

    private static let proFeatures: [(icon: String, title: String)] = [
        ("rectangle.3.group", "Home and lock screen widgets"),
        ("slider.horizontal.3", "Unlimited custom minimums profiles"),
        ("bell.badge", "Minimums alerts"),
        ("mic.fill", "Siri and Shortcuts"),
        ("square.grid.2x2", "Custom detail layout"),
    ]

    private var proProduct: Product? {
        store.products.first { $0.id == StoreManager.proID }
    }

    private var proScreen: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 54))
                    .foregroundColor(Brand.accentOrange)
                Text("MetarMate Pro")
                    .font(.avenir(30, .heavy))
                    .foregroundColor(Brand.cloud)
                Text("One purchase. Yours to keep.")
                    .font(.avenir(16, .demibold))
                    .foregroundColor(Brand.fog2)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.proFeatures, id: \.title) { feature in
                    HStack(spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.title3)
                            .foregroundColor(Brand.accentOrange)
                            .frame(width: 30)
                        Text(feature.title)
                            .font(.avenir(16, .demibold))
                            .foregroundColor(Brand.fog)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                buyButton
                if let error = store.purchaseError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(Brand.valueRed)
                        .multilineTextAlignment(.center)
                }
                Text("Shared with your family through Family Sharing.")
                    .font(.caption)
                    .foregroundColor(Brand.slate)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    Button("Restore Purchases") { restore() }
                        .disabled(isRestoring)
                        .accessibilityIdentifier("restorePurchasesButton")
                    Text("·").foregroundColor(Brand.slate)
                    Button("Redeem Code") { showRedeemSheet = true }
                        .accessibilityIdentifier("redeemCodeButton")
                }
                .font(.subheadline)
                .foregroundColor(Brand.fog2)
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.caption)
                        .foregroundColor(Brand.slate)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var buyButton: some View {
        if let product = proProduct {
            Button {
                isPurchasing = true
                Task { await store.purchase(product); isPurchasing = false }
            } label: {
                ZStack {
                    Text("Buy Pro · \(product.displayPrice)").opacity(isPurchasing ? 0 : 1)
                    if isPurchasing { ProgressView().tint(.white) }
                }
                .font(.avenir(18, .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Brand.accentOrange, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isPurchasing)
            .accessibilityIdentifier("buyProButton")
        } else if store.isLoading {
            ProgressView("Loading…").tint(Brand.fog2).foregroundColor(Brand.fog2).padding()
        } else {
            VStack(spacing: 8) {
                Text("Couldn't reach the App Store.")
                    .font(.subheadline)
                    .foregroundColor(Brand.fog2)
                Button("Try Again") { Task { await store.loadProducts() } }
                    .font(.subheadline.bold())
                    .foregroundColor(Brand.accentOrange)
            }
            .padding()
        }
    }

    private func restore() {
        isRestoring = true
        restoreMessage = nil
        Task {
            await store.restore()
            isRestoring = false
            // On success the screen closes (onChange above); say so when nothing was found.
            if !store.isProUser {
                restoreMessage = "No MetarMate Pro purchase was found for this Apple Account."
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 50))
                .foregroundColor(.cyan)
            Text("ASOS Updates")
                .font(.title.bold())
            Text("Live weather between METARs")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 20)
        .padding(.horizontal)
    }

    @ViewBuilder
    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow("antenna.radiowaves.left.and.right", "5-Minute Updates", "ASOS data refreshes automatically — not just hourly METARs")
            featureRow("wind", "Wind Trend Strip", "See wind changes over the last hour at a glance")
            featureRow("arrow.triangle.2.circlepath", "METAR Delta", "Instantly see what changed since the last official report")
            featureRow("clock.arrow.circlepath", "Auto-Refresh", "Always current while you're on the detail page")
        }
        .padding(.horizontal)
    }

    private var productSection: some View {
        VStack(spacing: 12) {
            if store.products.isEmpty {
                ProgressView("Loading…").padding()
            } else {
                ForEach(asosProducts, id: \.id) { product in
                    productButton(product)
                }
            }
            if let error = store.purchaseError {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }
            Button("Restore Purchases") {
                Task { await store.restore() }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }

    private var footerSection: some View {
        Text("Annual plan includes a 7-day free trial. Subscriptions renew automatically. Cancel anytime in Settings → Subscriptions.")
            .font(.caption2)
            .foregroundColor(.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            .padding(.bottom)
    }

    private func featureRow(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.cyan)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            isPurchasing = true
            Task { await store.purchase(product); isPurchasing = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName).font(.headline)
                    if product.id == StoreManager.asosAnnualID {
                        Text("Best value · 7-day free trial")
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                    }
                }
                Spacer()
                Text(product.displayPrice).font(.headline)
            }
            .foregroundColor(.primary)
            .padding()
            .background(product.id == StoreManager.asosAnnualID ? Color.cyan.opacity(0.15) : Color(.systemGray6))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(product.id == StoreManager.asosAnnualID ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .disabled(isPurchasing)
    }
}

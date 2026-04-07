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

    private var relevantProducts: [Product] {
        switch mode {
        case .pro:
            return store.products.filter { $0.id == StoreManager.proID }
        case .asos:
            return store.products.filter {
                $0.id == StoreManager.asosMonthlyID || $0.id == StoreManager.asosAnnualID
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    heroSection
                    featureSection
                    productSection
                    footerSection
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if store.products.isEmpty { await store.loadProducts() }
            }
            .onChange(of: store.isProUser) { _, isPro in
                if mode == .pro, isPro { dismiss() }
            }
            .onChange(of: store.isAsosSubscriber) { _, isSub in
                if mode == .asos, isSub { dismiss() }
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: mode == .pro ? "star.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 50))
                .foregroundColor(.cyan)
            Text(mode == .pro ? "MetarMate Pro" : "ASOS Updates")
                .font(.title.bold())
            Text(mode == .pro
                 ? "Favorites, widgets, and Siri — one-time purchase"
                 : "Live weather between METARs")
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
            if mode == .pro {
                featureRow("star.fill", "Unlimited Favorites", "Save and organize as many airports as you fly")
                featureRow("rectangle.3.group", "All Widgets", "Home screen and lock screen widgets for your airports")
                featureRow("mic.fill", "Siri Shortcuts", "Ask Siri for weather at any airport")
            } else {
                featureRow("antenna.radiowaves.left.and.right", "5-Minute Updates", "ASOS data refreshes automatically — not just hourly METARs")
                featureRow("wind", "Wind Trend Strip", "See wind changes over the last hour at a glance")
                featureRow("arrow.triangle.2.circlepath", "METAR Delta", "Instantly see what changed since the last official report")
                featureRow("clock.arrow.circlepath", "Auto-Refresh", "Always current while you're on the detail page")
            }
        }
        .padding(.horizontal)
    }

    private var productSection: some View {
        VStack(spacing: 12) {
            if store.products.isEmpty {
                ProgressView("Loading…").padding()
            } else {
                ForEach(relevantProducts, id: \.id) { product in
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
        Group {
            if mode == .asos {
                if store.isAsosInFreePeriod {
                    Text("You have \(store.asosFreeDaysRemaining) days remaining in your free ASOS period.")
                        .font(.caption)
                        .foregroundColor(.cyan)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Text("Annual plan includes a 7-day free trial. Subscriptions renew automatically. Cancel anytime in Settings → Subscriptions.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("One-time purchase. No subscription required for Pro features.")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
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
                    if product.id == StoreManager.proID {
                        Text("One-time purchase")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(product.displayPrice).font(.headline)
            }
            .foregroundColor(.primary)
            .padding()
            .background(product.id == StoreManager.asosAnnualID || product.id == StoreManager.proID
                        ? Color.cyan.opacity(0.15) : Color(.systemGray6))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(product.id == StoreManager.asosAnnualID || product.id == StoreManager.proID
                              ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .disabled(isPurchasing)
    }
}

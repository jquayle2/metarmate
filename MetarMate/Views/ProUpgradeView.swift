import SwiftUI
import StoreKit

// MARK: - Pro Upgrade View
// Shown when non-Pro users tap the ASOS teaser or via settings.
struct ProUpgradeView: View {
    @ObservedObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 50))
                            .foregroundColor(.cyan)

                        Text("MetarMate Pro")
                            .font(.title.bold())

                        Text("Live ASOS weather between METARs")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // Feature list
                    VStack(alignment: .leading, spacing: 14) {
                        featureRow("antenna.radiowaves.left.and.right",
                                   "Live ASOS Data",
                                   "Weather updates every few minutes — not just hourly METARs")
                        featureRow("wind",
                                   "Wind Trend Strip",
                                   "See wind speed and direction changes over the last hour")
                        featureRow("arrow.triangle.2.circlepath",
                                   "METAR Delta",
                                   "Instantly see what changed since the last official report")
                        featureRow("clock.arrow.circlepath",
                                   "Auto-Refresh",
                                   "ASOS data refreshes automatically while you're on the page")
                    }
                    .padding(.horizontal)

                    // Product buttons
                    if store.products.isEmpty {
                        ProgressView("Loading plans…")
                            .padding()
                    } else {
                        VStack(spacing: 12) {
                            ForEach(store.products, id: \.id) { product in
                                productButton(product)
                            }
                        }
                        .padding(.horizontal)
                    }

                    if let error = store.purchaseError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal)
                    }

                    // Restore
                    Button("Restore Purchases") {
                        Task { await store.restore() }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    // Fine print
                    Text("Subscriptions renew automatically. Cancel anytime in Settings → Subscriptions.")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if store.products.isEmpty {
                    await store.loadProducts()
                }
            }
            .onChange(of: store.isProUser) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    private func featureRow(_ icon: String, _ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.cyan)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func productButton(_ product: Product) -> some View {
        Button {
            isPurchasing = true
            Task {
                await store.purchase(product)
                isPurchasing = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.headline)
                    if product.id == StoreManager.proAnnualID {
                        Text("Best value")
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                    }
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.headline)
            }
            .foregroundColor(.primary)
            .padding()
            .background(product.id == StoreManager.proAnnualID ? Color.cyan.opacity(0.15) : Color(.systemGray6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(product.id == StoreManager.proAnnualID ? Color.cyan.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .disabled(isPurchasing)
    }
}

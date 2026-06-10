import SwiftUI
import SwiftData
import Combine

// MARK: - AlertsViewModel
// Holds the read-only display evaluation for the watches list. checkNow runs the real pipeline
// (fires + persists), then refreshes the display.
@MainActor
final class AlertsViewModel: ObservableObject {
    @Published var displays: [String: AlertPipeline.WatchDisplay] = [:]
    @Published var isChecking = false
    @Published var isLoading = false

    func refresh(_ watches: [AirportWatch], in context: ModelContext) async {
        isLoading = true
        displays = await AlertPipeline.evaluateForDisplay(watches, in: context)
        isLoading = false
    }

    func checkNow(_ watches: [AirportWatch], in context: ModelContext) async {
        isChecking = true
        await AlertPipeline.checkNow(in: context)        // the proven pipeline: fetch → evaluate → notify → persist
        await refresh(watches, in: context)              // reflect any newly-persisted sides
        isChecking = false
    }
}

// MARK: - AlertsView
struct AlertsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<AirportWatch> { $0.isEnabled },
           sort: \AirportWatch.createdDate)
    private var watches: [AirportWatch]
    @Query(sort: \MinimumsProfile.name) private var profiles: [MinimumsProfile]
    @AppStorage("activeMinimumsProfileID") private var activeProfileID: String = ""
    @StateObject private var vm = AlertsViewModel()

    private var activeProfile: MinimumsProfile? {
        profiles.first { $0.uuid.uuidString == activeProfileID }
            ?? profiles.first { $0.name == "VFR day" }
            ?? profiles.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if watches.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(watches) { watch in
                            WatchRow(watch: watch, display: vm.displays[watch.icao])
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await vm.refresh(watches, in: context) }
                }
            }
            .navigationTitle("Alerts")
            .safeAreaInset(edge: .top) { profileSwitcher }
            .safeAreaInset(edge: .bottom) {
                if !watches.isEmpty { checkNowButton }
            }
        }
        .task(id: watches.map(\.icao)) { await vm.refresh(watches, in: context) }
        .onChange(of: activeProfileID) {
            // Switching the active profile re-evaluates every visible watch.
            Task { await vm.refresh(watches, in: context) }
        }
    }

    // Active-profile switcher, pinned at top.
    private var profileSwitcher: some View {
        Menu {
            ForEach(profiles) { profile in
                Button {
                    ActiveMinimumsProfile.set(profile.uuid)   // writes the active-profile pointer
                } label: {
                    if profile.uuid == activeProfile?.uuid {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                Text("Minimums:")
                    .foregroundColor(.secondary)
                Text(activeProfile?.name ?? "—")
                    .fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private var checkNowButton: some View {
        Button {
            Task { await vm.checkNow(watches, in: context) }
        } label: {
            HStack {
                if vm.isChecking { ProgressView().tint(.white) }
                Text(vm.isChecking ? "Checking…" : "Check Now")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(vm.isChecking)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.badge.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Alerts Yet")
                .font(.headline)
            Text("Add an airport to watch against your personal minimums. You'll be notified when its go/no-go status changes.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WatchRow
private struct WatchRow: View {
    let watch: AirportWatch
    let display: AlertPipeline.WatchDisplay?

    private var conditions: AlertConditions? { display?.conditions }
    private var verdict: Verdict? { display?.verdict }

    var body: some View {
        HStack(spacing: 0) {
            // (a) Left status strip — airport's current flight category (existing category colors).
            (conditions?.flightCategory.swiftUIColor ?? Color(.systemGray3))
                .frame(width: 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(watch.icao)
                        .font(.headline)
                    if let cat = conditions?.flightCategory {
                        FlightCategoryBadge(category: cat)
                    }
                    Spacer()
                    verdictBadge
                }

                // (c) Limiting factor(s) in plain language when NO-GO.
                if let v = verdict, v.newSide == .noGo, !v.failingFactors.isEmpty {
                    Text(v.failingFactors.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // (d) Source + freshness.
                if let c = conditions {
                    Text(freshness(c))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if display == nil {
                    Text("Checking…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("No weather data")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 8)
        }
    }

    // (b) Go/no-go verdict badge — red NO-GO, green GO (per spec; distinct from the category strip).
    @ViewBuilder private var verdictBadge: some View {
        if let v = verdict {
            let isNoGo = v.newSide == .noGo
            Text(isNoGo ? "NO-GO" : "GO")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(isNoGo ? Color.red : Color.green)
                .clipShape(Capsule())
        } else {
            Text("—")
                .font(.caption.bold())
                .foregroundColor(.secondary)
        }
    }

    private func freshness(_ c: AlertConditions) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(c.timestamp) / 60))
        let source = (c.source == .asos) ? "live ASOS" : "METAR"
        return "via \(source) · \(mins) min ago"
    }
}

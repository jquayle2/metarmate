import SwiftUI
import SwiftData
import Combine

// MARK: - AlertsViewModel
// Read-only display evaluation for the watches list. Refreshing shows verdicts but NEVER fires
// notifications or mutates lastSide — firing is the background task's job alone.
@MainActor
final class AlertsViewModel: ObservableObject {
    @Published var displays: [String: AlertPipeline.WatchDisplay] = [:]

    func refresh(_ watches: [AirportWatch], in context: ModelContext) async {
        displays = await AlertPipeline.evaluateForDisplay(watches, in: context)
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
    @State private var showAddSheet = false
    @State private var showProfiles = false

    private var activeProfile: MinimumsProfile? {
        profiles.first { $0.uuid.uuidString == activeProfileID }
            ?? profiles.first { $0.name == "VFR day" }
            ?? profiles.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header: profile switcher sits as a fixed band at the top; rows scroll under it
                // (a top safeAreaInset was colliding with the list/title).
                profileSwitcher
                Group {
                    if watches.isEmpty {
                        emptyState
                    } else {
                        List {
                            ForEach(watches) { watch in
                                WatchRow(watch: watch, display: vm.displays[watch.icao])
                                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 16))
                            }
                            .onDelete(perform: deleteWatches)
                        }
                        .listStyle(.plain)
                        .refreshable { await vm.refresh(watches, in: context) }   // pull-to-refresh
                    }
                }
            }
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSheet) { AddWatchView() }
            .sheet(isPresented: $showProfiles, onDismiss: {
                // Edits to the active profile should show immediately on return.
                Task { await vm.refresh(watches, in: context) }
            }) {
                ProfilesListView()
            }
        }
        .task(id: watches.map(\.icao)) {
            MinimumsProfile.ensureUniqueUUIDs(in: context)   // repair shared-uuid built-ins (once)
            await vm.refresh(watches, in: context)
            // 5-min auto-refresh, same pattern as the detail view. Read-only — never fires.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await vm.refresh(watches, in: context)
            }
        }
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
                    // SINGLE-select: only the active profile is checked. Compare by
                    // persistentModelID (always unique per row) so exactly one row checks.
                    if profile.persistentModelID == activeProfile?.persistentModelID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button {
                showProfiles = true
            } label: {
                Label("Manage Profiles…", systemImage: "slider.horizontal.3")
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
            Button {
                showAddSheet = true
            } label: {
                Label("Add Airport", systemImage: "plus")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func deleteWatches(at offsets: IndexSet) {
        for index in offsets { context.delete(watches[index]) }
        try? context.save()
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

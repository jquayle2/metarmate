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
        profiles.first { $0.activeToken == activeProfileID }
            ?? profiles.first { $0.uuid.uuidString == activeProfileID }   // legacy raw-uuid pointer
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
                                // Resolve the watch's ICAO to an Airport so the row can push
                                // WeatherDetailView, exactly like a Nearest row. Done once here
                                // (not per body pass). Unresolvable stations fall back to a
                                // non-tappable row rather than crashing.
                                let airport = AirportService.shared.airport(icao: watch.icao)
                                let row = WatchRow(watch: watch,
                                                   display: vm.displays[watch.icao],
                                                   airport: airport)
                                Group {
                                    if let airport {
                                        NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                            row
                                        }
                                    } else {
                                        row
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 16))
                                .listRowBackground(Color(.systemGray6).opacity(0.2))
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
            MinimumsProfile.backfillBuiltInKeys(in: context)   // assign stable starter keys (once)
            MinimumsProfile.ensureUniqueUUIDs(in: context)     // then de-dup, preserving the active choice
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
                    ActiveMinimumsProfile.set(profile)   // writes the active-profile pointer (stable token)
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
// Reads as a sibling of the Nearest list's AirportRowView (same left category strip, ICAO/IATA
// header, airport name, and "CLR · 10+SM · 180@19G30" conditions line) with the alert-specific
// elements layered on top: the GO/NO-GO verdict badge, the failing-factors line, and the
// "via METAR · N min ago" freshness line.
//
// COLOR AXIS (kept strictly separate — do not regress):
//   • Left strip + FlightCategoryBadge = CATEGORY axis (VFR/MVFR/IFR/LIFR).
//   • GO/NO-GO badge                   = VERDICT axis (red NO-GO / green GO).
//   • Wind text in the conditions line = WIND axis (amber/red only, otherwise secondary).
private struct WatchRow: View {
    let watch: AirportWatch
    let display: AlertPipeline.WatchDisplay?
    let airport: Airport?

    private var conditions: AlertConditions? { display?.conditions }
    private var verdict: Verdict? { display?.verdict }

    // CATEGORY axis — left strip color (falls back to gray when conditions are unknown).
    private var categoryColor: Color {
        conditions?.flightCategory.swiftUIColor ?? Color(.systemGray3)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left-edge flight category strip — matches AirportRowView's treatment exactly.
            Rectangle()
                .fill(categoryColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.vertical, 6)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    // ICAO prominent, IATA small/secondary, category badge inline.
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(airport?.icao ?? watch.icao)
                            .font(.system(.headline, design: .default).weight(.bold))
                            .foregroundColor(.primary)
                        if let iata = airport?.iata, !iata.isEmpty {
                            Text(iata)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        if let cat = conditions?.flightCategory {
                            FlightCategoryBadge(category: cat)
                        }
                    }

                    // Airport name line (sibling to Nearest), when the ICAO resolved.
                    if let name = airport?.name {
                        Text(name)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // Conditions summary ("CLR · 10+SM · 180@19G30") or a status placeholder.
                    if let c = conditions {
                        conditionsSummary(c)
                    } else if display == nil {
                        Text("Checking…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No weather data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Limiting factor(s) in plain language when NO-GO.
                    if let v = verdict, v.newSide == .noGo, !v.failingFactors.isEmpty {
                        Text(v.failingFactors.joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Source + freshness — the alert-specific provenance line.
                    if let c = conditions {
                        Text(freshness(c))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // VERDICT axis — GO/NO-GO badge, trailing (red NO-GO / green GO).
                verdictBadge
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)
        }
    }

    // VERDICT axis — must stay distinct from the category strip.
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

    // MARK: - Conditions line (built from AlertConditions, mirroring AirportRowView)

    @ViewBuilder private func conditionsSummary(_ c: AlertConditions) -> some View {
        let skyVis = skyVisString(c)
        let windStr = windString(c)
        let wColor = windColor(c)   // WIND axis — amber/red only

        HStack(spacing: 0) {
            Text(skyVis)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let wColor {
                Text(" · ")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(windStr)
                    .font(.caption)
                    .foregroundColor(wColor)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            } else {
                Text(" · \(windStr)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func skyVisString(_ c: AlertConditions) -> String {
        var parts: [String] = []
        if let ceiling = c.ceilingFeet {
            // AlertConditions keeps only ceiling height (coverage code is normalized away),
            // so label it with the conventional ceiling marker.
            parts.append("BKN \(ceiling / 100)")
        } else {
            parts.append("CLR")
        }
        let vis = c.visibilitySM >= 10 ? "10+SM" : "\(String(format: "%g", c.visibilitySM))SM"
        parts.append(vis)
        return parts.joined(separator: " · ")
    }

    private func windString(_ c: AlertConditions) -> String {
        if c.windSpeed == 0 { return "Calm" }
        let dir = c.windDirection.map { String(format: "%03d", $0) } ?? "VRB"
        if let gust = c.windGust { return "\(dir)@\(c.windSpeed)G\(gust)" }
        return "\(dir)@\(c.windSpeed)"
    }

    // WIND axis — amber/red only, matching AirportRowView's thresholds. nil = no wind emphasis.
    private func windColor(_ c: AlertConditions) -> Color? {
        let speed = c.windSpeed
        let gust = c.windGust ?? 0
        let spread = gust - speed
        if gust >= 20 || speed >= 25 || spread >= 15 { return .red }
        if gust >= 15 || speed >= 20 || spread >= 10 { return .orange }
        return nil
    }

    private func freshness(_ c: AlertConditions) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(c.timestamp) / 60))
        let source = (c.source == .asos) ? "live ASOS" : "METAR"
        return "via \(source) · \(mins) min ago"
    }
}

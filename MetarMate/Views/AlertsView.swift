import SwiftUI
import SwiftData
import Combine

// MARK: - AlertsViewModel
// Read-only display evaluation for the watches list. Refreshing shows verdicts but NEVER fires
// notifications or mutates lastSide — firing is the background task's job alone.
@MainActor
final class AlertsViewModel: ObservableObject {
    @Published var displays: [String: AlertPipeline.WatchDisplay] = [:]

    func refresh(_ watches: [AirportWatch], in context: ModelContext, force: Bool = false) async {
        displays = await AlertPipeline.evaluateForDisplay(watches, in: context, force: force)
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
    @ObservedObject private var store = StoreManager.shared
    @State private var showAddSheet = false
    @State private var showProfiles = false
    @State private var showProSheet = false

    private var canCustomize: Bool { ProGate.allows(.customProfiles, isPro: store.isProForUI) }
    /// Alerts are Pro (D#20). A lapsed or refunded user's watches stay stored, but nothing is
    /// evaluated or checked until Pro returns.
    private var alertsAllowed: Bool { ProGate.allows(.alerts, isPro: store.isProForUI) }

    private func refresh(force: Bool = false) async {
        guard alertsAllowed else { vm.displays = [:]; return }
        await vm.refresh(watches, in: context, force: force)
    }

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
                if let active = activeProfile, !active.isBuiltIn, !canCustomize,
                   let starter = ProfileAccess.fallbackStarter(profiles) {
                    Text(ProfileAccess.lapsedNotice(starterName: starter.name))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("lapsedProfilesNotice")
                }
                if !alertsAllowed, !watches.isEmpty {
                    Text("Alerts are paused. Your watches are saved and resume with MetarMate Pro.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("alertsPausedNotice")
                }
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
                                                   airport: airport,
                                                   paused: !alertsAllowed)
                                Group {
                                    if let airport {
                                        NavigationLink(destination: WeatherDetailView(airport: airport)) {
                                            row
                                        }
                                    } else {
                                        row
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 16))
                                .listRowBackground(Color.clear)
                            }
                            .onDelete(perform: deleteWatches)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .refreshable { await refresh(force: true) }   // pull-to-refresh: bypass cache freshness
                    }
                }
            }
            .background(IsobarBackground())
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { alertsAllowed ? (showAddSheet = true) : (showProSheet = true) } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("addWatchButton")
                }
            }
            .sheet(isPresented: $showAddSheet) { AddWatchView() }
            .sheet(isPresented: $showProfiles, onDismiss: {
                // Edits to the active profile should show immediately on return.
                Task { await refresh() }
            }) {
                ProfilesListView()
            }
            .sheet(isPresented: $showProSheet) {
                ProUpgradeView(mode: .pro)
            }
        }
        .task(id: watches.map(\.icao)) {
            MinimumsProfile.backfillBuiltInKeys(in: context)   // assign stable starter keys (once)
            MinimumsProfile.ensureUniqueUUIDs(in: context)     // then de-dup, preserving the active choice
            await refresh()
            // 5-min auto-refresh, same pattern as the detail view. Read-only — never fires.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
        .onChange(of: activeProfileID) {
            // Switching the active profile re-evaluates every visible watch.
            Task { await refresh() }
        }
    }

    // Active-profile switcher, pinned at top.
    private var profileSwitcher: some View {
        Menu {
            ForEach(profiles) { profile in
                Button {
                    // Starters are free; choosing a custom profile is Pro (D#19–20).
                    if profile.isBuiltIn || canCustomize {
                        ActiveMinimumsProfile.set(profile)   // writes the active-profile pointer (stable token)
                    } else {
                        showProSheet = true
                    }
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
                if alertsAllowed { showAddSheet = true } else { showProSheet = true }
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
    var paused = false   // alerts are Pro and Pro has lapsed: nothing is being checked

    private var conditions: AlertConditions? { display?.conditions }
    private var verdict: Verdict? { display?.verdict }
    // Shared wording and color rule with the detail screen and widgets.
    private var shown: VerdictDisplay? {
        guard let display, let verdict = display.verdict else { return nil }
        return VerdictDisplay(verdict, profile: display.profile)
    }

    // A station-less airport we've already tried (display present) with no METAR: advisory-only.
    // A GO/NO-GO verdict on estimated data would be misleading, so we mark & suppress it.
    private var isAdvisoryOnly: Bool {
        airport?.hasMetar == false && conditions == nil && display != nil
    }

    // CATEGORY axis — left strip color (brand category palette; gray when unknown).
    private var categoryColor: Color {
        if isNoCurrent { return ColorRules.flightCategoryColor(.unknown) }
        return ColorRules.flightCategoryColor(conditions?.flightCategory ?? .unknown)
    }

    // Over 75 min: no verdict, and the old category/conditions are withheld like the widget (D#4).
    private var isNoCurrent: Bool { verdict?.outcome == .noCurrent }

    var body: some View {
        HStack(spacing: 14) {
            // Left-edge category strip — solid for a real METAR, dashed neutral for a
            // station-less advisory airport (matches AirportRowView's treatment exactly).
            Group {
                if isAdvisoryOnly {
                    DashedRail(color: Brand.slate)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(categoryColor)
                }
            }
            .frame(width: 3)
            .frame(maxHeight: .infinity)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    // ICAO prominent, IATA small/secondary, category badge inline.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(airport?.icao ?? watch.icao)
                            .font(.avenir(19, .heavy))
                            .tracking(0.4)
                            .foregroundColor(Brand.cloud)
                        if let cat = conditions?.flightCategory, !isNoCurrent {
                            FlightCategoryBadge(category: cat)
                        }
                    }

                    // Airport name line (sibling to Nearest), when the ICAO resolved.
                    if let name = airport?.name {
                        Text(name)
                            .font(.avenir(14.5, .demibold))
                            .foregroundColor(Brand.fog2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    // Conditions summary ("CLR · 10+SM · 180@19G30") or a status placeholder.
                    Group {
                        if isNoCurrent {
                            Text("No current METAR")
                                .font(.avenir(12.5, .bold))
                                .foregroundColor(Brand.slate)   // neutral: amber is for wind and pressure only
                        } else if let c = conditions {
                            conditionsSummary(c)
                        } else if isAdvisoryOnly {
                            Text("Advisory weather only")
                                .font(.avenir(12.5, .bold))
                                .foregroundColor(Brand.slate)
                        } else if paused {
                            Text("Paused")
                                .font(.brandMono(13, weight: .medium))
                                .foregroundColor(Brand.slate)
                        } else if display == nil {
                            Text("Checking…")
                                .font(.brandMono(13, weight: .medium))
                                .foregroundColor(Brand.slate)
                        } else {
                            Text("No weather data")
                                .font(.brandMono(13, weight: .medium))
                                .foregroundColor(Brand.slate)
                        }
                    }
                    .padding(.top, 4)

                    // Limiting factor(s) in plain language when NO-GO; what couldn't be checked when
                    // CHECK (D#2: "CHECK: visibility not reported"); VRB qualifier on a GO (D#3).
                    if let line = verdictDetail {
                        Text(line)
                            .font(.avenir(12.5, .demibold))
                            .foregroundColor(Brand.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Source + freshness — the alert-specific provenance line. Late / no current
                    // METAR per D#4, from the observation time.
                    if let c = conditions {
                        Text(freshness(c))
                            .font(.avenir(11.5, .demibold))
                            // Late and no current METAR are neutral: amber is for wind and pressure only.
                            .foregroundColor(Brand.slate)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 8)

                // VERDICT axis — GO/NO-GO badge, trailing (red NO-GO / green GO).
                verdictBadge
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
    }

    // VERDICT axis — must stay distinct from the category strip.
    @ViewBuilder private var verdictBadge: some View {
        if isAdvisoryOnly {
            // Neutral "verify" affordance — never a GO/NO-GO verdict on estimated data.
            Text("ADVISORY")
                .font(.avenir(10.5, .heavy)).tracking(0.5)
                .foregroundColor(Brand.slate)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(Brand.slate.opacity(0.5), lineWidth: 1))
        } else if let shown, shown.tone != .neutral {
            VStack(alignment: .trailing, spacing: 3) {
                Text(shown.headline)
                    .font(.avenir(13, .heavy)).tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(shown.tone == .noGo ? Brand.dangerRed : Brand.vfrGreen))
                starterCaption
            }
            .accessibilityElement(children: .combine)
        } else if let shown, verdict?.outcome != .noCurrent {
            // Neutral: CHECK (D#2) or a late METAR's GO/NO-GO (D#4). The reason is on the detail line.
            VStack(alignment: .trailing, spacing: 3) {
                Text(shown.headline)
                    .font(.avenir(13, .heavy)).tracking(0.5)
                    .foregroundColor(Brand.cloud)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(Brand.slate, lineWidth: 1.5))
                starterCaption
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("—")
                .font(.avenir(13, .heavy))
                .foregroundColor(Brand.slate)
        }
    }

    // MARK: - Conditions line (built from AlertConditions, mirroring AirportRowView)

    private func conditionsSummary(_ c: AlertConditions) -> some View {
        // Whole wind token colored by the shared list rule (orange on gust/strong, green
        // CALM, neutral otherwise); sky/vis stay neutral — identical to AirportRowView.
        let wColor = c.windSpeed.map { ColorRules.windColor(speedKt: $0, gustKt: c.windGust) } ?? Brand.monoDim
        return (Text("\(skyVisString(c)) · ").foregroundColor(Brand.monoDim)
                + Text(windString(c)).foregroundColor(wColor))
            .font(.brandMono(13, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func skyVisString(_ c: AlertConditions) -> String {
        var parts: [String] = []
        if let sky = c.skyCode {
            parts.append(sky)   // METAR: shared token ("BKN 25" / "FEW 55" / "CLR" / "Sky —")
        } else if let ceiling = c.ceilingFeet {
            // Show the TRUE coverage code from the observation (OVC vs BKN is operationally
            // meaningful). If coverage is genuinely unavailable, show height alone rather than
            // guessing a prefix.
            if let cov = c.ceilingCoverage {
                parts.append("\(cov) \(ceiling / 100)")
            } else {
                parts.append("\(ceiling / 100)")
            }
        } else {
            parts.append("CLR")
        }
        let vis = c.visibilitySM.map { $0 >= 10 ? "10+SM" : "\(String(format: "%g", $0))SM" } ?? "—"
        parts.append(vis)
        return parts.joined(separator: " · ")
    }

    private func windString(_ c: AlertConditions) -> String {
        guard let spd = c.windSpeed else { return "—" }   // wind not reported (nil ≠ calm)
        if spd == 0 { return "Calm" }
        let dir = c.windIsVariable ? "VRB" : c.windDirection.map { String(format: "%03d", $0) } ?? "///"
        if let gust = c.windGust { return "\(dir)@\(spd)G\(gust)" }
        return "\(dir)@\(spd)"
    }

    // "vs VFR day starter" / "vs Night XC" under the badge: a verdict always names its profile, so a
    // starter verdict is never mistaken for the pilot's own minimums (D#19).
    @ViewBuilder private var starterCaption: some View {
        if let against = shown?.against {
            Text(against)
                .font(.avenir(10.5, .demibold))
                .foregroundColor(Brand.slate)
        }
    }

    private var verdictDetail: String? {
        guard let lines = shown?.lines, !lines.isEmpty else { return nil }
        return lines.joined(separator: " · ")
    }

    private func freshness(_ c: AlertConditions) -> String {
        let mins = max(0, Int(Date().timeIntervalSince(c.timestamp) / 60))
        let source = (c.source == .asos) ? "live ASOS" : "METAR"
        switch verdict?.outcome {
        case .noCurrent:
            return "Last report \(Self.spokenAge(mins)) ago"
        default:
            if let late = verdict?.lateMinutes { return "METAR late: \(late) min old" }
            return "via \(source) · \(mins) min ago"
        }
    }

    // "2 h 10 min" (D#4 wording).
    private static func spokenAge(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

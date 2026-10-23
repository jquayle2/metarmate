import SwiftUI
import SwiftData

// MARK: - VerdictCard
// The go/no-go verdict on the detail screen (free, D#19), against VerdictProfile.current(). Same
// engine, wording and color rule as Alerts and the widgets (VerdictEngine / VerdictDisplay).
// METAR only (D#1): it's handed the METAR, never the 5-minute ASOS observation. Not a layout
// section: always shown, directly under the header.
struct VerdictCard: View {
    let metar: Metar
    let icao: String
    var allowsSwitching = true    // false in the read-only test harness

    @Environment(\.modelContext) private var context
    @Query(sort: \MinimumsProfile.name) private var profiles: [MinimumsProfile]
    @AppStorage(ActiveMinimumsProfile.key) private var activeProfileID: String = ""
    @State private var profile: MinimumsProfile?

    var body: some View {
        Group {
            if let profile {
                // Re-evaluated every 30 s so late (65 min) and no current METAR (over 75) arrive on time.
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    let verdict = GoNoGoEvaluator.evaluate(profile, AlertConditions(from: metar),
                                                           previousSide: nil, icao: icao, now: tl.date)
                    let shown = VerdictDisplay(verdict, profile: GoNoGoEvaluator.snapshot(of: profile))
                    VerdictCardFace(shown: shown) { profileLabel(shown.against) }
                }
            } else {
                // Not EmptyView: .task never runs on an empty view, so the profile would never resolve.
                Color.clear.frame(height: 0)
            }
        }
        // Resolve outside body: resolve() can heal the stored pointer, which is a state write.
        .task(id: activeProfileID) { profile = VerdictProfile.current(in: context) }
        .onChange(of: profiles.map(\.persistentModelID)) { profile = VerdictProfile.current(in: context) }
    }

    // "vs VFR day starter ▾": tap to judge against another profile. Writes the one active-profile
    // pointer, so Alerts and the widgets follow.
    @ViewBuilder private func profileLabel(_ against: String) -> some View {
        let label = HStack(spacing: 4) {
            Text(against)
            if allowsSwitching {
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
        .font(.avenir(13, .demibold))
        .foregroundColor(Brand.slate)
        .lineLimit(1)
        .minimumScaleFactor(0.8)

        if allowsSwitching, profiles.count > 1 {
            Menu {
                ForEach(profiles) { p in
                    Button {
                        ActiveMinimumsProfile.set(p)
                    } label: {
                        let name = p.isBuiltIn ? "\(p.name) starter" : p.name
                        if p.persistentModelID == profile?.persistentModelID {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: { label }
            .accessibilityLabel("Minimums profile, \(against)")
        } else {
            label
        }
    }
}

// MARK: - VerdictCardFace
// The card's look, apart from the profile query and evaluation, so it renders the same for any
// VerdictDisplay (and in tests).
struct VerdictCardFace<ProfileLabel: View>: View {
    let shown: VerdictDisplay
    @ViewBuilder let profileLabel: () -> ProfileLabel

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(railColor(shown.tone))
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                // Headline and profile on one row when they fit, else the profile under the headline.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        headline
                        profileLabel().fixedSize()
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        headline
                        profileLabel()
                    }
                }
                ForEach(shown.lines, id: \.self) { line in
                    Text(line)
                        .font(.avenir(14, .demibold))
                        .foregroundColor(Brand.cloud)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(shown.status)
                    .font(.avenir(12, .demibold))
                    .foregroundColor(Brand.slate)
            }
            .padding(.vertical, 2)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                .fill(Brand.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cardRadius, style: .continuous)
                        .stroke(Brand.cardBorder, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
    }

    private var headline: some View {
        Text(shown.headline)
            .font(.avenir(shown.headline.count > 5 ? 20 : 26, .heavy))
            .tracking(0.6)
            .foregroundColor(headlineColor(shown.tone))
            .lineLimit(1)
            .fixedSize()
    }

    // Green/red only for a current GO/NO-GO; everything else neutral. No category colors here.
    private func railColor(_ tone: VerdictDisplay.Tone) -> Color {
        switch tone {
        case .go:      return Brand.vfrGreen
        case .noGo:    return Brand.dangerRed
        case .neutral: return Brand.slate
        }
    }

    private func headlineColor(_ tone: VerdictDisplay.Tone) -> Color {
        tone == .neutral ? Brand.cloud : railColor(tone)
    }
}

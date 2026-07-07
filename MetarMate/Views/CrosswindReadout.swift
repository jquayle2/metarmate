import SwiftUI

/// The 8A/8B BIG readout — the glanceable answer, kept large on purpose (usable in
/// turbulence): a centered "CROSSWIND" label, a thick left/right arrow + the crosswind
/// number `17`G`24` in mono at ~66px (sustained value-red, the gust `G24` caution-orange),
/// then either the favorable HEADWIND (green) or, on a tailwind, an unmissable red
/// TAILWIND banner with the readout border flipped to danger red.
struct CrosswindReadout: View {
    let crosswind: Int
    let gustCrosswind: Int?      // nil when steady (no G part)
    let headwind: Int           // signed: positive = headwind, negative = tailwind
    let side: String            // "R", "L", or "" (aligned)
    let runway: Int
    let windDirDisplay: Int     // already rounded to tens
    let windSpeed: Int
    let gustSpeed: Int?
    var onFlipRunway: (() -> Void)? = nil

    private var isTailwind: Bool { headwind < 0 }
    private var sideRight: Bool { side != "L" }
    private var windRecap: String {
        "RWY \(String(format: "%02d", runway)) · \(String(format: "%03d", windDirDisplay))@\(windSpeed)\(gustSpeed.map { "G\($0)" } ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            TrackedLabel(text: "Crosswind", color: Brand.slate, size: 11, tracking: 3.0)

            // Big crosswind number, flanked by an arrow on the wind's source side pointing
            // the way it pushes you: from the left → "→ 12"; from the right → "12 ←".
            HStack(alignment: .center, spacing: 14) {
                if crosswind > 0 && !sideRight { sideArrow(pointsRight: true) }
                crosswindNumber
                if crosswind > 0 && sideRight { sideArrow(pointsRight: false) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.top, 8)

            if isTailwind {
                tailwindBanner
                Text(windRecap)
                    .font(.brandMono(12, weight: .medium))
                    .foregroundColor(Brand.monoDim2)
                    .padding(.top, 14)
            } else {
                Rectangle().fill(Brand.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 12)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TrackedLabel(text: "Headwind", color: Brand.slate, size: 13, tracking: 2.6)
                    Text("\(headwind)")
                        .font(.brandMono(40, weight: .bold))
                        .foregroundColor(Brand.vfrGreen)
                    Text("kt")
                        .font(.avenir(15, .bold))
                        .foregroundColor(Brand.slate)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(isTailwind ? Brand.dangerRed.opacity(0.35) : Brand.cardBorder,
                    lineWidth: isTailwind ? 1.5 : 1))
        .overlay(alignment: .topTrailing) { flipHint }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onFlipRunway?() }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var flipHint: some View {
        if onFlipRunway != nil {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10, weight: .bold))
                Text("FLIP").font(.avenir(9.5, .heavy)).tracking(1.0)
            }
            .foregroundColor(Brand.slate)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .padding(10)
        }
    }

    private func sideArrow(pointsRight: Bool) -> some View {
        Image(systemName: pointsRight ? "arrow.right" : "arrow.left")
            .font(.system(size: 38, weight: .bold))
            .foregroundColor(Brand.valueRed)
    }

    private var crosswindNumber: Text {
        var t = Text("\(crosswind)").font(.brandMono(66, weight: .bold)).foregroundColor(Brand.valueRed)
        if let g = gustCrosswind, g > crosswind {
            t = t
                + Text("G").font(.brandMono(32, weight: .bold)).foregroundColor(Brand.cautionOrange)
                + Text("\(g)").font(.brandMono(66, weight: .bold)).foregroundColor(Brand.valueRed)
        }
        return t
    }

    private var tailwindBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Brand.dangerRed)
            Text("TAILWIND \(abs(headwind)) kt")
                .font(.avenir(22, .heavy))
                .tracking(0.5)
                .foregroundColor(Brand.valueRed)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Brand.dangerRed.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Brand.dangerRed.opacity(0.6), lineWidth: 1.5))
        .padding(.top, 12)
    }
}

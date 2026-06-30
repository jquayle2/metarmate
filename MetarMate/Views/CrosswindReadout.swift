import SwiftUI

/// Wind-components hero (visual refresh — badge 4A): a runway/wind vector diagram beside
/// a stacked component readout, under a "WIND COMPONENTS" front-line header with a Flip chip,
/// and a mono footer recapping the runway + wind. The result is a *diagram*, not a lone number.
struct CrosswindReadout: View {
    let crosswind: Int
    let gustCrosswind: Int?
    let headwind: Int
    let side: String
    let color: Color
    let runway: Int
    let windDirection: Int
    let windSpeed: Int
    let gustSpeed: Int?
    var onFlipRunway: (() -> Void)? = nil

    private var sideRight: Bool { side != "L" }   // "" (aligned) and "R" draw to the right
    private var reciprocal: Int { runway > 18 ? runway - 18 : runway + 18 }
    private var windDirDisplay: Int { windDirection == 0 ? 360 : windDirection }

    var body: some View {
        VStack(spacing: 0) {
            // Header: WIND COMPONENTS · front-line · Flip chip
            HStack(spacing: 10) {
                TrackedLabel(text: "Wind Components", color: Brand.slate, size: 10, tracking: 2.4)
                FrontLine()
                if let onFlipRunway {
                    Button(action: onFlipRunway) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("Flip")
                        }
                        .font(.avenir(11, .bold))
                        .foregroundColor(Brand.slate)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(red: 219/255, green: 221/255, blue: 227/255).opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)

            // Body: vector diagram + stacked component readout
            HStack(alignment: .center, spacing: 10) {
                CrosswindDiagramView(
                    runwayIdent: String(format: "%02d", runway),
                    reciprocalIdent: String(format: "%02d", reciprocal),
                    windDirDeg: windDirDisplay,
                    runwayHeadingDeg: runway * 10,
                    crosswind: crosswind,
                    headwind: headwind,
                    sideRight: sideRight
                )

                VStack(alignment: .leading, spacing: 9) {
                    crosswindReadout
                    Rectangle().fill(Brand.cardBorder).frame(height: 1)
                    alongReadout
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer: mono runway + wind recap
            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.top, 10)
            Text("RWY \(String(format: "%02d", runway)) · \(String(format: "%03d", windDirDisplay))@\(windSpeed)\(gustSpeed.map { "G\($0)" } ?? "")")
                .font(.brandMono(11.5, weight: .medium))
                .foregroundColor(Brand.monoDim2)
                .frame(maxWidth: .infinity)
                .padding(.top, 9)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .brandCard()
    }

    private var crosswindReadout: some View {
        VStack(alignment: .leading, spacing: 3) {
            TrackedLabel(text: "Crosswind \(sideRight ? "←" : "→")", color: Brand.slate,
                         size: 10, tracking: 1.8)
            crosswindValue
            Text(side == "L" ? "from left" : (side == "R" ? "from right" : "aligned"))
                .font(.avenir(11, .demibold))
                .foregroundColor(Brand.slate)
        }
    }

    private var crosswindValue: some View {
        var t = Text("\(crosswind)").foregroundColor(Brand.valueRed)
        if let g = gustCrosswind, g > crosswind {
            t = t + Text("G").font(.brandMono(16, weight: .bold)).foregroundColor(Brand.cautionOrange)
                  + Text("\(g)").foregroundColor(Brand.valueRed)
        }
        return (t + Text(" kt").font(.brandMono(13, weight: .medium)).foregroundColor(Brand.slate))
            .font(.brandMono(27, weight: .bold))
    }

    @ViewBuilder
    private var alongReadout: some View {
        let isTailwind = headwind < 0
        VStack(alignment: .leading, spacing: 3) {
            TrackedLabel(text: isTailwind ? "Tailwind ↑" : "Headwind ↓", color: Brand.slate,
                         size: 10, tracking: 1.8)
            (Text("\(abs(headwind))").foregroundColor(isTailwind ? Brand.dangerRed : Brand.vfrGreen)
             + Text(" kt").font(.brandMono(13, weight: .medium)).foregroundColor(Brand.slate))
                .font(.brandMono(27, weight: .bold))
            Text(isTailwind ? "unfavorable" : "favorable")
                .font(.avenir(11, .demibold))
                .foregroundColor(Brand.slate)
        }
    }
}

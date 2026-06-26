import SwiftUI

/// Big crosswind number with L/R arrows, headwind/tailwind line, and Vref/flap
/// advisories. Ported from the XW Calc app for the contextual crosswind keypad sheet.
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

    private var gustAddKts: Int? {
        guard let gust = gustSpeed, gust > windSpeed else { return nil }
        let add = (gust - windSpeed + 1) / 2
        return add > 0 ? add : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("CROSSWIND")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(Color(white: 0.4))
                if onFlipRunway != nil {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(white: 0.25))
                }
            }

            // Main crosswind number with arrows
            HStack(spacing: 6) {
                if side == "L" {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundColor(color)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(crosswind)")
                        .font(.system(size: 96, weight: .heavy, design: .rounded))
                        .foregroundColor(color)

                    if let gust = gustCrosswind, gust > crosswind {
                        Text("G")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(color.opacity(0.8))
                        Text("\(gust)")
                            .font(.system(size: 96, weight: .heavy, design: .rounded))
                            .foregroundColor(color)
                    }
                }

                if side == "R" {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 44, weight: .heavy))
                        .foregroundColor(color)
                }
            }
            .minimumScaleFactor(0.5)
            .lineLimit(1)

            // Headwind/Tailwind line
            if headwind < 0 {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                        Text("TAILWIND")
                        Text("\(abs(headwind)) kt")
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 22))
                    }
                    .font(.system(size: 26, weight: .heavy, design: .monospaced))
                    .foregroundColor(.red)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.red.opacity(0.4), lineWidth: 1)
                        )
                )
            } else {
                HStack(spacing: 6) {
                    Text("HEADWIND")
                        .foregroundColor(Color(white: 0.45))
                    Text("\(abs(headwind)) kt")
                        .foregroundColor(.green)
                }
                .font(.system(size: 22, weight: .bold, design: .monospaced))
            }

            // Winds line below
            HStack(spacing: 10) {
                Text("RWY \(String(format: "%02d", runway))")
                    .foregroundColor(Color(white: 0.35))
                Text("·").foregroundColor(Color(white: 0.2))
                Group {
                    let dir = windDirection == 0 ? 360 : windDirection
                    let g = gustSpeed.map { "G\($0)" } ?? ""
                    Text("\(String(format: "%03d", dir))@\(windSpeed)\(g)")
                        .foregroundColor(Color(white: 0.35))
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .monospaced))

            // Advisories
            VStack(spacing: 4) {
                if let addKts = gustAddKts {
                    Text("Increase Vref by \(addKts) kt")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                }

                if crosswind > 10 {
                    Text("Consider reducing flaps")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(color.opacity(0.15), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onFlipRunway?()
        }
    }
}

//
//  AdaptiveStripPrimitives.swift
//  MetarMate
//
//  The two genuinely shared, novel visual primitives behind the TAF adaptive hero and the
//  METAR History wind strip — the pieces the design spec wants both sections to "read as
//  one system." Everything else about those two sections (columns, delta cards, the
//  pressure card) is specific enough to its own call site that it lives directly in
//  WeatherDetailView.swift instead of here.
//

import SwiftUI

/// Segmented duration/index-weighted color bar — the shared ribbon under both the TAF hero
/// row and the METAR History wind strip. Zero awareness of TAF vs. History; the caller
/// builds the segments.
struct CategoryRibbon: View {
    struct Segment: Identifiable {
        let id = UUID()
        let color: Color
        let weight: Double   // relative width — period duration (TAF) or 1.0 per sample (History)
        var isCurrent: Bool = false
    }

    let segments: [Segment]
    var height: CGFloat = 6

    private var totalWeight: Double { max(segments.reduce(0) { $0 + $1.weight }, 0.001) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(segments) { seg in
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(seg.color)
                        .frame(width: max(4, geo.size.width * (seg.weight / totalWeight)))
                        .overlay(
                            seg.isCurrent
                                ? RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                                    .stroke(Brand.cloud.opacity(0.6), lineWidth: 1)
                                : nil
                        )
                }
            }
        }
        .frame(height: height)
    }
}

/// Compact rotatable wind-direction glyph — a simple shaft + arrowhead pointing toward the
/// compass bearing (clockwise from north/up), not full synoptic barb notation (no feathers/
/// pennants); the adjacent mono value text carries the numeric precision. Calm/variable
/// renders as a hollow circle. Faithful port of the handoff's small wind-glyph SVG
/// (viewBox 0 0 40 40).
struct WindBarbGlyph: View {
    let directionDeg: Int?     // nil = calm/variable; degrees true, compass convention
    let color: Color
    var size: CGFloat = 22

    private let box: CGFloat = 40
    private let center = CGPoint(x: 20, y: 20)

    var body: some View {
        Canvas { ctx, sz in
            let sx = sz.width / box
            let sy = sz.height / box
            func P(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }

            guard let dir = directionDeg else {
                let r: CGFloat = 6
                let rect = CGRect(x: (center.x - r) * sx, y: (center.y - r) * sy,
                                  width: r * 2 * sx, height: r * 2 * sy)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                           style: StrokeStyle(lineWidth: 2.6 * sx))
                return
            }

            let rad = Double(dir) * .pi / 180
            func rotated(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let dx = x - center.x, dy = y - center.y
                let rx = dx * CGFloat(cos(rad)) - dy * CGFloat(sin(rad))
                let ry = dx * CGFloat(sin(rad)) + dy * CGFloat(cos(rad))
                return CGPoint(x: center.x + rx, y: center.y + ry)
            }

            let tail = rotated(20, 29)
            let tip = rotated(20, 11)
            var shaft = Path()
            shaft.move(to: P(tail)); shaft.addLine(to: P(tip))
            ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 2.6 * sx, lineCap: .round))

            let headL = rotated(16, 18)
            let headR = rotated(24, 18)
            var head = Path()
            head.move(to: P(tip)); head.addLine(to: P(headL)); head.addLine(to: P(headR)); head.closeSubpath()
            ctx.fill(head, with: .color(color))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)   // decorative; adjacent value text carries the meaning
    }
}

/// Small Canvas line chart for the pressure-trend card. Same family as TrendArrowView
/// (Canvas + normalized coordinate space) but data-driven instead of fixed geometry.
struct PressureSparkline: View {
    let values: [Double]     // oldest-first; caller guards count >= 2 before showing
    var color: Color = Brand.fog
    var height: CGFloat = 28

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return }
            let range = max(hi - lo, 0.01)   // avoid divide-by-zero on a flat series
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: size.height * (1 - CGFloat((values[i] - lo) / range)))
            }
            var path = Path(); path.move(to: point(0))
            for i in 1..<values.count { path.addLine(to: point(i)) }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
                     with: .color(color))
        }
        .frame(height: height)
        .accessibilityHidden(true)   // decorative; the numeric delta text carries the meaning
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            WindBarbGlyph(directionDeg: nil, color: Brand.monoDim)
            WindBarbGlyph(directionDeg: 0, color: Brand.cautionOrange)
            WindBarbGlyph(directionDeg: 90, color: Brand.cautionOrange)
            WindBarbGlyph(directionDeg: 190, color: Brand.cautionOrange)
        }
        CategoryRibbon(segments: [
            .init(color: Brand.vfrGreen, weight: 4),
            .init(color: Brand.mvfrBlue, weight: 3),
            .init(color: Brand.dangerRed, weight: 5, isCurrent: true),
        ])
        .frame(width: 240)
        PressureSparkline(values: [30.10, 30.02, 29.92, 29.78], color: Brand.cautionOrange)
            .frame(width: 200)
    }
    .padding(40)
    .background(Brand.navy)
}

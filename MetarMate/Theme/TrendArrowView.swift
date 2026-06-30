//
//  TrendArrowView.swift
//  MetarMate
//
//  The brand's signature "where it's heading" mark: a solid lower front-curve with
//  three dots continuing into a dashed arrow. Points UP for improving/stable
//  (accent orange) and DOWN for deteriorating (danger red).
//
//  Geometry is a faithful port of the handoff SVG paths (viewBox 0 0 120 60).
//

import SwiftUI

struct TrendArrowView: View {
    let up: Bool
    let color: Color

    /// Convenience: derive direction + color from a TrendDirection via the shared rules.
    init(direction: TrendDirection) {
        let style = ColorRules.trendStyle(direction)
        self.up = style.up
        self.color = style.color
    }

    init(up: Bool, color: Color) {
        self.up = up
        self.color = color
    }

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 120
            let sy = size.height / 60
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
            let lw = 3.5 * sx
            let dashLw = 3.0 * sx
            let dotR = 4 * sx

            // Curve + dot anchors + dashed-arrow endpoints differ only by vertical mirror.
            let curveStart: CGPoint
            let curveCtrl: CGPoint
            let curveEnd = p(72, 30)
            let dots: [CGPoint]
            let tip: CGPoint
            let head: [CGPoint]   // two relative offsets from the tip, closed

            if up {
                curveStart = p(6, 48)
                curveCtrl  = p(40, 46)
                dots = [p(20, 46.5), p(40, 44), p(58, 37)]
                tip = p(108, 12)
                head = [p(108, 12), p(97, 13), p(103, 22)]
            } else {
                curveStart = p(6, 14)
                curveCtrl  = p(40, 16)
                dots = [p(20, 15.5), p(40, 17.5), p(58, 25)]
                tip = p(107, 49)
                head = [p(107, 49), p(106, 38), p(97, 43)]
            }

            // Front curve (solid).
            var curve = Path()
            curve.move(to: curveStart)
            curve.addQuadCurve(to: curveEnd, control: curveCtrl)
            ctx.stroke(curve, with: .color(color),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round))

            // The three "front" dots.
            for d in dots {
                ctx.fill(Path(ellipseIn: CGRect(x: d.x - dotR, y: d.y - dotR,
                                                width: dotR * 2, height: dotR * 2)),
                         with: .color(color))
            }

            // Dashed arrow shaft from the curve end to the tip.
            var shaft = Path()
            shaft.move(to: curveEnd)
            shaft.addLine(to: tip)
            ctx.stroke(shaft, with: .color(color),
                       style: StrokeStyle(lineWidth: dashLw, lineCap: .round,
                                          dash: [2 * sx, 7 * sx]))

            // Arrowhead (filled triangle).
            var arrow = Path()
            arrow.move(to: head[0])
            arrow.addLine(to: head[1])
            arrow.addLine(to: head[2])
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(color))
        }
        .frame(width: 74, height: 44)
        .accessibilityLabel(up ? "Trend improving or stable" : "Trend deteriorating")
    }
}

#Preview {
    HStack(spacing: 24) {
        TrendArrowView(up: true, color: Brand.accentOrange)
        TrendArrowView(up: false, color: Brand.dangerRed)
    }
    .padding(40)
    .background(Brand.navy)
}

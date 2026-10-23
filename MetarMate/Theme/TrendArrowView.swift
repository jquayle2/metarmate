//
//  TrendArrowView.swift
//  MetarMate
//
//  The brand's signature "where it's heading" mark: a solid lower front-curve with
//  three dots continuing into a dashed arrow. Points UP for improving, DOWN for
//  deteriorating (danger red), LEVEL for steady or mixed; unknown is a level slate mark
//  with no arrowhead (P3: steady/mixed/unknown used to point up).
//
//  Geometry is a faithful port of the handoff SVG paths (viewBox 0 0 120 60).
//

import SwiftUI

struct TrendArrowView: View {
    enum Heading { case up, down, level, unknown }

    let heading: Heading
    let color: Color
    let accessibilityText: String

    /// Direction + color from a TrendDirection via the shared rules. `mixed`: some axes improving
    /// and others deteriorating — drawn level, and said as mixed.
    init(direction: TrendDirection, mixed: Bool = false) {
        let style = ColorRules.trendStyle(mixed ? .steady : direction)
        self.heading = style.heading
        self.color = style.color
        if mixed {
            accessibilityText = "Trend mixed"
        } else {
            switch direction {
            case .improving:     accessibilityText = "Trend improving"
            case .steady:        accessibilityText = "Trend steady"
            case .deteriorating: accessibilityText = "Trend deteriorating"
            case .unknown:       accessibilityText = "Trend unknown"
            }
        }
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

            switch heading {
            case .up:
                curveStart = p(6, 48)
                curveCtrl  = p(40, 46)
                dots = [p(20, 46.5), p(40, 44), p(58, 37)]
                tip = p(108, 12)
                head = [p(108, 12), p(97, 13), p(103, 22)]
            case .down:
                curveStart = p(6, 14)
                curveCtrl  = p(40, 16)
                dots = [p(20, 15.5), p(40, 17.5), p(58, 25)]
                tip = p(107, 49)
                head = [p(107, 49), p(106, 38), p(97, 43)]
            case .level, .unknown:
                curveStart = p(6, 32)
                curveCtrl  = p(40, 30)
                dots = [p(20, 31.5), p(40, 30.5), p(58, 30)]
                tip = p(108, 30)
                head = [p(108, 30), p(98, 24), p(98, 36)]
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

            // Arrowhead (filled triangle). None for unknown: no direction to point in.
            guard heading != .unknown else { return }
            var arrow = Path()
            arrow.move(to: head[0])
            arrow.addLine(to: head[1])
            arrow.addLine(to: head[2])
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(color))
        }
        .frame(width: 74, height: 44)
        .accessibilityLabel(accessibilityText)
    }
}

#Preview {
    HStack(spacing: 24) {
        TrendArrowView(direction: .improving)
        TrendArrowView(direction: .steady)
        TrendArrowView(direction: .deteriorating)
        TrendArrowView(direction: .unknown)
    }
    .padding(40)
    .background(Brand.navy)
}

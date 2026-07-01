//
//  CrosswindDiagramView.swift
//  MetarMate
//
//  The 8B "done" result: the crosswind answer drawn as a diagram. Two faint compass
//  rings + an "N" mark, the selected runway pointing up (dark strip, dashed grey
//  centerline, threshold labels), the wind as a dashed caution-orange arrow at its
//  relative bearing, and the decomposed components from the aircraft node — crosswind
//  (red, across, "XW") and headwind (green, favorable, "HW") / tailwind (red, up).
//
//  Faithful port of the handoff SVG (viewBox 0 0 300 300, rendered ~272pt). The
//  geometry is static in spirit but driven by the live crosswind math.
//

import SwiftUI

struct CrosswindDiagramView: View {
    var runwayIdent: String        // bottom threshold label, e.g. "07"
    var reciprocalIdent: String    // top threshold label, e.g. "25"
    var windDirDeg: Int            // actual wind direction (for the label + bearing)
    var runwayHeadingDeg: Int      // runway magnetic/most-aligned heading, e.g. 70
    var crosswind: Int             // sustained crosswind component (kt)
    var headwind: Int              // signed: positive = headwind, negative = tailwind
    var sideRight: Bool            // true = wind from the right

    // viewBox space (matches the handoff SVG).
    private let box = CGSize(width: 300, height: 300)
    private let center = CGPoint(x: 150, y: 150)
    private let outerR: CGFloat = 132
    private let innerR: CGFloat = 90

    // Rendered size (the keypad-replacing result; kept tight so the whole screen fits).
    private let renderSize: CGFloat = 226

    /// Wind bearing relative to the runway-up frame, normalized to -180…180.
    private var angleOff: Double {
        var a = Double(windDirDeg - runwayHeadingDeg).truncatingRemainder(dividingBy: 360)
        if a > 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }

    private func pt(bearing: Double, radius: CGFloat) -> CGPoint {
        let r = bearing * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(sin(r)),
                       y: center.y - radius * CGFloat(cos(r)))
    }

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / box.width
            let sy = size.height / box.height
            func P(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
            func L(_ a: CGPoint, _ b: CGPoint, color: Color, w: CGFloat,
                   dash: [CGFloat] = []) {
                var path = Path()
                path.move(to: P(a)); path.addLine(to: P(b))
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: w * sx, lineCap: .round,
                                              dash: dash.map { $0 * sx }))
            }
            func fillTriangle(_ pts: [CGPoint], _ color: Color) {
                var path = Path()
                path.move(to: P(pts[0]))
                path.addLine(to: P(pts[1]))
                path.addLine(to: P(pts[2]))
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            }
            func ring(_ radius: CGFloat, _ color: Color, w: CGFloat = 1, dash: [CGFloat] = []) {
                let rect = CGRect(x: (center.x - radius) * sx, y: (center.y - radius) * sy,
                                  width: radius * 2 * sx, height: radius * 2 * sy)
                ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                           style: StrokeStyle(lineWidth: w * sx, dash: dash.map { $0 * sx }))
            }

            let ringTint = Color(red: 219/255, green: 221/255, blue: 227/255)

            // Two concentric compass rings — solid + dashed outer, faint inner.
            ring(outerR, ringTint.opacity(0.10), w: 1)
            ring(outerR, ringTint.opacity(0.05), w: 1, dash: [2, 8])
            ring(innerR, ringTint.opacity(0.06), w: 1)

            // North mark.
            ctx.draw(Text("N").font(.brandMono(11, weight: .bold))
                        .foregroundColor(Brand.monoDim2),
                     at: P(CGPoint(x: 150, y: 28)), anchor: .center)

            // Runway strip (points up).
            let stripRect = CGRect(x: 132 * sx, y: 44 * sy, width: 36 * sx, height: 212 * sy)
            ctx.fill(Path(roundedRect: stripRect, cornerRadius: 6 * sx),
                     with: .color(Color(hex: "#0C2034")))
            ctx.stroke(Path(roundedRect: stripRect, cornerRadius: 6 * sx),
                       with: .color(ringTint.opacity(0.18)), lineWidth: 1.5 * sx)

            // Dashed grey centerline (provenance-neutral: NOT orange).
            L(CGPoint(x: 150, y: 62), CGPoint(x: 150, y: 238),
              color: ringTint.opacity(0.3), w: 2.5, dash: [10, 12])

            // Threshold labels.
            ctx.draw(Text(runwayIdent).font(.brandMono(15, weight: .heavy))
                        .foregroundColor(Brand.cloud),
                     at: P(CGPoint(x: 150, y: 246)), anchor: .center)
            ctx.draw(Text(reciprocalIdent).font(.brandMono(12, weight: .bold))
                        .foregroundColor(Brand.monoDim2),
                     at: P(CGPoint(x: 150, y: 52)), anchor: .center)

            // Wind arrow: dashed caution-orange, from the outer ring inward to the aircraft.
            let windOuter = pt(bearing: angleOff, radius: 128)
            let windInner = pt(bearing: angleOff, radius: 40)
            L(windOuter, windInner, color: Brand.cautionOrange, w: 4, dash: [5, 7])
            // Arrowhead at the inner end, pointing toward center.
            let windHeadBase = pt(bearing: angleOff, radius: 52)
            let perp = angleOff + 90
            let hb1 = pt2(bearing: perp, dist: 7, base: windHeadBase)
            let hb2 = pt2(bearing: perp + 180, dist: 7, base: windHeadBase)
            fillTriangle([windInner, hb1, hb2], Brand.cautionOrange)
            // Wind label just outside the ring — clamped inside the viewBox so the full
            // value (e.g. "200°") never clips at the canvas edge for any wind bearing.
            var windLabelAt = pt(bearing: angleOff, radius: 150)
            windLabelAt.x = min(max(windLabelAt.x, 26), box.width - 26)
            windLabelAt.y = min(max(windLabelAt.y, 16), box.height - 16)
            ctx.draw(Text("\(windDirDeg)°").font(.brandMono(13, weight: .bold))
                        .foregroundColor(Brand.cautionOrange),
                     at: P(windLabelAt), anchor: .center)

            // Aircraft node.
            let nodeR: CGFloat = 6
            ctx.fill(Path(ellipseIn: CGRect(x: (center.x - nodeR) * sx, y: (center.y - nodeR) * sy,
                                            width: nodeR * 2 * sx, height: nodeR * 2 * sy)),
                     with: .color(Brand.cloud))

            // Component scale (px per kt in viewBox space), capped near the inner ring.
            let scale: CGFloat = 4.2
            func len(_ kt: Int) -> CGFloat { min(CGFloat(abs(kt)) * scale, 84) }

            // Thin shaft + a long, narrow arrowhead. The shaft stops at the arrowhead base so
            // the round line-cap never pokes past the tip (which blunted the old arrows).
            let shaftW: CGFloat = 4      // thinner
            let ahLen: CGFloat = 15      // pointier: long…
            let ahHalf: CGFloat = 5      // …and narrow
            /// Draw a component arrow from center toward `tip` along a unit vector (ux, uy).
            func arrow(_ tip: CGPoint, ux: CGFloat, uy: CGFloat, _ color: Color) {
                let base = CGPoint(x: tip.x - ux * ahLen, y: tip.y - uy * ahLen)
                L(center, base, color: color, w: shaftW)
                // Perpendicular to the arrow direction for the two base corners.
                let px = -uy, py = ux
                fillTriangle([tip,
                              CGPoint(x: base.x + px * ahHalf, y: base.y + py * ahHalf),
                              CGPoint(x: base.x - px * ahHalf, y: base.y - py * ahHalf)], color)
            }

            // Crosswind — horizontal, red. Wind from right pushes left, and vice-versa.
            let xwLen = len(crosswind)
            if crosswind > 0 {
                let dirX: CGFloat = sideRight ? -1 : 1
                arrow(CGPoint(x: center.x + dirX * xwLen, y: center.y), ux: dirX, uy: 0, Brand.dangerRed)
            }

            // Along-runway — vertical. Headwind points down (green); tailwind up (red).
            let hwLen = len(headwind)
            if headwind > 0 {
                arrow(CGPoint(x: center.x, y: center.y + hwLen), ux: 0, uy: 1, Brand.vfrGreen)
            } else if headwind < 0 {
                arrow(CGPoint(x: center.x, y: center.y - hwLen), ux: 0, uy: -1, Brand.dangerRed)
            }
        }
        .frame(width: renderSize, height: renderSize)
        .accessibilityLabel(
            "Crosswind \(crosswind) knots from the \(sideRight ? "right" : "left"), "
            + (headwind >= 0 ? "headwind \(headwind) knots" : "tailwind \(-headwind) knots"))
    }

    /// Helper for arrowhead base points: a point `dist` from `base` along `bearing`.
    private func pt2(bearing: Double, dist: CGFloat, base: CGPoint) -> CGPoint {
        let r = bearing * .pi / 180
        return CGPoint(x: base.x + dist * CGFloat(sin(r)), y: base.y - dist * CGFloat(cos(r)))
    }
}

#Preview {
    CrosswindDiagramView(runwayIdent: "07", reciprocalIdent: "25",
                         windDirDeg: 120, runwayHeadingDeg: 70,
                         crosswind: 17, headwind: 13, sideRight: true)
        .padding(40)
        .background(Brand.navy)
}

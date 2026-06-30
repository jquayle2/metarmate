//
//  CrosswindDiagramView.swift
//  MetarMate
//
//  The refresh's big move: the crosswind result is a *diagram*, not just a number.
//  A compass ring, the selected runway drawn pointing up, the wind as a dashed
//  caution-orange arrow at its relative bearing, and the decomposed components as
//  solid arrows from the aircraft node — crosswind (red, across) and headwind
//  (green, favorable) / tailwind (red, up).
//
//  Faithful port of the handoff SVG (viewBox 0 0 156 160). The geometry is static
//  in spirit but driven by the live crosswind math so it reflects real inputs.
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

    // viewBox space
    private let box = CGSize(width: 156, height: 160)
    private let center = CGPoint(x: 78, y: 78)
    private let ringR: CGFloat = 68

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

            let ringTint = Color(red: 219/255, green: 221/255, blue: 227/255)

            // Compass ring — solid faint + dashed faint.
            let ringRect = CGRect(x: (center.x - ringR) * sx, y: (center.y - ringR) * sy,
                                  width: ringR * 2 * sx, height: ringR * 2 * sy)
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(ringTint.opacity(0.12)),
                       lineWidth: 1)
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(ringTint.opacity(0.06)),
                       style: StrokeStyle(lineWidth: 1, dash: [2 * sx, 6 * sx]))

            // Runway strip (points up).
            let stripRect = CGRect(x: 66 * sx, y: 16 * sy, width: 24 * sx, height: 124 * sy)
            ctx.fill(Path(roundedRect: stripRect, cornerRadius: 4 * sx),
                     with: .color(Color(hex: "#0C2034")))
            ctx.stroke(Path(roundedRect: stripRect, cornerRadius: 4 * sx),
                       with: .color(ringTint.opacity(0.16)), lineWidth: 1)

            // Dashed-orange centerline.
            L(CGPoint(x: 78, y: 26), CGPoint(x: 78, y: 130),
              color: Brand.accentOrange.opacity(0.35), w: 2, dash: [6, 9])

            // Threshold labels.
            ctx.draw(Text(runwayIdent).font(.brandMono(12, weight: .bold))
                        .foregroundColor(Brand.fog),
                     at: P(CGPoint(x: 78, y: 124)), anchor: .center)
            ctx.draw(Text(reciprocalIdent).font(.brandMono(9, weight: .bold))
                        .foregroundColor(Brand.monoDim2),
                     at: P(CGPoint(x: 78, y: 22)), anchor: .center)

            // Wind arrow: dashed caution-orange, from the ring inward to the aircraft.
            let windOuter = pt(bearing: angleOff, radius: 70)
            let windInner = pt(bearing: angleOff, radius: 30)
            L(windOuter, windInner, color: Brand.cautionOrange, w: 3, dash: [3, 6])
            // Arrowhead at the inner end, pointing toward center.
            let windHeadBase = pt(bearing: angleOff, radius: 38)
            let perp = angleOff + 90
            let hb1 = pt2(from: windInner, bearing: perp, dist: 5, base: windHeadBase)
            let hb2 = pt2(from: windInner, bearing: perp + 180, dist: 5, base: windHeadBase)
            fillTriangle([windInner, hb1, hb2], Brand.cautionOrange)
            // Wind label just outside the ring.
            let windLabelAt = pt(bearing: angleOff, radius: 84)
            ctx.draw(Text("\(windDirDeg)°").font(.brandMono(10, weight: .bold))
                        .foregroundColor(Brand.cautionOrange),
                     at: P(windLabelAt), anchor: .center)

            // Aircraft node.
            let nodeR: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(x: (center.x - nodeR) * sx, y: (center.y - nodeR) * sy,
                                            width: nodeR * 2 * sx, height: nodeR * 2 * sy)),
                     with: .color(Brand.cloud))

            // Component scale (≈ 2.8 px/kt, matching the mock), capped to the ring.
            let scale: CGFloat = 2.8
            func len(_ kt: Int) -> CGFloat { min(CGFloat(abs(kt)) * scale, 60) }

            // Crosswind — horizontal, red. Wind from right pushes left, and vice-versa.
            let xwLen = len(crosswind)
            let xwEnd = CGPoint(x: sideRight ? center.x - xwLen : center.x + xwLen, y: center.y)
            L(center, xwEnd, color: Brand.dangerRed, w: 4)
            if sideRight {
                fillTriangle([xwEnd, CGPoint(x: xwEnd.x + 11, y: xwEnd.y - 5),
                              CGPoint(x: xwEnd.x + 11, y: xwEnd.y + 5)], Brand.dangerRed)
            } else {
                fillTriangle([xwEnd, CGPoint(x: xwEnd.x - 11, y: xwEnd.y - 5),
                              CGPoint(x: xwEnd.x - 11, y: xwEnd.y + 5)], Brand.dangerRed)
            }

            // Along-runway — vertical. Headwind points down (green); tailwind up (red).
            let hwLen = len(headwind)
            if headwind >= 0 {
                let hwEnd = CGPoint(x: center.x, y: center.y + hwLen)
                L(center, hwEnd, color: Brand.vfrGreen, w: 4)
                fillTriangle([hwEnd, CGPoint(x: hwEnd.x - 5, y: hwEnd.y - 11),
                              CGPoint(x: hwEnd.x + 5, y: hwEnd.y - 11)], Brand.vfrGreen)
            } else {
                let twEnd = CGPoint(x: center.x, y: center.y - hwLen)
                L(center, twEnd, color: Brand.dangerRed, w: 4)
                fillTriangle([twEnd, CGPoint(x: twEnd.x - 5, y: twEnd.y + 11),
                              CGPoint(x: twEnd.x + 5, y: twEnd.y + 11)], Brand.dangerRed)
            }
        }
        .frame(width: 134, height: 138)
        .accessibilityLabel(
            "Crosswind \(crosswind) knots from the \(sideRight ? "right" : "left"), "
            + (headwind >= 0 ? "headwind \(headwind) knots" : "tailwind \(-headwind) knots"))
    }

    /// Helper for arrowhead base points: a point `dist` from `from` along `bearing`,
    /// anchored near `base`.
    private func pt2(from: CGPoint, bearing: Double, dist: CGFloat, base: CGPoint) -> CGPoint {
        let r = bearing * .pi / 180
        return CGPoint(x: base.x + dist * CGFloat(sin(r)), y: base.y - dist * CGFloat(cos(r)))
    }
}

#Preview {
    CrosswindDiagramView(runwayIdent: "07", reciprocalIdent: "25",
                         windDirDeg: 123, runwayHeadingDeg: 70,
                         crosswind: 17, headwind: 13, sideRight: true)
        .padding(40)
        .background(Brand.navy)
}

//
//  Theme.swift
//  MetarMate
//
//  Design-token layer for the "MetarMate — Visual Refresh" ("The Chart" direction).
//  Single source of truth for the brand palette, typography, and the disciplined
//  color rules described in the design handoff. See design_handoff_metarmate_refresh.
//
//  Color discipline (the whole point of the refresh):
//   • Red is rationed — only genuine danger (IFR, sub-minimum vis, deteriorating trend).
//   • In-range scalar values get NO color — neutral Fog/Cloud. Color is signal, not decoration.
//   • Two-tier orange: accent (#FF4E00) = brand / caution-low; caution (#FF8A3D) = situational.
//   • Gust discipline — a wind code lights orange only if it gusts.
//

import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// Build a Color from a hex string ("#RRGGBB", "RRGGBB", or "#RRGGBBAA").
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        switch s.count {
        case 8: // RRGGBBAA
            r = Double((v & 0xFF00_0000) >> 24) / 255
            g = Double((v & 0x00FF_0000) >> 16) / 255
            b = Double((v & 0x0000_FF00) >> 8) / 255
            a = Double(v & 0x0000_00FF) / 255
        default: // RRGGBB
            r = Double((v & 0xFF0000) >> 16) / 255
            g = Double((v & 0x00FF00) >> 8) / 255
            b = Double(v & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Brand palette & tokens

/// Brand design tokens. All raw values come straight from the handoff token tables.
enum Brand {
    // Ground & surfaces
    static let navy        = Color(hex: "#0B1D33")   // app background, every screen
    static let bezel       = Color(hex: "#05101D")   // deepest; tab-bar tint base
    static let cardFill    = Color.white.opacity(0.025)
    static let cardBorder  = Color(red: 219/255, green: 221/255, blue: 227/255).opacity(0.09)
    static let rowDivider  = Color(red: 219/255, green: 221/255, blue: 227/255).opacity(0.07)
    static let hairline    = Color(red: 219/255, green: 221/255, blue: 227/255).opacity(0.08)
    static let tabBarFill   = Color(red: 7/255, green: 18/255, blue: 32/255).opacity(0.82)
    static let tabBarDocked = Color(red: 7/255, green: 18/255, blue: 32/255).opacity(0.94)

    // Text
    static let cloud   = Color(hex: "#F6F4F1")   // headlines, ICAO, primary values
    static let fog     = Color(hex: "#DBDDE3")   // strong body text
    static let fog2    = Color(hex: "#C4CCD6")   // row labels
    // Neutral text greys — brightened for cockpit legibility (contrast pass, B5).
    // These are non-semantic; the category/caution/go-no-go color axes are unchanged.
    static let slate   = Color(hex: "#9EABBB")   // secondary labels, distances
    static let monoDim  = Color(hex: "#8695A9")  // raw METAR strings
    static let monoDim2 = Color(hex: "#7A8A9E")  // chevrons / dimmest mono

    // Semantic (use ONLY for the documented meaning)
    static let accentOrange  = Color(hex: "#FF4E00") // brand accent; caution-low altimeter; trend-up
    static let cautionOrange = Color(hex: "#FF8A3D") // gusts, present wx, advisory
    static let vfrGreen      = Color(hex: "#00FF00") // good / in-limits — Garmin CDI green (was #5FC588)
    static let dangerRed     = Color(hex: "#F0473F") // deteriorating trend mark / alert chrome
    static let valueRed      = Color(hex: "#FF5A50") // danger values in text (IFR, sub-min vis)
    static let ifrBadgeBG    = Color(hex: "#E0453D") // solid fill behind white "IFR"

    // Flight-category axis (VFR/MVFR/IFR/LIFR) — reserved ONLY for category signaling.
    // Brightened for cockpit legibility on the navy ground.
    static let mvfrBlue      = Color(hex: "#4FA3F0") // MVFR
    static let lifrMagenta   = Color(hex: "#E06AD0") // LIFR (aviation magenta)

    // VFR pill  (Garmin CDI green; was 84/177/122)
    static let vfrPillFill   = Color(red: 0/255, green: 255/255, blue: 0/255).opacity(0.16)
    static let vfrPillBorder = Color(red: 0/255, green: 255/255, blue: 0/255).opacity(0.40)

    // Tinted card washes
    static let pilotNotesTop    = accentOrange.opacity(0.07)
    static let pilotNotesBottom = accentOrange.opacity(0.02)
    static let pilotNotesBorder = accentOrange.opacity(0.28)
    static let advisoryTop      = cautionOrange.opacity(0.09)
    static let advisoryBottom   = cautionOrange.opacity(0.02)
    static let advisoryBorder   = cautionOrange.opacity(0.30)
    static let alertTop         = dangerRed.opacity(0.12)
    static let alertBottom      = dangerRed.opacity(0.03)
    static let alertBorder      = dangerRed.opacity(0.40)

    // Radii
    static let cardRadius: CGFloat   = 20
    static let chipRadius: CGFloat   = 8
    static let stripRadius: CGFloat  = 14
    static let tabRadius: CGFloat    = 26
}

// MARK: - Typography (Avenir Next display + SF Mono data)

extension Font {
    /// Avenir Next at an explicit PostScript weight (guaranteed present on iOS).
    /// `.custom(_:size:)` scales with Dynamic Type by default — layout robustness across
    /// the size range is handled in the views (wrapping columns, scroll insets, a cap).
    static func avenir(_ size: CGFloat, _ weight: AvenirWeight = .regular) -> Font {
        .custom(weight.psName, size: size)
    }
    /// Monospaced data type — SF Mono via the system monospaced design (also Dynamic-Type-scaled).
    static func brandMono(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum AvenirWeight {
    case regular, medium, demibold, bold, heavy
    var psName: String {
        switch self {
        case .regular:  return "AvenirNext-Regular"
        case .medium:   return "AvenirNext-Medium"
        case .demibold: return "AvenirNext-DemiBold"
        case .bold:     return "AvenirNext-Bold"
        case .heavy:    return "AvenirNext-Heavy"   // heaviest Avenir; stands in for weight 900
        }
    }
}

// MARK: - Color rules (pure functions — the only new presentation logic)

enum ColorRules {

    /// flightCategoryColor(cat) — the aviation four-way axis, used ONLY for category:
    /// VFR green · MVFR blue · IFR red · LIFR magenta. (Never re-used for non-category signals.)
    static func flightCategoryColor(_ cat: FlightCategory) -> Color {
        switch cat {
        case .vfr:     return Brand.vfrGreen
        case .mvfr:    return Brand.mvfrBlue
        case .ifr:     return Brand.valueRed
        case .lifr:    return Brand.lifrMagenta
        case .unknown: return Brand.slate
        }
    }

    /// Status-rail color for the Nearest list: green VFR, caution-orange advisory-only.
    static func railColor(hasMetar: Bool, category: FlightCategory) -> Color {
        guard hasMetar else { return Brand.cautionOrange }
        return flightCategoryColor(category)
    }

    /// Whole-wind-token color for the airport lists — real METAR and advisory rows alike, so
    /// the two read the same. Matches the airport-detail orange rule (gust, strong ≥ 20 kt, or
    /// wide gust spread ≥ 10 → caution); CALM reads good; light steady stays neutral.
    static func windColor(speedKt: Int, gustKt: Int?) -> Color {
        if speedKt == 0 { return Brand.vfrGreen }       // CALM, muted green
        let spread = (gustKt ?? speedKt) - speedKt
        if gustKt != nil || speedKt >= 20 || spread >= 10 { return Brand.cautionOrange }
        return Brand.monoDim                            // steady light → neutral mono
    }

    /// Convenience over `windColor` for a parsed METAR `Wind`.
    static func windCodeColor(_ wind: Wind) -> Color {
        guard wind.isReported else { return Brand.slate }   // wind not reported (nil ≠ calm-green)
        return windColor(speedKt: wind.speed, gustKt: wind.gust)
    }

    // valueColor(metric, value): neutral unless out-of-range. Per-metric below.

    /// Altimeter: genuinely-low pressure reads caution (accent orange); normal is neutral.
    static func altimeterColor(_ inHg: Double) -> Color {
        inHg < 29.80 ? Brand.accentOrange : Brand.fog
    }

    /// Visibility (statute miles) on the flight-category axis:
    /// < 1 LIFR magenta · < 3 IFR red · <= 5 MVFR blue · > 5 VFR green.
    /// Boundaries match calculateFlightCategory (FAA: 5 SM is MVFR, not VFR).
    static func visibilityColor(_ sm: Double) -> Color {
        if sm < 1 { return Brand.lifrMagenta }
        if sm < 3 { return Brand.valueRed }
        if sm <= 5 { return Brand.mvfrBlue }
        return Brand.vfrGreen
    }

    /// Ceiling (feet AGL, nil = unlimited) on the flight-category axis:
    /// < 500 LIFR magenta · < 1000 IFR red · <= 3000 MVFR blue · > 3000 VFR green.
    /// Boundaries match calculateFlightCategory (FAA: 3000 ft is MVFR, not VFR).
    static func ceilingColor(_ feet: Int?) -> Color {
        guard let feet = feet else { return Brand.vfrGreen }
        if feet < 500  { return Brand.lifrMagenta }
        if feet < 1000 { return Brand.valueRed }
        if feet <= 3000 { return Brand.mvfrBlue }
        return Brand.vfrGreen
    }

    /// Decoded wind value color: gusts caution; calm/light steady reads good (green).
    static func windValueColor(_ wind: Wind) -> Color {
        guard wind.isReported else { return Brand.slate }   // wind not reported (nil ≠ calm-green)
        if wind.gust != nil { return Brand.cautionOrange }
        return Brand.vfrGreen
    }

    /// Temp/dew spread: tight spread (fog risk) is caution; comfortable spread is good.
    static func spreadColor(tempC: Int, dewpointC: Int) -> Color {
        let spread = tempC - dewpointC
        if spread <= 2 { return Brand.valueRed }
        if spread <= 4 { return Brand.cautionOrange }
        return Brand.vfrGreen
    }

    /// trendStyle(direction, severity) → (arrowDirection, color).
    /// Up/orange for improving or stable; down/red for deteriorating.
    static func trendStyle(_ direction: TrendDirection) -> (up: Bool, color: Color) {
        switch direction {
        case .deteriorating: return (false, Brand.dangerRed)
        case .improving, .steady: return (true, Brand.accentOrange)
        case .unknown: return (true, Brand.slate)
        }
    }
}

// MARK: - Reusable chrome

/// Faint concentric-contour ("isobar") wash on the navy ground — the brand's chart identity.
/// Two offset "pressure centers" (upper-right + lower-left) so the contours curve and
/// interfere across the whole screen, not a single near-horizontal set.
struct IsobarBackground: View {
    /// Relative origins of the contour rings. Defaults to two offset centers; per-origin
    /// opacity is halved automatically so overlapping fields don't read twice as dense
    /// where two rings cross.
    var origins: [UnitPoint] = IsobarBackground.dualOrigin
    var tint: Color = Color(red: 219/255, green: 221/255, blue: 227/255)
    var opacity: Double = 0.045

    static let dualOrigin: [UnitPoint] = [
        UnitPoint(x: 0.72, y: -0.04),   // existing, unchanged — upper-right
        UnitPoint(x: 0.18, y: 1.08),    // new — lower-left
    ]

    var body: some View {
        Brand.navy.overlay(
            GeometryReader { geo in
                Canvas { ctx, size in
                    let perOriginOpacity = opacity / Double(max(origins.count, 1))
                    for origin in origins {
                        drawContours(ctx: ctx, size: size, origin: origin, opacity: perOriginOpacity)
                    }
                }
            }
        )
        .ignoresSafeArea()
    }

    private func drawContours(ctx: GraphicsContext, size: CGSize, origin: UnitPoint, opacity: Double) {
        let cx = origin.x * size.width
        let cy = origin.y * size.height
        let maxR = hypot(size.width, size.height) * 1.2
        let step: CGFloat = 26
        var r: CGFloat = step
        while r < maxR {
            // Elliptical contours (wider than tall), echoing the CSS approximation.
            let rect = CGRect(x: cx - r * 1.5, y: cy - r * 0.8,
                              width: r * 3.0, height: r * 1.6)
            ctx.stroke(Path(ellipseIn: rect),
                       with: .color(tint.opacity(opacity)),
                       lineWidth: 1)
            r += step
        }
    }
}

extension View {
    /// Lay the brand navy + isobar wash behind any screen.
    func brandGround() -> some View {
        self.background(IsobarBackground())
    }

    /// Standard floating card surface (fill + hairline border + radius).
    func brandCard(radius: CGFloat = Brand.cardRadius,
                   fill: Color = Brand.cardFill,
                   border: Color = Brand.cardBorder) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(border, lineWidth: 1))
    }
}

/// Tracked uppercase caps label ("DECODED METAR", "TREND", kickers).
struct TrackedLabel: View {
    let text: String
    var color: Color = Brand.slate
    var size: CGFloat = 10.5
    var tracking: CGFloat = 2.6   // ≈ 0.28em at this size

    var body: some View {
        Text(text.uppercased())
            .font(.avenir(size, .heavy))
            .tracking(tracking)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // Decorative tracked caps (kickers/section headers): cap growth so a long,
            // widely-tracked label can't run past the screen edge at accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }
}

/// The brand "front-line": a gradient rule fading from an accent color to transparent.
struct FrontLine: View {
    var color: Color = Brand.accentOrange
    var body: some View {
        LinearGradient(colors: [color.opacity(0.5), color.opacity(0)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
    }
}

/// Cold-front triangle marker — section-header punctuation pointing down.
struct WeatherFrontTriangle: View {
    var color: Color = Brand.accentOrange
    var size: CGFloat = 8
    var body: some View {
        Triangle()
            .fill(color)
            .frame(width: size, height: size * 0.75)
    }
}

/// Downward-pointing filled triangle.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Section header: tracked caps label + front-line + two front triangles.
struct SectionFrontHeader: View {
    let title: String
    var accent: Color = Brand.accentOrange
    var labelColor: Color = Brand.slate
    var showTriangles: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            TrackedLabel(text: title, color: labelColor)
            FrontLine(color: accent)
            if showTriangles {
                WeatherFrontTriangle(color: accent)
                WeatherFrontTriangle(color: accent.opacity(0.55))
            }
        }
    }
}

/// VFR / IFR status pill. VFR = translucent green outline; IFR = solid danger fill.
struct StatusPill: View {
    let category: FlightCategory

    var body: some View {
        let color = ColorRules.flightCategoryColor(category)
        // IFR/LIFR get a solid alarming pill; VFR/MVFR a translucent outline.
        let solid = (category == .ifr || category == .lifr)
        return HStack(spacing: 6) {
            Circle().frame(width: 6, height: 6)
            Text(category.displayName)
        }
        .font(.avenir(13, .heavy))
        .tracking(1.0)
        .foregroundColor(solid ? .white : color)
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Brand.chipRadius, style: .continuous)
                .fill(solid ? color : color.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Brand.chipRadius, style: .continuous)
                .stroke(solid ? .clear : color.opacity(0.4), lineWidth: 1)
        )
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // category pill is fixed chrome
    }
}

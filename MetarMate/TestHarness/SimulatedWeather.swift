import SwiftUI

// MARK: - Simulated Weather infrastructure (Test Harness only)
//
// Everything here supports the METAR Injection harness. None of it touches the network, SwiftData,
// favorites, or the widget App-Group snapshot. Injection goes through the SAME JSON-decode → real
// parser seam the live network fetch uses (see SimulatedDecode), so the harness exercises the
// production parser, not a stand-in.

// MARK: - End-to-end "this screen is simulated" flag
//
// Set once at the top of the simulated navigation and read by every descendant (including pushed
// sub-screens) to decide whether to paint the SIMULATED chrome. This is the mechanism that makes
// the safety marker impossible to lose on sub-navigation.
private struct IsSimulatedWeatherKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSimulatedWeather: Bool {
        get { self[IsSimulatedWeatherKey.self] }
        set { self[IsSimulatedWeatherKey.self] = newValue }
    }
}

// MARK: - Injection payload
//
// The already-parsed model to seed into a real WeatherViewModel. Parsing happens up front (via
// SimulatedDecode) so a parse FAILURE is surfaced honestly in the harness list — never papered over
// with a fallback model. `metars` is newest-first; `metars.first` becomes the current observation.
struct SimulatedInjection: Equatable {
    var metars: [Metar]
    var taf: Taf?

    static func == (lhs: SimulatedInjection, rhs: SimulatedInjection) -> Bool {
        lhs.metars.map(\.id) == rhs.metars.map(\.id) && lhs.taf?.id == rhs.taf?.id
    }
}

// MARK: - The injection seam
//
// These two functions are a byte-for-byte match of the decode+parse the live fetch does in
// WeatherService.fetchMetar / fetchTaf: decode `[RawMetar]` / `[RawTaf]`, take `.first`, hand it to
// the real MetarParser.parse / TafParser.parse. There is NO separate text parser. A raw METAR/TAF
// line is injected by wrapping it into the SAME JSON shape (only rawOb/rawTAF populated), so it
// travels the identical path — the un-populated fields then render honestly as unknown, never a
// fabricated default.
enum SimulatedDecode {
    static func parseMetar(json: String) throws -> Metar {
        let raws = try JSONDecoder().decode([RawMetar].self, from: Data(json.utf8))
        guard let first = raws.first else { throw WeatherError.noData }
        return try MetarParser.parse(raw: first)
    }

    static func parseTaf(json: String) throws -> Taf {
        let raws = try JSONDecoder().decode([RawTaf].self, from: Data(json.utf8))
        guard let first = raws.first else { throw WeatherError.noData }
        return try TafParser.parse(raw: first)
    }

    /// Wrap a pasted RAW METAR line into the NOAA JSON shape with ONLY rawOb populated. Everything
    /// the parser derives from structured fields (vis/wind/clouds/category) will be unknown/empty —
    /// that is the honest result, not a bug. `icaoId` is required by the parser, so we take the
    /// first token if it looks like an ident, else a placeholder.
    static func metarJSON(fromRawLine line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let icao = inferredIdent(from: trimmed) ?? "ZZZZ"
        let escaped = jsonEscape(trimmed)
        // No obsTime → parser fills Date(); no visib/wdir/wspd/clouds/wxString/fltCat → all unknown.
        return #"[{"icaoId":"\#(icao)","rawOb":"\#(escaped)"}]"#
    }

    /// Wrap a pasted RAW TAF line into the NOAA JSON shape with ONLY rawTAF populated. No `fcsts`,
    /// so the forecast list is empty — again the honest result of a raw line carrying no structure.
    static func tafJSON(fromRawLine line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let icao = inferredIdent(from: trimmed) ?? "ZZZZ"
        let escaped = jsonEscape(trimmed)
        return #"[{"icaoId":"\#(icao)","rawTAF":"\#(escaped)"}]"#
    }

    /// First whitespace-delimited token that looks like a station ident (skips a leading
    /// METAR/SPECI/TAF keyword). Best-effort only — the parser just needs a non-nil icaoId.
    private static func inferredIdent(from line: String) -> String? {
        let tokens = line.uppercased().split(separator: " ").map(String.init)
        for t in tokens {
            if t == "METAR" || t == "SPECI" || t == "TAF" || t == "AMD" || t == "COR" { continue }
            if t.count == 4, t.allSatisfy({ $0.isLetter }) { return t }
            if t.count == 4, t.first == "K", t.dropFirst().allSatisfy({ $0.isLetter || $0.isNumber }) { return t }
            return nil   // first real token wasn't an ident
        }
        return nil
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\t", with: " ")
    }
}

// MARK: - SIMULATED chrome (banner + watermark + tint)
//
// Applied to EVERY simulated screen. Requirements it satisfies:
//   • Permanent, full-width, high-contrast banner — pinned via safeAreaInset so it never scrolls.
//   • Not a toast, not dismissible — it is structural, redrawn on every layout.
//   • A tiled diagonal "SIMULATED" watermark + faint red wash + red edge, so the screen is distinct
//     from a live render at a glance even if the banner is somehow off-screen.
//   • Sets isSimulatedWeather in the environment so pushed sub-screens can re-apply the same chrome.
private struct SimulatedWeatherChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.isSimulatedWeather, true)
            .overlay(SimulatedWatermark().allowsHitTesting(false))
            .overlay(Color.red.opacity(0.035).allowsHitTesting(false))   // whole-screen tint
            .overlay(                                                    // red edge — distinct frame
                Rectangle().strokeBorder(Color.red.opacity(0.55), lineWidth: 3).allowsHitTesting(false)
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                SimulatedBanner()
            }
    }
}

extension View {
    /// Paint the full SIMULATED safety chrome on this screen. Apply to every injected view AND every
    /// pushed sub-screen so the marker cannot be lost on sub-navigation.
    func simulatedWeatherChrome() -> some View {
        modifier(SimulatedWeatherChrome())
    }
}

struct SimulatedBanner: View {
    var body: some View {
        Text("⚠️ SIMULATED — NOT REAL WEATHER")
            .font(.system(size: 14, weight: .heavy))
            .kerning(0.5)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(Color(red: 0.80, green: 0.0, blue: 0.0))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.yellow).frame(height: 2)
            }
            .accessibilityLabel("Simulated. Not real weather.")
    }
}

private struct SimulatedWatermark: View {
    var body: some View {
        Canvas { context, size in
            context.rotate(by: .degrees(-30))
            let resolved = context.resolve(
                Text("SIMULATED")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundColor(Color.red.opacity(0.06))
            )
            let stepX: CGFloat = 220
            let stepY: CGFloat = 120
            var y = -size.height
            while y < size.height * 1.6 {
                var x = -size.width
                while x < size.width * 1.6 {
                    context.draw(resolved, at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
            }
        }
    }
}

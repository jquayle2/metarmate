import SwiftUI

/// Contextual crosswind calculator. Pre-fills from the current wind, lists every
/// runway end with live crosswind/headwind, and allows manual override of the wind.
/// Crosswind magnitudes use the amber/red wind palette only — never flight-category
/// or verdict colors.
struct RunwayCrosswindSheet: View {
    let airport: Airport
    let initialWind: Wind

    @Environment(\.dismiss) private var dismiss

    @State private var dirText: String = ""
    @State private var speedText: String = ""
    @State private var gustText: String = ""

    // Amber → orange → red, keyed on crosswind magnitude. Wind palette only.
    private static let amber = Color(red: 1.0, green: 0.6, blue: 0.0)
    private static func crosswindColor(_ xw: Int) -> Color {
        if xw >= 20 { return .red }
        if xw >= 15 { return .orange }
        if xw >= 10 { return amber }
        return .secondary
    }

    private var direction: Int? { Int(dirText.trimmingCharacters(in: .whitespaces)) }
    private var speed: Int? { Int(speedText.trimmingCharacters(in: .whitespaces)) }
    private var gust: Int? {
        let g = Int(gustText.trimmingCharacters(in: .whitespaces))
        guard let g, let s = speed, g > s else { return nil }
        return g
    }

    /// Runway ends, ranked best-first (same preference as RunwayService.bestRunway), with
    /// parallel runways collapsed — 12L/12R share a heading, so an identical crosswind.
    private var results: [RunwayResult] {
        guard let dir = direction, let spd = speed, spd > 0 else { return [] }
        let raw = RunwayService.shared.crosswinds(
            for: airport.icao, windDirection: dir,
            windSpeed: Double(spd), windGust: gust.map(Double.init))
        var seen = Set<String>()
        return raw.sorted(by: Self.isBetter)
            .filter { seen.insert(RunwayService.runwayNumber($0.runwayEnd.ident)).inserted }
    }

    private func ident(_ r: RunwayResult) -> String {
        RunwayService.shared.displayIdent(r.runwayEnd, icao: airport.icao)
    }

    /// Mirrors RunwayService.bestRunway selection: headwind-favored, then lowest crosswind.
    private static func isBetter(_ a: RunwayResult, _ b: RunwayResult) -> Bool {
        if a.headwind > 0 && b.headwind <= 0 { return true }
        if a.headwind <= 0 && b.headwind > 0 { return false }
        if a.crosswind != b.crosswind { return a.crosswind < b.crosswind }
        return a.headwind > b.headwind
    }

    private var hasRunwayData: Bool { !RunwayService.shared.runways(for: airport.icao).isEmpty }
    private var effectiveSpeedLabel: String {
        if let g = gust { return "gust \(g) kt" }
        return "\(speed ?? 0) kt"
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasRunwayData {
                    noDataView
                } else {
                    content
                }
            }
            .navigationTitle("Crosswind — \(airport.icao)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    Spacer()
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Reset") { prefillFromWind() }
                }
            }
        }
        .onAppear(perform: prefillFromWind)
    }

    private func prefillFromWind() {
        dirText = (initialWind.isVariable ? nil : initialWind.direction).map(String.init) ?? ""
        speedText = String(initialWind.speed)
        gustText = initialWind.gust.map(String.init) ?? ""
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                windInputCard
                if results.isEmpty {
                    Text(direction == nil
                         ? "Enter a wind direction to compute crosswinds."
                         : "Enter a wind speed to compute crosswinds.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                } else {
                    bestCard(results[0])
                    runwayList
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var windInputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WIND")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .tracking(1)
            HStack(spacing: 12) {
                windField(label: "Dir°", text: $dirText, width: 70)
                windField(label: "Speed", text: $speedText, width: 70)
                windField(label: "Gust", text: $gustText, width: 70)
                Spacer()
            }
            Text("Computed off \(effectiveSpeedLabel). Tap a field to override.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    private func windField(label: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            TextField("—", text: text)
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: width)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(8)
        }
    }

    private func bestCard(_ r: RunwayResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("BEST RUNWAY")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .tracking(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("RWY \(ident(r))")
                    .font(.title2.bold().monospacedDigit())
                Spacer()
                crosswindBadge(r)
            }
            Text(alongText(r))
                .font(.subheadline)
                .foregroundColor(.secondary)
            if let len = r.runwayEnd.length {
                Text("\(len.formatted()) ft\(r.runwayEnd.surface.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.green.opacity(0.4), lineWidth: 1)
        )
    }

    private var runwayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ALL RUNWAYS")
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .tracking(1)
                .padding(.bottom, 8)
            ForEach(Array(results.enumerated()), id: \.offset) { idx, r in
                HStack(spacing: 12) {
                    Text("RWY \(ident(r))")
                        .font(.body.monospacedDigit())
                        .frame(width: 90, alignment: .leading)
                    Text(alongText(r))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    crosswindBadge(r)
                }
                .padding(.vertical, 10)
                if idx < results.count - 1 {
                    Divider()
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    private func crosswindBadge(_ r: RunwayResult) -> some View {
        let color = Self.crosswindColor(r.crosswind)
        return HStack(spacing: 4) {
            Text("\(r.crosswind)")
                .font(.headline.monospacedDigit())
            Text("kt XW")
                .font(.caption)
            Image(systemName: r.isLeft ? "arrow.left" : "arrow.right")
                .font(.caption2)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private func alongText(_ r: RunwayResult) -> String {
        let side = r.isLeft ? "from left" : "from right"
        let along = r.headwind >= 0 ? "\(r.headwind) kt headwind" : "\(abs(r.headwind)) kt tailwind"
        return "\(side) · \(along)"
    }

    private var noDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "ruler")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No runway data for \(airport.icao)")
                .font(.headline)
            Text("Crosswind components require published runway headings, which aren't available for this airport.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
    }
}

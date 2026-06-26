import SwiftUI

/// Contextual crosswind calculator, opened by tapping a wind display. Hosts the
/// ported XW Calc keypad (CrosswindKeypadView): pre-filled from the wind that opened
/// the sheet and seeded to the best runway, with the manual swipe keypad for override.
///
/// Crosswind/headwind colors stay on MetarMate's wind palette (amber/red, neutral
/// wind-axis blue) — the flight-category green and go/no-go verdict red live elsewhere.
struct RunwayCrosswindSheet: View {
    let airport: Airport

    @Environment(\.dismiss) private var dismiss

    @State private var runway: Int
    @State private var windDirection: Int
    @State private var windSpeed: Int
    @State private var gustSpeed: Int

    init(airport: Airport, initialWind: Wind) {
        self.airport = airport

        let dir = initialWind.direction ?? 0
        let spd = initialWind.speed
        let gst = initialWind.gust ?? spd

        // The METAR wind is TRUE-north; the keypad works in the MAGNETIC frame (designator×10
        // headings, like the manual tab). Convert before seeding so the calc lines up with the
        // runway numbers and with Pilot Notes / bestRunway.
        let magDir = RunwayService.shared.magneticWind(dir, for: airport.icao)

        // Seed the runway from the best runway for this wind (bestRunway takes the TRUE wind and
        // converts internally). Fall back to the runway most aligned with the magnetic wind
        // (designator ≈ magnetic direction / 10) when there's no runway data.
        let seededRunway: Int = {
            if let best = RunwayService.shared.bestRunway(
                for: airport.icao, windDirection: dir,
                windSpeed: Double(spd), windGust: initialWind.gust.map(Double.init)),
               let n = Int(RunwayService.runwayNumber(best.runwayEnd.ident)), (1...36).contains(n) {
                return n
            }
            let n = Int((Double(magDir) / 10).rounded())
            return min(36, max(1, n == 0 ? 36 : n))
        }()

        _runway = State(initialValue: seededRunway)
        _windDirection = State(initialValue: magDir)
        _windSpeed = State(initialValue: spd)
        _gustSpeed = State(initialValue: gst)
    }

    var body: some View {
        CrosswindKeypadView(
            runway: $runway,
            windDirection: $windDirection,
            windSpeed: $windSpeed,
            gustSpeed: $gustSpeed,
            title: airport.icao,
            onDone: { dismiss() }
        )
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

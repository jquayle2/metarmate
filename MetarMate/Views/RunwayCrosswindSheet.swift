import SwiftUI

/// Contextual crosswind calculator, opened by tapping a wind display. Hosts the
/// ported XW Calc keypad (CrosswindKeypadView): pre-filled from the wind that opened
/// the sheet and seeded to the best runway, with the manual swipe keypad for override.
///
/// Crosswind/headwind colors stay on MetarMate's wind palette (amber/red, neutral
/// wind-axis blue) — the flight-category green and go/no-go verdict red live elsewhere.
struct RunwayCrosswindSheet: View {
    let airport: Airport
    let initialWind: Wind

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CrosswindKeypadView(airport: airport, initialWind: initialWind) {
            dismiss()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

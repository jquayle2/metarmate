import SwiftUI

/// Standalone XWind tab: the ported XW Calc keypad with last-used values persisted
/// across sessions via @AppStorage (xwcalc_ prefix to avoid key collisions). Unlike the
/// contextual sheet, this isn't tied to a station — the use case is short final, when
/// tower calls winds different from the METAR and you want a fast one-handed answer.
/// First field is active on open so digits can be thumbed immediately from cold.
struct CrosswindTabView: View {
    @AppStorage("xwcalc_runway")        private var runway: Int = 18
    @AppStorage("xwcalc_windDirection") private var windDirection: Int = 180
    @AppStorage("xwcalc_windSpeed")     private var windSpeed: Int = 10
    @AppStorage("xwcalc_gustSpeed")     private var gustSpeed: Int = 10

    var body: some View {
        CrosswindKeypadView(
            runway: $runway,
            windDirection: $windDirection,
            windSpeed: $windSpeed,
            gustSpeed: $gustSpeed,
            title: "MANUAL"
        )
    }
}

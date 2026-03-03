import AppIntents
import WidgetKit

// MARK: - Widget Configuration Intent
// Uses a simple String parameter for the ICAO code.
// The entity-based approach crashes in the widget extension
// because AirportService is too heavy for that context.

struct SelectAirportIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Airport"
    static var description = IntentDescription("Choose which airport to display.")

    @Parameter(title: "Airport Code", description: "ICAO code like KLAS, KVGT, KSMO")
    var airportCode: String?
}

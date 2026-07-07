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

// MARK: - Interactive Widget Button
// Executes in-process in the widget extension (that's where WidgetKit runs a tapped button's
// intent), so it only touches the App-Group-shared WidgetDataManager — never AirportService or
// anything else main-app-only.

/// Forces the widget's timeline to re-run immediately instead of waiting for the next scheduled
/// refresh. ConfigurableProvider.timeline(for:) always re-fetches from network on every run, so
/// reloading the timeline is enough — no need to duplicate the fetch here.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Weather"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        WidgetDataManager.reloadWidgets()
        return .result()
    }
}

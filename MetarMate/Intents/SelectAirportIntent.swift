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

/// Refresh button on the widget. WidgetKit reloads the tapped widget's timeline itself after an
/// interactive intent's perform() returns, and ConfigurableProvider.timeline(for:) re-fetches from
/// network on every run — so this does nothing. Calling reloadAllTimelines() here was a budgeted
/// request from the extension and became a no-op once the daily reload budget was spent.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Weather"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        .result()
    }
}

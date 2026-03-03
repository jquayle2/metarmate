import AppIntents
import WidgetKit

// MARK: - Widget Configuration Intent
// Lets users pick which airport each widget instance displays.
// Must live in the main app target (shared with widget extension)
// so the system can resolve the intent type at runtime.

struct SelectAirportIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Airport"
    static var description = IntentDescription("Choose which airport to display.")

    @Parameter(title: "Airport")
    var airport: AirportEntity?
}

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

// MARK: - Interactive Widget Buttons
// Both execute in-process in the widget extension (that's where WidgetKit runs a tapped
// button's intent) so they only touch the App-Group-shared WidgetDataManager — never
// AirportService or anything else main-app-only.

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

/// Steps an unconfigured ("most recent") widget to the next cached airport. Widgets pinned to a
/// specific airport via Edit Widget ignore this — ConfigurableProvider only consults the
/// override when the widget has no explicit airportCode set.
struct CycleWidgetAirportIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Airport"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Current Airport Code")
    var currentICAO: String?

    init() {}
    init(currentICAO: String?) { self.currentICAO = currentICAO }

    func perform() async throws -> some IntentResult {
        let pool = WidgetDataManager.loadAll().map(\.icao)
        guard !pool.isEmpty else { return .result() }
        let next: String
        if let currentICAO, let idx = pool.firstIndex(of: currentICAO) {
            next = pool[(idx + 1) % pool.count]
        } else {
            next = pool[0]
        }
        WidgetDataManager.saveCycleOverride(next)
        WidgetDataManager.reloadWidgets()
        return .result()
    }
}

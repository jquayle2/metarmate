import SwiftUI
import SwiftData

@main
struct MetarMateApp: App {
    // App-wide default crosswind alert minimum (knots), used when an alert has no
    // explicit crosswindLimitKt. Lives here as the app-wide setting; the management UI
    // (and the AlertEvaluator's fallback) read the same "globalCrosswindMinimumKt" key.
    @AppStorage("globalCrosswindMinimumKt") private var globalCrosswindMinimumKt = 15

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([AirportFavorite.self, WeatherAlert.self])
        // Store lives in the shared App Group container so the app, widget, and
        // background alert task all read/write the same SwiftData store.
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.jeffquayle.MetarMate") else {
            fatalError("App Group container group.com.jeffquayle.MetarMate is unavailable")
        }
        let storeURL = groupURL.appendingPathComponent("MetarMate.store")
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            SplashScreenView()
        }
        .modelContainer(sharedModelContainer)
    }
}

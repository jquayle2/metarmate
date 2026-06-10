import SwiftUI
import SwiftData

@main
struct MetarMateApp: App {
    init() {
        // App-wide default for the global crosswind alert minimum (knots). Registered at
        // launch so every reader — the alert evaluator (plain UserDefaults) and the
        // settings UI (@AppStorage) — sees 15 before the user sets anything, instead of 0.
        // A 0 default would make crosswind alerts fire on essentially any wind.
        UserDefaults.standard.register(defaults: ["globalCrosswindMinimumKt": 15])
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([AirportFavorite.self, MinimumsProfile.self, AirportWatch.self])
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

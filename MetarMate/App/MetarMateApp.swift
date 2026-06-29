import SwiftUI
import SwiftData
import UserNotifications

@main
struct MetarMateApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // App-wide default for the global crosswind alert minimum (knots). Registered at
        // launch so every reader — the alert evaluator (plain UserDefaults) and the
        // settings UI (@AppStorage) — sees 15 before the user sets anything, instead of 0.
        // A 0 default would make crosswind alerts fire on essentially any wind.
        UserDefaults.standard.register(defaults: ["globalCrosswindMinimumKt": 15])
        // Register the background alert-check task here, in App.init, so it's registered before
        // launch completes and the system can hand back a task scheduled while the app was dead.
        AlertScheduler.register(container: sharedModelContainer)
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

        func build() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [config])
        }

        do {
            return try build()
        } catch {
            // Recovery path. A failed open is usually one of two things:
            //   1. A stale/locked WAL sidecar left behind when a prior run (often the
            //      background alert task) was killed mid-write — the classic 0xdead10cc /
            //      slow-open cause. Clearing -wal/-shm lets SQLite rebuild them cleanly.
            //   2. A schema mismatch (SwiftData 134110) the user can't otherwise escape.
            // Clearing the sidecars preserves the real data in MetarMate.store, so favorites,
            // profiles, and watches survive this first recovery attempt.
            let fm = FileManager.default
            // Sidecars are named by appending to the FULL store filename:
            // "MetarMate.store-wal" / "MetarMate.store-shm". Build the paths by string
            // append — appendingPathExtension would wrongly yield "MetarMate.store.wal".
            let wal = URL(fileURLWithPath: storeURL.path + "-wal")
            let shm = URL(fileURLWithPath: storeURL.path + "-shm")
            try? fm.removeItem(at: wal)
            try? fm.removeItem(at: shm)
            do {
                return try build()
            } catch {
                // Last resort: the store itself is unusable. Drop it (and any sidecars) so
                // the app can launch with a fresh store rather than crash-looping. User data
                // is lost here, but a launchable app beats an unlaunchable one.
                try? fm.removeItem(at: storeURL)
                try? fm.removeItem(at: wal)
                try? fm.removeItem(at: shm)
                do {
                    return try build()
                } catch {
                    fatalError("Could not create ModelContainer even after recovery: \(error)")
                }
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            SplashScreenView()
                .task {
                    // Set the notification delegate so foreground notifications present.
                    UNUserNotificationCenter.current().delegate = NotificationManager.shared
                    // Seed the built-in minimums profiles on first launch (idempotent).
                    MinimumsProfile.seedBuiltInsIfNeeded(in: sharedModelContainer.mainContext)
                    // Submit an initial background alert-check request.
                    AlertScheduler.schedule()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Re-submit when entering background (the canonical place — that's when iOS
                    // starts considering the task). Safe to call repeatedly; it replaces the
                    // pending request for the same identifier.
                    if phase == .background { AlertScheduler.schedule() }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

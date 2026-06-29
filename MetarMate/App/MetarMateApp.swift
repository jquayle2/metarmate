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
        // NOTE: register() must NOT touch sharedModelContainer — doing so would force-open the
        // App Group store on every launch, including pure background (BGTask) launches, leaving
        // its WAL lock held across the subsequent suspension. That lock-across-suspension is
        // exactly what RunningBoard kills with 0xdead10cc. The task builds its own short-lived
        // container only when it actually fires.
        AlertScheduler.register()
    }

    // Lazy, process-wide singleton: a `static let` is built on first access, not during
    // App.init() or as a stored-property initializer. A foreground launch builds it when the
    // scene/`.task` below first touch it; a background-only launch never touches it, so the
    // store is never opened (and never locked) in that path.
    static let sharedModelContainer: ModelContainer = ModelStore.makeContainer()

    var body: some Scene {
        WindowGroup {
            SplashScreenView()
                .task {
                    // Set the notification delegate so foreground notifications present.
                    UNUserNotificationCenter.current().delegate = NotificationManager.shared
                    // Seed the built-in minimums profiles on first launch (idempotent).
                    MinimumsProfile.seedBuiltInsIfNeeded(in: Self.sharedModelContainer.mainContext)
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
        .modelContainer(Self.sharedModelContainer)
    }
}

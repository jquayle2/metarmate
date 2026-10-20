import SwiftUI
import SwiftData
import UserNotifications
import Combine
import os

// MARK: - Deep Link Router
// Bridges the widget's `.widgetURL(metarmate://airport/<ICAO>)` tap into a modal presentation
// of that airport's detail page. A plain @Published property (not a NavigationPath) because the
// target is a fullScreenCover from the app root, independent of whichever tab/stack is active.
@MainActor
final class DeepLinkRouter: ObservableObject {
    @Published var requestedAirport: Airport?
}

@main
struct MetarMateApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var deepLinkRouter = DeepLinkRouter()

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
    // App.init() or as a stored-property initializer. Every access sits inside the WindowGroup
    // content closure, which SwiftUI only runs when a scene connects. A background-only launch
    // (BGTask, Siri) may still evaluate `body`, but should never build the window content, so
    // the store is never opened (and never locked) in that path. The "[store] container opened"
    // log in ModelStore.makeContainer records the app state, to confirm this on device.
    static let sharedModelContainer: ModelContainer = ModelStore.makeContainer(for: "app")

    var body: some Scene {
        WindowGroup {
            SplashScreenView()
                .task {
                    // Log the App Store receipt filename at launch so the Test Harness gate's real
                    // runtime value is observable in any build (incl. a Release-config run). This is
                    // the honest production-unreachability evidence: the gate is DENIED unless this
                    // reads "sandboxReceipt" (Debug/TestFlight); an App Store install reads "receipt".
                    Log.load.info("[harness] launch receiptName=\(TestHarnessGate.receiptName ?? "nil", privacy: .public) harnessAvailable=\(TestHarnessGate.isAvailable, privacy: .public)")
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
                    // Re-check entitlements on every foreground so the widget's App Group
                    // Pro flag is rewritten and timelines reloaded — guards against a missed
                    // reload leaving the widget stuck on "Pro Required".
                    if phase == .active { Task { await StoreManager.shared.checkEntitlements() } }
                }
                .onOpenURL { url in
                    // metarmate://airport/<ICAO> — sent by the home screen widget's widgetURL.
                    guard url.scheme == "metarmate", url.host == "airport" else { return }
                    let icao = url.lastPathComponent.uppercased()
                    guard let airport = AirportService.shared.airport(icao: icao) else { return }
                    deepLinkRouter.requestedAirport = airport
                }
                .fullScreenCover(item: $deepLinkRouter.requestedAirport) { airport in
                    NavigationStack {
                        WeatherDetailView(airport: airport)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button("Close") { deepLinkRouter.requestedAirport = nil }
                                }
                            }
                    }
                }
                // On the window content, not the Scene: a Scene modifier's argument is evaluated
                // whenever `body` is, which would open the App Group store on background launches.
                .modelContainer(Self.sharedModelContainer)
        }
    }
}

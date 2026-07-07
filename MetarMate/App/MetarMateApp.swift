import SwiftUI
import SwiftData
import UserNotifications

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
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
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
        }
        .modelContainer(sharedModelContainer)
    }
}

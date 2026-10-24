import Foundation
import os
import SwiftData
import UIKit

// MARK: - Schema versions (audit #23)
// V1 is the schema every shipped build has used, unversioned until now. Its models are the live
// classes, so V1 matches the current models exactly. A future model change adds SchemaV2 (with
// frozen copies of the V1 classes moved in here) and a stage in MetarMateMigrationPlan.
nonisolated enum MetarMateSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [AirportFavorite.self, MinimumsProfile.self, AirportWatch.self]
    }
}

nonisolated enum MetarMateMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MetarMateSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - ModelStore
// The single source of truth for the SwiftData store's schema, configuration, and
// container construction. BOTH the app (long-lived container) and the background alert
// task (short-lived, per-run container) build through here, so they can never drift to
// mismatched URLs / schemas — the classic cross-context SwiftData lock-fight cause.
//
// The app never crashes on a store that won't open (audit #23, Jeff Oct 23):
//   1. Retry once (a transient lock usually clears).
//   2. Still failing: open an in-memory store for this session and tell the user nothing was
//      lost. The store on disk is untouched, so the next launch tries it again.
//   3. Only after `moveAsideAfterFailures` failed launches in a row are the store and its
//      -wal/-shm sidecars moved aside together (renamed, never deleted) and a fresh store created.
// The background task never recovers: if the store won't open it skips the run.
//
// We never delete the -wal on its own: in WAL mode, committed transactions live in the -wal
// until SQLite checkpoints them into the main file. Deleting it silently discards those
// commits and can leave the main file inconsistent. The three files only make sense as a set.
enum ModelStore {
    static let appGroupID = "group.com.jeffquayle.MetarMate"
    static let storeName = "MetarMate.store"
    static let moveAsideAfterFailures = 3
    // In the app's own defaults, not the App Group store this counts failures of.
    static let failureCountKey = "store.consecutiveOpenFailures"

    static var schema: Schema {
        Schema(versionedSchema: MetarMateSchemaV1.self)
    }

    // The store lives in the shared App Group container so the app and the background
    // alert task read/write the same SwiftData store. nil if the App Group is unavailable
    // (a provisioning error); the app then runs on an in-memory store instead of crashing.
    static var storeURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(storeName)
    }

    // MARK: Open outcome (read by ContentView for the notice)

    enum Outcome: Equatable {
        case opened
        case inMemory(consecutiveFailures: Int)
        case movedAside
    }

    /// How the app's container opened this launch. Set once by `makeContainer(for:)`.
    private(set) static var appOutcome: Outcome = .opened

    private static var appStateDescription: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    // UTC stamp for moved-aside filenames, e.g. "MetarMate.store.corrupt-20261016-185300".
    private static let corruptStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func open(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: schema,
                           migrationPlan: MetarMateMigrationPlan.self,
                           configurations: [ModelConfiguration(schema: schema, url: url)])
    }

    static func makeInMemoryContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: schema,
                                      configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        } catch {
            // An in-memory store has no file to be corrupt or locked; this fails only if the
            // schema itself is invalid, which no launch-time recovery can fix.
            fatalError("In-memory ModelContainer failed; the schema is invalid: \(error)")
        }
    }

    // MARK: App container

    /// The app's long-lived container. Never crashes on a store that won't open (see above).
    /// `owner` names the caller for the open log, which records the application state so a
    /// device log shows whether the store was ever opened during a background launch.
    static func makeContainer(for owner: String) -> ModelContainer {
        Log.load.info("[store] container opened for=\(owner, privacy: .public) appState=\(appStateDescription, privacy: .public)")
        let (container, outcome) = makeAppContainer(storeURL: storeURL, defaults: .standard)
        appOutcome = outcome
        return container
    }

    /// Testable core of `makeContainer(for:)`: the URL, defaults and retry delay are injected.
    static func makeAppContainer(storeURL: URL?, defaults: UserDefaults,
                                 retryDelay: TimeInterval = 0.5) -> (ModelContainer, Outcome) {
        guard let storeURL else {
            Log.load.error("[store] App Group \(appGroupID, privacy: .public) unavailable; using an in-memory store")
            return (makeInMemoryContainer(), .inMemory(consecutiveFailures: 0))
        }

        for attempt in 1...2 {
            do {
                let container = try open(at: storeURL)
                defaults.set(0, forKey: failureCountKey)
                return (container, .opened)
            } catch {
                Log.load.error("[store] open attempt \(attempt) failed at \(storeURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                if attempt == 1 { Thread.sleep(forTimeInterval: retryDelay) }
            }
        }

        let failures = defaults.integer(forKey: failureCountKey) + 1
        if failures >= moveAsideAfterFailures {
            Log.load.error("[store] \(failures) failed launches in a row; moving the store aside")
            let freshURL = moveAside(storeURL)
            if let container = try? open(at: freshURL) {
                Log.load.error("[store] created fresh store at \(freshURL.lastPathComponent, privacy: .public)")
                defaults.set(0, forKey: failureCountKey)
                return (container, .movedAside)
            }
            Log.load.error("[store] fresh store failed to open too; using an in-memory store")
        }
        defaults.set(failures, forKey: failureCountKey)
        return (makeInMemoryContainer(), .inMemory(consecutiveFailures: failures))
    }

    // Move the store and its sidecars aside as a set and return the URL to open the fresh store
    // at. Sidecars are named by appending to the FULL store filename ("MetarMate.store-wal"), so
    // build paths by string append — appendingPathExtension would wrongly yield "MetarMate.store.wal".
    // Nothing here deletes a file.
    private static func moveAside(_ storeURL: URL) -> URL {
        let fm = FileManager.default
        let stamp = corruptStampFormatter.string(from: Date())
        let corruptBase = storeURL.path + ".corrupt-" + stamp
        var renameFailed = false
        for suffix in ["", "-wal", "-shm"] {
            let source = storeURL.path + suffix
            guard fm.fileExists(atPath: source) else { continue }
            let destination = corruptBase + suffix
            do {
                try fm.moveItem(atPath: source, toPath: destination)
                Log.load.error("[store] moved \((source as NSString).lastPathComponent, privacy: .public) aside to \((destination as NSString).lastPathComponent, privacy: .public)")
            } catch {
                renameFailed = true
                Log.load.error("[store] could not move \((source as NSString).lastPathComponent, privacy: .public) aside: \(String(describing: error), privacy: .public)")
            }
        }
        // If any rename failed, the original URL may still hold some of the old files (e.g. a
        // stray -wal SQLite would try to replay), so open the fresh store at a new URL instead.
        return renameFailed ? URL(fileURLWithPath: storeURL.path + ".fresh-" + stamp) : storeURL
    }

    // MARK: Background container

    /// A short-lived container for the background alert task, or nil if the store won't open.
    /// Never retries, recovers or counts failures: moving the store aside from the background
    /// would hide the user's data without telling them, so the run is skipped instead.
    static func makeBackgroundContainer() -> ModelContainer? {
        Log.load.info("[store] container opened for=bgtask appState=\(appStateDescription, privacy: .public)")
        guard let storeURL else {
            Log.load.error("[store] bgtask: App Group unavailable; skipping")
            return nil
        }
        do {
            return try open(at: storeURL)
        } catch {
            Log.load.error("[store] bgtask: open failed, skipping this run: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

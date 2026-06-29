import Foundation
import SwiftData

// MARK: - ModelStore
// The single source of truth for the SwiftData store's schema, configuration, and
// container construction. BOTH the app (long-lived container) and the background alert
// task (short-lived, per-run container) build through here, so they can never drift to
// mismatched URLs / schemas — the classic cross-context SwiftData lock-fight cause.
//
// Container creation includes WAL-sidecar recovery: a failed open is usually a stale or
// locked -wal/-shm sidecar left behind when a prior run (often a background task) was
// killed mid-write, or a schema mismatch (SwiftData 134110). Clearing the sidecars
// preserves the real data in MetarMate.store and lets SQLite rebuild them cleanly.
enum ModelStore {
    static let appGroupID = "group.com.jeffquayle.MetarMate"
    static let storeName = "MetarMate.store"

    static var schema: Schema {
        Schema([AirportFavorite.self, MinimumsProfile.self, AirportWatch.self])
    }

    // The store lives in the shared App Group container so the app and the background
    // alert task read/write the same SwiftData store. App Group being unavailable is an
    // unrecoverable provisioning error, not a runtime condition, so it stays fatal.
    static var storeURL: URL {
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            fatalError("App Group container \(appGroupID) is unavailable")
        }
        return groupURL.appendingPathComponent(storeName)
    }

    static func makeConfiguration() -> ModelConfiguration {
        ModelConfiguration(schema: schema, url: storeURL)
    }

    // Build a container, recovering from a corrupt/locked store rather than crashing.
    static func makeContainer() -> ModelContainer {
        let schema = self.schema
        let config = makeConfiguration()
        let storeURL = self.storeURL

        func build() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [config])
        }

        do {
            return try build()
        } catch {
            // Sidecars are named by appending to the FULL store filename:
            // "MetarMate.store-wal" / "MetarMate.store-shm". Build the paths by string
            // append — appendingPathExtension would wrongly yield "MetarMate.store.wal".
            let fm = FileManager.default
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
    }
}

import Foundation
import os
import SwiftData
import UIKit

// MARK: - ModelStore
// The single source of truth for the SwiftData store's schema, configuration, and
// container construction. BOTH the app (long-lived container) and the background alert
// task (short-lived, per-run container) build through here, so they can never drift to
// mismatched URLs / schemas — the classic cross-context SwiftData lock-fight cause.
//
// Container creation includes non-destructive recovery: if the store won't open, the store
// and its -wal/-shm sidecars are moved aside together (renamed, never deleted) and a fresh
// store is created, so the user's data stays on disk for later recovery.
//
// We never delete the -wal on its own: in WAL mode, committed transactions live in the -wal
// until SQLite checkpoints them into the main file. Deleting it silently discards those
// commits and can leave the main file inconsistent. The three files only make sense as a set.
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

    // Build a container, recovering from a corrupt/locked store rather than crashing.
    // Nothing in this path deletes a file. `owner` names the caller ("app" / "bgtask") for the
    // open log, which records the application state so a device log shows whether the store
    // was ever opened during a background launch.
    static func makeContainer(for owner: String) -> ModelContainer {
        Log.load.info("[store] container opened for=\(owner, privacy: .public) appState=\(appStateDescription, privacy: .public)")
        let schema = self.schema
        let storeURL = self.storeURL

        func build(at url: URL) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        }

        do {
            return try build(at: storeURL)
        } catch {
            Log.load.error("[store] open failed at \(storeURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        // Move the store and its sidecars aside as a set. Sidecars are named by appending to
        // the FULL store filename ("MetarMate.store-wal"), so build paths by string append —
        // appendingPathExtension would wrongly yield "MetarMate.store.wal".
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
        let freshURL = renameFailed
            ? URL(fileURLWithPath: storeURL.path + ".fresh-" + stamp)
            : storeURL
        do {
            let container = try build(at: freshURL)
            Log.load.error("[store] created fresh store at \(freshURL.lastPathComponent, privacy: .public)")
            return container
        } catch {
            fatalError("Could not create ModelContainer even after recovery: \(error)")
        }
    }
}

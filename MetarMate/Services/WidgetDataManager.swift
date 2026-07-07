import Foundation
import WidgetKit

// MARK: - Widget Data Manager
// Reads and writes WidgetWeatherSnapshots via the App Group shared container.
// Used by the main app (write) and the widget extension (read).
// Fully nonisolated — safe to call from any context including widget TimelineProvider.

nonisolated enum WidgetDataManager {
    static let appGroupID = "group.com.jeffquayle.MetarMate"
    private static let snapshotPrefix = "widget.snapshot."
    private static let configKey = "widget.configs"
    static let isProKey = "widget.isPro"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Write (called by main app after every weather fetch)

    nonisolated static func save(snapshot: WidgetWeatherSnapshot) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotPrefix + snapshot.icao)
        reloadWidgets()
    }

    nonisolated static func save(snapshots: [WidgetWeatherSnapshot]) {
        for snapshot in snapshots {
            save(snapshot: snapshot)
        }
    }

    // MARK: - Read (called by widget TimelineProvider)

    nonisolated static func load(icao: String) -> WidgetWeatherSnapshot? {
        guard let defaults = sharedDefaults else { return nil }
        guard let data = defaults.data(forKey: snapshotPrefix + icao) else { return nil }
        return try? JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)
    }

    nonisolated static func loadAll() -> [WidgetWeatherSnapshot] {
        guard let defaults = sharedDefaults else { return [] }
        let dict = defaults.dictionaryRepresentation()
        return dict.keys
            .filter { $0.hasPrefix(snapshotPrefix) }
            .compactMap { key -> WidgetWeatherSnapshot? in
                guard let data = defaults.data(forKey: key) else { return nil }
                return try? JSONDecoder().decode(WidgetWeatherSnapshot.self, from: data)
            }
            .sorted { $0.icao < $1.icao }
    }

    // MARK: - Delete

    nonisolated static func remove(icao: String) {
        sharedDefaults?.removeObject(forKey: snapshotPrefix + icao)
    }

    nonisolated static func removeAll() {
        guard let defaults = sharedDefaults else { return }
        let dict = defaults.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix(snapshotPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Freshest snapshot (for single-airport widget default)

    nonisolated static func mostRecent() -> WidgetWeatherSnapshot? {
        loadAll().max(by: { $0.snapshotTime < $1.snapshotTime })
    }

    // MARK: - Widget configuration storage

    static func saveConfigs(_ configs: [String: WidgetAirportConfig]) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: configKey)
    }

    nonisolated static func loadConfigs() -> [String: WidgetAirportConfig] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: configKey) else { return [:] }
        return (try? JSONDecoder().decode([String: WidgetAirportConfig].self, from: data)) ?? [:]
    }

    // MARK: - Pro status (written by main app, read by widget extension)

    nonisolated static func saveProStatus(_ isPro: Bool) {
        sharedDefaults?.set(isPro, forKey: isProKey)
        reloadWidgets()
    }

    nonisolated static func loadProStatus() -> Bool {
        sharedDefaults?.bool(forKey: isProKey) ?? false
    }

    // MARK: - Reload all MetarMate widgets
    // Called after every snapshot write so the widget picks up fresh data immediately.

    nonisolated static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

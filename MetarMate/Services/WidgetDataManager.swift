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

    /// `reload: false` from the widget's own TimelineProvider: reloading from inside a timeline
    /// run re-triggers every widget, which loops and burns WidgetKit's daily reload budget.
    nonisolated static func save(snapshot: WidgetWeatherSnapshot, reload: Bool = true) {
        guard let defaults = sharedDefaults else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotPrefix + snapshot.icao)
        if reload { reloadWidgets() }
    }

    nonisolated static func save(snapshots: [WidgetWeatherSnapshot]) {
        for snapshot in snapshots {
            save(snapshot: snapshot, reload: false)
        }
        if !snapshots.isEmpty { reloadWidgets() }
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

    /// The last Pro status the app saved, or nil if it has never saved one (fresh install).
    nonisolated static func savedProStatus() -> Bool? {
        sharedDefaults?.object(forKey: isProKey) as? Bool
    }

    // MARK: - Widget run diagnostics (written by the widget extension, all builds)
    // Last `diagCapacity` provider runs, newest last, as plain strings so they read directly from
    // the App Group plist pulled off a device. Tiny (~100 bytes per line); no personal data.
    private static let diagKey = "widget.diag"
    private static let diagCapacity = 40

    nonisolated static func appendDiag(_ line: String) {
        guard let defaults = sharedDefaults else { return }
        var lines = defaults.stringArray(forKey: diagKey) ?? []
        lines.append(line)
        if lines.count > diagCapacity { lines.removeFirst(lines.count - diagCapacity) }
        defaults.set(lines, forKey: diagKey)
    }

    nonisolated static func diagLines() -> [String] {
        sharedDefaults?.stringArray(forKey: diagKey) ?? []
    }

    #if DEBUG
    // MARK: - Debug: forced report age (DEBUG builds only; compiled out of Release)
    // Makes every widget treat its report as exactly N minutes old at each timeline refresh, to
    // exercise the late (65 min) and no-current (75 min) states without waiting. Written by the
    // app's harness screen; read only by the widget's timeline provider. 0 = off.
    private static let debugForcedObsAgeKey = "debug.widget.forcedObsAgeMinutes"

    nonisolated static func setDebugForcedObsAge(minutes: Int) {
        sharedDefaults?.set(minutes, forKey: debugForcedObsAgeKey)
        reloadWidgets()
    }

    nonisolated static func debugForcedObsAgeMinutes() -> Int {
        sharedDefaults?.integer(forKey: debugForcedObsAgeKey) ?? 0
    }
    #endif

    // MARK: - Reload all MetarMate widgets
    // Called after app-side snapshot writes so the widget picks up fresh data immediately.

    nonisolated static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}

import SwiftUI
import SwiftData
import WidgetKit

// MARK: - WidgetVerdictSync
// Keeps the widget's verdict inputs in the App Group current (D#20): the profile from
// VerdictProfile.current() and runway ends for every airport a widget may show — each configured
// widget's airport, every favorite, and every airport with a snapshot (opened in the app; the
// unconfigured widget falls back to the most recent one). Without runways the widget can only say
// "crosswind: no runway data", so that CHECK is left for fields genuinely missing from runways.json.
@MainActor
enum WidgetVerdictSync {

    /// Profile + runways for every relevant airport; reloads timelines only if something changed.
    static func syncAll(in context: ModelContext) async {
        var changed = publishProfile(in: context)
        var icaos = Set(WidgetDataManager.loadAll().map(\.icao))
        icaos.formUnion(((try? context.fetch(FetchDescriptor<AirportFavorite>())) ?? []).map(\.icao))
        icaos.formUnion(await configuredWidgetICAOs())
        changed = publishRunways(for: Array(icaos)) || changed
        if changed { WidgetDataManager.reloadWidgets() }
    }

    /// Writes the current verdict profile. True when it differs from what the widget had.
    @discardableResult
    static func publishProfile(in context: ModelContext) -> Bool {
        guard let profile = VerdictProfile.current(in: context) else { return false }
        return WidgetDataManager.saveVerdictProfile(GoNoGoEvaluator.snapshot(of: profile))
    }

    /// Writes each airport's runway ends (an empty list when runways.json has none).
    @discardableResult
    static func publishRunways(for icaos: [String]) -> Bool {
        var changed = false
        for icao in icaos {
            changed = WidgetDataManager.saveRunways(RunwayService.shared.runways(for: icao.uppercased()),
                                                    icao: icao) || changed
        }
        return changed
    }

    /// The airport typed into each placed widget (SelectAirportIntent), uppercased like the widget does.
    private static func configuredWidgetICAOs() async -> [String] {
        // getCurrentConfigurations: the async currentConfigurations() is iOS 18+.
        let widgets: [WidgetInfo] = await withCheckedContinuation { done in
            WidgetCenter.shared.getCurrentConfigurations { done.resume(returning: (try? $0.get()) ?? []) }
        }
        return widgets.compactMap { info in
            info.widgetConfigurationIntent(of: SelectAirportIntent.self)?.airportCode?
                .uppercased().trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    }
}

// MARK: - Sync triggers
// Attached at the app root, inside the model container. Re-publishes when the active profile is
// switched, a profile is edited (limits or name), Pro status changes (a lapsed custom profile
// falls back to a starter), or favorites change.
struct WidgetVerdictSyncModifier: ViewModifier {
    @Environment(\.modelContext) private var context
    @ObservedObject private var store = StoreManager.shared
    @Query private var profiles: [MinimumsProfile]
    @Query private var favorites: [AirportFavorite]
    @AppStorage(ActiveMinimumsProfile.key) private var activeProfileID: String = ""

    private var profileSignature: String {
        activeProfileID + "|" + profiles.map {
            "\($0.activeToken):\($0.name):\(String(describing: $0.maxCrosswindKt)):\(String(describing: $0.maxGustKt)):"
                + "\(String(describing: $0.minVisibilitySM)):\(String(describing: $0.minCeilingFt)):"
                + "\(String(describing: $0.minFlightCategory)):\(String(describing: $0.maxSustainedWindKt))"
        }.sorted().joined(separator: ",")
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: profileSignature) {
                if WidgetVerdictSync.publishProfile(in: context) { WidgetDataManager.reloadWidgets() }
            }
            .onChange(of: store.isProForVerdicts) {
                if WidgetVerdictSync.publishProfile(in: context) { WidgetDataManager.reloadWidgets() }
            }
            .onChange(of: favorites.map(\.icao)) { _, icaos in
                if WidgetVerdictSync.publishRunways(for: icaos) { WidgetDataManager.reloadWidgets() }
            }
    }
}

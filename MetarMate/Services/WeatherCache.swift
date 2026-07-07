import SwiftUI
import Combine

// MARK: - WeatherCache
// A shared, freshness-aware store for fetched weather, keyed by the app's opaque airport id
// (the `icao` field — raw FAA LIDs for ~12,500 records, not always a true ICAO; treated purely
// as the app key, matching how the list views already key their dictionaries).
//
// Purpose (Phase 1): tab list views hold their fetch results in local @State, which SwiftUI
// tears down on tab switch and rebuilds on return — forcing a full re-fetch every visit. This
// singleton survives tab switches, so a view can read-through it: use a fresh cached value if
// present, and only fetch the misses. Weather-only — no go/no-go evaluation, runway math, or
// ASOS/Synoptic data lives here.
@MainActor
final class WeatherCache: ObservableObject {
    static let shared = WeatherCache()
    private init() {}

    struct Entry<T> {
        let value: T
        let fetchedAt: Date
    }

    @Published private(set) var metars: [String: Entry<Metar>] = [:]
    @Published private(set) var advisories: [String: Entry<AdvisoryWeather>] = [:]

    /// 5-minute freshness window — matches the app's existing 5-min auto-refresh cadence.
    static let freshness: TimeInterval = 5 * 60

    // MARK: Reads — return the value only if present AND fresh, else nil.
    func freshMetar(for icao: String) -> Metar? {
        guard let e = metars[icao], Date().timeIntervalSince(e.fetchedAt) < Self.freshness else { return nil }
        return e.value
    }
    func freshAdvisory(for icao: String) -> AdvisoryWeather? {
        guard let e = advisories[icao], Date().timeIntervalSince(e.fetchedAt) < Self.freshness else { return nil }
        return e.value
    }

    // MARK: Writes — stamp with now.
    func store(metar: Metar, for icao: String) { metars[icao] = Entry(value: metar, fetchedAt: Date()) }
    func store(advisory: AdvisoryWeather, for icao: String) { advisories[icao] = Entry(value: advisory, fetchedAt: Date()) }

    // Bulk store for the batch fetches the views already do.
    func store(metars newMetars: [String: Metar]) {
        let now = Date()
        for (k, v) in newMetars { metars[k] = Entry(value: v, fetchedAt: now) }
    }
    func store(advisories newAdv: [String: AdvisoryWeather]) {
        let now = Date()
        for (k, v) in newAdv { advisories[k] = Entry(value: v, fetchedAt: now) }
    }
}

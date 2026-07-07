# Handoff: Shared Weather Cache (Phase 1)

**Branch:** `feature/weather-cache` (already cut from `main`, pushed)
**Goal:** Stop the app re-fetching weather from scratch every time the user switches tabs. Hold fetched weather in a shared, freshness-aware cache so a tab is instant on every visit after the first.

**Scope discipline:** This is Phase 1 — the cache only. Do NOT build launch prefetch (that is Phase 2, spec'd at the bottom, decision deferred until the cache is tested on-device). Keep each view's existing fetch logic intact; only change *where the results are stored and read from*.

---

## The problem (why we're doing this)

Today, each tab's list view fetches weather in a SwiftUI `.task` and stores results in **local `@State`** (e.g. `FavoritesView` has `@State private var favMetars: [String: Metar]` and `favAdvisories`). Because that state is local to the view, SwiftUI tears it down when the user switches tabs and rebuilds it on return — so every tab visit re-fetches from NOAA/Open-Meteo from scratch. That is the wait the user sees, and it also hammers the APIs needlessly.

The detail view (`WeatherViewModel.load(airport:)`) already has a 60-second staleness guard, so the concept of "don't re-fetch if recent" is established in the codebase. This brief extends that idea to the tab-level list views with a shared store.

---

## What to build

### 1. New file: `MetarMate/Services/WeatherCache.swift`

A `@MainActor`, `ObservableObject` singleton that holds fetched weather keyed by the airport id (the same `icao` field used everywhere else in the app — note that field holds raw FAA LIDs for ~12,500 records, not always true ICAOs; treat it purely as the app's opaque airport key, matching how the views already key their dictionaries).

Structure (illustrative — match house style):

```swift
import SwiftUI

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

    // Read helpers: return the value only if present AND fresh; else nil.
    func freshMetar(for icao: String) -> Metar? {
        guard let e = metars[icao], Date().timeIntervalSince(e.fetchedAt) < Self.freshness else { return nil }
        return e.value
    }
    func freshAdvisory(for icao: String) -> AdvisoryWeather? {
        guard let e = advisories[icao], Date().timeIntervalSince(e.fetchedAt) < Self.freshness else { return nil }
        return e.value
    }

    // Write helpers: stamp with now.
    func store(metar: Metar, for icao: String) { metars[icao] = Entry(value: metar, fetchedAt: Date()) }
    func store(advisory: AdvisoryWeather, for icao: String) { advisories[icao] = Entry(value: advisory, fetchedAt: Date()) }

    // Bulk store (for the batch fetches the views already do).
    func store(metars newMetars: [String: Metar]) { let now = Date(); for (k, v) in newMetars { metars[k] = Entry(value: v, fetchedAt: now) } }
    func store(advisories newAdv: [String: AdvisoryWeather]) { let now = Date(); for (k, v) in newAdv { advisories[k] = Entry(value: v, fetchedAt: now) } }
}
```

Notes:
- Keep it weather-only. Do NOT put go/no-go evaluation, runway math, or ASOS/Synoptic data in here for Phase 1. (ASOS is Pro-gated and detail-view-only; leave it as-is.)
- `private(set)` on the published dicts so only the store's own methods mutate them.

### 2. Inject the cache app-wide

In `ContentView`, add it as an environment object alongside the existing ones so every tab can read it:

```swift
@StateObject private var weatherCache = WeatherCache.shared
```

and `.environmentObject(weatherCache)` on the `TabView` (or on each tab, matching how `airportVM` is currently injected). Confirm every data view that needs it declares `@EnvironmentObject var weatherCache: WeatherCache`.

### 3. Rewire each list view to read-through the cache

The pattern for every data-bearing view is identical: **before fetching an airport's weather, check the cache for a fresh value; use it if present; only fetch the misses; write fetched results back to the cache.**

Apply to these four views (XWind is a pure calculator — do not touch it):

**a. `FavoritesView.swift`** — currently `fetchMetars()` writes to `@State favMetars` / `favAdvisories`.
- Keep the existing LID-resolution and advisory-fallback logic exactly as-is.
- Before the NOAA batch call, split favorites into those with a fresh cached METAR (use it) vs. those that need fetching (fetch only those).
- After fetching, `weatherCache.store(metars:)` / `store(advisories:)` the results.
- The view's displayed data should come from the cache (fresh cached + newly fetched), not a throwaway local dict. Simplest correct approach: keep the local `@State` dicts as the *view's render source*, but populate them from `weatherCache.freshMetar(...)` first and only fetch+store the gaps. This keeps the view body unchanged while making revisits instant.

**b. `NearestAirportsView.swift`** — GPS-driven nearby airports + batch METARs. Same pattern: check cache per airport, fetch only misses, store results. Preserve the GPS/location logic untouched.

**c. `SearchView.swift`** — the persistent search-history list shows weather for previously-searched airports. Same read-through pattern for the history rows. (The live search itself is user-driven and fetches on demand — that part is fine as-is; only the *history rows'* weather should read-through the cache.)

**d. `AlertsView.swift`** — watched airports. Read weather through the cache; the go/no-go evaluation then runs off whatever weather it gets (cached or freshly fetched). Do NOT pre-run or cache the evaluation itself — evaluate on appear from cached weather, exactly as it does now, just sourcing the weather from the cache.

### 4. Manual refresh must bypass freshness

Pull-to-refresh (all four views have it) should **force** a re-fetch and overwrite the cache, ignoring the 5-min window. Implement by having the fetch path take a `force: Bool` (or similar) that skips the `freshMetar`/`freshAdvisory` short-circuit when the user explicitly pulls to refresh. The 5-min window only governs *automatic* reads on view appear.

---

## Acceptance checks (verify before commit)

1. `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5` gives BUILD SUCCEEDED.
2. First visit to Favorites fetches and shows weather (unchanged behavior).
3. Switch to another tab and back within 5 min — Favorites renders **instantly**, no spinner, no network call.
4. Wait over 5 min, revisit — data re-fetches (freshness expired).
5. Pull-to-refresh on any tab — forces a fresh fetch even if within the 5-min window, and updates the cache (so other tabs see the fresh data too).
6. Nearest, Search history, and Alerts all show the same instant-on-revisit behavior.
7. No behavior change to XWind, ASOS/Synoptic, go/no-go logic, or the detail view.

---

## Files expected to change (for Pi image tracking)

- `MetarMate/Services/WeatherCache.swift` — **new**
- `MetarMate/Views/ContentView.swift` — inject environment object
- `MetarMate/Views/FavoritesView.swift` — read-through cache
- `MetarMate/Views/NearestAirportsView.swift` — read-through cache
- `MetarMate/Views/SearchView.swift` — read-through cache (history rows)
- `MetarMate/Views/AlertsView.swift` — read-through cache

---

## Conventions (house rules)

- No `#` characters in terminal commands; single-line, chained with `&&` or `;`.
- Commit incrementally with specific files: `git add <specific files> && git commit -m "..."` — never `git add -A`.
- Build-verify before each commit.
- Suggested commit cadence: (1) `WeatherCache.swift` + `ContentView` injection, (2) FavoritesView, (3) NearestAirportsView, (4) SearchView, (5) AlertsView. One commit per view keeps the history reviewable and each step independently testable on-device.

---

## Phase 2 — Launch prefetch (DO NOT BUILD YET)

Deferred pending on-device evaluation of the cache alone. Spec'd here so the idea isn't lost.

Once the cache exists, a launch-time prefetch task can warm it *before* the user visits each tab, so even the first visit is instant. Priority order (decided): **current tab's airports first, then Favorites, then Search history, then Nearest, then Alerts.** Weather-only — no go/no-go pre-evaluation.

Concern to weigh after testing: prefetch adds a burst of network calls at launch that competes with the tab the user is actually looking at, and can make the app feel busy right at open. The cache alone may already feel fast enough that prefetch isn't worth the added orchestration. Decide after feeling the cache-only build on-device.

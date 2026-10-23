# MetarMate — Full Codebase Audit (Oct 12, 2026)

> Copied into the repo Oct 23, 2026 from Project knowledge (`claude/AUDIT_2026-10-12_full_codebase.md`) so Claude Code sessions can read it. Line numbers refer to build 20 (5ad1b4b); re-verify against HEAD. Status of each item lives in `docs/LAUNCH_CHECKLIST.md`, not here.

**Audited:** `origin/feat/trend-time-spine` @ `5ad1b4b` (build 1.2 (20), Sept 19) — read-only, ~17K lines Swift.
**Method:** three parallel deep reads (parsers/models, services/persistence/widget, pilot-facing logic/UI), with the top items spot-checked by hand. No build was run (Linux sandbox), so every item is code-path verified, not device-verified.
**Not covered:** Android, any local-only commits on JAQ-Studio-Mac not pushed to origin.

Severity: **P0** = fix before next TestFlight · **P1** = can make conditions look better than they are · **P2** = must fix before App Store release · **P3** = polish/hygiene.

---

## P0 — Fix before next TestFlight

### 1. Widget doesn't refresh until the app is opened; refresh button does nothing (user-reported, root-caused)
- **Reload loop burns WidgetKit's budget.** `ConfigurableProvider.timeline()` and `snapshot()` (`MetarMateWidget.swift:123, 141`) call `WidgetDataManager.save(snapshot:)`, which calls `WidgetCenter.shared.reloadAllTimelines()` (`WidgetDataManager.swift:25-29`). Every timeline run therefore re-triggers all 5 widget kinds, each of which fetches and reloads again. iOS throttles this, the daily reload budget is gone early, and further reloads are ignored. Opening the app works because reloads requested by a foreground app aren't budgeted, and the app writes fresh snapshots itself.
- **Refresh button.** `RefreshWidgetIntent.perform()` calls `reloadAllTimelines()` from the extension — also a budgeted request, so once the budget is spent it's a no-op. The system already reloads the tapped widget's timeline after an interactive intent finishes, so this call is redundant at best.
- **Trend/TAF fields are app-only.** The widget's own fetch sets `trendHeadline = "Widget Refresh"` / `trendDirection = .unknown`, and `mergeWithCached` keeps the *cached* trend, TAF accuracy and forecast deviation from the last app session. Those lines will always lag until the app opens, even after the loop is fixed.
- **Age text is frozen.** `ageString()` is computed once per timeline entry, so "12m ago" stays "12m ago" until the next reload — the widget looks stuck even when it isn't. Also, METARs only change about once an hour, so a refresh at :20 correctly returns the same :53 ob.
- **Fix:**
  1. `save(snapshot:reload: Bool = true)`; pass `reload: false` from the widget provider. Make `save(snapshots:)` reload once per batch.
  2. `RefreshWidgetIntent.perform()` → just `return .result()` (the system reloads the widget).
  3. Widget fetch: `URLRequest` with `.reloadIgnoringLocalCacheData` and a ~10 s timeout (currently `URLSession.shared`, 60 s default).
  4. Show age with `Text(snap.observationTime, style: .relative)` so it ticks without reloads.
  5. Either drop the trend line on widget-only refreshes or label it "as of <time>".

### 2. 0xdead10cc launch-crash exposure is live in this branch (Confirmed)
- `MetarMateApp.swift:32-47` builds `sharedModelContainer` eagerly in `App.init` on **every** launch (background alert task and Siri launches included), in the App Group container, and passes it to `AlertScheduler.register`. The `lazy static let` fix only exists on a local branch (`fix/swiftdata-launch-crash-0xdead10cc` is not on origin).
- The background path makes it worse: `AlertPipeline.runChecks` saves (`:46`) right before `setTaskCompleted`, and the expiry path keeps working and saving after `work.cancel()` (see #13).
- **Fix (minimal):** `enum AppStore { static let container = … }`; `register()` takes no container and touches `AppStore.container` only once there's work; `.modelContainer(AppStore.container)`; skip the save if `Task.isCancelled`.
- **Fix (robust):** the widget never uses SwiftData (it only uses App Group `UserDefaults`), so move the store out of the App Group into Application Support (one-time move of `.store`, `-wal`, `-shm`). That removes the shared-container lock rule entirely.

### 3. Synoptic/ASOS is live for every user despite `asosAvailable = false` (Confirmed)
- `StoreManager.isAsosUser = isAsosSubscriber || isAsosInFreePeriod` (60 days from first launch), and none of its call sites check `FeatureFlags.asosAvailable` (`WeatherViewModel.swift:92`, `AlertPipeline.swift:116`, `WeatherDetailView.swift:41`).
- Every beta user in their first 60 days hits Synoptic on each detail load, on every 5-min auto-refresh, and on every background alert run. There is **no 25/day limiter anywhere in code**, and the free period resets on reinstall.
- The token is hard-coded (`SynopticService.swift:16`) and sent as a query parameter. It can be extracted from the binary.
- **Fix:** `isAsosUser = FeatureFlags.asosAvailable && (…)`. Rotate the token. Long-term, put a small proxy in front of Synoptic that verifies the StoreKit JWS and enforces quotas.

---

## P1 — Can make conditions look better than they are

| # | Finding | Where | Notes |
|---|---|---|---|
| 4 | **Go/no-go goes GREEN when factors weren't evaluated** (F13, now with concrete paths). Unknown factors are dropped; `factors.allSatisfy` on an empty or partial list → GO, and a "Back within your minimums" alert is sent. | `GoNoGoEvaluator.swift:141`, `AlertPipeline.swift:150` | Example: vis sensor drops out while NO-GO for 2 SM → GO notification. Fix: tri-state factors; any unevaluated requested minimum → neutral "CHECK", never a transition to GO. |
| 5 | **VRB wind skips the "always tested" crosswind factor.** | `GoNoGoEvaluator.swift:70` | `VRB22G32KT` → GO with the default profile. Use gust ?? speed as the worst-case crosswind, or mark it not evaluated. |
| 6 | **Unknown sky = unlimited ceiling (99,000 ft)** in go/no-go. Missing `clouds` parses to `[]`. | `GoNoGoEvaluator.swift:117`, `MetarParser.swift:131` | Needs a "sky reported" signal. |
| 7 | **No staleness gate on verdicts.** A 3-hour-old VFR METAR keeps a green GO. | `AlertPipeline.swift:91-127` | Above ~75–90 min, show stale/unknown with a neutral badge. |
| 8 | **F15 still open, larger blast radius than logged.** Missing temp/dewp/altim → 0 °C / 0 °C / 29.92. | `MetarParser.swift:24-33` | Feeds density altitude (KLAS 42 °C day reads ~900 ft green instead of ~5,950 ft amber), a false "rapid falling" pressure trend, a false fog warning, and the **app-written** widget snapshot (`WidgetWeatherSnapshot.swift:110-112`). The F14 note claiming the widget reads from `raw` is only true for the widget's own fetch. |
| 9 | **Visibility trend goes blind against "10+" (P6SM).** `10+` → `1.5` FU reads "Stable Conditions" in the headline, widget and Siri. | `WeatherTrend.swift:210-213, 316-321` | The Flag-4 `.exactSM`-only rule over-corrected. Use interval ordering: `>10` vs `1.5` is clearly a decrease. `deriveOverall` should return `.unknown`, not `.steady`, when both axes are unknown. |
| 10 | **Missing wind direction → 000°, missing speed → 0 kt**, both flagged as reported. These feed crosswind, Pilot Notes and go/no-go. | `MetarParser.swift:62-85`, `TafParser.swift:104-122` | `///25KT` at runway 36 → "XW 0 kt". |
| 11 | **Red-tier crosswind hidden under "Red only" Pilot Notes.** Severity comes from speed/gust, the tier from the component. | `MetarPilotNotes.swift:97` | `27022KT` across the runway → 22 kt XW (danger) but severity `.caution`, so the section is hidden. |
| 12 | **Missing cloud base → 0 ft ceiling** (`var altitudeHundreds = 0`). | `MetarParser.swift:141`, `TafParser.swift:158` | `BKN///` → LIFR, a "0 ft" note, and a false "Ceiling Falling". |
| 13 | **TAF logic uses overlays, expired periods and expired TAFs.** ForecastTrend compares against TEMPO/PROB; TafVerification scores against expired TEMPOs; TafHeroBrief narrates from the first base period ("IFR now, improving by 4 AM" at 11 AM); `currentForecast` never checks `toTime`/`validTo` (`Taf.isValid` has no callers); BECMG never becomes prevailing. | `WeatherTrend.swift:311-331`, `TafVerification.swift:122`, `TafHeroBrief.swift:20-67`, `Taf.swift:35-58` | One "period covering time t" helper fixes most of these. |
| 14 | **TAF category reads VFR when one axis is unknown** (F7 only handles both unknown). Clouds aren't carried into overlays. | `TafParser.swift:199-212` | |
| 15 | **Missing `obsTime` → `Date()`**, so the ob looks fresh and sorts as newest. | `MetarParser.swift:10-15`, `TafParser.swift:9-17` | |
| 16 | **Unknown shown as good:** the `.unknown` TAF delta card gets the VFR-green rail; "Clear"/"CLR" is shown for an unknown sky (F18 widened); "Fcst on target" shows green when deviation data is nil; "Steady over the last 2 hrs" is based on wind only while VFR→IFR. | `WeatherDetailView.swift:1984, 3449, 1489-1497`; `MetarMateWidget.swift:610-618` | |
| 17 | **Lock-screen widgets** (circular/rectangular/inline) show cached data indefinitely with no age. `isStale` uses fetch time, not observation time. | `MetarMateWidget.swift:215-312`, `WidgetWeatherSnapshot.swift:60` | Overnight offline → green "KVGT VFR" on the lock screen. |
| 18 | **Category boundary drift (F9 regression in other functions).** | `WeatherDetailView.swift:654-656, 821`; `SynopticService.swift:285-286`; `AdvisoryWeather.swift:192-211` | `cloudLayerColor` uses `<3000`; Synoptic LIFR uses `<200`; the ASOS estimated category and advisory treat 3000 ft / 5 SM as VFR. |
| 19 | **TAF Pilot Notes miss strong steady winds and overlay gusts** (they require a gust ≥15). | `WeatherDetailView.swift:2185-2205` | `TEMPO 30035G50KT` → no wind mention. |
| 20 | **Gust approach-speed advice uses half the gust instead of half the gust factor.** 15G25 → "+12 kt" vs. the standard +5. The calculator uses a different formula. | `MetarPilotNotes.swift:113`, `WeatherDetailView.swift:917, 2224` | Ruled in D#8: ½ gust factor. |

---

## P2 — Release-readiness (App Store)

21. **Test harness visible to App Review.** Review builds carry `sandboxReceipt`, so the gate passes for reviewers → 2.2 rejection risk. Compile it out with a `TESTFLIGHT` Swift flag set only on the TestFlight archive. (`TestHarnessGate.swift:12-24`, `FavoritesView.swift:98-114`)
22. **Privacy manifest incomplete.** `NSPrivacyAccessedAPITypes` is empty despite UserDefaults use (CA92.1, 1C8F.1). The widget extension has no `PrivacyInfo.xcprivacy` at all → ITMS-91053.
23. **No SwiftData `VersionedSchema`/migration plan**, and `fatalError` on container failure (now on every launch type). Add V1 schema now; recover by moving the store aside.
24. **Pro gating not release-ready** (matters once the flags flip):
    - Siri reads `isProUser` before entitlements load, so paying users would get "Pro required".
    - Lock-screen widgets are never gated.
    - The StoreKit listener starts lazily, not in `App.init`.
    - ASOS product IDs are still requested.
25. **Siri flow:**
    - It prompts "Which airport?" instead of using location.
    - `nearest(count:1)` ignores `hasMetar`.
    - It skips `noaaCandidate`, so 3-character LIDs (CMA, 36K) always return empty.
    - The `O→0` rewrite corrupts O-prefixed ICAOs. (`FlyingWeatherIntent.swift:55-89`)
26. **Background task:**
    - The expiry handler doesn't stop the work.
    - Synoptic calls use 60 s timeouts and run sequentially.
    - The handler runs off-main while the type is MainActor-isolated (Swift 6 trap).
    - Watch `expiresAt` is never enforced. (`AlertScheduler.swift`, `AlertPipeline.swift`)
27. **Favorites never reconcile** with `airports.json` (no launch-time reconcile pass exists in this branch). (`Airport.swift:53-82`)
28. **Info.plist leftovers:**
    - `processing` background mode with no `BGProcessingTask`.
    - Siri entitlement and `NSSiriUsageDescription` not needed for App Intents.
    - Coarse location declared but `kCLLocationAccuracyBest` requested.

---

## P3 — Color axis, accessibility, performance, hygiene

- **Green outside category/verdict:** calm wind (`Theme.swift:156`, `WeatherDetailView.swift:568`, `AlertsView.swift:325` — on the same row as the GO badge), steady wind <20 kt (`:749`), `ForecastStripColumn` tinting wind with the category color, `TrendDirection.color`, TAF-vs-actual and accuracy colors, `spreadColor`, widget `trendColor`. F16 (weather chip `valueRed`) is confirmed still open.
- **Crosswind calculator:** readout is always red and headwind always green (tiers unused). "Tailwind exceeds 10 kt limit" shows for any tailwind. The tailwind uses sustained wind only. A gust carries over from the previous session. The comment cites a nonexistent `severityColor`. (`CrosswindReadout.swift`, `CrosswindDiagramView.swift`, `CrosswindKeypadView.swift`)
- **Trend arrow** points up for steady/mixed/unknown. VoiceOver reads "improving or stable" for unknown. LIFR is folded into IFR red on the TAF ribbon (`:1843`). VV ceilings are labelled "Broken".
- **Accessibility:** airport list rows convey category by a 3 pt color rail only, with no text label and no observation age.
- **Performance:** `DateFormatter` is allocated in view bodies (6+ sites). `pilotNotes()` and density altitude are computed twice per render.
- **Misc:**
  - Search results race (`AirportViewModel.swift:85-91`).
  - Layout prefs wiped on an unknown `SectionID`.
  - Open-Meteo has no timeouts and treats cancellation as an error.
  - Alert `force` doesn't bypass the in-memory METAR cache.
  - `metars.first ?? metars[0]` traps on empty in `seedSimulated`.
  - `M1/4SM` becomes `.exact(0.25)`.
  - Ceiling `.first` vs `.min()` inconsistency.
  - Two density-altitude formulas differ by ~50 ft.
  - PROB defaults to PROB30.
  - PROB30 TEMPO loses its probability.
- **Test gaps:** none of these have tests:
  - DensityAltitude
  - Observed/ForecastTrend
  - TafVerification
  - `currentForecast` time selection
  - BECMG
  - Advisory category
  - Parser with missing temp/altim/obsTime/cloud base, or `wdir:null` with a speed

## Checked and correct
- **Crosswind math** (`RunwayService.swift:97-111`): angle difference, absolute value, sign, wraparound, gust high / sustained low.
- **Runway handling:** the frame is consistent (the WMM rotation cancels in the difference). Best-runway ranking is sound (minor: water runways are eligible). Tier boundaries and the ≥5 kt trigger match spec. The manual calculator correctly skips WMM.
- **DA formula and units** are correct (only the missing-input path is wrong).
- **Networking:** NOAA 204 / cancellation are handled in WeatherService.
- **Build config:** build numbers (20) and App Group IDs are consistent. `BGTaskSchedulerPermittedIdentifiers` matches the scheduler.
- **StoreKit core:** `Transaction.updates`, finishing unfinished transactions, and revocation via `currentEntitlements`.
- **Audit doc:** F1–F14 and F16 fixes from the audit branch are still in place, except where noted above.

## Rulings
All "Needs Mike" items from the original audit were ruled by Jeff on Oct 21, 2026; see `docs/DECISIONS_2026-10.md`.

## Addendum (Oct 16) — TAFs missing at most airports
- **Cause:** the app only ever requests the TAF for the selected station (`WeatherViewModel.loadMETAR` → `fetchTaf(for: icao)`; Siri same at `FlyingWeatherIntent.swift:104`). There is no nearby-TAF fallback, so any field that doesn't issue its own TAF shows "No TAF available" (`WeatherDetailView.swift:1233`).
- **Scale (live check Oct 16):** a 6°×8° box over SoCal/southern NV returned 30 TAF sites vs 54 METAR stations. KVGT and KHND are not TAF sites; KLAS is.
- **Not a decode bug:** live TAF JSON field types match `RawTaf`; KLAS-type stations parse.
- Built on `feat/nearby-taf` per D#13–17.

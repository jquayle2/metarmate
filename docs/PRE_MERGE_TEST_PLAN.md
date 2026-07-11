# Pre-Merge Test Plan — METAR/TAF Adverse-Weather Audit

This plan backs the **METAR Injection** test harness (`MetarMate/TestHarness/`). The adverse cases
below don't occur in a July live fetch, so the harness lets testers (and Mike) inject them on demand
against the **real** detail screen. It ships to TestFlight.

The canonical fixtures live in code — `MetarMate/TestHarness/MetarInjectionFixtures.swift` — and are
mirrored here so the plan and the fixtures live together. If they ever diverge, the Swift file is the
source of truth (it's what actually runs).

---

## How the harness is gated (kept out of the App Store)

- Entry: **five taps on the "METAR Injection — tap 5×" chip** at the bottom of the Favorites content
  → opens the harness (`FavoritesView`). (Was a 5-second long-press on the nav-bar header; moved off
  the top screen edge because iOS's system gesture gate wins there — "System gesture gate timed out" —
  starving the app recognizer. The chip and its 5-tap gesture sit inside the content area, clear of
  the top edge, and compete with no system gesture. The chip is present only when the gate is open.)
- The gesture is convenience; the **App Store receipt** is the real boundary. Both the gesture and
  the screen are gated on `TestHarnessGate.isAvailable`:
  - `appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"` → **allowed** (Debug device+sim, TestFlight)
  - `"receipt"` (App Store production download) → **denied**
  - `nil` (no receipt URL — can happen in the simulator) → **denied (fail-closed)**
- **Not** `#if DEBUG` — that would compile the harness out of the TestFlight Release build, which is
  exactly where the pilots who exercise these cases live.

### Receipt-gate proof (what is and isn't provable locally)

The receipt filename is set by the **install channel**, not the build configuration. A locally-built
Release/Archive still reports `sandboxReceipt` — identical to Debug — because only a real App Store
download stamps a production `receipt`. So you **cannot** make `isAvailable` return false by building
Release locally. What is proven instead:

1. `TestHarnessGate.isTestFlightOrDebug(receiptName:)` is a **pure predicate**, unit-tested in
   `MetarMateTests/TestHarnessGateTests.swift`: `"sandboxReceipt"→true`, `"receipt"→false`,
   `nil→false` (fail-closed), any other name → false.
2. The gate **compiles into the Release binary** (no `#if DEBUG`): confirmed via `nm` on the
   Release build product (`TestHarnessGate.receiptName`, `.isTestFlightOrDebug`, `.isAvailable`).
3. The real runtime value is **logged at launch**: `[harness] launch receiptName=… harnessAvailable=…`
   (`MetarMateApp`), observable in a Release-config simulator run.

---

## Safety marker (protects the TestFlight pilots who CAN reach it)

Every injected/simulated screen carries the SIMULATED chrome (`SimulatedWeather.swift`):

- A **permanent, full-width, high-contrast banner** — `⚠️ SIMULATED — NOT REAL WEATHER` — pinned via
  `safeAreaInset(edge: .top)` so it never scrolls, is not a toast, and is not dismissible.
- A tiled diagonal **"SIMULATED" watermark**, a faint red wash, and a red screen edge, so the screen
  is distinct from a live render at a glance even if the banner were off-screen.
- An `\.isSimulatedWeather` **environment flag** set at the top of the simulated navigation and
  re-applied on every screen (including the pushed "Raw text" sub-screen), so the marker cannot be
  lost on sub-navigation.

---

## Injection path (exercises the real production parser)

Injection goes through the **same JSON decode → real parser** seam the live network fetch uses:

```
NOAA-shaped JSON string
  → JSONDecoder().decode([RawMetar].self / [RawTaf].self)   // SimulatedDecode — identical to WeatherService.fetchMetar/fetchTaf
  → MetarParser.parse(raw:) / TafParser.parse(raw:)         // the real, audited parser
  → WeatherViewModel.seedSimulated(...)                     // in-memory only; no network/SwiftData/widget writes
  → real WeatherDetailView
```

There is **no separate text parser**. The parser reads NOAA's **structured** fields
(`visib`/`wdir`/`clouds`/`wxString`/`fltCat`/`fcsts`), not the raw string — so every fixture is
authored as structured JSON. A pasted **raw** line is wrapped into the same JSON shape with only
`rawOb`/`rawTAF` populated; the fields a raw line can't carry then render honestly as `—`/unknown,
never a fabricated default (the harness contains **no `?? <number>`** fallbacks).

**Each fixture injects a 3-observation history** (newest first; obsTime now / −60 min / −120 min) so
the trend engine — which needs ≥2 observations (`ObservedTrend.derive` guards `metars.count >= 2`) —
produces a real OBSERVED summary instead of "Unknown". The `minAgo:0` observation is the current one
under test (structured fields unchanged, so the current render is identical); the two priors trend
INTO the current condition — adverse cases deteriorate (visibility dropping, ceiling lowering, winds
building), benign VFR cases stay steady. Altimeter is held constant per fixture to avoid a spurious
pressure-trend note. Regression: `SimulatedBannerSnapshotTests.testFixturesInjectHistoryForTrend`.

**METAR `fltCat` is a passthrough** — `MetarParser` reads it verbatim and never computes it. So
A1–A12 set `fltCat` to NOAA's real value (flagged per-row below). **TAF category is computed** by
`TafParser.calculateFlightCategory`, so T1–T4 omit any category hint and let vis/ceiling drive it
(T4 is the genuine category-computation test).

**TAF scaffolding:** the production detail view renders the TAF section only when a METAR is present
(`if let metar = vm.metar`). To avoid changing that production gating, each T-fixture is paired with a
scaffolding METAR (same ident) so the screen renders. The scaffold's category is **matched to the
TAF's first period** (T1→LIFR, T2→VFR, T3→IFR, T4→IFR) — a real station's METAR ≈ its TAF's current
period — so the screen doesn't lead with a chip that contradicts the case under test. Scaffolds carry
**no weather phenomena**; their category comes from vis/ceiling only, so nothing bleeds into the TAF
case. The scaffold is not the thing under test — TAF-sourcing is proven structurally
(`SimulatedBannerSnapshotTests`): the hero takes only a `Taf`, and the computed category tracks the
ceiling (raising it to 5000 ft flips IFR→VFR).

---

## Section 1 — Canned adverse fixtures

### METAR (A1–A13) — `fltCat` is passthrough

| Case | Authored JSON (key fields) | Expected render | Notes |
|---|---|---|---|
| **A1** | `"visib":"P6SM"` (string) | **"6+ SM"** (never "6 SM") | `fltCat:"VFR"` passthrough. String form (commit-10 core) |
| **A2** | `"visib":6` (number) | **"6 SM"** (never "6+ SM") | `fltCat:"VFR"` passthrough. Number form — must differ from A1 |
| **A3** | `"visib":"P10SM"` (string) | **"10+ SM"** | `fltCat:"VFR"` passthrough |
| **A4** | `"visib":0.5,"wxString":"FG","clouds":[{"cover":"OVX","base":200}]` | vis 0.5 SM, ceiling ~200 ft, **LIFR/magenta** | `fltCat:"LIFR"` passthrough |
| **A5** | `"visib":2,"wxString":"BR","clouds":[{"cover":"OVC","base":400}]` | IFR, **red** | `fltCat:"IFR"` passthrough |
| **A6** | `"visib":0.25,"wxString":"FG","clouds":[{"cover":"OVX"}],"vertVis":1` | ceiling ~100 ft from **vertVis** (NOT dropped) | `fltCat:"LIFR"` passthrough. OVX/vertVis fallback |
| **A7** | *(no `wdir`, no `wspd`)* | wind **"—"** + "Wind not reported" note (NOT "Calm") | `fltCat:"VFR"`. Both wind keys omitted |
| **A8** | `"wdir":0,"wspd":0` | wind **"Calm"**, reported | `fltCat:"VFR"`. Must differ from A7 (commit-6 core) |
| **A9** | `"wdir":180,"wspd":15,"wgst":25,"visib":4,"wxString":"TSRA","clouds":[{"cover":"BKN","base":2500,"type":"CB"}]` | present-wx chip **RED (TS)**, gust **amber** | `fltCat:"MVFR"` passthrough |
| **A10** | `"wdir":270,"wspd":25,"wgst":40,"visib":3,"wxString":"SQ +RA","clouds":[{"cover":"SCT","base":1500}]` | chip **RED (SQ escalated, commit 11)** | `fltCat:"MVFR"`. `wdir` added to avoid bogus 000@25 |
| **A11** | `"wdir":200,"wspd":10,"visib":2,"wxString":"+FC","clouds":[{"cover":"BKN","base":1500}]` | chip **RED (+FC escalated, commit 11)** | `fltCat:"IFR"`. wind added for sane render |
| **A12** | `"wdir":90,"wspd":8,"visib":1,"temp":2,"dewp":1,"wxString":"-FZRA","clouds":[{"cover":"OVC","base":800}]` | icing note **RED/.danger** — **fires at +2 °C surface temp (temp-independence)** | `fltCat:"IFR"`. Warm-layer-aloft case (commit 11) |
| **A13** | *(no `altim`)* `"temp":32,"dewp":5,…` + **Airport elev 5355 ft** | DA renders a **fabricated** 29.92-derived value | **DOCUMENTED-DEFECT MARKER (Finding 15)** — expected-WRONG, do not "fix" |

### TAF (T1–T4) — `fltCat` omitted, category **computed**

Period times are built at runtime from `Date()` so labels read sensibly; improving/worsening logic is
array-order based, so phrasing is deterministic regardless of when opened.

| Case | Periods | Computed category | Expected hero |
|---|---|---|---|
| **T1** | `base` LIFR (vis 0.5, OVC003) → `FM` IFR (vis 2, OVC008) | LIFR→IFR | **"LIFR now, improving by …"** — "improving", NOT "improving to IFR" (commit 11) |
| **T2** | `base` VFR (P6SM, SCT040) + `PROB40` TSRA (vis 2, BKN035 CB) | PROB → **.prob40** overlay | PROB period typed **probabilistic**, surfaced as an overlay, not a firm base forecast |
| **T3** | `base` IFR (vis 2, OVC008) → `FM` VFR (P6SM, SCT050) | IFR→VFR | **"IFR now, improving by …"** — reflects clearing, doesn't claim IFR throughout |
| **T4** | single `base`: `visib:""` + BKN007 (no `fltCat`) | ceiling 700 → **IFR** | Category from the **ceiling**, NOT fabricated VFR. The genuine category-computation test |

---

## Section 2 — Live spot-check airports (real fetch, LIVE)

`KJFK · KORD · KDEN · KSEA · KATL` — a **normal live fetch**, clearly labeled LIVE (no banner). NOT a
guaranteed-adverse injection; today's weather may be VFR.

## Section 3 — Free-text paste

Accepts NOAA-shaped JSON (full-fidelity) or a raw METAR/TAF line (wrapped into `rawOb`/`rawTAF` — only
raw text + present-weather populate; other fields render unknown, with a persistent caveat note). Same
decode→parse seam; parse failures are shown honestly, never replaced with a fallback model.

---

## Constraints honored

- **Read-only**: no network for injected cases, no favorites/SwiftData writes, no widget App-Group
  snapshot. In simulated mode the Nearby (network) and favorite-star (SwiftData) toolbar actions and
  pull-to-refresh are disabled; `seedSimulated` never calls `WidgetDataManager.save`.
- **No `?? <number>`** anywhere in the harness — a canned string that fails to parse surfaces the
  parse error; it is never replaced with a fabricated model.
- **Production render path unchanged**: `WeatherDetailView`'s injection param defaults `nil`; with
  `nil` the `.task`, `.refreshable`, and toolbar are byte-identical to before.

## Future items

- **StoreKit 2 migration**: `TestHarnessGate` uses `Bundle.main.appStoreReceiptURL`, soft-deprecated
  in favor of StoreKit 2 (`AppTransaction.shared`). It still functions and is the simplest correct
  signal for the sandbox-vs-production boundary; migrate to `AppTransaction.shared.environment`
  (`.sandbox` / `.production` / `.xcode`) when convenient. Warning only, not an error.

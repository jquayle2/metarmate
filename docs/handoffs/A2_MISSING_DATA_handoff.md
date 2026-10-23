# Handoff — A2: missing data is never a value; verdict logic

**Repo:** `/Users/jquayle/code/xcode/MetarMate` (JAQ-Studio-Mac)
**Branch:** `fix/a2-missing-data`, created off `feat/nearby-taf` (top of the release stack: trend-time-spine → A1 → Siri → nearby-TAF). Its first commit holds this handoff.
**Parallel session:** A3 runs at the same time in `/Users/jquayle/code/xcode/MetarMate-a3` (`fix/a3-release`). See "Boundaries with A3" below.
**Read first:**
- `docs/DECISIONS_2026-10.md` (binding)
- `docs/AUDIT_2026-10-12_full_codebase.md` (item numbers below = `#n` there)
- `docs/AUDIT_metar_taf_findings.md` (F-numbers)
- `docs/WIND_REFERENCE_FRAMES.md`
- `docs/LAUNCH_CHECKLIST.md` section 3

## Context

The audit was done at build 20 (5ad1b4b). A1, Siri hands-free and nearby-TAF have landed since. Nearby-TAF already closed **#13 and #14** (TAF "forecast at time t" helper, unknown axis not VFR, overlays) and added a shared 65/75-minute report-age function (`1f3d383`). **Re-verify every item against HEAD before changing anything**; some may be partly done.

Jeff is traveling. He reviews from his phone, so keep Phase 0 and each diff summary short and scannable. No device checks are possible until he's home; everything here must be provable with unit tests and simulator builds.

## Scope, in order

### Step 1 — Density altitude with humidity (one shared function)
- Oct 22 ground truth: **KIGM 19/13 A2996, elevation 3,449 ft** → ForeFlight 4,884 ft; MetarMate showed 4,706 ft; the humid (virtual-temperature) calculation gives ~4,871 ft.
- One shared `DensityAltitude` function using virtual temperature from the dewpoint. Dry-air formula only when the dewpoint is missing. Remove the second formula (P3 "two DA formulas", ~50 ft apart).
- Missing temperature or altimeter → no density altitude at all (ties into Step 2 / #8). Never 0 °C or 29.92.
- Unit tests: KIGM case within ±30 ft of 4,884; a hot dry case; a dewpoint-missing case; missing temp → nil.
- Jeff will collect 3–4 more ForeFlight samples while traveling; leave a table-driven test so they drop in.

### Step 2 — Unknown is never a value (parsers and models)
- **#8 / F15:** temp, dewpoint, altimeter optional. Follow every consumer: density altitude, pressure trend (no false "rapid falling"), fog/spread warning, the app-written widget snapshot (`WidgetWeatherSnapshot`).
- **#10:** missing wind direction/speed are not 000° / 0 kt, in METAR and TAF parsers. Consumers (crosswind, Pilot Notes, go/no-go) treat them as not evaluated.
- **#12:** missing cloud base (`BKN///`) is not 0 ft. No LIFR, no "0 ft" note, no false "Ceiling Falling".
- **#6:** unknown sky ≠ unlimited ceiling. Add a "sky reported" signal; no cloud group → ceiling unknown, not 99,000 ft.
- **#15:** missing `obsTime` is not `Date()`. A report with no time can't look fresh or sort newest.
- **#9:** visibility trend uses interval ordering against "10+"/P6SM (`>10` → `1.5` is a decrease). `deriveOverall` returns `.unknown`, not `.steady`, when both axes are unknown.
- **#18:** one category function everywhere: `cloudLayerColor` (<3000), Synoptic LIFR (<200), ASOS estimated and advisory category (3000 ft / 5 SM boundary).

### Step 3 — Go/no-go verdict logic
- **#4 / D#2:** tri-state factors. Any requested minimum that can't be evaluated → verdict **CHECK** (neutral, not green, not red), never GO. No "Back within your minimums" alert on a transition into CHECK or out of NO-GO via an unevaluated factor. This is the F13 skip-vs-pass fix.
- **#5 / D#3:** VRB wind uses worst-case crosswind (gust, else speed, at 90° to the runway). If VRB decides the outcome, CHECK per D#3.
- **#7 / D#4:** staleness gate on verdicts. Use the existing shared 65/75 function from `1f3d383`: late at 65 min (verdict shown, marked late), over 75 min no verdict. Same boundary as widget and Siri.
- **#11:** crosswind severity in Pilot Notes follows the crosswind tier, so a red-tier crosswind is never hidden under "Red only".
- **#20 / D#8:** gust approach-speed advice = ½ the gust factor, with the D#8 wording. One shared function used by Pilot Notes, the detail view and the crosswind calculator.
- **D#19:** starter-profile verdicts are labeled with the profile ("GO vs VFR day starter").
- Alerts (`AlertPipeline`) use the same evaluator; they stay METAR-only (D#1, done in A1).

### Step 4 — Display: unknown never shown as good
- **#16:** `.unknown` TAF delta card gets no VFR-green rail; no "Clear"/"CLR" for unknown sky; no green "Fcst on target" when deviation data is nil; "Steady over the last 2 hrs" can't be wind-only while the category changed.
- **F16:** present-weather chip off `Brand.valueRed` (category axis).
- **F18:** never "Clear" when FEW/SCT are reported (Siri already says "No ceiling"; match it).
- **#19:** TAF Pilot Notes mention strong steady winds and overlay gusts (`TEMPO 30035G50KT` → a wind note).
- **D#10:** symmetric missing-field notes (missing vis and missing wind get the same treatment). **D#11:** F17 hazards in the observation line and history. **D#12:** PROB TSRA in the headline.

### Step 5 — P3 data-integrity items (recommended for launch; confirm with Jeff in Phase 0)
Same defect class as this pass, so they belong here if Jeff agrees:
- `M1/4SM` parses as less-than ¼ SM, not exact 0.25.
- Ceiling uses the lowest BKN/OVC/VV layer (`.min()`), never `.first`, everywhere.
- PROB group with no explicit number isn't assumed PROB30; PROB30 TEMPO keeps its probability (check whether nearby-TAF already fixed this).
- Trend arrow: no up arrow for steady/mixed/unknown; VoiceOver doesn't say "improving or stable" for unknown.
- TAF ribbon keeps LIFR magenta separate from IFR red; VV is labeled "Vertical visibility", not "Broken".
- `seedSimulated`: `metars.first ?? metars[0]` can't trap on empty.

### Step 6 — Unit tests for the audit's gaps
DensityAltitude, Observed/ForecastTrend, TafVerification, advisory category, and parser missing-field cases (temp/altim/obsTime/cloud base, `wdir:null` with a speed, `///25KT`, `BKN///`, `VRB22G32KT`). Every fix above lands with a test that failed before it. Full suite: `-parallel-testing-enabled NO`.

## Boundaries with A3 (parallel session)
- A2 owns parsers, models, `GoNoGoEvaluator`, trends, Pilot Notes, detail-view display logic, and the verdict path inside `AlertPipeline`.
- A3 owns `AlertScheduler`/background-task mechanics (expiry, timeouts, MainActor), StoreKit/Pro gating, Info.plist, project settings, SwiftData schema, test-harness compile flags.
- If you need to touch an A3 file, keep the change minimal and say so in the commit message so the merge is easy. Don't refactor shared files (`WeatherDetailView.swift` is the big conflict risk: keep edits local).

## Out of scope
Pro gating, paywall, App Review blockers, ASOS/Synoptic work, P3 items not listed in Step 5, Android.

## Rules
- **Planning first.** Phase 0 is read-only: a table of each item (already fixed / partly / open, file:line) and your plan, plus the Step 5 question for Jeff. Wait for his go-ahead.
- **Validate against ground truth** (ForeFlight, NOAA raw text, FAA) for any aviation calculation; cite the reference in the test.
- **No `?? <number>` anywhere.** Unknown skips or omits; it never gets a benign default.
- **Build-verify before every commit:** `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -8` ending in BUILD SUCCEEDED, plus the unit tests.
- **Diffs inline,** uncollapsed, before each commit. One commit per logical unit, staging specific paths only. `tools/madis/` and `MetarMate_Project_State.md` are untracked; never stage them. Report hashes. **Ask before pushing.**
- **Flag scope changes before making them.** A code fix must not double as a product ruling; if DECISIONS doesn't cover it, stop and ask.
- **Commands for Jeff:** single line, `&&`/`;` chained, no `#` characters.
- **Keep `docs/LAUNCH_CHECKLIST.md` section 3 current** in the same commit as each item, with the hash.
- **At the end:** a short device-test list for Jeff for when he's home (a few live METARs vs ForeFlight: DA, a missing-field station if one is reporting, a VRB day, a stale report via the DEBUG age override).

# Handoff — Audit: METAR/TAF Parsing Against Adverse-Weather Stations

**Repo:** `/Users/jquayle/code/xcode/MetarMate` · branch `main`
**Build check:** `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5`
**Conventions:** no `#` in terminal commands; single-line, chained with `&&`/`;`; commit specific files (never `git add -A`); build-verify before each commit.

---

## Why this audit exists

On Jul 9 a user spotted "Snow" reported at KSNA (John Wayne) on a clear 19°C/17°C day. Root cause: `parseWeatherPhenomena`'s fallback scanned every raw-METAR token and kept any token *containing* a weather code as a substring, never stopping at `RMK`. The station identifier itself matched — `K-SN-A` → "SN" → "Snow".

Blast radius, measured against the real `airports.json`: **556 of 14,753 idents** would fabricate a weather phenomenon from their own name. KMSN→Snow, KICT→Ice Crystals, KBGR→Hail, KDSM→Duststorm, 161 idents→Volcanic Ash. It only surfaced when NOAA's `wxString` was empty (i.e. clear weather), so it manifested as *phantom* precip.

Fixed in `4b61a4b` (strict present-weather grammar + stop at RMK). While fixing it, the first regex attempt silently dropped bare `TS`, `VCTS`, `VCSH` — a worse bug than the original. **Caught only because it was tested against a battery of real codes.** That is the lesson driving this audit: these parsers have never had systematic adverse-weather testing.

A second bug found the same day (`994095f`): `tafHeroBrief` only checked whether the forecast got *worse* than the first period. A TAF that started IFR and cleared to VFR fell into the "no change" branch and printed "IFR the entire forecast period. No significant changes expected." — which would keep a pilot on the ground when the TAF says it lifts.

Both bugs share a shape: **logic that is correct for benign weather and wrong for adverse weather.** Assume there are more.

---

## Scope

Audit these files against real observations from stations reporting adverse conditions:

- `MetarMate/Utilities/MetarParser.swift` (251 lines) — `parse`, `parseWind`, `parseVisibility`, `parseClouds`, `parseWeatherPhenomena`, `WeatherDecoder.decode`
- `MetarMate/Utilities/TafParser.swift` (173 lines) — `parse`, `parseForecastPeriods`, `parseWind`, `parseVisibility`, `parseClouds`, `parseDate`, `calculateFlightCategory`
- Consumers that derive operational meaning: `tafHeroBrief`, `historyTrendBrief`, pilot-notes generators in `WeatherDetailView.swift`

Out of scope for now: `AdvisoryWeather` (Open-Meteo) — separate code path, separate audit.

---

## Known-suspicious spots (start here, do not stop here)

### 1. `parseVisibility` fails UNSAFE — highest priority
```swift
if let str = value as? String {
    if str == "10+" || str == "P6SM" { return 10.0 }
    if str == "6+" { return 6.0 }
    return Double(str) ?? 10.0     // <-- everything else becomes 10 SM
}
...
return 10.0                        // <-- nil visibility becomes 10 SM
```
Every failure path returns **10.0 SM** — the most permissive possible value. Consequences to verify:
- Fractional visibility (`1/2`, `1/4`, `3/4`, `1 1/2`, `M1/4`) → `Double("1/2")` returns nil → **10.0 SM**. A LIFR half-mile silently renders as VFR.
- `"M1/4SM"`, `"P6SM"`, `"9999"` (metric), `"0000"`, `"CAVOK"` — check each.
- nil / missing → 10.0, not "unknown".

A safety-critical field must not default to the safest-looking value. Determine the correct behavior (likely: return optional, and have callers render "—"/unknown rather than inventing 10 SM), then fix. **This one plausibly mis-renders flight category at exactly the stations where it matters most.**

### 2. `wdir` polymorphism
Per the project state doc, `wdir` can be Int, Double, or the String `"VRB"`. Verify `parseWind` handles all three, plus `0` (calm vs. north), missing `wspd`, `wgst` without `wspd`, and `VRB` with a gust.

### 3. `parseClouds` / ceiling derivation
- Vertical visibility (`VV002`) — is it treated as a ceiling? It must be.
- `CLR` / `SKC` / `NCD` / `NSC` — no layers vs. missing data.
- `CB` / `TCU` type suffixes.
- Multiple layers where the *lowest broken/overcast* defines the ceiling — confirm `ForecastRules.ceilingFeet` picks BKN/OVC/VV and ignores FEW/SCT.

### 4. `calculateFlightCategory` (TafParser)
Verify boundaries exactly: LIFR (<500 ft or <1 SM), IFR (500–<1000 / 1–<3), MVFR (1000–3000 / 3–5), VFR (>3000 and >5). Off-by-one at each boundary. Behavior when visibility or ceiling is *unknown* (see item 1 — today it silently gets 10.0).

### 5. `WeatherDecoder.decode` substring bug (same class as the fixed one)
```swift
for (abbr, name) in types {
    if remaining.contains(abbr) { ... }     // <-- contains, not prefix
}
```
This runs on already-extracted codes so it's less exposed, but the loop is order-dependent and uses `contains`. Check compound groups: `TSRA`, `+TSRA`, `-FZRA`, `FZFG`, `BLSN`, `DRSN`, `SHSN`, `VCSH`, `VCTS`, `RASN`, `TSGR`, `SHRAGS`, `MIFG`, `BCFG`, `PRFG`. Verify each decodes to the correct plain English, and that `SG` doesn't get eaten by a prior `SN` match, etc.

### 6. `parseDate` (TafParser)
TAF period boundaries crossing month end / year end / DST. Malformed or missing `timeFrom`/`timeTo`.

### 7. Consumers, not just parsers
- `tafHeroBrief` — now handles deteriorating and improving. Verify: LIFR→IFR (improving but still bad — does "improving to IFR" read acceptably?); category oscillation (VFR→IFR→VFR); TEMPO/PROB groups (currently `baseForecasts` filters to `.base`/`.fm` only — confirm a TEMPO IFR isn't silently dropped from the hero when it's the operationally important bit).
- Pilot notes — thunderstorm, freezing precip, low-vis notes should fire when present.
- Color axes — frozen precip / TS must land on the red (IFR/TS) axis, NOT amber. In the KSNA screenshot the phantom "Snow" rendered **amber**, which is the wind-caution axis. Even once the phantom is gone, confirm real snow/TS color correctly.

---

## Method

1. **Assemble a corpus of REAL adverse-weather observations.** Pull live from NOAA:
   - METAR: `https://aviationweather.gov/api/data/metar?ids={IDS}&format=json&hours=2`
   - TAF: `https://aviationweather.gov/api/data/taf?ids={IDS}&format=json`

   Target stations that reliably produce hard cases. Suggested starting set (seasonally adjust — pick stations that are ACTUALLY bad right now, don't assume):
   - Freezing precip / snow: KBUF, KSYR, KBTV, KMSP, KFAR, KNEW (as available)
   - Dense fog / low IFR: KSFO, KMRY, KACV, KEKA, KHUM
   - Thunderstorms: KMCO, KTPA, KOKC, KICT, KDFW (convective season)
   - High wind / gusts: KAMA, KLBB, KCYS, KRAP
   - Volcanic ash / dust: PANC, PAKN, KELP, KTUS
   - Mountain/obscuration: KASE, KEGE, KJAC, KSUN
   - Fractional visibility: any station currently reporting `1/2SM`, `1/4SM`, `M1/4SM`

   Also fetch the 556 substring-colliding idents (KMSN, KICT, KBGR, KABR, KDSM, KFUL, KMSS, KSGF, …) to confirm the phantom-weather fix holds against live data.

   **Do NOT hand-write fake METARs and call it verification.** Use real strings. Hand-written cases are fine as *additional* edge tests, but the corpus must be real.

2. **Write the corpus to a fixture file** (`MetarMateTests/Fixtures/adverse_metars.json`) so tests are reproducible and offline.

3. **For each observation, compare parsed output against ground truth.** Ground truth = the raw METAR/TAF string itself, decoded by hand or cross-checked against an authoritative decoder (aviationweather.gov's own decoded view, ForeFlight). Flag every disagreement.

4. **Write regression tests** in `MetarMateTests/` — there is an existing test target (`MetarMateTests.swift`, `ActiveProfilePointerTests.swift`) but the parsers have no coverage. At minimum, one test per bug found, plus the boundary tables for flight category and visibility.

5. **Report before fixing.** Produce a findings list (below) and let Jeff triage severity before changing behavior. Some "bugs" may be deliberate design calls.

---

## Deliverables

1. `docs/AUDIT_metar_taf_findings.md` — for each finding:
   - Symptom, the exact raw METAR/TAF that triggers it, expected vs. actual, affected code path, estimated blast radius (how many stations / how often), severity (does it mis-report a flight-critical value?).
2. `MetarMateTests/Fixtures/adverse_metars.json` — the real-observation corpus.
3. Regression tests covering every finding.
4. **No behavior changes committed until Jeff reviews the findings.** Exception: if you find something as severe as the visibility fail-unsafe default, flag it immediately rather than waiting.

---

## Principles for this work

- **Correctness before shipping.** Validate against authoritative ground truth (the raw string, aviationweather.gov, ForeFlight, FAA references) before declaring anything correct.
- **Test the fix, not just the bug.** The `TS`/`VCTS` near-miss above happened because a fix was written before the test battery existed. Write the battery first.
- **Fail loudly, not permissively.** In aviation weather, "unknown" must never silently become "10 SM and VFR." Where the parser cannot determine a value, prefer surfacing uncertainty over inventing a benign default.
- **Blast radius matters.** For every finding, quantify how many stations/observations it affects. `airports.json` is right there — measure, don't estimate.

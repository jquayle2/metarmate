# Audit Findings — METAR/TAF Parsing vs. Real Adverse-Weather Observations

**Date:** 2026-07-09 · **Branch:** `main` · **Scope:** per `docs/HANDOFF_metar_taf_audit.md`
**Method:** live NOAA corpus → run the *actual* shipping parsers (`MetarParser`, `TafParser`) against it → compare parsed output to the raw string as ground truth.

---

# ⇢ IMPLEMENTATION HANDOFF (2026-07-10 — continuing in a new session)

## Branch state
- **Branch:** `fix/metar-taf-adverse-audit` — **6 commits landed, NOT pushed** (local only), on top of `main`.
- **Untracked (never committed — carry them forward):** `MetarMateTests/AdverseWeatherParsingTests.swift` (test scaffold; still has `withKnownIssue` wrappers for the pre-fix bugs), `MetarMateTests/Fixtures/` (`adverse_metars.json`, `adverse_tafs.json`), and **this doc**.
- Every commit is `xcodebuild … iPhone 17` build-verified. No behavior is pushed/released.

## Commits landed (hash · one line)
| hash | commit |
|---|---|
| `1cd1144` | F1: parse indefinite-ceiling obscurations (OVX/VV) instead of dropping them |
| `8d783ec` | F2/F7: classify PROB groups as overlays; carry TAF visibility forward |
| `12658e8` | F6/F3c/F10: surface unreported visibility instead of faking 10 SM; harden decoder & temp |
| `de90a9c` | F11/F12 (3b): fix the widget's duplicate METAR parser |
| `627a2a8` | F3/F5: fire freezing-precip icing regardless of temp; red tier for TS/CB pilot notes |
| `00d84ae` | F4: surface significant TEMPO/PROB overlays in the TAF hero, regardless of base trend |

## Findings RESOLVED (by commit)
- **F1** OVX/VV indefinite ceiling parsed (METAR + TAF, `vertVis` fallback) — `1cd1144`
- **F2** PROB30/40 (`fcstChange:"PROB"`+`probability`) → `.prob30/.prob40` overlays — `8d783ec`
- **F7** TAF unknown visibility carry-forward; `calculateFlightCategory` returns `.unknown` (no `?? 10`); hero `.unknown` short-circuit ("Forecast incomplete") + excluded from worst/improving — `8d783ec` + hero
- **F6** `parseVisibility → Double?`; `Metar.visibilityReported` flag; every consumer gates ("—"/skip/filter/omit); ASOS `missingVisibilitySM=10` deleted; GoNoGo criterion skipped when unknown; P6SM→6 — `12658e8`
- **F3c** temp/dewp round-to-nearest (was truncate) — `12658e8`
- **F10** `WeatherDecoder` fallback = prefix-consumption (was `contains`) — `12658e8`
- **F11** widget's duplicate `parseVisibility`/`parseCeiling` brought to parity (F1+F6+F3c) — `de90a9c`
- **F12** widget missing flight category → `.unknown` (was fail-permissive `.vfr`) — `de90a9c`
- **F3** freezing-precip icing note fires regardless of surface temp (all `FZ` precip incl. FZUP; FZFG separate) — `627a2a8`
- **F5** `.danger` (red) pilot-note tier; **TS/CB only** routed to it; dead `ColorRules.presentWeatherColor` deleted — `627a2a8`
- **F4** TAF hero surfaces significant TEMPO/PROB overlays regardless of base trend — `00d84ae`

## DEFERRED to Jeff's CFII — do NOT decide these (kept at current behavior)
1. **Freezing-precip pilot note: red or amber?** Currently `.warning` (orange). (The present-weather *chip* already reds FZ via `wxPhenomenaConditionColor`; the *note* was not escalated.)
2. **`SQ` (squall): red or amber?** Not escalated.
3. **`+FC` (funnel cloud/tornado): red tier?** Not escalated.
4. **"Improving to IFR" hero phrasing** when LIFR lifts to IFR — acceptable, or reword? Currently ships as-is.
5. **P6SM → 6.0 lossiness** — losing the "greater than 6 SM" nuance; acceptable, or does P6SM need its own representation? Currently maps to `6.0` (VFR either way).
6. **Missing-visibility note asymmetry vs missing-wind. — STILL OPEN (Mike/CFII rules).** F8 (commit 6) full-gates unreported wind: it now renders "—" in every cell (like visibility) **and** carries a "wind not reported" pilot note. Unreported **visibility** still renders "—" in cells but has **no** analogous pilot note. The full gate *changed the surface area* of this asymmetry (wind cells now match visibility cells) but did **not** resolve the domain question: should wind carry a note that visibility doesn't, or should the two be symmetric (drop the wind note / add a vis note)? That is a CFII call, not a code call — left open.

## REMAINING WORK

**Commits 6–8 — LANDED** (see [Resolution status](#resolution-status-as-of-commit-8)):
- **Commit 6 (`6dc9b00`)** — F9 color boundaries + F8 missing-wind full gate (every `Metar.wind` consumer gated; `AlertConditions.windSpeed`/`TafVerification.actualWindKt`/`RateOfChange` wind fields optional; widget `windReported`).
- **Commit 7 (`9f1240c`)** — removed `withKnownIssue` for F1/F2/F7; F8 (5 surfaces + negative) and F9 boundary tests; extracted `MetarPilotNotes`; logged Finding 13.
- **Commit 8** — extracted `TafHeroBrief`/`TafFormat`; tests for F3 (note-fires), F4 (hero TEMPO overlay + segment color), F5 (TS/CB `.danger`), F1 `vertVis` synthetic, F7 hero short-circuit, F10 dict-audit + decoder battery; KDUJ `VV003` fixture; this audit-doc finalization; logged Finding 14. **F11/F12 dropped from commit 8** — the widget parsers are `private`/`fileprivate` and unreachable without widening access; pinning the duplicate's behavior would ratify the duplication. See Finding 14.

**Commit 9 — de-duplicate the widget parser (Finding 14), standalone:**
- Link `MetarParser` into the widget target; `buildSnapshot` calls `MetarParser.parse(raw:)` and maps `Metar → WidgetWeatherSnapshot`; delete the widget's `parseVisibility`/`parseCeiling`/`parseWindDirection`. The widget-side `windReported`/`isReported` plumbing becomes redundant (expected). Scope fresh when it starts.

**Not scheduled (optional):** fallback-targeted decoder tests for the ~10 codes that reach prefix-consumption (`SH, -TSRA, RASN, -RASN, SNRA, VA, DU, SA, PO, PY`) beyond the current battery + dict-audit — nice-to-have, F10 already resolved and audited.

## Method reminders for the next session (Jeff's working style)
- **Build-verify before EVERY commit; show `BUILD SUCCEEDED` immediately before committing.** No bundling build+commit; show the diff (inline plain text — piped through `cat`, tool-call diffs may not render), get explicit approval, then commit.
- **No `?? <number>` fail-permissive defaults** anywhere in this work; unknown → skip/filter/omit/"—", never a fabricated benign value.
- **Don't silently narrow coverage** when widening (e.g. the FZUP catch).
- Commit specific files (never `git add -A`); no push between dependent commits.
- The SourceKit "Cannot find type 'Airport'/'Brand'/…" diagnostics are whole-module-resolution false positives (per-file indexing); `xcodebuild` is the authority.

---

## How this was verified (not hand-waved)

1. Pulled **~590 live observations** from `aviationweather.gov` on 2026-07-09 across every adverse category in the brief (fog/low-IFR, convective TS, high wind/gust, dust, mountain obscuration, Alaska, Southern-Hemisphere winter fog, high-Arctic), plus the 556 substring-collision idents.
2. Curated the real-observation corpus into `MetarMateTests/Fixtures/adverse_metars.json` and `adverse_tafs.json`.
3. Compiled the **real** parser source (`Metar.swift`, `Taf.swift`, `SharedTypes.swift`, `MetarParser.swift`, `TafParser.swift`) into a CLI harness and ran the whole corpus through it — findings below are the harness's actual output, not code reading.
4. Wrote regression tests in `MetarMateTests/AdverseWeatherParsingTests.swift` (Swift Testing). **Ran on the iPhone 17 simulator:** 4 confirmations pass, 4 reproduced bugs recorded as `withKnownIssue` (suite stays green; each flips to a hard failure when fixed).

## What the live corpus overturned (measure, don't estimate)

The brief's **highest-priority** concern — `parseVisibility` fractional strings (`Double("1/2") → nil → 10.0`) — **does not occur with live data.** NOAA delivers visibility already normalized to statute-mile **numbers**: `1 3/4SM → 1.75`, `3/4SM → 0.75`, and even metric `0300 m → 0.19`, `9999 m → "6+"`. Across 439 METAR obs the only visibility *string* NOAA ever sent was `"10+"`, and there were **zero** null/missing `visib` fields. Every low/fractional/metric visibility in the corpus parsed **exactly**. The `10.0` fail-unsafe default is a real latent design flaw (Finding 6), but its measured live blast radius is ≈ 0 — it is **not** the flight-category mis-render the brief feared. Reported honestly rather than "fixed immediately."

---

# Findings (severity-ranked)

## Resolution status (as of commit 8)

| # | Finding | Status |
|---|---|---|
| F1 | OVX/VV indefinite ceiling dropped | ✅ Resolved — `1cd1144`; regression `ovxObscurationYieldsIndefiniteCeiling` + `ovxVertVisOnlyYieldsCeilingFromVertVis` |
| F2 | PROB30/40 mis-typed as base | ✅ Resolved — `8d783ec`; regression `probPeriodIsClassifiedAsOverlayNotBase` |
| F3 | Freezing-precip icing note temp-gated | ✅ Resolved (note fires) — `627a2a8`; regression `freezingPrecipIcingNoteFiresRegardlessOfTemp`. **Note tier (red/amber) → CFII.** |
| F4 | Hero excludes TEMPO/PROB overlays | ✅ Resolved — `00d84ae`; regression `heroSurfacesTempoOverlayOnCautionAxis`. **"Improving to IFR" phrasing → CFII.** |
| F5 | TS/CB never reach red on METAR side | ✅ Resolved (TS/CB → `.danger`) — `627a2a8`; regression `thunderstormAndCumulonimbusReachDangerTier`. **SQ / +FC tier → CFII.** |
| F6 | `parseVisibility` fails unsafe to 10.0 | ✅ Resolved — `12658e8` (`Double?`, callers gate). **P6SM→6.0 lossiness → CFII.** |
| F7 | TAF unknown visibility → 10 SM VFR | ✅ Resolved — `8d783ec`; regression `tafUnknownVisibilityYieldsUnknownCategoryNotVFR` + `heroShortCircuitsOnUnknownCurrentPeriod` |
| F8 | Missing wind renders as calm | ✅ Resolved (full gate) — `6dc9b00`; regression `missingWindGroupIsUnknownNotCalm` + `realCalmIsReportedAndRendersCalm` |
| F9 | Color boundaries disagree with category | ✅ Resolved — `6dc9b00`; regression `categoryColorsAgreeWithFlightCategoryAtBoundary` |
| F10 | Decoder compound path order-dependent | ✅ Resolved — `12658e8`; regression `weatherDecoderHandlesAdverseCodes` + `weatherDecoderDictAuditEveryKeyDecodes` (dict-audit: 0 offenders) |
| F11 | Widget duplicate parser drifted | ✅ Resolved (parity) — `de90a9c`; **but see F14 — the duplication itself is structural and slated for de-duplication (commit 9).** |
| F12 | Widget missing category → `.vfr` | ✅ Resolved (`.unknown`) — `de90a9c` |
| F13 | GoNoGo `Verdict` can't express skip-vs-pass | 🔶 **OPEN** — structural; not fixed. Code issue, not CFII. |
| F14 | Widget carries a duplicate parser (no shared `MetarParser`) | 🔶 **OPEN** — structural; resolution is de-duplication (commit 9), not test coverage. |

Six items require human (CFII) judgment and are **not** resolved by any code change or test — see [Requires human judgment (CFII)](#requires-human-judgment-cfii).

## 🔴 Finding 1 — Vertical-visibility / indefinite-ceiling obscurations are dropped (ceiling lost)  **[HIGH]**

- **Symptom:** In dense fog with an indefinite ceiling (raw `VV002`), the app shows **no ceiling at all** — `ceilingFeet == nil`, zero cloud layers parsed. The "Ceiling … LIFR" pilot note never fires and the ceiling readout/color is blank/unlimited at exactly the stations where the ceiling is the killer.
- **Exact raw (live):**
  `METAR EFHK 092220Z 36003KT 330V030 0300 FG VV002 14/14 Q1012` (Helsinki, LIFR)
  `METAR NZDN 092100Z AUTO 20001KT 0150 FG VV001 00/M01 Q1022` (Dunedin, ~150 m vis, VV001)
- **Root cause:** NOAA encodes an indefinite ceiling as **`cover:"OVX"` plus a separate top-level `vertVis` field** — *not* as `cover:"VV"`. `CloudCoverage` has no `OVX` case, so `MetarParser.parseClouds` / `TafParser.parseClouds` return `nil` for the layer (dropped by `compactMap`). `RawMetar`/`RawTaf` never read `vertVis`. The enum's existing `.verticalVisibility = "VV"` case is therefore **dead** for the JSON path — confirmed: 0 `"VV"` covers vs 6 `"OVX"` covers in a small live sample.
- **Expected vs actual:** EFHK `VV002` → expected ceiling **200 ft** (LIFR); actual **nil**.
- **Affected code:** `MetarParser.parseClouds` (`MetarParser.swift:97`), `TafParser.parseClouds` (`TafParser.swift:118`), `CloudCoverage` (`Metar.swift:33`), `Metar.ceilingFeet` (`Metar.swift:65`), `ForecastRules.ceilingFeet` (`WeatherStory.swift:35`), and the low-ceiling pilot note (`WeatherDetailView.swift:1039`).
- **Severity asymmetry:** METAR flight-category **badge** is safe (it comes from NOAA's `fltCat`, still `LIFR`), which masks the bug. But every *derived* ceiling surface is wrong. **On the TAF side it is worse** — TAF flight category is **computed** by `calculateFlightCategory`, so an obscuration-only TAF period would lose its ceiling and can misclassify LIFR/IFR as VFR/MVFR.
- **Blast radius:** every fog obscuration report (VV/indefinite ceiling) — seasonal and fog-station-driven; 6 live layers in an incidental summer sample.
- **Fix direction:** add `OVX` to `CloudCoverage` (treat as vertical-visibility), and read the `vertVis` field into the layer base for both `RawMetar` and TAF `fcsts`. Regression: `ovxObscurationYieldsIndefiniteCeiling`.

## 🔴 Finding 2 — `PROB30`/`PROB40` periods are mis-typed as firm `.base` forecasts  **[HIGH]**

- **Symptom:** A 30–40 %-probability adverse window (e.g. `PROB30 … 2SM TSRA`) is treated as a **definite base forecast** — it feeds `tafHeroBrief`'s worst-case, `currentForecast` selection, and the red "IFR from …" onset note as though certain — while the intended overlay path never sees it.
- **Exact raw (live):**
  `TAF KORD … PROB30 1000/1002 2SM TSRA BR BKN035CB … PROB30 1002/1004 1 1/2SM TSRA BR SCT020 BKN035CB`
  Harness output: KORD `raw PROB periods=2 → parsed .prob30/.prob40 in overlays=0`; the two `TSRA` periods appear as **`.base`, category IFR** (vis 2.0 / 1.5).
- **Root cause:** NOAA sends **`fcstChange:"PROB"`** with the number in a separate `probability` field. `TafForecast.ForecastType` raw values are `"PROB30"`/`"PROB40"`, so `ForecastType(rawValue:"PROB")` fails and `parseForecastPeriods` defaults to **`.base`** (`TafParser.swift:43-47`). Consequently `overlayForecasts` (filters `.prob30/.prob40`, `Taf.swift:62`) is **always empty**, and the `probability` value is never surfaced.
- **Expected vs actual:** PROB period → expected an **overlay** (surfaced in TAF Pilot Notes with a "30 %" qualifier, excluded from the firm hero/current); actual **base period**, indistinguishable from a firm FM group.
- **Affected code:** `TafParser.parseForecastPeriods` (`TafParser.swift:32`), `TafForecast.ForecastType` (`Taf.swift:15`), consumers `Taf.baseForecasts/overlayForecasts/currentForecast` (`Taf.swift`), `tafHeroBrief` (`WeatherDetailView.swift:1997`), `tafPilotNotes` §1/§2 (`WeatherDetailView.swift:2387`).
- **Direction of error:** generally **over-warns** (safer than under-warning) but corrupts the base timeline and mislabels probabilistic weather as certain; note the inconsistency with `TEMPO`, which *is* correctly excluded from the hero (Finding 4).
- **Blast radius:** every TAF containing a PROB group — **5 of 16** TAFs in the adverse batch. Very common in convective/adverse TAFs.
- **Fix direction:** map `fcstChange == "PROB"` + `probability` (30/40) to `.prob30`/`.prob40`; surface the probability in the overlay note. Regression: `probPeriodIsClassifiedAsOverlayNotBase`.

## 🟠 Finding 3 — Freezing-precip icing pilot note is gated on `temperature <= 0` (suppressed at ice-storm onset)  **[MEDIUM]**

- **Symptom:** The icing warning for freezing precipitation only fires when the reported air temp is **≤ 0 °C**. Freezing rain/drizzle (`FZRA`/`FZDZ`) is routinely reported by observers at surface temps of **0 to +3 °C** (supercooled rain freezing on contact; onset of an ice storm). At those temps the red icing note is **silently suppressed** — correct for benign, wrong for the exact adverse case.
- **Code:** `WeatherDetailView.swift:1093`
  `if metar.temperature <= 0 && metar.weatherPhenomena.contains(where: { $0.contains("FZ") || $0.contains("FZRA") }) { … "Freezing precipitation — icing…" }`
- **Supporting live evidence:** no `FZRA` was reachable in a July corpus (out of season across all accessible NOAA stations — documented, not skipped), **but** `METAR CYRB 09…Z … -RA … 01/…` (Resolute Bay, **+1 °C with rain**) proves the "precip present, temp just above 0" regime is real and common at high latitude — exactly where an `-FZRA` would be gated out.
- **Secondary defects same line:** (a) `|| $0.contains("FZRA")` is dead (anything containing `FZRA` already contains `FZ`). (b) `contains("FZ")` also matches `FZFG` (freezing *fog*, not precipitation) — mislabels it as "freezing precipitation." (c) `temperature` is `Int(raw.temp ?? 0)` — truncated toward zero (`MetarParser.swift:22`), so a `-0.6 °C` obs reads `0`.
- **Affected code:** `pilotNotes` freezing branch (`WeatherDetailView.swift:1092-1097`).
- **Blast radius:** every `FZRA`/`FZDZ` report at surface temp 0…+3 °C (ice-storm onset). Seasonal; high-value when it occurs.
- **Fix direction:** fire the icing note on `FZ`-precip presence regardless of the +0…+3 band (freezing precip *is* the temperature signal); separate `FZFG` handling; round rather than truncate temp. Verified by hand with real historical `-FZRA` strings in the test file's decoder battery.

## 🟠 Finding 4 — TAF hero brief silently excludes `TEMPO` (and `BECMG`) periods  **[MEDIUM — likely design, flag]**

- **Symptom:** `tafHeroBrief` reasons only over `taf.baseForecasts` (`.base`/`.fm`). A `TEMPO … TSRA`/`TEMPO … 3SM BR` — often the operationally important transient — is **absent from the hero one-liner** (it appears only in TAF Pilot Notes). This is the same *shape* as the two Jul-9 bugs: a hero that reads "no significant changes" while a real hazard sits one collection over.
- **Exact raw (live):** `TAF KTPA … TEMPO 0922/0923 10010G18KT 4SM SHRA BKN060 …`; `TAF KDEN … TEMPO 0921/0924 VRB20G35KT -TSRA BKN080CB`.
- **Affected code:** `tafHeroBrief` (`WeatherDetailView.swift:1998`, uses `taf.baseForecasts`).
- **Note:** interacts with Finding 2 — `PROB` (which *should* be an overlay like `TEMPO`) is currently *included* in the hero because it's mis-typed `.base`, so the two overlay classes are treated inconsistently.
- **Recommendation:** decide intentionally — either surface a worst-case `TEMPO`/`PROB` hazard in the hero ("VFR, but TEMPO IFR 09–13Z"), or document that overlays are Pilot-Notes-only. No code change pending your call.

## 🟠 Finding 5 — Thunderstorm / CB pilot *note* never reached the red tier on the METAR side  **[MEDIUM — color/design]** — ✅ RESOLVED (`627a2a8`)

- **Correction to the original framing:** the present-weather **chip** already reds `TS`/`FZ` via `wxPhenomenaConditionColor` — that surface was never amber-only. The defect was narrower and specific to the **pilot-note tier**: `PilotNote.Severity` had only `{caution, warning}` (max = orange), so a METAR *note* could not produce red, while the TAF notes had a red rank. The two *note* surfaces disagreed; the chip did not.
- **Resolution:** added a `.danger` (red) tier to `PilotNote.Severity`; **TS and CB** notes route to it (`MetarPilotNotes.build`). SQ and +FC are deliberately **not** escalated — that tier is a CFII call (see [Requires human judgment](#requires-human-judgment-cfii)). Regression: `thunderstormAndCumulonimbusReachDangerTier` (asserts TS/CB `.danger`; does not assert SQ/+FC).
- **Live evidence (unchanged):** `KTPA … TS` (VFR), `KEGE … TS HZ` (MVFR), `KPUB … +TSRA SQ 31021G58KT` (LIFR), `KMSS … +TSRA` — all parse and trip the TS note, now at the red tier.

## 🟡 Finding 6 — `parseVisibility` fails UNSAFE to 10.0 SM  **[LOW live impact — flagged per brief]**

- **Status:** the brief's flag-immediately item. **Confirmed present in code; measured live blast radius ≈ 0.** Every failure path returns the most permissive value: `Double(str) ?? 10.0` and the trailing `return 10.0` for nil (`MetarParser.swift:82-93`). But live NOAA never triggers it: 0 null `visib` in 439 obs; fractional/metric all arrive as correct SM numbers; the only string is `"10+"`.
- **Residual real issues:** (a) *latent* — any future null/odd `visib` silently becomes VFR 10 SM instead of "unknown"; (b) METAR vs TAF **disagree on `"P6SM"`** — METAR `parseVisibility` maps it to **10.0** (`MetarParser.swift:86`), TAF to **6.0** (`TafParser.swift:108`) — dead for current live data (NOAA sends `"6+"`), but a real inconsistency if the field ever changes.
- **Recommendation:** make `MetarParser.parseVisibility` return `Double?` and have callers render "—"/unknown rather than inventing 10 SM (the safety principle in the brief), and unify the `P6SM` mapping. Given the ≈0 live impact I did **not** change behavior; surfacing for your triage. Regression documenting correct fidelity: `fractionalVisibilityParsesExactly`.

## 🟡 Finding 7 — TAF unknown visibility → 10.0 SM / VFR (fail-unsafe default, live-confirmed)  **[LOW]**

- **Symptom:** `TafParser.parseVisibility` correctly returns `nil` for an empty `visib:""`, but `calculateFlightCategory` does `let vis = visibility ?? 10.0` (`TafParser.swift:151`) — an **unknown** TAF visibility becomes **10 SM VFR** on the vis axis.
- **Live evidence:** 5 TAF periods (KDEN/KASE/KPUB/KEGE `-TSRA` overlays) had `visib:""` → parsed `visibility=nil` → category VFR. In these cases the high CB ceilings kept the category VFR anyway (coincidentally harmless), but the fail-unsafe mechanism is confirmed to operate on real data.
- **Affected code:** `calculateFlightCategory` (`TafParser.swift:150`).
- **Recommendation:** treat unknown visibility as unknown (or carry forward the prior period), not 10 SM. ✅ Resolved (`8d783ec`). Regression: `tafUnknownVisibilityYieldsUnknownCategoryNotVFR`.

## 🟡 Finding 8 — Missing wind group renders as calm  **[LOW]**

- **Symptom:** A METAR with **no wind group** parses to `direction 0, speed 0` — identical to a real `00000KT` calm. "Unknown wind" becomes benign "calm."
- **Exact raw (live):** `METAR KABR 092153Z AUTO 10SM CLR 27/19 A2988` (no wind group; `wdir` & `wspd` both null). Harness: `wind dir=Optional(0) speed=0 variable=false`.
- **Affected code:** `MetarParser.parseWind` (`MetarParser.swift:53-59`) — `wspd ?? 0` and the `guard … else { return Wind(direction: 0 …) }`.
- **Recommendation:** signal unknown wind (e.g. `direction = nil` + a "wind not reported" note) rather than 0/0. ✅ Resolved (full gate, `6dc9b00`) — every `Metar.wind` consumer gates on `isReported`; `AlertConditions.windSpeed`/`TafVerification.actualWindKt`/`RateOfChange` wind fields made optional. Regression: `missingWindGroupIsUnknownNotCalm` + `realCalmIsReportedAndRendersCalm`.

## 🟡 Finding 9 — Category color functions disagree with `calculateFlightCategory` at the exact boundary  **[LOW]**

- **Symptom:** `ColorRules.ceilingColor` uses `feet < 3000` (so **exactly 3000 ft → green/VFR**) and `visibilityColor` uses `sm < 5` (so **exactly 5 SM → green/VFR**), but `calculateFlightCategory` uses `<= 3000` and `<= 5` (→ **MVFR**), matching the FAA definition (3000 ft and 5 SM are MVFR). At the exact boundary the **color says VFR while the category says MVFR.**
- **Affected code:** `ceilingColor` (`Theme.swift:185`), `visibilityColor` (`Theme.swift:176`) vs `calculateFlightCategory` (`TafParser.swift:167-168`).
- **Blast radius:** values landing exactly on 3000 ft / 5.0 SM. Small but a real inconsistency.
- **Recommendation:** align the color thresholds to `<=` at the MVFR boundary.

## 🟡 Finding 10 — `WeatherDecoder.decode` compound path is order-dependent  **[LOW — cosmetic]**

- **Symptom:** The precip-type loop uses `remaining.contains(abbr)` in a fixed order (`WeatherParser`→`MetarParser.swift:207`), so codes **not** in the exact-match table decode in the wrong word order: `SNRA → "Rain Snow"` (should be "Snow Rain"). `RASN → "Rain Snow"` (correct). All **listed** real codes decode correctly (verified against the brief's item-#5 battery: `+TSRA`, `-FZRA`, `FZFG`, `BLSN`, `DRSN`, `SHSN`, `VCTS`, `VCSH`, `TSGR`, `MIFG`, `BCFG`, `PRFG`, `+FC` all correct).
- **Blast radius:** rare unlisted mixed-precip codes only; wxString is already tokenized so the descriptor stacking mostly doesn't arise. Cosmetic.
- **Recommendation:** low priority; if touched, prefer prefix-consumption over `contains`. ✅ Resolved (`12658e8`, prefix-consumption). Regression: `weatherDecoderHandlesAdverseCodes`, and `weatherDecoderDictAuditEveryKeyDecodes` walks every exact-match key (0 offenders: each decodes non-empty and non-passthrough).

## 🟡 Finding 11 — Widget carried a duplicate METAR parser that had drifted from the app  **[LOW]** — ✅ RESOLVED (parity, `de90a9c`)

- **Symptom:** `MetarMateWidget` reimplements `parseVisibility`/`parseCeiling`/`parseWindDirection` inside a private `WidgetFetcher`, independent of `MetarParser`. It had drifted (e.g. the OVX/`vertVis` and `P6SM`/`6+` handling, temp rounding, F1/F6/F3c behaviors).
- **Resolution:** the widget parser was brought to parity (F1 OVX+vertVis, F6 `Double?`/no-fake-10, F3c rounding), and the missing-wind → `windReported` "—" render was added in `6dc9b00`.
- **Residual:** parity is currently maintained by hand across two implementations — see **Finding 14** (the duplication itself is the structural defect; de-duplication is commit 9).

## 🟡 Finding 12 — Widget missing flight category defaulted to `.vfr` (fail-permissive)  **[LOW]** — ✅ RESOLVED (`de90a9c`)

- **Symptom:** the widget mapped an absent `fltCat` to `.vfr` (green) instead of `.unknown` — a fail-permissive default on the single most important datum.
- **Resolution:** `FlightCategory(rawValue: raw.fltCat ?? "") ?? .unknown` (matches `MetarParser`; no fail-permissive green).

## 🟡 Finding 14 — Widget target carries a duplicate parser; drift is unobservable by any test  **[LOW — structural; OPEN, not fixed in commit 8]**

- **Symptom:** The widget target does not link MetarMate's `MetarParser` and carries a duplicate implementation of `parseVisibility`/`parseCeiling`/`parseWindDirection`, including the `P6SM`/`6+`/`vertVis` branches. Drift between the two parsers is unobservable by any test in either target. F11/F12 are the observed instances; the class is structural. Resolution is de-duplication, not test coverage.
- **Ruling:** code issue, not a CFII call. Out of scope for commit 8 (which is test-only — a test that pins the duplicate's behavior would ratify the duplication). **Resolution = commit 9:** link `MetarParser` into the widget target, have `buildSnapshot` call `MetarParser.parse(raw:)` and map `Metar → WidgetWeatherSnapshot`, delete the widget's parse funcs. (The `windReported`/`isReported` plumbing added to the widget in `6dc9b00` becomes redundant once the widget shares the app parser — an expected simplification, not a regression.)

## 🟡 Finding 13 — `GoNoGo Verdict` cannot express "factor not evaluated" vs "factor passed"  **[LOW — structural; OPEN, not fixed in commit 7]**

- **Symptom:** `Verdict` exposes only `failingFactors`. A skipped factor and a present-but-passing 0-kt factor are indistinguishable to any consumer. 0 kt never fails a max limit, so a fabricated calm reads as a satisfied wind minimum. `AlertConditions.windSpeed: Int?` (commit 6, F8) closes the current path, but `Verdict`'s shape still cannot express "this factor was not evaluated" vs "this factor passed." Any future non-optional numeric reaching a factor reintroduces the failure silently.
- **Class:** same as the `?? 10.0` / `?? 0` fail-benign family, but structural rather than a single call site.
- **Ruling:** code issue, not a CFII call. Out of scope for commit 7 — flagged, not fixed. (A fix would give `Verdict` a way to report evaluated-but-passed vs not-evaluated, without adding test-only API to production.)

---

# Requires human judgment (CFII)

These are **domain/UX decisions, not code defects.** No commit or test resolves them; a test asserting the current behavior would silently ratify an unmade decision, so the regression tests deliberately avoid pinning these (e.g. F3 asserts the icing note *fires*, never its severity; F5 asserts TS/CB `.danger` but never SQ/+FC). **None of the below is "resolved."**

1. **Freezing-precip pilot-note tier — red or amber?** The icing note currently ships at `.warning` (orange). The present-weather *chip* already reds `FZ`; the *note* tier was never escalated. OPEN.
2. **`SQ` (squall) — red or amber?** Not escalated on the METAR note side. OPEN.
3. **`+FC` (funnel cloud / tornado) — red tier?** Not escalated on the METAR note side. OPEN.
4. **"Improving to IFR" hero phrasing** when LIFR lifts to IFR — acceptable, or reword? Ships as-is. OPEN.
5. **`P6SM` → 6.0 lossiness** — the "greater than 6 SM" nuance is dropped (maps to `6.0`; VFR either way). Acceptable, or does `P6SM` need its own representation? OPEN.
6. **Missing-visibility vs missing-wind note asymmetry (Deferred item #6).** Post-F8, unreported wind renders "—" in cells **and** carries a "wind not reported" pilot note; unreported visibility renders "—" in cells but has **no** analogous note. The full gate changed the *surface area* of the asymmetry but not the domain question: should wind carry a note that visibility doesn't, or should the two be symmetric? OPEN.

---

# Confirmations (no action needed)

- **Phantom-weather fix (4b61a4b) holds on live data.** All 12 tested substring-collision idents (`KSNA`, `KMSN`, `KICT`, `KBGR`, `KDSM`, `KSGF`, `KFUL`, `KPIH`, `KGRR`, `KBIL`, `KABR`, `KMSS`) with empty `wxString` produced **zero** phenomena. (Blast radius of the *original* bug was 556 idents; now 0.) Real present weather still parses (`KPUB → ["+TSRA","SQ"]`, `KTPA → ["TS"]`). Regression: `collisionIdentsProduceNoPhantomWeather`, `realPresentWeatherStillParsed`.
- **Fractional & metric visibility parse exactly** (Finding 6 discussion). NOAA pre-normalizes to SM.
- **TAF cloud parsing works.** The feared `as? [[String: Any]]` cast (`TafParser.swift:123`) through `AnyCodable` succeeds — categories vary correctly across periods (KORD → VFR/IFR/MVFR/…). No bug.
- **`wdir` polymorphism** (Int / Double / `"VRB"`) and `VRB…G…KT` gusts parse correctly across 269 numeric + 19 `"VRB"` live obs.

---

# Deliverables in this change

- `docs/AUDIT_metar_taf_findings.md` (this file).
- `MetarMateTests/Fixtures/adverse_metars.json`, `adverse_tafs.json` — the real-observation corpus (verbatim NOAA JSON, 2026-07-09).
- `MetarMateTests/AdverseWeatherParsingTests.swift` — regression tests (Swift Testing). Confirmations assert pass; reproduced bugs use `withKnownIssue` so the suite stays green until each fix lands. **Ran on iPhone 17 simulator.**

**Status (post-triage).** Commits 1–8 landed on `fix/metar-taf-adverse-audit` (build-verified each; not pushed). F1–F12 resolved with regression coverage; F13 and F14 are OPEN structural code issues (not CFII); the six items under [Requires human judgment (CFII)](#requires-human-judgment-cfii) remain open and unratified. Remaining planned work: **commit 9** — de-duplicate the widget parser (Finding 14). The original "no behavior changes made" note applied to the audit-only phase and no longer holds.

# MetarMate — True/Magnetic Wind Source Toggle Brief

## Context
The crosswind engine now converts the TRUE METAR wind to MAGNETIC per-airport (WMM, implemented in MagneticDeclination.swift, used by RunwayService). That conversion is correct and verified (KVGT, KSDL vs ForeFlight). BUT the conversion is currently INVISIBLE: the XW sheet shows the converted wind (e.g. KSDL "210@5G15") while the raw METAR says 220 — a pilot cross-checking sees an unexplained 10° difference and may think it's a bug. This brief makes the reference frame VISIBLE and user-controllable.

Build MetarMate FIRST. XW Calc port comes later (separate brief) and will reuse the same WMM + toggle component.

## Feature: MAG/TRUE source toggle on the crosswind sheet/keypad

### Behavior by entry point
The toggle is shown in BOTH cases, but its initial state differs based on how the sheet was opened:

1. **Opened FROM a METAR context** (RunwayCrosswindSheet launched from a wind display / Pilot Notes — the app KNOWS the wind came from a METAR, which is TRUE):
   - Toggle arrives PRE-SET to TRUE (because METAR wind is true).
   - Wind is converted true→magnetic via the airport's WMM declination (already happening) and the computed crosswind/headwind reflect the magnetic frame.
   - The displayed wind value shows the MAGNETIC-converted wind (e.g. 210) with the toggle visibly on TRUE, so the pilot understands WHY it's 210 and not the METAR's 220.
   - If the pilot flips the toggle to MAG, treat the displayed wind as already-magnetic (no conversion) — i.e. it reasons as if the entered number is magnetic. (This lets a pilot who wants to think in raw magnetic do so.) Recompute live on toggle.
   - Source label: show which source/frame is active, e.g. a small "TRUE (METAR) → MAG" indicator near the toggle.

2. **Manual XWind TAB** (CrosswindTabView — pilot types runway + wind from scratch, NO airport context):
   - Toggle defaults to MAG (runway numbers + voice ATIS/tower are magnetic — the common manual case). Pilot's typed wind is treated as magnetic, no conversion (current behavior).
   - If the pilot flips to TRUE: convert the typed wind true→magnetic using WMM at the **current GPS position** (see GPS rules below), then compute. This covers the pilot working off a METAR/D-ATIS on the ground.

### Optional: source picker lists (the MAG/TRUE buckets)
Per Jeff's design — under the toggle, show the sources that fall under each frame so the pilot can self-identify which to pick:
- **MAGNETIC** (use as-is): Voice ATIS, Tower/ATC, AWOS/ASOS voice, Runway numbers
- **TRUE** (convert): METAR/SPECI, TAF, Digital ATIS (D-ATIS), Winds aloft
This can be a small expandable hint/legend, not a giant list. Keep it compact. The lists TEACH the convention — that's the value.

## GPS rules for the manual TRUE case (GPS-ONLY, must fail loud)
Jeff chose GPS-only (no manual variation fallback). Therefore:
- When TRUE is selected on the manual tab, compute declination from CURRENT GPS location via WMM, convert, compute.
- Requires CoreLocation: add NSLocationWhenInUseUsageDescription to Info.plist with a clear string, e.g. "Your location is used to compute magnetic variation for converting true winds to magnetic." Request when-in-use authorization the first time TRUE is selected.
- **CRITICAL — no silent failure**: if GPS is unavailable (permission denied, no fix, location services off), the TRUE option must NOT silently leave the wind unconverted while appearing selected. Instead: disable the TRUE toggle and show "Location needed to convert true winds" (or keep it on MAG). The pilot must never see a TRUE result that wasn't actually converted. A wrong crosswind that looks authoritative is the worst outcome.
- The METAR-launched case does NOT need GPS — it uses the airport's lat/lon (already known) for declination, same as the existing conversion. GPS is only for the manual no-airport case.

## Color / display constraints
- Wind text stays amber/red wind palette. The toggle/indicator is neutral UI chrome, not on the category/verdict/wind color axes.
- The Decoded METAR block elsewhere in the detail view must continue to show the RAW (true) wind as observed (220) — do NOT convert the decoded display. Only the runway-relative crosswind sheet shows/uses magnetic. (This separation is already correct; preserve it.)

## Deep-link note (do not implement now, but don't make it worse)
WeatherDetailView has dead openXWCalc(_:) / xwcalc:// code that would pass a TRUE wind to an external XW Calc app unconverted. It's unused. When/if MetarMate→XW Calc handoff is ever wired, the source/frame state (and/or the converted magnetic value) MUST travel with it so the toggle work isn't undone at the app boundary. For now: leave dead code alone; just don't wire it without handling frame.

## Verify
- KSDL opened from detail: sheet shows toggle on TRUE, wind 210 (converted from METAR 220), RWY 21, 0 XW / 5 HW. Flipping to MAG keeps 210 as magnetic, recomputes (still ~0/5 here since 210≈rwy). Flip is live.
- Manual XWind tab, GPS available: type RWY 21 / wind 220 / TRUE → converts off current GPS declination. With GPS denied: TRUE disabled with "location needed," stays on MAG (220 treated magnetic).
- Decoded METAR block still shows raw 220 unchanged.

## Build / commit
- xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5
- Commits: (a) toggle UI + METAR-launched pre-set/convert-display, (b) manual-tab TRUE + GPS/CoreLocation + fail-loud, (c) source legend.
- No # in terminal commands; single-line.

## Files
- MetarMate/Views/CrosswindKeypadView.swift / RunwayCrosswindSheet.swift / CrosswindTabView.swift (toggle, entry-point state, GPS path)
- MetarMate/Services/RunwayService.swift + MagneticDeclination.swift (reuse; expose a convert-from-GPS-lat/lon path if not already callable without an airport)
- Info.plist (NSLocationWhenInUseUsageDescription)
- New: a small LocationProvider/CoreLocation wrapper if one doesn't exist

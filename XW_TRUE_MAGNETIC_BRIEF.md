# MetarMate — Crosswind True/Magnetic Correction Brief (HIGH PRIORITY, correctness, launch-blocker)

## SUPERSEDES all prior crosswind briefs (XW_MISMATCH_BRIEF.md, XW_DISPLAY_BRIEF.md). Ignore those.

## The finding (verified against NOAA + FAA + ForeFlight)
Two stacked true/magnetic problems exist in the crosswind feature:

1. **METAR wind direction is referenced to TRUE north.** Confirmed by NOAA ASOS docs: "Wind direction is reported relative to true north in the METAR/SPECI message." METAR/TAF/winds-aloft are all TRUE. (ATIS/AWOS/ASOS *voice*, tower, and runway numbers are MAGNETIC — but the app uses the METAR text, which is TRUE.)
2. **runways.json leHdg/heHdg are TRUE headings, not magnetic.** Verified: KSEA runway numbered "16" has leHdg 180 in runways.json — impossible as magnetic (16 ⇒ ~160° magnetic); 180 is true (Seattle var ~16°E, 180−16≈164≈160 mag). KVGT "12" has leHdg 134; diagram shows 120° magnetic; 134 is true (var ~12°E). 

The app currently feeds the TRUE METAR wind and the TRUE runway headings into the crosswind engine. Because both are true, the relative angle is internally consistent — BUT the results do NOT match ForeFlight or what a pilot expects, because pilots and ForeFlight work in the MAGNETIC frame (runway numbers are magnetic; the runway a pilot lines up on is magnetic). The displayed runway designator ("RWY 12") references magnetic, while the heading used in math (134) is true — that mismatch is what made Pilot Notes look wrong, and makes our numbers differ from ForeFlight at any airport with meaningful variation.

## The goal
Work the crosswind math entirely in the MAGNETIC frame so MetarMate matches ForeFlight and matches the runway numbers pilots actually use. For KVGT wind 200@21G30, the correct result (per ForeFlight) is RWY 25: ~19 kt XW, ~9 kt headwind (wind 200T → ~189M; rwy 254M; 65° off).

## Required conversions
Single source of magnetic declination: compute it from the airport lat/lon (already in airports.json) using the World Magnetic Model (WMM). 
- Find or add a lightweight WMM/geomagnetic Swift implementation (there are MIT/public-domain WMM coefficient ports; the WMM2020/2025 coefficient set + the standard evaluation routine is small). If adding a dependency is undesirable, a compact WMM implementation can live in a new MagneticDeclination service. Declination sign convention: EAST positive.
- magneticFromTrue(trueDeg, declination): magnetic = true − declination (East is least / subtract east; West is best / add west). Normalize to 0–360.

Apply in TWO places so the whole engine is magnetic:
1. **Wind**: when the METAR (true) wind enters the crosswind engine, convert to magnetic using the airport's declination BEFORE any angle math.
2. **Runway headings**: convert runways.json true headings to magnetic using the same declination, OR equivalently keep the angle computed in true-space but ensure the DISPLAYED heading and the selection are consistent. Cleanest: convert both wind and runway heading to magnetic and do all math + display in magnetic. Then the displayed magnetic heading will round to the runway number (e.g. 134T → ~121M ⇒ "RWY 12"), which is what we want.

## Where it lives
- `MetarMate/Services/RunwayService.swift` — bestRunway() and the heading helpers. This is the right chokepoint: convert wind→magnetic and runway-heading→magnetic here so EVERY caller (Pilot Notes, alerts, XW sheet seeding) gets corrected values from one place.
- The crosswind/headwind/side math stays the same formula; only the input angles change to magnetic.
- `MetarMate/Views/WeatherDetailView.swift` Pilot Notes — no math change needed once RunwayService returns magnetic-correct results; the displayed heading (if shown) must be the MAGNETIC heading.
- `MetarMate/Views/CrosswindKeypadView.swift` / RunwayCrosswindSheet / CrosswindTabView — the manual XWind tab takes runway NUMBER + wind that the PILOT types; the pilot is already thinking magnetic (runway numbers, ATIS winds are magnetic), so the manual tab should NOT convert — designator×10 vs typed wind is correct for manual entry. ONLY the airport-context paths (Pilot Notes, alerts, and the sheet when pre-filled FROM a METAR) need the true→magnetic wind conversion. IMPORTANT: when the sheet is pre-filled from a METAR (true wind), that pre-filled wind value must be converted to magnetic before seeding, so the manual calc using designator×10 lines up.

## Declination data dependency
- airports.json has lat/lon, NO declination field. Compute via WMM at runtime (cache per airport). Do not hardcode a single national value.
- Validate: KVGT declination ≈ +11.5°E (2026), KSEA ≈ +15.5°E, KBOS ≈ −14°W. Spot-check these.

## Verify (must match ForeFlight)
- KVGT, METAR wind 200@21G30: best runway should be RWY 25 with ~19 kt crosswind / ~9 kt headwind (NOT RWY 12, NOT 21/4, NOT 19/9-off-134). Confirm best-runway SELECTION returns 25, and the displayed heading rounds to a magnetic value consistent with "25".
- KSEA (high east var) and KBOS (west var) spot checks — pick a wind, compare to ForeFlight's runway page.
- Manual XWind tab: type RWY 25, wind 250, speed 21 → designator math, unchanged (no conversion for typed input).
- Anomaly to FLAG (not necessarily fix now): KBOS runways.json shows RWY "15" with heading 135 — looks inconsistent (15 ⇒ ~150° mag, ~164T expected). May be a data error in runways.json. Note it; don't silently trust it.

## Build / commit
- xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5
- Suggested commits: (a) add WMM/declination service, (b) convert wind+heading to magnetic in RunwayService, (c) ensure pre-filled sheet converts, (d) Pilot Notes display heading magnetic.
- No # in terminal commands; single-line.

## Do NOT
- Do NOT just subtract a fixed offset — declination varies by location and must come from lat/lon.
- Do NOT convert the manual XWind tab's typed inputs (pilot types magnetic already).
- Do NOT change the core sin/cos formula — only the input reference frame.


---

## CONFIRMED against primary sources (do not re-litigate)
- METAR wind = TRUE north: NOAA ASOS docs, verbatim — "Wind direction is reported relative to true north in the METAR/SPECI message." (weather.gov/asos/WindSensor.html)
- runways.json headings = TRUE: this data derives from OurAirports runways.csv, whose heading fields are named `le_heading_degT` / `he_heading_degT` — the `degT` suffix is degrees TRUE. Confirmed via OurAirports schema. So our leHdg/heHdg are true headings.
- Therefore both the wind and the runway headings entering the engine are TRUE-referenced, while runway NUMBERS and ForeFlight's computation are MAGNETIC. The fix (convert both to magnetic via per-airport declination) is correct.

## Declination source — options for Code
1. PREFERRED: compute declination from airport lat/lon (already in airports.json) via a World Magnetic Model (WMM) implementation. Robust, full coverage, this is what ForeFlight does.
2. FALLBACK/shortcut: OurAirports navaids.csv has a `magnetic_variation_deg` field, but it's keyed to navaids not airports and coverage is incomplete — not reliable as the primary source.
3. ALTERNATIVE (bigger): re-source runway headings as MAGNETIC from the FAA NASR dataset (it provides magnetic runway headings directly). Avoids converting the runway heading, but still requires converting the METAR wind true→magnetic, and is a larger data change. Not required for this fix.

Go with option 1 (WMM from lat/lon).


---

## Note: Digital ATIS (D-ATIS) edge case — awareness only, no action required
Standard voice ATIS reports wind in MAGNETIC (why the manual XWind tab assumes the pilot's typed wind is magnetic and does NOT convert). HOWEVER, Digital ATIS (D-ATIS) at ~57 mostly-busy US sites (ATL, DFW, SEA, JFK, SFO, DEN, LAX, BOS, ORD, MSP, DCA, IAD, etc.) pulls wind directly from ASOS in TRUE, not magnetic.

Impact on MetarMate: NONE for the automatic paths — the app ingests the METAR (always true) and converts to magnetic per this brief, correct at every airport regardless of D-ATIS. The only theoretical edge is the MANUAL XWind tab: a pilot at a D-ATIS airport reading their digital ATIS gets a TRUE wind, but the manual tab assumes typed wind is magnetic. This is an inherent ambiguity of any manual calculator (ForeFlight has it too), not something to fix now. Do NOT add conversion to the manual tab. Just be aware the edge exists if a future "is this wind true or magnetic?" toggle is ever considered for the manual tab.

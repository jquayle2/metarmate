# MetarMate — Crosswind: NASR Headings + Magnetic Conversion + Pilot Notes Restyle (ALL IN ONE)

This brief lands the full crosswind upgrade in one pass: authoritative runway data, true->magnetic
math (replacing designator x10), the restyled Pilot Notes line, and "show both" for near-tie runways.
Everything here is downstream of the data work, which is DONE and validated.

---

## 1. Deploy the new runway data (DONE — just install it)
A rebuilt, validated runways.json is at:
  tools/nasr/runways_merged.json
It is a strict improvement over the current MetarMate/Resources/runways.json:
- Same 9,957 airports (zero coverage lost).
- 6,937 runway-ends use FAA-surveyed NASR true headings; 1,876 of those CORRECTED drifted OurAirports values.
- 17,287 ends keep OurAirports computed headings (small fields NASR doesn't survey); 12 ends fall to designator x10.
- Heliports stripped. Uniformly TRUE headings. Same schema (le/leHdg/he/heHdg/len/wid/sfc).
- Validated: computed magnetic (true - WMM declination) matches published FAA airport diagrams across
  variation extremes (KSEA 16E, KBOS 15W exact; KVGT/KLAS within ~2deg rounding).

ACTION: copy tools/nasr/runways_merged.json over MetarMate/Resources/runways.json.
  cp tools/nasr/runways_merged.json MetarMate/Resources/runways.json
The tools/nasr/ folder (merge_runways.py + this data) stays in the repo for the 28-day NASR refresh.
merge_runways.py is parameterized: --nasr <csv dir> --current <runways.json> --out <new file>.

## 2. RunwayService: use TRUE heading -> WMM magnetic (REPLACE designator x10)
Currently the auto/Pilot-Notes crosswind path uses designator x10 for the runway heading.
Now that runways.json carries authoritative TRUE headings, switch to converting them to magnetic via
the existing MagneticDeclination (WMM), the SAME way the wind is already converted.

- For each runway end, runwayMagHeading = trueHeading(from runways.json leHdg/heHdg) - declination(airport lat/lon).
  Reuse the declination already computed for the wind conversion in this path; do not recompute differently.
- Compare magnetic wind vs magnetic runway heading for crosswind/headwind. Both in the magnetic frame, both WMM.
- REMOVE designator x10 from the auto path entirely.
- Recompute the arrow side (isLeft) in the magnetic frame.
- MANUAL XWind tab is UNCHANGED — it still uses designator x10 (pilot types a runway number, no airport
  context, no true heading available). Do not touch CrosswindTabView / CrosswindKeypadView.

Verify: KVGT RWY 25, wind 210@10G18 -> matches ForeFlight on BOTH components (XW ~8-14, HW ~5-9).
(Previously HW was 6-11 because of designator x10; the corrected heading brings it to ~5-9.)

## 3. Pilot Notes crosswind line restyle (the staged design — fold in now with final numbers)
Three-line block, borrowing the calculator's arrow + amber/red wind palette. DISPLAY over the section 2 math.
- Line 1: "Gusts {g} kt — RWY {ident}"  (or "Wind {s} kt — RWY {ident}" when no gust)
- Line 2: "{arrow before/after}XW {low}-{high} kt   HW {low}-{high} kt"
- Line 3 (muted/smaller): Vref advice, e.g. "consider adding {n} kt to approach speed"

Ranges: compute XW and HW at BOTH sustained and gust; show low-high. No-gust collapses to a single value
and Line 1 says "Wind" not "Gusts". Whole kt.

Arrow (must match the calculator's CrosswindReadout exactly — reuse the same side logic, do not reimplement):
- Wind FROM the LEFT  -> arrow points RIGHT, placed BEFORE the XW value:  "-> XW 8-14 kt"
- Wind FROM the RIGHT -> arrow points LEFT, placed AFTER the XW value:    "XW 9-16 kt <-"
- The arrow sits on the side the wind comes from and points the way it blows.

Colors (wind axis only):
- XW value + arrow: amber default; RED when the GUST crosswind (range high end) >= the calc's red threshold (~20 kt). Wind icon picks up the same color.
- HW value: NEUTRAL gray — headwind is not a caution, keep it off the amber/red axis.
- Line 3: muted gray. No flight-category or go/no-go colors anywhere in this line.

Units: match existing notes ("kt" vs "kts"). Dynamic Type: line 2 one line at default, graceful wrap at large sizes.
Applies to BOTH the METAR and TAF Pilot Notes crosswind builders.

## 4. Show BOTH runways when it's a near-tie
When the two best runway options are within ~2-3 kt of each other (headwind-component delta), show BOTH in
Pilot Notes rather than forcing one pick — this is more "thinks like a pilot" than ForeFlight's single badge.
- Threshold: if the second-best runway's headwind component is within ~3 kt of the best, render both
  (best first), each as its own crosswind line (per the section 3 format). Otherwise show only the best.
- This resolves genuine ties like KVGT 200@21G30 (RWY 25 vs 12 are near-equal) honestly.
- Keep it to at most 2 runways. Subtle framing for the second (e.g. not a second "best" badge; just the second line).

## 5. Verify (on device, against ForeFlight)
- KVGT 210@10G18: RWY 25, XW ~8-14 kt, HW ~5-9 kt, amber, arrow before (wind from left). Matches ForeFlight.
- KLAS 270@11: best runway 26R (ForeFlight's "Best Wind"), ~straight headwind. Matches.
- A wind-from-right runway: arrow AFTER the XW value, pointing left.
- A high gust-crosswind case: XW + arrow + icon RED.
- A near-tie airport/wind: BOTH runways shown.
- Manual XWind tab unchanged (designator x10, no GPS).

## Build / commit
- xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5
- Suggested commits (your call on granularity):
  1. "Rebuild runways.json from FAA NASR (authoritative true headings); add tools/nasr refresh scripts"
  2. "RunwayService: true->WMM magnetic runway heading (replaces designator x10) in auto path"
  3. "Pilot Notes crosswind: range + directional arrow + wind-axis colors; show both runways on near-tie"
- No # in terminal commands; single-line.

## Files
- MetarMate/Resources/runways.json (replace with tools/nasr/runways_merged.json)
- MetarMate/Services/RunwayService.swift (heading: true->WMM magnetic; near-tie selection)
- MetarMate/Services/MagneticDeclination.swift (reuse)
- MetarMate/Views/WeatherDetailView.swift (Pilot Notes crosswind builder, METAR + TAF; restyle + show-both)
- tools/nasr/ (merge_runways.py, runways_merged.json — keep in repo for 28-day refresh)
- DO NOT TOUCH: CrosswindTabView / CrosswindKeypadView (manual tab stays designator x10)

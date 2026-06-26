# MetarMate — Crosswind Integration Brief

## Context
The crosswind engine is ALREADY BUILT on the Pi and just needs wiring in. Do not rebuild it.
- `MetarMate/Resources/runways.json` — keyed by ICAO (9,957 airports), each runway has le/he idents, leHdg/heHdg (magnetic), len, wid, sfc. KVGT confirmed present.
- `MetarMate/Services/RunwayService.swift` — has Runway/RunwayEnd/RunwayResult models, JSON loader, `runways(for:)`, and `bestRunway(for:windDirection:windSpeed:windGust:)` doing sin/cos crosswind+headwind trig, selecting best runway (highest headwind, then lowest crosswind). Currently UNREFERENCED — nothing calls it yet.

Math note: NOAA US METAR wind is magnetic, runway headings are magnetic — same reference, no true/mag bug.

## Decisions (locked by Jeff)
- Best (lowest-crosswind, headwind-favored) runway as headline, then list all runways.
- Crosswind numbers use the amber/red WIND palette ONLY — never flight-category colors, never go/no-go verdict colors.

## Part A — Auto-compute in Pilot Notes
1. METAR Pilot Notes (`WeatherDetailView.swift`, `pilotNotes(for:history:)` ~line 818): in the wind notes, call `RunwayService.shared.bestRunway(...)` with the METAR wind. Replace generic "check crosswind component for your runway" with computed value, e.g. "RWY 30R: 18 kt XW (right), 12 kt headwind." Keep generic fallback when bestRunway returns nil.
2. TAF Pilot Notes (separate generator producing "Gusts X kt from TIME local"): same treatment per forecast period. FIRST CONFIRM the TAF note generator carries wind DIRECTION per period — the engine needs dir, not just speed/gust.

## Part B — Port the XW Calc keypad
Source files in the XW Calc project:
- `/Users/jquayle/code/Pi/Xcode/CrosswindCalc/CrosswindCalc/KeypadView.swift` (483 lines — 2x2 value boxes, swipe-to-enter-two-digits gesture, validation, haptics)
- `/Users/jquayle/code/Pi/Xcode/CrosswindCalc/CrosswindCalc/CrosswindReadout.swift` (147 lines — big crosswind number, L/R arrows, headwind/tailwind, Vref advisory)

Both self-contained; only external deps are four @AppStorage keys (runway, windDirection, windSpeed, gustSpeed) and UIKit haptics.

1. Copy both files into MetarMate.
2. Namespace the @AppStorage keys to avoid collisions (prefix `xwcalc_`). Last-used values persist across sessions (see Part C state decision).
3. COLOR AXIS REMAP — critical. CrosswindReadout uses green for headwind and green/orange/red severity on the crosswind number. In MetarMate green/red are reserved for flight-category and go/no-go verdict axes. Remap before merging:
   - Crosswind severity: amber/red WIND palette only (amber >=15 kt, red >=20 kt per project gust thresholds).
   - Headwind "green" -> neutral/wind-axis color. Do NOT leave green.
   - Tailwind red acceptable as wind-axis caution; confirm it reads distinctly from IFR/verdict red.

## Part C — 5th tab "XWind"
1. Add a 5th tab labeled "XWind" to the bottom tab bar (Nearest / Search / Favorites / Alerts / XWind). iOS supports 5 before collapsing to More — fine.
2. Tab hosts the ported KeypadView.
3. Open state: LAST-USED VALUES (persisted via the namespaced @AppStorage keys). First field active so digits can be thumbed immediately (KeypadView already defaults activeField = .runway).
4. Use case is short final — tower calls winds different from METAR, one hand, seconds. Optimize for fewest taps from cold. Plain tap-a-digit path must remain (already present) as the turbulence-friendly alternative to the swipe gesture.

## Part D — Contextual tap-to-open sheet (keep alongside the tab)
1. Make wind displays on detail views tappable to open the same KeypadView as a sheet.
2. Pre-fill windDirection/windSpeed/gust from that METAR (or TAF period), and seed runway from `RunwayService.bestRunway(...)`.
3. Flip-runway tap already wired in CrosswindReadout (onFlipRunway).

## Build / commit discipline
- Build-verify after each step: `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5`
- Incremental git commits after each meaningful change. No `#` in commit/terminal commands; single-line, chain with && or ;.
- Suggested commit points: (a) RunwayService wired into METAR Pilot Notes, (b) TAF Pilot Notes, (c) keypad files copied+compiling, (d) color remap, (e) XWind tab, (f) contextual sheet.

## Files expected to change on the Pi (track for Pi image update)
- MetarMate/Views/WeatherDetailView.swift (Pilot Notes wiring, tappable wind)
- MetarMate/Services/RunwayService.swift (possibly minor, mostly read)
- NEW: MetarMate/Views/KeypadView.swift (ported)
- NEW: MetarMate/Views/CrosswindReadout.swift (ported)
- Main tab/scaffold file (add XWind tab) — locate the TabView root
- TAF Pilot Notes generator file (locate)

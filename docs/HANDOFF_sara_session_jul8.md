# Handoff — Parked Items for Sara Session (Jul 8, 9:00 AM)

**Repo:** `/Users/jquayle/code/xcode/MetarMate` · branch `main` (all session work merged, pushed).
**Last commit:** `3b0a6ac` (TAF hero "midday").
**Workflow for the session:** demo each change live in the Xcode sim (iPhone 17). May also use Claude Design.
**Build check:** `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5`
**Conventions:** no `#` in terminal commands; single-line, chained with `&&`/`;`; commit specific files (never `git add -A`); build-verify before each commit; remind + help with git saves.

Full design detail for the bigger items lives in `MetarMate_Future_Enhancements.md`. This handoff is the ordered agenda.

---

## 1. Garmin CDI green — SCOPE DECISION NEEDED (waiting on Sara)

Swap some green to Garmin-CDI green: `#00FF00` = `Color(red: 0, green: 1, blue: 0)`.

The blocker is WHICH green. There are two greens on separate axes (color discipline: never bleed them):
- VFR flight-category green (VFR/MVFR/IFR/LIFR reserved set)
- XWind headwind green (headwind readout + wind arrow)

`#00FF00` reads as a nav/headwind aesthetic, not a flight-category one. A blanket swap would also
shift how VFR reads everywhere (lists, badges, detail). **Ask Sara: XWind headwind green only, VFR
category green only, or both?** Then it's a small change in `Theme.swift`. Do NOT swap blindly.

## 2. Headwind gust range display — DECISION (parked for beta feel too)

On the XWind readout, headwind currently shows only SUSTAINED (e.g. "HEADWIND 2 kt"). The gust
headwind component (e.g. 6 kt) is computed internally (drives the Vref add) but not shown. Question:
should headwind show a range/gust like the crosswind does?

Options to mock with Sara: (a) flat range "2–6 kt", (b) sustained-with-gust-annotation "2 ᴳ6"
mirroring the crosswind's G grammar, (c) leave sustained-only. Lean: (b) — keeps the honest planning
number (2) dominant while surfacing the 6 that explains the Vref advisory. Aviation-judgment call;
good one to get Sara/Mike input on. `CrosswindReadout.swift` / `CrosswindKeypadView.swift`.

## 3. Performance section redesign — PICK A/B/C (re-read current code FIRST)

Current section shows calc INPUTS pilots don't act on and lists DA twice (ISA Deviation, DA Penalty,
Pressure Altitude are intermediate values; "~X% power loss" stands alone but is misleading — power
loss ≠ runway/climb penalty). Goal: surface operational CONSEQUENCES.

IMPORTANT: the live build already shows an evolved collapsed Performance header ("✓ 1,022 ft MSL ·
~3% power loss (NA)"). RE-READ `densityAltitudeSection` in `WeatherDetailView.swift` (~line 1149)
before building — the older screenshots may be stale. Note `da.takeoffRollText` already exists
(currently buried tertiary text) and can be reused.

Math (validated, full detail in enhancements doc): multiplicative model,
`Distance = Base × DA_factor × Wind_factor`.
- DA: takeoff roll +10%/1000 ft DA (NA); landing similar/softer. Climb −7%/1000 ft (variable-pitch NA),
  −8% (fixed-pitch). Engine HP −3.5%/1000 ft (this is the "power loss" number — keep secondary).
- Wind (asymmetric): headwind −1.75%/kt; tailwind +5%/kt. Use runway-axis component
  (windSpeed × cos(angle)) — already computed as `headwind`/`gustHeadwind` in the XWind view.

Three mocked directions (see chat / enhancements doc):
- A — consequences first: 2 big tiles (takeoff roll %, climb rate %), power loss demoted to caveat.
- B — collapsed one-liner: DA + 2 deltas on one line, tap to expand (closest to existing pattern + live build).
- C — takeoff/landing split, wind-aware: separate TO/landing rows, wind folded into the numbers.
All three: DA shown ONCE; drop ISA Deviation + DA Penalty from primary view; reframe power loss as
secondary. Honesty caveat stays (rule-of-thumb, verify POH). Decide takeoff-forward emphasis vs TO/landing parity.

## 4. Consistency: other `gust / 2` Vref spots — FOLLOW-UP

The XWind tab now uses the headwind-component Vref gust factor (`(gustHeadwind - headwind + 1)/2`).
Three spots in `WeatherDetailView.swift` still use the OLD raw `gust / 2`: lines ~911, ~1014, ~2444
(METAR pilot notes, compact line, TAF pilot notes). So the Vref add can DIFFER between the XWind tab
and the airport-detail notes. Decide whether to unify. Caveat: those contexts don't always have a
runway to resolve against (a runway is needed for the headwind component), so this needs thought,
not a blind copy.

## 5. Advisory Weather multi-day forecast — DESIGN (park, review with Sara)

Full write-up in enhancements doc. Extend the existing 6-hr Advisory pattern to a ~7-day outlook.
Open-Meteo supports it (add `daily` block + `forecast_days`), same free source. Directions A (daily
strip) / B (flyability rows) / C (pattern summary + strip); leaning C-summary + B-rows. Hard rule:
cap at 7 days; prominent "estimated, not a briefing" framing. Real build work (new request vars, new
`AdvisoryDailyDay` model, day-level flyability derivation, new UI section) — design-decide before building.

---

## Already DONE this session (on `main`, for reference — don't redo)
Pressure-card wrap fix · wind "DIR at SPD" phrasing · TAF hero gusty-period caution · XWind input-cell
enlargement · weather cache (Phase 1) · CFBundleVersion 16→18 + onChange migration · Vref
headwind-component gust factor · GUST→NONE skip button · Raw TAF inline (like Raw METAR) · TAF hero
"midday" phrasing.

## Also parked (not for this session unless time)
- Tab-reset-on-switch (detail page persists across tabs) — held for beta feedback.
- Weather cache Phase 2 (launch prefetch) — deferred; cache-only felt snappy enough.
- XWind `180°` at 36pt — watch it doesn't scale down vs siblings on-device.

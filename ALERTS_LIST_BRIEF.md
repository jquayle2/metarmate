# MetarMate — Alerts List Polish + Tap-to-Detail Brief

## Goal
Make the Alerts tab list visually consistent with the Nearest Airports list, and make tapping an alert row open that airport's detail view (WeatherDetailView) — same as tapping a Nearest row.

## Current state (read these first)
- `MetarMate/Views/AlertsView.swift` — Alerts tab. Rows rendered by a private `WatchRow` struct (bottom of file). Hand-rolled layout, no NavigationLink, so tapping does nothing. Has a left category strip, ICAO + FlightCategoryBadge, GO/NO-GO verdict badge, failing factors, freshness line.
- `MetarMate/Views/NearestAirportsView.swift` — the look to match. Uses `AirportRowView` (from SharedComponents.swift) wrapped in `NavigationLink(destination: WeatherDetailView(airport: airport))`, with `.listRowBackground(Color(.systemGray6).opacity(0.2))`.
- `MetarMate/Views/SharedComponents.swift` — contains `AirportRowView` and `FlightCategoryBadge`. Read AirportRowView to see its exact signature (it takes airport, metar, distance).

## The one real obstacle
Nearest has `Airport` objects to pass to `WeatherDetailView(airport:)`. Alerts only has `AirportWatch`, which stores an ICAO string (`watch.icao`), not an Airport. To navigate, resolve the watch's ICAO to an `Airport` via AirportService (check AirportService for the lookup method — likely something like `airport(forICAO:)` or a cached dictionary). Do the lookup once per row (cache it), not repeatedly.

## Tasks
1. **Tap-to-detail (priority — the functional ask):**
   - Wrap each alerts row in `NavigationLink(destination: WeatherDetailView(airport: resolvedAirport))`.
   - Resolve `watch.icao` -> `Airport` via AirportService. If the airport can't be resolved (rare), fall back to a non-tappable row rather than crashing.
   - AlertsView already has a NavigationStack, so NavigationLink will work.

2. **Visual consistency with Nearest:**
   - Match the row chrome to the Nearest list: same left category strip width/treatment, same `.listRowBackground(Color(.systemGray6).opacity(0.2))`, same listRowInsets feel, same chevron affordance (NavigationLink provides the chevron automatically).
   - Reuse the visual language of `AirportRowView` where it makes sense (airport name line, ICAO/IATA, the wind/conditions summary line that Nearest shows). The screenshots show Nearest displays "CLR · 10+SM · 180@19G30" as a conditions line — bring that same conditions summary into the alert row so the two lists read as siblings.
   - KEEP the alert-specific elements layered on top: the GO/NO-GO verdict badge (right side), the failing-factors line when NO-GO, and the "via METAR · 23 min ago" freshness line. These are what make it an Alerts row vs a Nearest row.

## COLOR AXIS — must preserve (do not regress)
The current WatchRow already separates the axes correctly. Keep it that way:
- Left strip = flight CATEGORY color (VFR green / MVFR blue / IFR red / LIFR magenta) — category axis only.
- GO/NO-GO badge = verdict axis (red NO-GO / green GO) — must stay distinct from the category strip.
- Any crosswind/wind text (e.g. "Rwy 12L crosswind 22 kt over 15 kt") = WIND axis, amber/red only.
- Do not let these three axes share colors. This is foundational — verify after the change.

## Build / commit
- Build-verify: `xcodebuild -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" build 2>&1 | grep -E "error:|BUILD" | tail -5`
- Commit points: (a) tap-to-detail navigation working, (b) visual consistency pass.
- No `#` in terminal commands; single-line, chain with && or ;.

## Files expected to change (track for records)
- MetarMate/Views/AlertsView.swift (WatchRow rework + NavigationLink)
- Possibly MetarMate/Views/SharedComponents.swift (if AirportRowView needs a variant/param to support the alert context)
- Read-only ref: NearestAirportsView.swift, AirportService.swift


---

## Follow-up (decided): fix ceiling coverage code on the alert row
The first pass built the conditions summary from `AlertConditions`, which normalizes away cloud coverage and stores only ceiling HEIGHT. Result: the row shows "BKN NN" generically even when the real METAR is OVC. This is a display correctness issue in a pilot tool (OVC vs BKN is operationally meaningful), so fix it:

- Thread the actual coverage through `WatchDisplay` — either the source `Metar`, or at minimum the worst-layer coverage string (e.g. "OVC"/"BKN"/"SCT") plus its height.
- The alert row's conditions summary must then show the TRUE coverage code from the observation, matching what the airport detail view and the raw METAR show.
- Do NOT synthesize a placeholder coverage code. Showing a generic-but-wrong "BKN" is worse than showing height alone. If for some reason coverage is genuinely unavailable, show height without a coverage prefix rather than a guessed prefix.
- Verdict/go-no-go logic is unaffected (it keys off ceiling height, which AlertConditions already has). This is display-only.
- Commit as its own change after build-verify.

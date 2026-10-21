# Handoff: Nearby-TAF fallback (with TAF time-logic fix first)

**Branch:** `feat/nearby-taf`, off `fix/launch-hardening-a1` @ `1821b68` (A1 not merged yet; rebase onto the release line once it is).
**Read first:** `docs/DECISIONS_2026-10.md` #4, #13–17 (binding), `docs/LAUNCH_CHECKLIST.md` section 4b, `claude/AUDIT_2026-10-12_full_codebase.md` #13, #14 and the Oct 16 addendum.
**Scope:** launch-blocking. Decisions are final (Jeff, Oct 21). If something isn't covered by DECISIONS, stop and ask; a code fix must not double as a product ruling.

## Ground rules
- **Phase 0 first:** read-only report on the current code (it has moved since the audit), plus your plan and commit sequence. **No code changes until Jeff approves the plan.**
- Re-verify every audit finding against HEAD before changing anything.
- One commit per step, staged by explicit paths. Before each commit: build Debug and Release, and run the full suite:
  `xcodebuild test -scheme MetarMate -destination "platform=iOS Simulator,name=iPhone 17" -parallel-testing-enabled NO`
- Show diffs inline, report hashes, **don't push**.
- Tick items in `docs/LAUNCH_CHECKLIST.md` section 4b (and A2 #13/#14) in the same commit as the work.
- Commands for Jeff: single line, `&&`/`;` chained, no `#` characters.
- Color axis: green/blue/red/magenta are flight category only (green also verdict). Amber for warnings. Advisory = orange accent + dashed border. **No color encodes TAF distance.**
- Never stage `tools/madis/` or `MetarMate_Project_State.md`.

## Step 1 — TAF time logic (audit #13, #14)
One helper answers "what is forecast at time t" and everything uses it.
- **Prevailing conditions at t:** the base/FM period covering t, with BECMG changes applied once their window ends (BECMG currently never becomes prevailing).
- **Overlays separate:** TEMPO/PROB covering t returned alongside, never merged into prevailing.
- **Validity:** a TAF past `validTo`, or a period past its `toTime`, is never "current" (`Taf.isValid` exists but has no callers).
- Use it in: `Taf.currentForecast`, ForecastTrend (compare prevailing, not TEMPO/PROB), `TafVerification` (score against the prevailing period at each obs time, not expired TEMPOs), `TafHeroBrief` (narrate from the period covering now, not the first base period).
- **#14:** TAF category with one axis unknown is unknown, not VFR; clouds are carried into overlays.
- Tests: period selection at boundaries, BECMG before/during/after, TEMPO not leaking into prevailing, expired TAF, PROB30 TEMPO keeps its probability.

## Step 2 — Find the nearby TAF
- Trigger: the field's TAF request returns 204 (`WeatherError.noContent`) in `WeatherViewModel.loadMETAR`, including the 3-char LID retry path, and in `FlyingWeatherIntent` (line ~104).
- One request: `taf?bbox=lat0,lon0,lat1,lon1&format=json`. **Order is lat,lon** (verified Oct 21: lon,lat returns 204). Size the box to cover 50 nm (≈0.83° lat; lon scaled by cos(lat)).
- Response gives `icaoId`, `name`, `lat`, `lon`, `elev`, `validTimeFrom/To`. **`elev` is meters** (KLAS reads 662 = 2,181 ft): convert before the elevation caution.
- Field position and elevation from `airports.json`. Great-circle distance in nm; bearing from field to TAF station as 8-point compass ("SW").
- Pick the nearest station within 50 nm whose TAF is still valid. None → "No TAF within 50 nm", as today's empty state with that wording.
- Carry a source record (station, name, distance, bearing, elevation difference ft, borrowed: yes/no) with the TAF so every consumer can label it.
- Report in Phase 0, don't fix: `WeatherService.fetchNearbyMetars` builds its bbox as lon,lat (always 204) and has no callers.

## Step 3 — Show the substitution (D#14, #17)
- Forecast card's **first line**: "**No TAF for KBVU** · using **KHND** (13 nm W)". Not a caption.
- Whole borrowed-TAF card gets the existing advisory treatment (dashed border, orange accent). Reuse the advisory components; don't invent a new style.
- Distance wording:
  - ≤10 nm: the substitution line only.
  - >10–25 nm: add "TAF site 13 nm away. Local conditions may differ."
  - >25–50 nm: stronger caution, e.g. "TAF site 38 nm away. Conditions here may be quite different." Propose exact wording in Phase 0.
- Elevation difference ≥1,000 ft: "TAF site is 1,200 ft higher/lower", on top of any tier.
- Wherever TAF-derived text appears (trend forecast section, TafHeroBrief, Pilot Notes TAF items), name the station when borrowed.

## Step 4 — Verification against the TAF station (D#15)
- Fetch the TAF station's own 6 h METAR history; TAF accuracy and the Forecast Deviation Strip compare the TAF station's forecast with **its own** METARs.
- Label: "KHND forecast vs KHND actual". Never compute against this field's METAR.

## Step 5 — "Right now" row (D#16)
- This field's current METAR beside the TAF station's (category, ceiling, vis, wind).
- Warn only if this field is worse: lower category, ceiling >300 ft lower, vis >0.5 SM lower, or wind/gust >5 kt higher. Text: "Conditions here are worse than at the TAF site" (amber). If better or equal: no message.
- Either METAR missing or older than 75 min: say which ("KHND report not current") and make no comparison.
- Missing fields never become numbers (D#2).

## Step 6 — Widget and Siri
- Widget: anywhere it shows TAF accuracy or forecast deviation for a borrowed TAF, label the station. Propose the compact form in Phase 0.
- Siri: "There's no TAF for Boulder City. The forecast from Henderson, 13 miles west, shows…". Coordinate with the D#4 Siri age wording; don't implement the rest of Siri #25 here.

## Step 7 — Military TAF parsing
- The fallback pulls more stations, including military (KLSV, KINS nearby). Verify `TafParser` handles `QNH2992INS`, `TX25/2120Z TN12/2212Z`, and anything else in live KLSV/KINS/KNKX TAFs. Add fixtures.

## Tests (beyond step 1)
Nearest selection, 50 nm cap, expired-TAF exclusion, meters→feet, bearing, tier wording at 10/25/50 boundaries, elevation caution, verification uses the TAF station's METARs, Right-now thresholds and the not-current case.

## End: device checklist for Jeff
- KBVU → KHND (~13 nm W): substitution line, 10–25 nm caution, Right-now row, compare with ForeFlight.
- A field 25–50 nm from its nearest TAF, and one with none within 50 nm.
- KVGT: has its own TAF since Oct 21; must look exactly as before.
- Siri on a borrowed-TAF field.

# Device check — Oct 21, 2026 (A1 open items + nearby-TAF 4b, on the Siri hands-free base)

One install, one pass, in this order. Tick each box; note anything that differs from "Correct" with the time (Z) and a screenshot.

Install: Xcode → Run (Debug) on the iPhone, from `feat/nearby-taf` at the commit that adds this file. It is built on `origin/feat/siri-hands-free` @ `612dea3`, which contains all of A1 (including `23ebb56` widget reload on the station's interval and `2531a18` harness footer) plus the Siri hands-free work; the nearby-TAF work is on top. The Siri hands-free device check in `docs/handoffs/SIRI_HANDS_FREE_handoff.md` can run on this same install. Debug is needed for the age override (item 13); the harness opens with five taps on the "METAR Injection — tap 5×" chip at the bottom of Favorites.

Live weather changes during the day, so categories and wording that depend on it are given as rules, not fixed text. Distances, bearings and station choices are fixed (computed Oct 21 from NOAA's positions).

Decision numbers are `docs/DECISIONS_2026-10.md`; "Oct 21 ruling" means the nearby-TAF Phase 0 rulings recorded there (`f299bfc`, `60b40ed`, `4717d0e`); "audit #" is the Oct 12 audit (launch checklist section 2/3).

## A. Setup

- [ ] **1. Install and first launch.** Run from Xcode, then stop the debugger and launch from the home screen. Allow notifications. Note the time (Z).
  - Correct: launches normally; Favorites shows; no crash.
  - Checks: baseline for 14–16.

## B. Nearby-TAF on the detail screen (4b)

For each field: search the ident, open it, and look at the Forecast · TAF card, the Trend card and Forecast Reliability. Compare the borrowed station and distance with ForeFlight's TAF for the same field.

- [ ] **2. KVGT — has its own TAF (unchanged).**
  - Correct: no "No TAF for …" line, no dashed orange border, no Right-now row. Hero may say "now" ("VFR now, …"); the current period row is tagged "now". "TAF PILOT NOTES" and "TAF vs ACTUAL" without a station name; Forecast Reliability without "… forecast vs … actual".
  - Checks: D#13 (the field's own current TAF always wins).

- [ ] **3. KBVU → KHND, 13 nm W.** Also add KBVU to Favorites (Siri's "…at KBVU…" phrases match favorites; item 12).
  - Correct:
    - First line of the forecast card: **No TAF for KBVU** · using **KHND** (13 nm W), with "TAF site 13 nm away. Local conditions may differ." in amber under it. No elevation line (KHND is ~280 ft higher).
    - The whole card (hero, period rows, Pilot Notes, Raw TAF) has the dashed orange border. Nothing about distance is green, yellow or red.
    - RIGHT NOW: KBVU and KHND, each with category, ceiling, vis, wind and age. "Conditions here are worse than at the TAF site" only if KBVU is worse (lower category; ceiling >300 ft lower with KBVU's ceiling at or below 5,000 ft; vis >0.5 SM lower unless both >5; sustained or gust >5 kt higher). If KBVU is the same or better: no message. A missing item reads "… not reported at …".
    - Hero starts "KHND forecasts …" and never says "now". If KBVU's category is lower than KHND's current forecast period, it starts "KBVU is IFR now. KHND (13 nm W) forecasts …".
    - Current period row tagged "current". "TAF PILOT NOTES · KHND".
    - Trend: OBSERVED is KBVU's. "KHND FORECAST vs KHND ACTUAL" over the deviation lines; "FORECAST · KHND TAF vs KHND NOW"; the summary is two sentences ("Conditions here have been …. KHND's forecast is …."), never one blended sentence; the footnote reads "KHND forecasts conditions to be …".
    - Forecast Reliability: "KHND forecast vs KHND actual".
    - ForeFlight shows KHND as the nearest TAF too.
  - Checks: D#13, D#14, D#15, D#16, D#17 (≤25 nm tier); Oct 21 rulings (forecast trend from KHND's METAR, hero never "now", no blended trend).

- [ ] **4. KBCE → KCDC, 45 nm W (or KIGM → KIFP, 31 nm W).**
  - Correct:
    - KBCE: "TAF site 45 nm away. Conditions here may be quite different." and "TAF site is 2,000 ft lower." Both in amber.
    - KIGM instead: "TAF site 31 nm away. Conditions here may be quite different." and "TAF site is 2,800 ft lower."
    - Everything else as in item 3 with that station. If the field's category is lower than the station's current forecast period, the hero leads with the field ("KBCE is IFR now. KCDC (45 nm W) forecasts VFR, …").
  - Checks: D#17 (25–50 nm tier, elevation caution ≥1,000 ft), D#16, Oct 21 rulings (hero leads only on a lower category).

- [ ] **5. KTMT (Austin, NV) — no TAF within 50 nm.**
  - Correct: no forecast card at all. The Trend card's FORECAST section reads "No TAF within 50 nm." No borrowed station anywhere.
  - Checks: D#17 (over 50 nm: no TAF shown).

- [ ] **6. Refresh while borrowing.** On KBVU, pull to refresh, then wait 5+ minutes and come back.
  - Correct: still borrows KHND, same line. (Pull-to-refresh re-runs the nearby lookup; the 5-min auto refresh reuses it for 10 min. The field's own TAF is requested every time.)
  - Checks: D#13.

## C. Widgets

Your existing KVGT medium widget stays as it is (it's the A1 refresh-timing widget for item 15).

- [ ] **7. KVGT medium widget unchanged.**
  - Correct: no orange "No TAF …" line; "TAF nn%" without a station; deviation lines without a "… fcst vs actual" header.
  - Checks: D#14 (labels only for a borrowed TAF).

- [ ] **8. Second medium widget set to KBVU.** Open KBVU in the app once (item 3 did this; do it again if more than ~an hour has passed), then add a second medium widget and set its airport to KBVU.
  - Correct: under the conditions, in orange: "No TAF for KBVU · using KHND (13 nm W)". "KHND TAF nn%" at the bottom right. If there are deviation lines, "KHND fcst vs actual" above them. A forecast-driven headline reads "Deterioration Forecast · KHND TAF" / "Improvement Forecast · KHND TAF"; other headlines unchanged.
  - Checks: D#14 (same wording in the widget), D#15 (labeled "KHND … vs KHND …"), Oct 21 ruling (widget "Fcst" headline names the station).

- [ ] **9. KBVU widget after the next KBVU report, without opening the app.** KBVU reports every 20 min (:15, :35, :55), so the widget asks for a reload ~24 min after each report (report + 20 + 4 min, e.g. 1855Z report → ~1919Z), then every 10 min until a newer one. Wait for that refresh.
  - Correct: the new conditions show within ~24–34 min of the previous report, not an hour later. The KHND line, "KHND TAF nn%", deviation lines and the forecast headline disappear (the app hasn't analysed this report yet). Nothing borrowed ever shows without the KHND label. Opening KBVU in the app brings them back.
  - Checks: D#14, A1 audit #1 (trend/TAF/deviation reused only for the same observation), A1 `23ebb56` (reload on the station's own interval).

- [ ] **10. Small and lock-screen widgets (if you use them), set to KBVU.**
  - Correct: small — a forecast-driven trend reads "KHND Fcst: Down/Up". Lock-screen rectangular — no "TAF nn%" for KBVU (no room to name the station); KVGT's still shows "TAF nn%".
  - Checks: D#14.

- [ ] **11. Refresh button.** Tap the refresh arrow on the KVGT medium widget.
  - Correct: the widget refreshes within a few seconds (observation time updates if a newer report exists); no reload loop; the app doesn't open. `widget.diag` gets a new line for the run (item 16).
  - Checks: A1 audit #1 (refresh intent without `reloadAllTimelines()`).

## D. Siri

- [ ] **12. Siri on a borrowed field.** "Check flying weather at KBVU with MetarMate" (KBVU is a favorite from item 3), or "What's the weather at Boulder City in MetarMate".
  - Correct: no list or "Which one?". Starts with the report age and KBVU's own conditions: "As of 12 minutes ago, Boulder City Municipal is VFR. …" (65–75 min: "The latest Boulder City Municipal report is 68 minutes old. Boulder City Municipal was VFR."; over 75: "There's no current METAR for Boulder City Municipal. …" and nothing else). If KBVU has enough history for an observed trend (usual), it ends "Conditions are …" and says nothing about a TAF. Only if it voices forecast content does it end "There's no TAF for Boulder City Municipal. The forecast from Henderson Executive, 13 miles west, shows conditions …". It never voices KHND's forecast as Boulder City's. The card reads "KBVU · Boulder City Municipal" with the age first ("12 min ago · …").
  - Checks: D#14 (same wording in Siri), D#4 (spoken report age), Oct 21 ruling (borrowed-TAF sentence only when voicing forecast content).

## E. Debug-attached and timed checks

- [ ] **13. Late / no-current widget states via the DEBUG age override, then Off.** Harness (5 taps on the Favorites chip) → ④ Widget report age. For each of 66, 74, 76, 130, 725: pick it, tap "Apply to widgets", tap the KVGT widget's refresh arrow, look at medium, small and lock-screen widgets.
  - Correct: 66 and 74 — conditions still shown, with "METAR late: 66 min old" (medium) / "LATE 66m" (lock-screen rectangular), orange. 76 — "No current METAR", conditions withheld, "Last report 1 h 16 min ago". 130 — "Last report 2 h 10 min ago". 725 — "Last report 12+ h ago". **Then set "Off (real age)", Apply, refresh: widgets back to the real age.**
  - Checks: D#4 (late 65 through 75, no current over 75; same in widgets and lock screen), A1 `e929f3c`, `2531a18` (footer says over 75).

- [ ] **14. Background alert run (debugger attached).** In the app, add an airport watch (Alerts) on a field near a minimum if possible. Attach Xcode's debugger to the running app, background the app, pause, and run in the lldb console:
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.jeffquayle.MetarMate.alertcheck"]`
  then continue.
  - Correct: the check runs and completes (console shows the alert run and the task completing), no crash or 0xdead10cc. A notification appears only if a watch's verdict changed. The verdict comes from the METAR only, never 5-minute data.
  - Checks: D#1 (alerts METAR-only), A1 audit #2 (no store save after cancel; container opened only when there's work).

- [ ] **15. Widget refresh timing after `20aad2a` and `23ebb56`.** Leave the phone alone (locked, not opening the app) across at least two :53 METAR times. Then pull `widget.diag` from the App Group (`group.com.jeffquayle.MetarMate`) preferences, as on Oct 21.
  - Correct: each fetch line now ends with the measured interval ("ok obs 221853Z every 60m"; the KBVU widget from item 8 shows "every 20m"). KVGT (hourly): each new report picked up within ~15 min of :53 (a run at obs + 64 min, then every 10 min until a newer report, then every 30 min). KBVU: a run at obs + 24 min, then every 10 min. A line with "every ?" (one report, or a gap outside 10–70 min) falls back to hourly. No "No current METAR" while a newer report exists.
  - Checks: A1 `20aad2a` (reload scheduling), `23ebb56` (station interval), D#4.

- [ ] **16. Cold launch after suspension.** Background MetarMate, lock the phone, leave it 30+ min (or open several heavy apps), then launch MetarMate from the home screen. Repeat once from a widget tap.
  - Correct: launches straight into the app, no crash. Settings → Privacy & Security → Analytics & Improvements → Analytics Data has no new MetarMate crash log, and none with 0xdead10cc.
  - Checks: A1 audit #2 (SwiftData store opened only from window content).

## F. Wrap-up

- [ ] **17. Results.** Note pass/fail per item in `docs/LAUNCH_CHECKLIST.md` (section 2 device checks; 4b device check). Keep `backup/nearby-taf-pre-rebase` and `backup/nearby-taf-pre-siri-rebase` local until this passes.

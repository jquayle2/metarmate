# MetarMate — Launch Checklist

**Single source of truth for everything between now and App Store release.**
Started Oct 21, 2026. Release line: `feat/trend-time-spine` (build 1.2 (21)).

How this list is maintained:
- Claude (chat) or Claude Code updates it at the end of any session that changes status, in the same commit as the work where possible.
- Check an item only when it's verified (built, tested, or confirmed by the named person). Not just "code written".
- Refs: `#n` = `docs/AUDIT_2026-10-12_full_codebase.md`, `D#n` = `docs/DECISIONS_2026-10.md`.
- Owner tags: **[Jeff]**, **[Code]** (Claude Code), **[Claude]** (chat).

---

## 0. Decisions needed before scope is final [Jeff]

- [x] **ASOS Updates at launch or after?** At launch (Jeff, Oct 23). Section 6 is now on the critical path.
- [x] **Pro at launch or after?** At launch (D#18, Oct 21). Section 4's Pro gating is launch-blocking.
- [x] **Pro scope** (D#19–20, Oct 21): Pro = widgets, unlimited custom minimums profiles, alerts, Siri, layout, Watch; $5.99 one-time, Family Sharing. Free = starter-profile verdicts, crosswind calculator, favorites.
- [ ] **ASOS Updates subscription price** (D#21): set against Synoptic cost and category norms.
- [x] **Nearby-TAF fallback (D#13–17): at launch** (Oct 21). Build items in section 4b.
- [x] **Siri staleness rule** (D#4, Oct 21): Siri always speaks the report age, says when it's late, and calls it stale with no conditions over 75 min.
- [ ] **P3 triage:** which items in section 5 are launch-required. Recommendation sent Oct 23; the data-integrity P3 items are staged as A2 step 5, pending Jeff's OK.
- [ ] **Proxy hosting** for ASOS: Cloudflare Worker (proposed) or other. Oct 23: Jeff proposed calling Synoptic directly from the app to start; open until the token-in-binary tradeoff is settled.

## 1. Product rulings [Jeff]

Oct 21: Jeff confirmed all rulings in `docs/DECISIONS_2026-10.md` himself; the Mike packet is dropped.

- [x] D#2 CHECK for unevaluated minimums, no "back within minimums" alert
- [x] D#3 VRB worst-case crosswind; CHECK when it decides the outcome
- [x] D#4 Staleness: late 65 min, no verdict over 75 min
- [x] D#5–7 Warn-never-reassure (never NO-GO→GO), displayed-gust rule, label "ASOS 5-min · supplemental"
- [x] D#8 ½ gust factor, with the stated wording
- [x] D#9–12 5 kt crosswind floor, symmetric missing notes, F17 hazards, PROB TSRA in headline
- [x] D#13–17 Nearby-TAF: 50 nm cap, substitution headline + advisory styling, 10/25/50 nm wording tiers, elevation caution (design agreed Oct 21; launch scope still open)

## 2. A1 — launch hardening P0s (`fix/launch-hardening-a1`)

Code done: 7 commits (`d28cbab`…`1fe5edc`), builds, 58/58 unit tests. Pushed, not merged.
- [x] Widget reload loop removed; refresh intent no longer calls `reloadAllTimelines()` (#1)
- [x] Widget fetch: no URL cache, 10 s timeout (#1)
- [x] Late (65 min) / no-current (75 min) states in every widget family, from observation time (#1, #17, D#4)
- [x] Trend/TAF/deviation reused only for the same observation (#1)
- [x] SwiftData store opened only from window content; open logged with app state (#2)
- [x] ASOS free period removed; hard-coded Synoptic token deleted (#3)
- [x] Alerts are METAR-only (D#1)
- [x] **Unconfigured widget fetches live** (falls back to the last-viewed ICAO). Found Oct 21: an unconfigured widget never fetched. `9fa71fa` [Code]
- [x] **`widget.diag` breadcrumb**: last 40 provider runs (time, kind, ICAO, configured/fallback, fetch outcome) in the App Group. `b8a732c` [Code]
- [x] No-current boundary is "over 75" (76+ whole minutes), matching D#4. `e929f3c` [Code]
- [x] Reloads scheduled to the report cadence (obs+64, retry 10 min to obs+2 h, then 30 min) instead of a fixed 15 min; Oct 21 diag showed the configured widget getting 30–80 min reloads and briefly showing "No current METAR" with a newer report available. `20aad2a` [Code]
- [x] Device check: widget refreshes on its own without opening the app. Oct 21 diag: 31 runs from 17:41Z, all fetches OK, 1753Z/1853Z/1953Z picked up unaided [Jeff]
- [x] Reloads follow each station's own interval, measured from its two newest routine METARs (KBVU 20 min: reload at obs+24; hourly: obs+64; unknown: hourly). `23ebb56` [Code]
- [ ] Device check after `20aad2a`: new report shows within ~15 min of each report on the configured widget, and a KBVU widget picks up its :15/:35/:55 reports (pull `widget.diag`) [Jeff]
- [ ] Device check: refresh button [Jeff]
- [ ] Device check: late / no-current states via the DEBUG age override, then set it back to Off [Jeff]
- [ ] Device check: background alert run (debugger attached) [Jeff]
- [ ] Device check: cold launch after suspension, no 0xdead10cc [Jeff]
- [ ] Merge A1 into `feat/trend-time-spine` [Jeff]

## 3. A2 — missing data never shown as a value; verdict logic [Code]

Handoff: `docs/handoffs/A2_MISSING_DATA_handoff.md` (branch `fix/a2-missing-data`, off `feat/nearby-taf`).

- [ ] #4 Go/no-go tri-state: unevaluated minimum → CHECK, never GO; no "back within minimums" alert (D#2)
- [ ] #5 VRB worst-case crosswind (D#3)
- [ ] #6 Unknown sky ≠ unlimited ceiling
- [ ] #7 Staleness gate on verdicts (D#4)
- [ ] #8 / F15 Missing temp/dewp/altim are optional, not 0 °C / 29.92 (density altitude, pressure trend, fog, app-written widget snapshot)
- [ ] #9 Visibility trend against "10+" (P6SM); `.unknown` not `.steady` when both axes unknown
- [ ] #10 Missing wind direction/speed not reported as 000° / 0 kt
- [ ] #11 Red-tier crosswind not hidden under "Red only" Pilot Notes
- [ ] #12 Missing cloud base not 0 ft
- [x] #13 TAF: one "period covering time t" helper (overlays, expired periods/TAFs, BECMG, TafHeroBrief)
- [x] #14 TAF category with one axis unknown; clouds into overlays
- [ ] #15 Missing `obsTime` not `Date()`
- [ ] #16 Unknown shown as good (green rail, "Clear", "Fcst on target", wind-only "Steady")
- [ ] #18 Category boundary drift (`cloudLayerColor`, Synoptic LIFR, ASOS/advisory category)
- [ ] #19 TAF Pilot Notes: strong steady winds and overlay gusts
- [ ] #20 Gust approach speed = ½ gust factor, one shared function (D#8)
- [ ] Density altitude includes humidity (virtual temperature from the dewpoint); dry-air formula only when the dewpoint is missing; one shared function (also closes the "two DA formulas" P3 item). Oct 22: KIGM 19/13 A2996 elev 3,449 showed 4,706 ft vs ForeFlight 4,884 ft; the humid calculation gives 4,871 ft
- [ ] Starter-profile verdicts labeled with the profile ("GO vs VFR day starter") (D#19)
- [ ] D#10 symmetric missing-field notes; D#11 F17 hazards in history; D#12 PROB TSRA in headline
- [ ] F16 present-weather chip off the category red; F18 "Clear" with only FEW/SCT
- [ ] Unit tests for the gaps listed in the audit (DensityAltitude, trends, TafVerification, `currentForecast`, BECMG, advisory category, parser missing-field cases)
- [ ] Merge A2 [Jeff]

## 4. A3 — App Review blockers, Pro gating, Siri [Code]

Handoff: `docs/handoffs/A3_RELEASE_handoff.md` (branch `fix/a3-release`, worktree `MetarMate-a3`, off `feat/nearby-taf`). Siri items below were done on `feat/siri-hands-free`.

App Review blockers (required regardless of section 0):
- [x] #21 Test harness compiled out with a `TESTFLIGHT` flag set only on TestFlight archives (2.2 rejection risk). New build configuration **TestFlight** (Release + `TESTFLIGHT`) and shared scheme **MetarMate TestFlight**, which archives with it. App Store archives use scheme **MetarMate** (Release). Built Release binary: 0 harness symbols or strings; TestFlight and Debug still carry it
- [ ] #21 TestFlight builds say "TestFlight" on a version line (Jeff, Oct 23). There's no About/settings screen yet; placement pending Jeff
- [x] #21 Add a UI test that the harness entry chip is absent in a Release (App Store) build [Code]. `HarnessAbsentUITests`: forces the runtime gate open, then the chip is present in Debug/TestFlight and absent in Release (all three run)
- [x] #22 Privacy manifest: app declares UserDefaults (CA92.1, 1C8F.1); widget extension has its own manifest (1C8F.1). Both verified in the built bundles; no other required-reason APIs in use. `7fb7c29`
- [ ] #23 SwiftData `VersionedSchema` V1 + migration plan; no `fatalError` on container failure
- [x] #28 Info.plist: drop unused `processing` background mode, Siri entitlement / `NSSiriUsageDescription`; location accuracy matches coarse declaration. `27a04d6`. Verified in the built bundle; the App Shortcut still runs from the Shortcuts app in the simulator without the entitlement (voice Siri on device: see the A3 device list)

Pro gating (launch-blocking; scope in D#19–20):
- [ ] #24 Siri waits for entitlements before reading `isProUser`
- [ ] #24 Lock-screen widgets gated
- [ ] #24 StoreKit listener started in `App.init`
- [x] #24 ASOS product IDs requested only when `FeatureFlags.asosAvailable` is on. `49dd6d5`
- [ ] Favorites stay free: remove the Pro check on the detail-view star; retire `FeatureFlags.favoritesRequirePro`
- [ ] Widgets Pro: `WidgetDataManager.widgetsRequirePro = true` (home and lock screen)
- [ ] Custom minimums profiles Pro: creating/cloning/editing a non-built-in profile requires Pro; free users can select the built-in starters only
- [ ] Alerts Pro: creating an airport watch requires Pro; existing watches of a lapsed/refunded user stop with a clear message
- [ ] Crosswind calculator free: remove any Pro gate on it
- [ ] Layout customization Pro
- [ ] Paywall screen: lists what Pro adds; restore purchases; $5.99 shown from StoreKit (never hard-coded)
- [ ] Beta-tester migration: TestFlight users on Pro features get offer codes before the gate goes live
- [ ] TestFlight testers get Pro via offer codes (D#20)

Siri (#25) — handoff `docs/handoffs/SIRI_HANDS_FREE_handoff.md`, branch `feat/siri-hands-free`:
- [x] Use location instead of prompting "Which airport?" (Oct 22 device test: no-airport phrase prompted with a list; location is only used after cancel). No prompt; location off or unavailable gives spoken guidance, no list. `5b13947`
- [x] Airport suggestions: favorites, then nearest METAR stations by distance; no non-METAR strips (Oct 22 list was 06NV, 07NV, 0CL3… from the snapshot cache). `06a87ca`
- [x] Spoken name match: METAR stations only, ranked ident → favorites → distance; one result when clear, so no "Which one?" tap (Oct 22: "Kingman" offered KIGM and 9K8 Kingman, KS). `06a87ca`
- [x] Name match includes city ("Las Vegas" finds KLAS); with a match within 50 nm, matches beyond 150 nm are dropped (no KLVS near Las Vegas). Several local fields still ask "Which one?" (accepted). `a5ce1cb`
- [x] Result card says "No ceiling", not "Sky clear", when only FEW/SCT are reported (Oct 22, KIGM FEW055 SCT100). "Sky clear" only for CLR/SKC; no cloud group says "Sky not reported" (audit #6). `2173fb7`
- [x] Phrases led by the app name so Siri doesn't route to Apple Weather; favorites registered via `updateAppShortcutParameters()` so "…at KVGT…" matches. `8606c81`
- [x] Nearest fallback picks the nearest airport that reports a METAR (searches 25, not 1). `eadefa0`
- [x] 3-character LIDs (CMA, 36K) resolve via `noaaCandidate` (CMA → KCMA; 36K fetched as K36K). `5b13947`
- [x] `O→0` rewrite replaced: the spoken code is tried as heard, then with the leading O/0 swapped, preferring a METAR station (O22, OK36 and 0L7 all resolve). `eadefa0`
- [x] Siri speaks the report age on every answer; "late" at 65–75 min; over 75 min says stale, no category/conditions/verdict (D#4). Same boundaries as the widget. `2173fb7`
- [ ] Device check, hands-free with no touch: nearest, a favorite by ident, the new app-name phrase, location off [Jeff]

Background task (#26):
- [ ] Expiry handler stops the work; no save after cancel
- [ ] Synoptic calls: short timeouts, not sequential
- [ ] MainActor isolation of the handler
- [ ] Watch `expiresAt` enforced

Other:
- [ ] #27 Favorites reconcile with `airports.json` at launch
- [ ] Merge A3 [Jeff]

## 4b. Nearby-TAF fallback — launch (D#13–17) [Code]

Handoff: `docs/handoffs/NEARBY_TAF_handoff.md` (branch `feat/nearby-taf`).

- [x] Step 1: TAF time logic, audit #13/#14 ("period covering time t" helper; no expired periods/TAFs, overlays kept separate, BECMG applied, unknown axis not VFR). Also closes those two A2 items.
- [x] When the field's TAF request returns 204, one `taf?bbox=` request around the airport; pick the nearest TAF within 50 nm
- [x] Forecast card headline is the substitution: "No TAF for KVGT · using KLAS (9 nm SW)"; advisory styling (dashed border, orange accent); no green/yellow/red for distance
- [x] Distance tiers in wording: ≤10 nm line only; 10–25 nm "local conditions may differ"; 25–50 nm stronger caution; >50 nm no TAF
- [x] Elevation caution at ≥1,000 ft difference, on top of any tier
- [x] TAF accuracy and Forecast Deviation Strip computed against the TAF station's own METARs, labeled "KLAS forecast vs KLAS actual"
- [x] "Right now" row: this field's METAR beside the TAF station's; warn only if this field is worse (category lower, ceiling >300 ft lower, vis >0.5 SM lower, wind/gust >5 kt higher); no comparison if either METAR is missing or not current
- [x] Same substitution wording in the widget and Siri
- [x] Military TAF groups parse (`QNH…INS`, `TX/TN`) since the fallback pulls more stations
- [x] Unit tests: nearest selection, 50 nm cap, tier wording, verification against the TAF station
- [ ] Device check against ForeFlight: KBVU (→ KHND, ~13 nm W), a field 25–50 nm from its nearest TAF, a field with none within 50 nm, and KVGT (has its own TAF since Oct 21) unchanged [Jeff]

## 5. P3 polish — triage in section 0 first

- [ ] Green outside category/verdict (calm wind, steady wind, `ForecastStripColumn`, `TrendDirection.color`, accuracy colors, `spreadColor`, widget `trendColor`)
- [ ] Crosswind calculator: tiers unused, tailwind limit text, tailwind uses sustained only, gust carries over between sessions
- [ ] Trend arrow up for steady/unknown; VoiceOver "improving or stable" for unknown; LIFR folded into IFR on TAF ribbon; VV labelled "Broken"
- [ ] Accessibility: airport rows show category by color rail only, no text, no age
- [ ] Performance: `DateFormatter` in view bodies; `pilotNotes()` and density altitude computed twice per render
- [x] UI test target: template tests removed (`16f53c0`); full suite runs clean with `-parallel-testing-enabled NO` (parallel clones were refused launch); simulator `iPhone 17` re-created on iOS 26.1 after it went missing
- [ ] Nearby-TAF bbox near the 180° meridian is clamped, not wrapped (western Aleutians search a narrower box)
- [ ] Pilot Notes: consolidate repeated notes (e.g. one "Gusts 15–28 kt" line instead of five); military TAFs produce 15+ notes
- [ ] Misc: search race, layout prefs wiped on unknown `SectionID`, Open-Meteo timeouts/cancellation, alert `force` vs METAR cache, `seedSimulated` empty trap, `M1/4SM`, ceiling `.first` vs `.min()`, two DA formulas, PROB defaults

## 6. ASOS Updates — Synoptic (launch-blocking only if section 0 says so)

Source decided Oct 21: Synoptic paid plan. New trial token (~7 days) incoming. MADIS is not being used. 5-min data never changes a verdict (D#1).
- [x] Synoptic confirms (email Oct 21): displaying values in the app is allowed; the data must not be redistributed through an API [Jeff]
- [x] Synoptic confirms in writing that our proxy (authenticated app users only, app-shaped responses, no raw passthrough) is not "redistribution through an API" [Jeff]. Email Oct 22: an API closed to our authenticated users is allowed; a redistribution API is not.
- [x] Paid plan's statement of work covers commercial display in a paid consumer app (T&C 2.2(d)(i) needs written consent for commercial use) [Jeff]. Email Oct 22: display on a monetized app is allowed.
- [ ] Signed quote states the commercial app use [Jeff]
- [x] Check contract term: T&C says 12-month term, non-refundable, 60 days' notice to terminate. Confirm whether $100/mo is billed monthly or is an annual commitment [Jeff]. Email Oct 22: annual contract at $100/mo ($1,200/yr), 60 days' notice to terminate.
- [ ] Ask whether the 5-min ASOS data is Public or Restricted Data Content [Jeff]
- [ ] Ask whether the 12-month term can start at ASOS launch [Jeff]
- [ ] Ask Synoptic on the Oct 22 call: more than one token (TestFlight vs production proxy) and rotation without downtime; ~5 min per-station caching and 6 h history fetches OK; peak wind/gust fields and typical station-to-API latency for 5-min ASOS [Jeff]
- [x] Synoptic confirms (Oct 21): no API call limits on the paid plan; trial latency = paid latency [Jeff]
- [ ] Trial token received [Jeff]
- [ ] Validation rerun with the trial token: latency, gust capture, timeouts vs the same METARs (spike harness) [Code]
- [ ] Go/no-go on paying, based on the validation [Jeff]
- [ ] Proxy built: token server-side only, StoreKit JWS verification, ~5 min per-station cache, app-shaped responses only (no raw Synoptic passthrough). Per-user quota optional now (no Synoptic call limits); keep a simple abuse cap [Code]
- [ ] Proxy deployed; deployment record kept (what's deployed, from which commit, how to redeploy) [Code]
- [ ] Rotate token after trial → paid switch; never in the app binary [Jeff]
- [ ] `SynopticService` talks to the proxy, not Synoptic [Code]
- [ ] Fix the 13 app sites flagged by the spike [Code]
- [ ] D#5–7 implemented (warn-never-reassure, displayed gust, supplemental label) [Code]
- [ ] ASOS Updates subscription products + introductory offer set up in App Store Connect [Jeff]
- [ ] Sandbox purchase → proxy → data works end to end [Jeff]
- [ ] `FeatureFlags.asosAvailable = true` [Code]
- [ ] Old Synoptic token rotated/revoked (exposed in earlier binaries) [Jeff]
- [ ] Paid plan active before the trial ends [Jeff]
- [ ] Attribution: "Data aggregated by Synoptic" linking to synopticdata.com wherever 5-min data shows (T&C Att. A item 9); Synoptic named as source on the website and in marketing (T&C 6.2(c)); no rebranding of the data [Code/Jeff]. Wording confirmed by Synoptic (email Oct 22); implementation still open.
- [x] Annual usage report to Synoptic if our tier requires it (customers, views) [Jeff]. Email Oct 22: not needed.

## 7. App Store Connect and submission [Jeff]

- [ ] Version/build bumped (app + widget, Debug + Release)
- [ ] Pro IAP (non-consumable) at $5.99 in App Store Connect, Family Sharing on, review screenshot + notes
- [ ] App name, subtitle, keywords, description
- [ ] Screenshots: 6.9" and 6.5" iPhone, 13" iPad (iPad is supported)
- [ ] App Privacy ("nutrition label") matches what the app collects (location, purchases)
- [ ] Privacy policy URL and support URL live on the marketing site
- [ ] Age rating questionnaire
- [x] Export compliance: `ITSAppUsesNonExemptEncryption = NO` in the app Info.plist (standard HTTPS only), so App Store Connect stops asking per upload. `63ada9d`
- [ ] Data attribution where required (Open-Meteo CC BY 4.0; Synoptic per license)
- [ ] Aviation disclaimer in-app and in description (supplemental, not an official briefing)
- [ ] App Review notes: how to reach each feature; demo airport; IAP notes if any
- [ ] Final TestFlight round from the release branch; tester sign-off
- [ ] Release archive built from the merged release line; tag the commit

## 8. Repo and housekeeping [Jeff / Claude]

- [ ] Decide fate of `main` (060da26, far behind): fast-forward from the release line after launch
- [ ] `MetarMate_Project_State.md` updated, committed, re-uploaded to Project knowledge
- [ ] `tools/madis/` stays untracked on non-spike branches
- [ ] Marketing site updated for launch (metarmate-site)

---

## Log
- **Oct 21, 2026:** List created. Widget "not refreshing" root-caused to an unconfigured widget (no airport set → cache only); configured to KVGT, unconfigured-fetch fix added to section 2. Synoptic chosen as ASOS source.
- **Oct 21, 2026:** Jeff confirmed all product rulings himself (no Mike packet); Synoptic as ASOS source; nearby-TAF headline/tier design agreed. A2 is unblocked.
- **Oct 21, 2026:** Pro decided: ships at launch, $5.99 one-time, Family Sharing. Free gets starter-profile verdicts and the crosswind calculator; Pro gets unlimited custom profiles, alerts, widgets, Siri, layout, Watch. ASOS subscription price still open.
- **Oct 21, 2026:** Nearby-TAF fallback moved into launch scope (section 4b).
- **Oct 21, 2026:** Siri staleness rule decided (D#4).
- **Oct 21, 2026:** KVGT and KHND now issue their own TAFs (1728Z TAFs seen); KBVU is the new nearby-TAF test field. "Worse" thresholds for the Right-now row decided. TAF time-logic fix moved to step 1 of the nearby-TAF pass.
- **Oct 21, 2026:** Widget refresh confirmed on device; reload scheduling changed to follow the report cadence (`20aad2a`).
- **Oct 21, 2026:** Synoptic replied: display OK, no API redistribution, no call limits, trial latency = paid. T&C items added to section 6 (written OK for the proxy, commercial-use SOW, 12-month term, attribution).
- **Oct 22, 2026:** Widget showed KVGT "late · 65 min" correctly at 1558Z. Siri device test at Kingman: prompts for an airport, cached-strip suggestions, "Kingman" ambiguous with 9K8 (KS), "Sky clear" with FEW/SCT, first try went to Apple Weather. Siri items and handoff added (section 4). Density altitude 180 ft low vs ForeFlight (no humidity); fix added to A2.
- **Oct 22, 2026:** Siri hands-free code done on `feat/siri-hands-free` (`2173fb7`, `5b13947`, `06a87ca`, `a5ce1cb`, `8606c81`); device check pending [Jeff]. App search now also matches city.
- **Oct 22, 2026:** Synoptic written answers (email): API closed to our authenticated users allowed (redistribution API not); display on a monetized app allowed; annual contract $100/mo ($1,200/yr), 60 days' notice; attribution wording "Data aggregated by Synoptic" → synopticdata.com confirmed (implementation open); no annual usage report. Open [Jeff]: commercial use in the signed quote, Public vs Restricted Data Content for 5-min ASOS, 12-month term starting at ASOS launch, questions for the Oct 22 call (section 6).
- **Oct 23, 2026:** ASOS Updates moved to launch scope (section 6 now critical path). Nearby-TAF code complete on `feat/nearby-taf` (device check pending). Audit doc copied into `docs/`. A2 and A3 handoffs written; `fix/a2-missing-data` and `fix/a3-release` (worktree `MetarMate-a3`) branched off `feat/nearby-taf` to run in parallel. Open [Jeff]: proxy vs in-app Synoptic token, ASOS consumer price, P3 triage.
